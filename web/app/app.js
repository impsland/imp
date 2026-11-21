// The page: Imps visiting it, as on a Mac's screen. Each one thinks at its home (docs/connecting/link.md,
// "Visit"): this page only holds its body, sends what is said to it (`ask`) and how it was touched
// (`felt`), and shows what its home sends back (looks, mood, chat, work, speech, animations).
// Everything a device sends is shown as text, never as markup.
//
// Like the Mac's home it is one plain surface. Empty, it has one button that connects a device. With Imps
// on it, a + in the corner connects another. Imps on it see each other: the page tells every device which
// Imps are here (`stage`), so their homes let them talk, and the link forwards what they say.

import { Link } from './link.js';
import { drawImp } from './pkg/imp.js';
import { ConnectSheet, findCode } from './connect.js';
import { Hand, Shake, approach, carryExit, releaseExit } from './toss.js';
import { Camera, MAX_FILES, MAX_RECORDING, Recorder, defaultWords, fromCanvas, fromFile } from './media.js';

const $ = (id) => document.getElementById(id);
const stage = $('stage');
const PLACES = 'imp.web.places';
/** The size the chat was last made, for every Imp, as the Mac keeps it. */
const CHAT_SIZE = 'imp.web.chatSize';
/** Where the chat was last put once moved or resized away from its Imp (`{ left, top }`, shares of the page). */
const CHAT_PLACE = 'imp.web.chatPlace';
/** The least the chat may be, its size until it is resized (the least: it opens small the first time), and the room
 * kept free at the page's edges (the Mac's `BubbleSizing`). */
const CHAT_MINIMUM = { width: 320, height: 320 };
const CHAT_DEFAULT = CHAT_MINIMUM;
const CHAT_RESERVE = { width: 56, height: 72 };
const IMP_SIZE = 132;
/** A press longer than this without moving is a cuddle, not a click. */
const HOLD = 500;
/** Moving less than this is still a click. */
const SLOP = 6;
/** How close to a side a carried Imp must come for its doors to show, and how far it may drift back before they go. */
const DOOR_NEAR = 200;
const DOOR_LEAVE = 240;
/** How long the doors take to fade out, in milliseconds. */
const DOOR_FADE = 220;
/** How long a hint (why it bounced, and such) stays. */
const HINT_TIME = 3500;

const params = new URLSearchParams(location.search);
const link = new Link({ name: params.get('name') || 'Web', hopSocket: params.get('hopSocket') || undefined });
const connect = new ConnectSheet(link);
/** The Imps on the page, by id. */
const imps = new Map();
/** Where each Imp stood, as parts of the page, so a reload puts it back. */
const places = JSON.parse(localStorage.getItem(PLACES) || '{}');

// ---------------------------------------------------------------- small things

function el(tag, attrs = {}, ...children) {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(attrs)) {
    if (value === null || value === undefined || value === false) continue;
    if (key === 'class') node.className = value;
    else if (key.startsWith('on')) node.addEventListener(key.slice(2), value);
    else node.setAttribute(key, value === true ? '' : value);
  }
  for (const child of children.flat()) if (child !== null && child !== undefined && child !== false) node.append(child);
  return node;
}

const PATHS = {
  close: 'M6 6l12 12M18 6L6 18',
  // Two speech bubbles, filled (the Mac's bubble.left.and.bubble.right.fill).
  // Two equal speech bubbles, the back one cut around the front one (the Mac's bubble.left.and.bubble.right.fill).
  chat: {
    fill: true,
    back: 'M13 9h6a3 3 0 0 1 3 3v3a3 3 0 0 1-3 3L19.5 21.5 15.5 18H13a3 3 0 0 1-3-3v-3a3 3 0 0 1 3-3z',
    d: 'M5 3h6a3 3 0 0 1 3 3v3a3 3 0 0 1-3 3H8.5L4.5 15.5V12H5a3 3 0 0 1-3-3V6a3 3 0 0 1 3-3z',
  },
  move: 'M12 3v18M3 12h18M9.5 5.5L12 3l2.5 2.5M9.5 18.5L12 21l2.5-2.5M5.5 9.5L3 12l2.5 2.5M18.5 9.5L21 12l-2.5 2.5',
  newChat: 'M5 4h14a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2h-8l-5 4v-4H5a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2zM12 7.5v6M9 10.5h6',
  home: 'M4 11.5L12 4.5l8 7M6.5 9.5V19.5h11V9.5',
  laptop: 'M5.5 6h13a1 1 0 0 1 1 1v8h-15V7a1 1 0 0 1 1-1zM2.5 18h19',
  phone: 'M8.5 3h7a1.5 1.5 0 0 1 1.5 1.5v15a1.5 1.5 0 0 1-1.5 1.5h-7A1.5 1.5 0 0 1 7 19.5v-15A1.5 1.5 0 0 1 8.5 3zM11 18h2',
  'back-door': 'M9 14L4 9l5-5M4 9h10.5a5.5 5.5 0 0 1 0 11H11',
  resize: 'M19 13v6h-6M5 11V5h6M19 19l-6-6M5 5l6 6',
  plus: 'M12 5v14M5 12h14',
  camera: 'M4 8.5A1.5 1.5 0 0 1 5.5 7h2l1.5-2h6l1.5 2h2A1.5 1.5 0 0 1 20 8.5v9a1.5 1.5 0 0 1-1.5 1.5h-13A1.5 1.5 0 0 1 4 17.5zM12 16a3.2 3.2 0 1 0 0-6.4 3.2 3.2 0 0 0 0 6.4z',
  mic: 'M12 3.5a2.5 2.5 0 0 1 2.5 2.5v5a2.5 2.5 0 0 1-5 0V6A2.5 2.5 0 0 1 12 3.5zM6.5 10.5a5.5 5.5 0 0 0 11 0M12 16v4',
  clip: 'M16.5 7.5l-7 7a2 2 0 0 0 2.8 2.8l7.4-7.4a4 4 0 0 0-5.6-5.6l-7.6 7.6a6 6 0 0 0 8.5 8.5l6-6',
  flip: 'M4 9a8 8 0 0 1 14.5-3M20 4v4h-4M20 15a8 8 0 0 1-14.5 3M4 20v-4h4',
  wave: 'M4 12h1M8 8v8M12 5v14M16 9v6M20 11v2',
  film: 'M4 5h16v14H4zM8 5v14M16 5v14M4 9h4M4 15h4M16 9h4M16 15h4',
  check: 'M5 12.5l4.5 4.5L19 7.5',
  info: 'M12 3.5a8.5 8.5 0 1 0 0 17 8.5 8.5 0 0 0 0-17zM12 11v5M12 7.6v.2',
  back: 'M15 5l-7 7 7 7',
  reply: 'M10 7L4 12l6 5M4 12h11a5 5 0 0 1 5 5v1',
  copy: 'M9 9h10v10H9zM5 15V5h10',
  copied: 'M5 12.5l4.5 4.5L19 7.5',
  send: 'M12 19V5M6 11l6-6 6 6',
  stop: 'M7 7h10v10H7z',
};

function icon(name) {
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');

  svg.setAttribute('aria-hidden', 'true');
  const shape = typeof PATHS[name] === 'string' ? { d: PATHS[name] } : PATHS[name];
  svg.setAttribute('viewBox', shape.box || '0 0 24 24');
  if (shape.fill) svg.setAttribute('class', 'filled');
  if (shape.back) {
    const back = document.createElementNS('http://www.w3.org/2000/svg', 'path');
    back.setAttribute('d', shape.back);
    svg.append(back);
  }
  const path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
  path.setAttribute('d', shape.d);
  if (shape.back) path.setAttribute('class', 'front');
  svg.append(path);
  return svg;
}

function toast(text, bad = false) {
  const t = el('div', { class: bad ? 'toast bad' : 'toast' }, text);
  $('toasts').append(t);
  setTimeout(() => t.remove(), 4000);
}

/** The Imp's own colour, from its hue, for the send button and the dots. */
function tint(hue) {
  const h = Math.round((((Number(hue) || 0) % 1) + 1) % 1 * 360);
  return `hsl(${h} 72% 55%)`;
}

/** Dark or light ink on the Imp's colour, whichever reads better (the Mac's `OnTint`). */
function onTint(hue) {
  const h = ((((Number(hue) || 0) % 1) + 1) % 1) * 360;
  const a = 0.72 * Math.min(0.55, 0.45);
  const channel = (n) => {
    const k = (n + h / 30) % 12;
    const c = 0.55 - a * Math.max(-1, Math.min(k - 3, 9 - k, 1));
    return c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
  };
  const luminance = 0.2126 * channel(0) + 0.7152 * channel(8) + 0.0722 * channel(4);
  // The contrast with white against the contrast with near-black ink.
  return 1.05 / (luminance + 0.05) >= (luminance + 0.05) / 0.0588 ? '#fff' : '#17181c';
}

/**
 * A reply as paragraphs, code blocks and inline code, built from text nodes only: whatever a device
 * sends is never read as markup.
 */
function formatted(text, failed = false) {
  const box = el('div', { class: failed ? 'text failed' : 'text' });
  const parts = String(text ?? '').split(/```[^\n]*\n?/);
  parts.forEach((part, i) => {
    if (i % 2 === 1) {
      box.append(el('pre', {}, el('code', {}, part.replace(/\n$/, ''))));
      return;
    }
    for (const para of part.split(/\n{2,}/)) {
      if (!para.trim()) continue;
      const p = el('p');
      for (const [j, bit] of para.split('`').entries()) {
        if (j % 2 === 1) p.append(el('code', {}, bit));
        else for (const [k, bold] of bit.split('**').entries()) p.append(k % 2 === 1 ? el('strong', {}, bold) : bold);
      }
      box.append(p);
    }
  });
  return box;
}

/** `size` within the minimum and the page, less the room kept at its edges. On a page too small, the page wins. */
function clampedChat(size) {
  const maxW = Math.max(innerWidth - CHAT_RESERVE.width, 1);
  const maxH = Math.max(innerHeight - CHAT_RESERVE.height, 1);
  const w = Number.isFinite(size?.width) ? size.width : CHAT_DEFAULT.width;
  const h = Number.isFinite(size?.height) ? size.height : CHAT_DEFAULT.height;
  return {
    width: Math.min(Math.max(w, Math.min(CHAT_MINIMUM.width, maxW)), maxW),
    height: Math.min(Math.max(h, Math.min(CHAT_MINIMUM.height, maxH)), maxH),
  };
}

let chatSize = (() => {
  try {
    return JSON.parse(localStorage.getItem(CHAT_SIZE)) || CHAT_DEFAULT;
  } catch {
    return CHAT_DEFAULT;
  }
})();

/** Where the chat was last put, in pixels of this page, or null while it was never moved off its Imp. */
function chatPlace() {
  try {
    const p = JSON.parse(localStorage.getItem(CHAT_PLACE));
    if (!Number.isFinite(p?.left) || !Number.isFinite(p?.top)) return null;
    return { left: p.left * innerWidth, top: p.top * innerHeight };
  } catch {
    return null;
  }
}

function saveChatPlace(place) {
  localStorage.setItem(CHAT_PLACE, JSON.stringify({ left: place.left / innerWidth, top: place.top / innerHeight }));
}

function savePlaces() {
  localStorage.setItem(PLACES, JSON.stringify(places));
}

// ---------------------------------------------------------------- the page around the Imps

function renderPage() {
  const empty = imps.size === 0;
  $('connect').hidden = !empty;
  $('add').hidden = empty;
}

function publishStage() {
  link.setStage([...imps.values()].map((v) => ({ imp: v.look, home: { id: v.home, name: v.homeName, kind: v.homeKind } })));
}

/** A design token's number (`--behavior-…`), or `fallback`. */
function token(name, fallback) {
  const value = parseFloat(getComputedStyle(document.documentElement).getPropertyValue(name));
  return Number.isFinite(value) ? value : fallback;
}

/**
 * The doors along a side of the page while an Imp is carried toward it, as the Mac's door signs: a band per
 * device at the heights that lead to it, with its name, the one a throw would go to lit. A side that leads
 * nowhere says so. They show only once the Imp has rested near the side for a moment (the design's
 * `desk-door-delay`), so a fling straight across an edge shows nothing.
 */
class DoorSigns {
  constructor(board) {
    this.board = board;
    this.shown = false;
    this.dwelling = null;
    this.dwelled = false;
    this.last = null;
    this.key = '';
    this.fading = null;
  }

  /** The Imp `visitor` is carried with the pointer at (x, y). */
  carried(visitor, x, y) {
    this.last = { visitor, x, y };
    const side = approach({ x, width: innerWidth, distance: this.shown ? DOOR_LEAVE : DOOR_NEAR });
    if (!side) return this.hide();
    if (!this.shown && !this.dwelled) {
      this.dwelling ??= setTimeout(() => {
        this.dwelling = null;
        this.dwelled = true;
        if (this.last) this.carried(this.last.visitor, this.last.x, this.last.y);
      }, token('--behavior-desk-door-delay-seconds', 0.5) * 1000);
      return undefined;
    }
    let doors;
    try {
      doors = link.doors(visitor.look.id, side, Math.min(Math.max(y / innerHeight, 0), 1));
    } catch {
      return this.hide();
    }
    const key = JSON.stringify([side, doors]);
    if (key !== this.key) {
      this.key = key;
      this.draw(side, doors);
    }
    clearTimeout(this.fading);
    this.fading = null;
    this.board.hidden = false;
    // The doors fade in where they are: nothing slides over from another side.
    requestAnimationFrame(() => this.board.classList.add('shown'));
    this.shown = true;
    return undefined;
  }

  draw(side, { bands, lit }) {
    this.board.className = `doors ${side}${this.shown ? ' shown' : ''}`;
    if (!bands.length) {
      this.board.replaceChildren(el('div', { class: 'nobody' }, 'Nobody here'));
      return;
    }
    this.board.replaceChildren(...bands.map((band) => {
      const on = band.id === lit;
      return el('div', {
        class: on ? 'band lit' : 'band',
        style: `top: ${band.top * 100}%; height: ${(band.bottom - band.top) * 100}%`,
      },
      el('i', { class: 'strip' }),
      el('span', { class: 'sign' }, icon(band.back ? 'back-door' : band.kind === 'phone' ? 'phone' : 'laptop'),
        el('span', {}, band.back ? `Back to ${band.name}` : band.name)));
    }));
  }

  /** Fades the doors out. Also ends a wait that has not shown them yet. */
  hide() {
    clearTimeout(this.dwelling);
    this.dwelling = null;
    this.dwelled = false;
    this.last = null;
    if (!this.shown || this.fading) return;
    this.shown = false;
    this.board.classList.remove('shown');
    this.fading = setTimeout(() => {
      this.fading = null;
      this.board.hidden = true;
      this.key = '';
    }, matchMedia('(prefers-reduced-motion: reduce)').matches ? 0 : DOOR_FADE);
  }
}

const doorSigns = new DoorSigns($('doors'));

// ---------------------------------------------------------------- an Imp on the page

class Visitor {
  constructor(look, home, { entry = null, place = null } = {}) {
    this.look = look;
    this.home = home.id;
    this.homeName = home.name;
    this.homeKind = home.kind;
    this.turns = [];
    this.work = null;
    this.brain = true;
    this.tools = true;
    this.homeConnected = true;
    this.phase = null; // null, 'typing', 'thinking', 'result', 'chat' or 'hint'
    this.hintText = '';
    this.draft = '';
    this.asking = null; // the last turn's id when something was asked here, until its answer shows
    this.showSteps = false;
    this.chats = [];
    this.currentChat = null;
    this.confirming = null; // the header button that asks again ('new' or 'home'), for three seconds
    this.moved = null; // where the bubble was dragged to, `{ left, top }`, until it closes
    this.files = []; // photos, sound and video to go with the next message (media.js)
    this.recording = null; // the microphone while a sound is recorded
    this.bubble = null;
    this.speechEl = null;
    this.root = el('div', { class: 'imp', tabindex: '0', role: 'button', 'aria-haspopup': 'dialog' });
    const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    this.root.append(svg);
    this.figure = drawImp(svg, look, { live: true, follow: true });
    stage.append(this.root);
    this.label();
    this.scale(look.scale);
    if (place) this.place(place.x * innerWidth, place.y * innerHeight);
    else this.enter(entry);
    this.grab();
    this.root.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); this.open(); }
      if (e.key === 'ContextMenu' || (e.key === 'F10' && e.shiftKey)) {
        e.preventDefault();
        const r = this.root.getBoundingClientRect();
        openMenu(this, r.right, r.top);
      }
    });
    this.droppable(this.root);
    this.root.addEventListener('contextmenu', (e) => {
      e.preventDefault();
      openMenu(this, e.clientX, e.clientY);
    });
  }

  label() {
    this.root.setAttribute('aria-label', `${this.look.name}, visiting from ${this.homeName}`);
  }

  get size() {
    return this.root.offsetWidth || IMP_SIZE;
  }

  get awake() {
    return this.brain && this.homeConnected;
  }

  scale(scale) {
    const size = IMP_SIZE * Math.min(Math.max(Number(scale) || 1, 0.5), 2);
    Object.assign(this.root.style, { width: `${size}px`, height: `${size}px`, margin: `${-size / 2}px 0 0 ${-size / 2}px` });
  }

  /** Puts its middle at (x, y). `free` lets it past the sides, to leave or come in. */
  place(x, y, free = false) {
    const half = this.size / 2;
    this.x = free ? x : Math.min(Math.max(x, half * 0.4), innerWidth - half * 0.4);
    this.y = free ? y : Math.min(Math.max(y, half), innerHeight - half * 0.6);
    this.root.style.left = `${this.x}px`;
    this.root.style.top = `${this.y}px`;
    this.follow();
  }

  remember() {
    places[this.look.id] = { x: this.x / innerWidth, y: this.y / innerHeight };
    savePlaces();
  }

  /** Flies in by the side the entry names (the other device's throw, carried on), at the height it was thrown at. */
  enter(entry) {
    const side = entry?.side === 'right' ? 'right' : 'left';
    const height = Math.min(Math.max(Number(entry?.height ?? 0.5), 0.1), 0.9);
    const y = height * innerHeight;
    this.place(side === 'left' ? -IMP_SIZE : innerWidth + IMP_SIZE, y, true);
    requestAnimationFrame(() => requestAnimationFrame(() => {
      this.root.classList.add('flying');
      const inset = Math.min(innerWidth * 0.28, 240);
      this.place(side === 'left' ? inset : innerWidth - inset, y);
      this.remember();
      setTimeout(() => this.root.classList.remove('flying'), 500);
    }));
  }

  // ---------------------------------------------------------------- touching and carrying

  /**
   * A click opens the bubble. A long press is a cuddle. A carry moves it, and only a hard fling at a side
   * throws it (see toss.js): a slow drag to the side and letting go there just puts it down.
   */
  grab() {
    let press = null;
    const end = () => {
      clearTimeout(press?.holdTimer);
      this.root.classList.remove('held');
      doorSigns.hide();
      press = null;
    };
    this.root.addEventListener('pointerdown', (e) => {
      if (e.button !== 0 || press) return;
      closeMenu();
      this.root.setPointerCapture(e.pointerId);
      const touch = e.pointerType !== 'mouse';
      press = {
        id: e.pointerId, touch, x: e.clientX, y: e.clientY,
        dx: this.x - e.clientX, dy: this.y - e.clientY,
        moved: false, held: false, hand: new Hand(), shake: new Shake(),
      };
      press.hand.move(e.clientX, e.clientY, e.timeStamp);
      press.holdTimer = setTimeout(() => {
        if (!press || press.moved) return;
        press.held = true;
        this.feel('cuddle');
      }, HOLD);
    });
    this.root.addEventListener('pointermove', (e) => {
      if (!press || e.pointerId !== press.id) return;
      if (!press.moved && Math.hypot(e.clientX - press.x, e.clientY - press.y) < SLOP) return;
      if (!press.moved) {
        press.moved = true;
        clearTimeout(press.holdTimer);
        this.root.classList.add('held');
        closeMenu();
      }
      press.hand.move(e.clientX, e.clientY, e.timeStamp);
      const { vx, vy } = press.hand.velocity(e.timeStamp);
      if (press.shake.move(vx, e.timeStamp)) this.feel('shake');
      const point = { x: e.clientX, y: e.clientY, vx, vy, width: innerWidth, height: innerHeight, touch: press.touch };
      // In front of the camera an Imp may go half off the screen: no throws, no doors.
      const out = filming() ? null : carryExit(point);
      if (out) {
        const pointer = press;
        end();
        this.root.releasePointerCapture?.(pointer.id);
        this.throwOff(out.side, out.height, Math.abs(vx));
        return;
      }
      this.place(e.clientX + press.dx, e.clientY + press.dy, filming());
      if (!filming()) doorSigns.carried(this, e.clientX, e.clientY);
    });
    const release = (e) => {
      if (!press || e.pointerId !== press.id) return;
      const { moved, held, touch, hand } = press;
      end();
      if (!moved) {
        // In front of the camera a tap is a poke: the bubble would be in the photo.
        if (e.type === 'pointerup' && !held) {
          if (filming()) this.feel('poke');
          else this.toggle();
        }
        return;
      }
      if (filming()) return;
      const { vx, vy } = hand.velocity(e.timeStamp);
      const out = e.type === 'pointerup' && !filming()
        ? releaseExit({ x: e.clientX, y: e.clientY, vx, vy, width: innerWidth, height: innerHeight, touch })
        : null;
      if (out) {
        this.throwOff(out.side, out.height, Math.abs(vx));
        return;
      }
      this.remember();
      this.feel('drop');
    };
    this.root.addEventListener('pointerup', release);
    this.root.addEventListener('pointercancel', release);
  }

  throwOff(side, height, speed) {
    let result;
    try {
      result = link.throwImp(this.look.id, side, height, speed);
    } catch (e) {
      this.bounce(side);
      this.hint(String(e.message || e));
      return;
    }
    if (result.bounce) {
      this.bounce(side);
      this.hint({
        nobodyConnected: 'No device is connected, so it has nowhere to go.',
        wayBackIsClosed: `${this.homeName} is not connected.`,
        nowhereElse: 'That side leads back where it came from. Try the other side.',
      }[result.bounce] || 'It bounced back.');
      return;
    }
    this.transfer = result.transfer;
    this.close();
    this.showSpeech(null);
    this.root.classList.add('leaving');
    this.place(side === 'left' ? -this.size : innerWidth + this.size, this.y, true);
  }

  bounce(side) {
    this.root.classList.remove('leaving');
    this.root.classList.add('flying');
    this.place(side === 'left' ? this.size : innerWidth - this.size, this.y);
    this.remember();
    setTimeout(() => this.root.classList.remove('flying'), 500);
  }

  remove() {
    this.close();
    this.showSpeech(null);
    this.figure.destroy();
    this.root.remove();
  }

  // ---------------------------------------------------------------- what its home says

  setLook(look) {
    this.look = look;
    this.figure.setImp(look);
    this.figure.wake?.();
    this.scale(look.scale);
    this.label();
    this.render();
  }

  setAwake() {
    this.root.classList.toggle('asleep', !this.awake);
    this.render();
  }

  setChat(turns) {
    this.turns = turns || [];
    // The answer is in: the placeholder made when it was asked goes, even if the home sends no `work` after it.
    const last = this.lastTurn();
    if (this.work?.local && last && last.id !== this.asking) this.setWork(null);
    this.answered();
    this.render();
  }

  setWork(work) {
    // Streamed words of a turn that is already in the chat, arriving late: the turn is done.
    const last = this.lastTurn();
    if (work && !work.local && work.partial && last && last.request === work.request
        && (last.reply || '').startsWith(work.partial) && this.asking === null && !this.work) return;
    this.work = work || null;
    this.figure.setMood(work ? 'thinking' : 'idle');
    if (work && this.phase === 'typing' && work.request === this.sentText) this.phase = 'thinking';
    if (!work && this.phase === 'thinking' && this.asking === null) this.phase = null;
    this.answered();
    this.render();
  }

  /** What was asked here was answered: the answer shows, as on the Mac, even if the bubble was closed. */
  answered() {
    if (this.asking === null || this.work) return;
    const last = this.turns[this.turns.length - 1];
    if (!last || last.id === this.asking) return;
    this.asking = null;
    this.showSteps = false;
    if (this.phase !== 'chat') this.open('result');
  }

  // ---------------------------------------------------------------- talking to it

  ask(text, files = []) {
    if (!this.awake || this.work) return;
    // The files go first, then the question that names them (docs/connecting/link.md, "Attachments").
    const attachments = [];
    for (const file of files) {
      let id = null;
      try {
        id = link.upload(this.look.id, this.home, file.name, file.mime, file.bytes);
      } catch {
        id = null;
      }
      if (!id) {
        this.hint(`${file.name} couldn't be sent to ${this.homeName}.`);
        return;
      }
      attachments.push(id);
    }
    for (const file of files) if (file.preview) URL.revokeObjectURL(file.preview);
    link.send({ ask: { imp: this.look.id, text, ...(attachments.length ? { attachments } : {}) } }, this.home);
    this.asking = this.turns[this.turns.length - 1]?.id || '';
    this.sentText = text;
    this.draft = '';
    this.work = { request: text, partial: '', status: null, local: true };
    this.figure.setMood('thinking');
    if (this.phase !== 'chat') this.phase = 'thinking';
    this.render();
  }

  feel(feeling) {
    if (this.homeConnected) link.send({ felt: { imp: this.look.id, feeling } }, this.home);
  }

  stop() {
    link.send({ stop: { imp: this.look.id } }, this.home);
  }

  newChat() {
    link.send({ newChat: { imp: this.look.id } }, this.home);
    this.turns = [];
    this.render();
  }

  goHome() {
    if (link.sendHome(this.look.id)) leave(this.look.id, `${this.look.name} went home to ${this.homeName}.`);
  }

  // ---------------------------------------------------------------- the bubble

  toggle() {
    if (this.bubble && this.phase !== 'hint') this.close();
    else this.open();
  }

  /** Opens the bubble: what it is doing, or a text box. */
  open(phase) {
    for (const other of imps.values()) if (other !== this) other.close();
    closeMenu();
    this.phase = phase || (this.work ? 'thinking' : 'typing');
    if (!this.bubble) {
      this.bubble = el('section', { class: 'bubble', role: 'dialog', 'aria-label': this.look.name });
      this.bubble.addEventListener('keydown', (e) => {
        if (e.key === 'Escape') { e.stopPropagation(); this.close(); this.root.focus(); }
      });
      stage.append(this.bubble);
      this.movable(this.bubble);
      this.droppable(this.bubble);
    }
    this.showSpeech(null);
    this.render();
    this.bubble.querySelector('textarea')?.focus();
  }

  close() {
    clearTimeout(this.hintTimer);
    if (this.recording) this.stopRecording(false);
    const box = this.bubble?.querySelector('textarea');
    if (box) this.draft = box.value;
    this.bubble?.remove();
    this.bubble = null;
    this.phase = null;
    this.moved = null;
    this.confirming = null;
  }

  /** Says something short in the bubble (why it bounced), then closes it. */
  hint(text) {
    this.hintText = text;
    this.open('hint');
    clearTimeout(this.hintTimer);
    this.hintTimer = setTimeout(() => { if (this.phase === 'hint') this.close(); }, HINT_TIME);
  }

  render() {
    if (!this.bubble) return;
    const b = this.bubble;
    const box = b.querySelector('textarea');
    if (box) this.draft = box.value;
    const focused = box && document.activeElement === box;
    const phase = this.phase === 'thinking' && !this.work ? 'typing' : this.phase;
    b.style.setProperty('--tint', tint(this.look.hue));
    b.style.setProperty('--on-tint', onTint(this.look.hue));
    b.classList.toggle('wide', phase === 'result' && (this.lastTurn()?.reply || '').length > 600);
    b.classList.toggle('sized', phase === 'chat');
    b.classList.toggle('pinned', phase === 'typing' || phase === 'chat');
    const card = el('div', { class: `card ${phase}` });
    const chips = [];
    chips.push(el('button', { class: 'chip close', type: 'button', 'aria-label': 'Close', title: 'Close', onclick: () => this.close() }, icon('close')));
    if (phase === 'chat') {
      chips.push(el('button', { class: 'chip history', type: 'button', 'aria-label': 'Back', title: 'Back to the bubble', onclick: () => this.open() }, icon('back')));
    } else if (this.turns.length && phase !== 'hint') {
      chips.push(el('button', { class: 'chip history', type: 'button', 'aria-label': 'Chat', title: `Chat with ${this.look.name}`, onclick: () => this.open('chat') }, icon('chat')));
    }
    switch (phase) {
      case 'typing':
        card.append(this.field());
        break;
      case 'thinking':
        card.append(this.working());
        break;
      case 'result': {
        const turn = this.lastTurn();
        if (!turn) {
          this.phase = 'typing';
          return this.render();
        }
        card.append(formatted(turn.reply || '…', turn.failed));
        const steps = this.stepList(turn);
        const limit = this.tools ? null : this.limitButton();
        if (steps || limit) card.append(el('div', { class: 'foot' }, steps, limit));
        if (limit && this.showLimit) card.append(el('p', { class: 'note' }, this.limitText()));
        chips.push(el('button', { class: 'chip reply', type: 'button', 'aria-label': 'Reply', title: `Reply to ${this.look.name}`, onclick: () => this.open('typing') }, icon('reply')));
        const copy = el('button', { class: 'chip copy', type: 'button', 'aria-label': 'Copy', title: 'Copy' }, icon('copy'));
        copy.onclick = async () => {
          await navigator.clipboard?.writeText(turn.reply || '');
          copy.replaceChildren(icon('copied'));
          setTimeout(() => copy.replaceChildren(icon('copy')), 1400);
        };
        chips.push(copy);
        card.addEventListener('dblclick', () => this.open('typing'));
        break;
      }
      case 'chat': {
        // The chat is as big as it was last made: its edges and corners resize it, as on the Mac. Once it was
        // moved or resized off its Imp, it opens where it was last put.
        const size = clampedChat(chatSize);
        if (!this.moved) this.moved = chatPlace();
        b.style.width = `${size.width}px`;
        card.style.height = `${size.height}px`;
        card.append(this.chat(), ...this.resizeHandles(),
          el('span', { class: 'resize-mark', 'aria-hidden': 'true' }, icon('resize')));
        break;
      }
      case 'hint':
        card.append(el('div', { class: 'notice' }, this.hintText));
        break;
      default:
        return this.close();
    }
    if (phase !== 'chat') b.style.width = '';
    card.append(...chips.filter(Boolean));
    // The chat is a panel, not a speech bubble, and a bubble moved away from the Imp no longer points at it.
    const tail = phase !== 'chat' && !this.moved;
    b.replaceChildren(card, ...(tail ? [el('div', { class: 'trail', 'aria-hidden': 'true' }, el('i'), el('i'))] : []));
    const next = b.querySelector('textarea');
    if (next) {
      next.value = this.draft;
      this.grow(next);
      if (focused) next.focus();
    }
    const turns = b.querySelector('.turns');
    if (turns) turns.scrollTop = turns.scrollHeight;
    this.follow();
  }

  lastTurn() {
    return this.turns[this.turns.length - 1] || null;
  }

  /** The text box with its round send button, or a stop button while it works. */
  field() {
    const asleep = !this.awake;
    const area = el('textarea', {
      rows: '1',
      'aria-label': `Message ${this.look.name}`,
      placeholder: asleep
        ? (this.homeConnected ? `${this.look.name} is asleep` : `${this.homeName} is not connected`)
        : `Ask ${this.look.name} anything…`,
      disabled: asleep,
    });
    const busy = !!this.work;
    if (this.recording) return this.recordingRow();
    const send = el('button', { class: 'send', type: 'button' });
    const update = () => {
      const ready = !busy && !asleep && (area.value.trim().length > 0 || this.files.length > 0);
      send.classList.toggle('ready', ready || busy);
      send.classList.toggle('stop', busy);
      send.disabled = !ready && !busy;
      send.replaceChildren(icon(busy ? 'stop' : 'send'));
      send.setAttribute('aria-label', busy ? 'Stop' : 'Send');
      send.title = busy ? `Stop ${this.look.name}` : 'Send (↩)';
    };
    const submit = () => {
      if (busy) return this.stop();
      const files = this.files;
      const text = area.value.trim() || (files.length ? defaultWords(files) : '');
      if (!text || asleep) return undefined;
      area.value = '';
      this.files = [];
      return this.ask(text, files);
    };
    // A picture pasted into the box goes with the message.
    area.addEventListener('paste', (e) => {
      const pasted = [...(e.clipboardData?.files || [])];
      if (!pasted.length) return;
      e.preventDefault();
      this.addFiles(pasted);
    });
    area.addEventListener('input', () => { this.grow(area); update(); this.draft = area.value; });
    area.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' && !e.shiftKey && !e.isComposing) {
        e.preventDefault();
        submit();
      }
    });
    send.addEventListener('click', submit);
    update();
    const attach = asleep ? null : el('button', {
      class: 'attach', type: 'button', 'aria-label': 'Add a photo, sound or file', 'aria-haspopup': 'menu', title: 'Add a photo, sound or file',
      onclick: (e) => {
        const r = e.currentTarget.getBoundingClientRect();
        openAttachMenu(this, r.left, r.bottom + 6);
      },
    }, icon('plus'));
    const field = el('div', { class: 'field' }, attach, area, send);
    return this.files.length ? el('div', { class: 'compose' }, this.chips(), field) : field;
  }

  /** The files that go with the next message, each with a way to take it off. */
  chips() {
    return el('div', { class: 'chips' }, this.files.map((file, i) => el('div', { class: `chip-file ${file.kind}`, title: file.name },
      file.kind === 'image' ? el('img', { src: file.preview, alt: '' })
        : file.kind === 'video' ? el('video', { src: file.preview, muted: true, playsinline: true })
          : el('span', { class: 'glyph' }, icon(file.kind === 'audio' ? 'wave' : 'clip')),
      file.kind === 'image' ? null : el('span', { class: 'chip-name' }, file.name),
      el('button', { class: 'chip-off', type: 'button', 'aria-label': `Remove ${file.name}`, onclick: () => {
        if (file.preview) URL.revokeObjectURL(file.preview);
        this.files.splice(i, 1);
        this.render();
      } }, icon('close')))));
  }

  /** Files dropped on `target` (the Imp or its bubble) go with the next message, as on the Mac. */
  droppable(target) {
    target.addEventListener('dragover', (e) => {
      if (!e.dataTransfer?.types.includes('Files')) return;
      e.preventDefault();
      target.classList.add('dropping');
    });
    target.addEventListener('dragleave', () => target.classList.remove('dropping'));
    target.addEventListener('drop', (e) => {
      if (!e.dataTransfer?.files.length) return;
      e.preventDefault();
      target.classList.remove('dropping');
      this.addFiles(e.dataTransfer.files);
    });
  }

  /** Files picked, dropped or pasted: ready to go with the next message, in the text box. */
  async addFiles(list) {
    for (const file of [...list]) {
      if (this.files.length >= MAX_FILES) {
        this.hint(`${MAX_FILES} files at most in one message.`);
        break;
      }
      try {
        this.files.push(await fromFile(file));
      } catch (err) {
        this.hint(String(err.message || err));
        return;
      }
    }
    if (this.phase !== 'chat') this.open('typing');
    else this.render();
  }

  pickFiles() {
    const input = el('input', { type: 'file', accept: 'image/*,audio/*,video/*', multiple: true, hidden: true });
    input.addEventListener('change', () => { this.addFiles(input.files); input.remove(); });
    document.body.append(input);
    input.click();
  }

  // ---------------------------------------------------------------- recording a sound

  async record() {
    try {
      this.recording = await Recorder.start();
    } catch {
      this.hint('The microphone is not available here.');
      return;
    }
    if (this.phase !== 'chat') this.open('typing');
    else this.render();
    const tick = () => {
      const row = this.bubble?.querySelector('.recording');
      if (!this.recording) return;
      if (row) {
        const s = Math.floor(this.recording.seconds);
        row.querySelector('.time').textContent = `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
        row.style.setProperty('--level', this.recording.level().toFixed(2));
      }
      if (this.recording.seconds >= MAX_RECORDING) this.stopRecording(true);
      else requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  }

  async stopRecording(keep) {
    const recorder = this.recording;
    this.recording = null;
    if (!recorder) return;
    if (!keep) {
      recorder.cancel();
      this.render();
      return;
    }
    try {
      this.files.push(await recorder.stop());
    } catch {
      this.hint('The recording could not be read.');
      return;
    }
    this.render();
  }

  /** While recording: a red dot, the time and how loud it is, then cancel and done. */
  recordingRow() {
    return el('div', { class: 'field recording', role: 'status', 'aria-label': 'Recording' },
      el('span', { class: 'rec-dot', 'aria-hidden': 'true' }),
      el('span', { class: 'time' }, '0:00'),
      el('span', { class: 'meter', 'aria-hidden': 'true' }, el('i'), el('i'), el('i'), el('i'), el('i')),
      el('button', { class: 'attach', type: 'button', 'aria-label': 'Cancel the recording', title: 'Cancel', onclick: () => this.stopRecording(false) }, icon('close')),
      el('button', { class: 'send ready', type: 'button', 'aria-label': 'Done recording', title: 'Done', onclick: () => this.stopRecording(true) }, icon('check')));
  }

  grow(area) {
    area.style.height = 'auto';
    area.style.height = `${Math.min(area.scrollHeight, 140)}px`;
    this.follow();
  }

  /** At work: the dots, what it is doing now (a tool's name), and the answer as it comes. */
  working() {
    const work = this.work;
    return el('div', { class: 'working' },
      el('div', { class: 'top' },
        el('div', { class: 'dots', 'aria-hidden': 'true' }, el('i'), el('i'), el('i')),
        el('span', { class: 'status' }, work.status || (work.from ? `Answering ${work.from}` : 'Thinking…')),
        el('button', { class: 'send ready stop', type: 'button', 'aria-label': 'Stop', title: `Stop ${this.look.name}`, onclick: () => this.stop() }, icon('stop'))),
      work.partial ? formatted(work.partial) : null);
  }

  limitText() {
    return `Only talks here: to let ${this.look.name} use its tools, mark this page as Mine on ${this.homeName}.`;
  }

  /** Its home doesn't let it use its tools for this page: an ⓘ that says so on hover, and on a click. */
  limitButton() {
    return el('button', {
      class: 'limit', type: 'button', title: this.limitText(), 'aria-label': this.limitText(),
      'aria-expanded': String(!!this.showLimit),
      onclick: () => { this.showLimit = !this.showLimit; this.render(); },
    }, icon('info'));
  }

  /** The tools it used for an answer, folded under it: what ran, never what it thought. */
  stepList(turn) {
    const steps = turn.steps || [];
    if (!steps.length) return null;
    const thoughts = new Set(turn.thoughts || []);
    const tools = steps.filter((_, i) => !thoughts.has(i)).length;
    const words = tools ? `${tools} ${tools === 1 ? 'step' : 'steps'}` : 'Thought it through';
    const toggle = el('button', { class: 'steps-toggle', type: 'button', 'aria-expanded': String(this.showSteps), onclick: () => {
      this.showSteps = !this.showSteps;
      this.render();
    } }, `${this.showSteps ? '▾' : '▸'} ${words}`);
    if (!this.showSteps) return el('div', { class: 'note' }, toggle);
    return el('div', { class: 'note' }, toggle,
      el('ul', { class: 'steps' }, steps.map((s, i) => el('li', { class: thoughts.has(i) ? 'thought' : '' }, s))));
  }

  /** The whole talk with it, and a text box under it. */
  chat() {
    const turns = el('div', { class: 'turns' });
    for (const turn of this.turns.slice(-40)) {
      if (turn.request) {
        turns.append(el('div', { class: 'said' }, turn.from ? el('span', { class: 'from' }, turn.answer ? `${turn.from} answered` : turn.from) : null, turn.request));
      }
      turns.append(formatted(turn.reply || '…', turn.failed));
    }
    if (this.work) {
      turns.append(el('div', { class: 'said' }, this.work.from ? el('span', { class: 'from' }, this.work.from) : null, this.work.request));
      turns.append(this.working());
    }
    if (!this.turns.length && !this.work) turns.append(el('div', { class: 'empty' }, `A new chat with ${this.look.name}`));
    return el('div', { class: 'chat' }, this.chatHeader(), turns, this.work ? null : this.field());
  }

  /** The chat's title, as its home names it, or a new one's. */
  chatTitle() {
    const saved = this.chats.find((c) => c.id === this.currentChat);
    return saved?.title || `New chat with ${this.look.name}`;
  }

  /**
   * As on the Mac: a handle to move the chat by, the chat you are in (a menu of the saved ones), then new
   * chat and send home, each asking once more before it does it.
   */
  chatHeader() {
    const grip = el('span', { class: 'grip', title: 'Drag to move', 'aria-label': 'Drag to move', role: 'img' }, icon('move'));
    const others = this.chats.filter((c) => c.id !== this.currentChat);
    const title = others.length
      ? el('button', { class: 'chat-title', type: 'button', 'aria-haspopup': 'menu', title: 'Your chats', onclick: (e) => {
        const r = e.currentTarget.getBoundingClientRect();
        openChatsMenu(this, r.left, r.bottom + 4);
      } }, this.chatTitle(), el('span', { class: 'caret', 'aria-hidden': 'true' }, ' ▾'))
      : el('span', { class: 'chat-title' }, this.chatTitle());
    return el('div', { class: 'chat-head' }, grip, title,
      this.turns.length ? this.confirmButton('new', 'newChat', 'New chat?', 'New chat (this one stays in the list)', () => this.newChat()) : null,
      this.confirmButton('home', 'home', 'Send home?', `Send ${this.look.name} home to ${this.homeName}`, () => this.goHome()));
  }

  /** A button that asks once more: the first click turns it into its question for three seconds, the second does it. */
  confirmButton(key, iconName, question, help, action) {
    const asking = this.confirming === key;
    return el('button', {
      class: asking ? 'head-btn asking' : 'head-btn', type: 'button', title: help, 'aria-label': asking ? question : help,
      onclick: () => {
        clearTimeout(this.confirmTimer);
        if (asking) {
          this.confirming = null;
          action();
          return;
        }
        this.confirming = key;
        this.confirmTimer = setTimeout(() => { this.confirming = null; this.render(); }, 3000);
        this.render();
        this.bubble?.querySelector('.head-btn.asking')?.focus();
      },
    }, asking ? question : icon(iconName));
  }

  /** Invisible strips on the chat's sides and grips on its corners, each with its resize cursor. */
  resizeHandles() {
    return ['n', 's', 'e', 'w', 'ne', 'nw', 'se', 'sw'].map((edges) => {
      const handle = el('span', { class: `rz ${edges}`, 'aria-hidden': 'true' });
      handle.addEventListener('pointerdown', (e) => this.resizeFrom(e, edges));
      return handle;
    });
  }

  /**
   * Resizes the chat from `edges` (n, s, e, w or a corner) while the pointer is down. The side across from
   * the one pulled stays where it is. A resized chat is the user's: it stays where it is put (no tail).
   */
  resizeFrom(e, edges) {
    if (e.button !== 0 || !this.bubble) return;
    e.preventDefault();
    e.stopPropagation();
    const b = this.bubble;
    const card = b.querySelector('.card');
    const handle = e.currentTarget;
    handle.setPointerCapture(e.pointerId);
    const start = { x: e.clientX, y: e.clientY, left: b.offsetLeft, top: b.offsetTop, ...clampedChat(chatSize) };
    b.classList.add('resizing');
    const move = (ev) => {
      const dx = ev.clientX - start.x;
      const dy = ev.clientY - start.y;
      let width = start.width;
      let height = start.height;
      if (edges.includes('e')) width += dx;
      if (edges.includes('w')) width -= dx;
      if (edges.includes('s')) height += dy;
      if (edges.includes('n')) height -= dy;
      ({ width, height } = clampedChat({ width, height }));
      chatSize = { width, height };
      const left = edges.includes('w') ? start.left + start.width - width : start.left;
      const top = edges.includes('n') ? start.top + start.height - height : start.top;
      this.moved = { left, top };
      b.style.width = `${width}px`;
      card.style.height = `${height}px`;
      this.follow();
    };
    const end = () => {
      handle.removeEventListener('pointermove', move);
      handle.removeEventListener('pointerup', end);
      handle.removeEventListener('pointercancel', end);
      b.classList.remove('resizing');
      localStorage.setItem(CHAT_SIZE, JSON.stringify(chatSize));
      if (this.moved) saveChatPlace({ left: b.offsetLeft, top: b.offsetTop });
    };
    handle.addEventListener('pointermove', move);
    handle.addEventListener('pointerup', end);
    handle.addEventListener('pointercancel', end);
  }

  /**
   * The bubble moves by its card wherever that isn't text or a button (and by the chat's handle). Once
   * moved it stays where it was put, without its tail, until it closes.
   */
  movable(bubble) {
    let grab = null;
    bubble.addEventListener('pointerdown', (e) => {
      const target = e.target instanceof Element ? e.target : null;
      const handle = target?.closest('.grip, .chat-head');
      const bare = target && (target.classList.contains('card') || target.classList.contains('chat'));
      if (e.button !== 0 || (!handle && !bare) || target.closest('button, textarea, input, a')) return;
      e.preventDefault();
      bubble.setPointerCapture(e.pointerId);
      grab = { id: e.pointerId, dx: e.clientX - bubble.offsetLeft, dy: e.clientY - bubble.offsetTop };
      bubble.classList.add('moving');
    });
    bubble.addEventListener('pointermove', (e) => {
      if (!grab || e.pointerId !== grab.id) return;
      const first = !this.moved;
      this.moved = { left: e.clientX - grab.dx, top: e.clientY - grab.dy };
      if (first) this.render();
      else this.follow();
    });
    const drop = (e) => {
      if (!grab || e.pointerId !== grab.id) return;
      grab = null;
      bubble.classList.remove('moving');
      // The chat moved off its Imp is the user's: it opens there again, for every Imp.
      if (this.phase === 'chat' && this.moved) saveChatPlace({ left: bubble.offsetLeft, top: bubble.offsetTop });
    };
    bubble.addEventListener('pointerup', drop);
    bubble.addEventListener('pointercancel', drop);
  }

  /** What it says to another Imp, in a small bubble of its own. */
  showSpeech(speech) {
    this.speechEl?.remove();
    this.speechEl = null;
    clearTimeout(this.speechTimer);
    if (!speech || !speech.text || this.bubble) return;
    const who = el('b', { style: `color: ${tint(speech.hue)}` }, speech.peer);
    const line = speech.role === 'asked'
      ? [who, ': ', speech.question || speech.text]
      : [`To `, who, ': ', speech.text];
    this.speechEl = el('div', { class: 'speech', role: 'status' }, ...line);
    stage.append(this.speechEl);
    this.follow();
  }

  /** Keeps the bubble (with its trail pointing at the Imp) and the speech next to it. */
  follow() {
    const size = this.size;
    if (this.bubble) {
      const b = this.bubble;
      const w = b.offsetWidth || 320;
      const h = b.offsetHeight || 80;
      if (this.moved) {
        // Where it was put, kept on the page with room for the buttons on its corners.
        const left = Math.min(Math.max(this.moved.left, 14), innerWidth - w - 14);
        const top = Math.min(Math.max(this.moved.top, 20), innerHeight - Math.min(h, 60) - 20);
        b.classList.remove('below');
        Object.assign(b.style, { left: `${left}px`, top: `${top}px` });
        return this.followSpeech();
      }
      const left = Math.min(Math.max(this.x - w / 2, 12), innerWidth - w - 12);
      const above = this.y - size * 0.42 - h;
      const below = above < 12;
      const top = below ? Math.min(this.y + size * 0.45, innerHeight - h - 12) : above;
      b.classList.toggle('below', below);
      Object.assign(b.style, { left: `${left}px`, top: `${top}px` });
      const reach = Math.min(Math.max(this.x - left, 30), w - 30);
      for (const [i, dot] of [...b.querySelectorAll('.trail i')].entries()) {
        const side = i === 0 ? 10 : 6;
        dot.style.left = `${reach - side / 2 + (i === 1 ? Math.sign(this.x - left - reach) * 4 : 0)}px`;
      }
    }
    return this.followSpeech();
  }

  followSpeech() {
    const size = this.size;
    if (this.speechEl) {
      const w = this.speechEl.offsetWidth || 200;
      const h = this.speechEl.offsetHeight || 40;
      const right = this.x + size * 0.35;
      const left = right + w < innerWidth - 8 ? right : this.x - size * 0.35 - w;
      Object.assign(this.speechEl.style, { left: `${Math.max(left, 8)}px`, top: `${Math.max(this.y - size / 2 - h * 0.5, 8)}px` });
    }
  }
}

function leave(id, note) {
  const visitor = imps.get(id);
  if (!visitor) return;
  imps.delete(id);
  visitor.remove();
  delete places[id];
  savePlaces();
  publishStage();
  renderPage();
  if (note) toast(note);
}

// ---------------------------------------------------------------- the menu (right click on an Imp)

function openMenu(visitor, x, y) {
  const menu = $('menu');
  const item = (text, action) => el('button', { type: 'button', role: 'menuitem', onclick: () => { closeMenu(); action(); } }, text);
  menu.replaceChildren(
    item('Message', () => visitor.open('typing')),
    item('Chat', () => visitor.open('chat')),
    el('hr'),
    item('Poke', () => visitor.feel('poke')),
    item('Cuddle', () => visitor.feel('cuddle')),
    // As on the Mac, a new chat asks once more: the chat opens with its question showing.
    item('New chat…', () => {
      visitor.open('chat');
      visitor.bubble?.querySelector('.head-btn[title^="New chat"]')?.click();
    }),
    el('hr'),
    item(`Send home to ${visitor.homeName}`, () => visitor.goHome()));
  menu.hidden = false;
  const w = menu.offsetWidth;
  const h = menu.offsetHeight;
  Object.assign(menu.style, { left: `${Math.min(x, innerWidth - w - 8)}px`, top: `${Math.min(y, innerHeight - h - 8)}px` });
  menu.querySelector('button').focus();
}

/** What can go with a message: a photo taken now, a sound recorded now, or files. */
function openAttachMenu(visitor, x, y) {
  const menu = $('menu');
  const item = (iconName, text, action) => el('button', { type: 'button', role: 'menuitem', onclick: () => { closeMenu(); action(); } },
    el('span', { class: 'menu-icon', 'aria-hidden': 'true' }, icon(iconName)), text);
  const live = !!navigator.mediaDevices?.getUserMedia;
  menu.replaceChildren(
    live ? item('camera', 'Take a photo', () => openCamera(visitor)) : null,
    live ? item('mic', 'Record a sound', () => visitor.record()) : null,
    item('clip', 'Choose a file…', () => visitor.pickFiles()));
  menu.hidden = false;
  Object.assign(menu.style, { left: `${Math.min(x, innerWidth - menu.offsetWidth - 8)}px`, top: `${Math.min(y, innerHeight - menu.offsetHeight - 8)}px` });
  menu.querySelector('button')?.focus();
}

// ---------------------------------------------------------------- the camera, with the Imps in the way

const camera = new Camera($('camera-layer'), $('camera-video'));
/** The Imp the photo is for, while the camera is open, and where every Imp stood before. */
let filmingFor = null;
let standing = null;

function filming() {
  return filmingFor !== null;
}

/**
 * Where the Imps wait in front of the camera: peeking in from the corners and the sides, half off the screen,
 * so they frame the shot. They can be carried anywhere over it. The photo has them where they are.
 */
function framingSpots(count) {
  const w = innerWidth;
  const h = innerHeight;
  const spots = [
    { x: 46, y: h - 34 }, { x: w - 46, y: 74 }, { x: w - 52, y: h - 34 }, { x: 50, y: 74 },
    { x: 14, y: h * 0.5 }, { x: w - 14, y: h * 0.42 },
  ];
  return Array.from({ length: count }, (_, i) => spots[i % spots.length]);
}

async function openCamera(visitor) {
  try {
    await camera.open();
  } catch {
    visitor.hint('The camera is not available here.');
    return;
  }
  filmingFor = visitor;
  $('camera-bar').hidden = false;
  closeMenu();
  doorSigns.hide();
  document.body.classList.add('filming');
  $('camera-preview').hidden = true;
  const all = [...imps.values()];
  standing = new Map(all.map((v) => [v, { x: v.x, y: v.y }]));
  const spots = framingSpots(all.length);
  all.forEach((v, i) => {
    v.close();
    v.showSpeech(null);
    v.root.classList.add('flying');
    v.place(spots[i].x, spots[i].y, true);
    v.figure.setMood('excited');
    setTimeout(() => v.root.classList.remove('flying'), 500);
  });
  $('shutter').focus();
}

function closeCamera(then) {
  camera.close();
  $('camera-bar').hidden = true;
  $('camera-preview').hidden = true;
  document.body.classList.remove('filming');
  const visitor = filmingFor;
  filmingFor = null;
  for (const [v, at] of standing || []) {
    if (!imps.has(v.look.id)) continue;
    v.root.classList.add('flying');
    v.place(at.x, at.y);
    v.figure.setMood('idle');
    setTimeout(() => v.root.classList.remove('flying'), 500);
  }
  standing = null;
  if (visitor && imps.has(visitor.look.id)) then?.(visitor);
}

let shot = null;

async function shoot() {
  const layer = $('camera-layer');
  layer.classList.remove('flash');
  void layer.offsetWidth;
  layer.classList.add('flash');
  const canvas = await camera.shoot([...imps.values()].map((v) => v.root));
  shot = canvas;
  const preview = $('camera-preview');
  preview.querySelector('img').src = canvas.toDataURL('image/jpeg', 0.85);
  $('camera-send').textContent = `Send to ${filmingFor?.look.name || 'Imp'}`;
  preview.hidden = false;
  $('camera-bar').hidden = true;
  $('camera-send').focus();
  for (const v of imps.values()) v.figure.setMood('happy');
}

function wireCamera() {
  $('shutter').addEventListener('click', shoot);
  $('camera-flip').addEventListener('click', () => camera.flip());
  $('camera-close').addEventListener('click', () => closeCamera());
  $('camera-retake').addEventListener('click', () => {
    $('camera-preview').hidden = true;
    $('camera-bar').hidden = false;
    shot = null;
    $('shutter').focus();
  });
  $('camera-save').addEventListener('click', () => {
    const a = el('a', { href: $('camera-preview').querySelector('img').src, download: `imp-${Date.now()}.jpg` });
    document.body.append(a);
    a.click();
    a.remove();
  });
  $('camera-send').addEventListener('click', async () => {
    if (!shot) return;
    const file = await fromCanvas(shot, 'photo.jpg');
    shot = null;
    closeCamera((visitor) => {
      visitor.files.push(file);
      visitor.open('typing');
    });
  });
  addEventListener('keydown', (e) => {
    if (!filming()) return;
    if (e.key === 'Escape') closeCamera();
    if (e.key === ' ' && $('camera-preview').hidden && document.activeElement?.tagName !== 'BUTTON') { e.preventDefault(); shoot(); }
  });
}

/** The Imp's saved chats, to carry on in one (`openChat`). */
function openChatsMenu(visitor, x, y) {
  const menu = $('menu');
  menu.replaceChildren(...visitor.chats.map((c) => el('button', {
    type: 'button', role: 'menuitem', 'aria-current': c.id === visitor.currentChat ? 'true' : null,
    onclick: () => {
      closeMenu();
      link.send({ openChat: { imp: visitor.look.id, chat: c.id } }, visitor.home);
    },
  }, c.title || 'Untitled chat')));
  menu.hidden = false;
  Object.assign(menu.style, { left: `${Math.min(x, innerWidth - menu.offsetWidth - 8)}px`, top: `${Math.min(y, innerHeight - menu.offsetHeight - 8)}px` });
  menu.querySelector('button')?.focus();
}

function closeMenu() {
  $('menu').hidden = true;
}

// ---------------------------------------------------------------- the link

/** Whether each visitor's home is connected: a visitor sleeps while its home is away. */
function refreshHomes() {
  const connected = new Set(link.state().links.filter((d) => d.connected).map((d) => d.id));
  for (const v of imps.values()) {
    const now = connected.has(v.home);
    if (now !== v.homeConnected) {
      v.homeConnected = now;
      v.setAwake();
    }
  }
}

function arrived(pass) {
  if (!pass.home) {
    // Only an Imp's home sends it without a home card, and nothing is at home on this page.
    link.decline(pass.transfer, 'other');
    return;
  }
  if (!link.accept(pass.transfer)) return;
  const visit = link.state().visits.find((v) => v.imp.id === pass.imp.id);
  const home = visit ? visit.home : pass.home.device;
  imps.get(pass.imp.id)?.remove();
  imps.set(pass.imp.id, new Visitor(pass.imp, home, { entry: pass.entry }));
  publishStage();
  renderPage();
  refreshHomes();
}

function onMessage({ message }) {
  const [type] = Object.keys(message);
  const body = message[type];
  if (type === 'pass') return arrived(body);
  const id = typeof body?.imp === 'object' && body.imp ? body.imp.id : body?.imp;
  const visitor = imps.get(id);
  if (!visitor) return undefined;
  switch (type) {
    case 'look': return visitor.setLook(body.imp);
    case 'chat': return visitor.setChat(body.turns);
    case 'work': return visitor.setWork(body.work);
    case 'chats':
      visitor.chats = Array.isArray(body.chats) ? body.chats : [];
      visitor.currentChat = body.current || null;
      return visitor.render();
    case 'mood': return visitor.figure.setMood(body.mood);
    case 'brain':
      visitor.brain = !!body.ready;
      visitor.tools = body.tools !== false;
      return visitor.setAwake();
    case 'animate': return visitor.figure.play({ beats: body.beats || [] });
    case 'speech': return visitor.showSpeech(body.speech);
    case 'gone': return leave(id, `${visitor.look.name} went back to ${visitor.homeName}.`);
    default: return undefined;
  }
}

function onPassed({ imp, took, reason }) {
  const visitor = imps.get(imp);
  if (!visitor) return;
  if (took) {
    leave(imp, null);
    return;
  }
  const side = visitor.x < innerWidth / 2 ? 'left' : 'right';
  visitor.bounce(side);
  visitor.hint({
    full: 'The other device is full.',
    playing: 'The other device is playing a game.',
    notLinked: 'That device is not linked any more.',
    timeout: 'The other device did not answer.',
  }[reason] || 'It bounced back.');
}

/** The Imps that were here before the page was reloaded: their visits are in the book. */
function restore() {
  for (const visit of link.state().visits) {
    if (imps.has(visit.imp.id)) continue;
    const place = places[visit.imp.id] || { x: 0.5, y: 0.55 };
    imps.set(visit.imp.id, new Visitor(visit.imp, visit.home, { place }));
  }
  for (const id of Object.keys(places)) if (!imps.has(id)) delete places[id];
  savePlaces();
  publishStage();
  refreshHomes();
}

function wire() {
  wireCamera();
  $('connect').addEventListener('click', () => connect.open());
  $('add').addEventListener('click', () => connect.open());
  // A press on the empty page closes the bubble and the menu.
  stage.addEventListener('pointerdown', (e) => {
    if (e.target !== stage) return;
    closeMenu();
    for (const v of imps.values()) if (v.phase !== 'hint') v.close();
  });
  document.addEventListener('pointerdown', (e) => { if (!$('menu').contains(e.target)) closeMenu(); }, true);
  addEventListener('keydown', (e) => { if (e.key === 'Escape') closeMenu(); });
  addEventListener('resize', () => {
    for (const v of imps.values()) {
      const place = places[v.look.id];
      if (place) v.place(place.x * innerWidth, place.y * innerHeight);
      else v.place(v.x, v.y);
    }
  });

  link.addEventListener('message', (e) => onMessage(e.detail));
  link.addEventListener('passed', (e) => onPassed(e.detail));
  link.addEventListener('linked', (e) => toast(`${e.detail.device.name} is connected.`));
  link.addEventListener('forgotten', (e) => {
    for (const id of e.detail.sentHome) leave(id, null);
    toast('A device forgot this page.');
  });
  link.addEventListener('problem', (e) => toast(e.detail, true));
  link.addEventListener('change', refreshHomes);
}

async function main() {
  wire();
  await link.start();
  if (params.get('hop')) link.setHop(params.get('hop'));
  restore();
  renderPage();
  // A code in the address (#join=implink://...) connects at once, so a link to the page can carry it.
  const code = findCode(new URLSearchParams(location.hash.slice(1)).get('join'));
  if (code) {
    history.replaceState(null, '', location.pathname + location.search);
    connect.open();
    connect.use(code);
  }
  // For tests and the console: the link and the Imps on the page.
  window.impWeb = { link, imps, connect };
}

main().catch((e) => {
  renderPage();
  toast(`Imp could not start: ${e.message || e}`, true);
});
