// The toolbar popup: the Imps that are out (alive: they watch your pointer, blink, think, sleep),
// what tab Imp knows you're on, and what it just did there.
//
// The background pushes its state over a port, whenever it changes; nothing here polls, and
// nothing waits on the background: a click updates the screen at once, then the news follows.
// Every render step only touches the DOM when its value changed.

import { ImpCanvas, Clock, reducedMotion } from "./imp.js";

const api = globalThis.browser ?? globalThis.chrome;
const $ = (id) => document.getElementById(id);
const SVG_NS = "http://www.w3.org/2000/svg";

// While Imp isn't there (or hasn't said who's out yet), one red Imp stands in.
const STAND_IN = { name: "", hue: 0, scale: 1, mood: "idle", away: false, traits: null };
const MAX_IMPS = 4;
const MIN_TRYING = 600;    // a reconnect shows as "trying" at least this long (ms), so it reads as an answer
const GIVE_UP = 5000;      // ...and never longer than this
const AGO_EVERY = 20_000;
const WANDER_EVERY = 2600;

const still = reducedMotion();
const clock = new Clock();

let state = null;          // the background's last word
let tab = null;            // the tab in front: { url, title, icon }
let trying = 0;            // when Reconnect was pressed (0: not trying)
let online = false;        // which layout is showing; kept steady while trying, so nothing jumps
let pointer = null;
let port = null;

// MARK: Small helpers

function setText(el, text) {
  if (el.textContent !== text) el.textContent = text;
}

function hostOf(url) {
  try { return new URL(url).host; } catch { return ""; }
}

function icon(use, name) {
  use.setAttribute("href", `#${name}`);
}

const clamp = (x, lo, hi) => Math.min(Math.max(x, lo), hi);

// MARK: Render

function render() {
  const connected = !!state?.connected;
  if (!trying) online = connected;
  $("main").hidden = !state;
  renderStatus(connected);
  $("offline").hidden = !state || online;
  renderTab(online ? tab : null);
  renderActivity(state && online ? state.activity : null);
  if (state) renderImps(state.troupe?.length ? state.troupe : [STAND_IN]);
}

function renderStatus(connected) {
  const text = trying ? "Connecting…"
    : connected ? (state.browser ? `Connected · ${state.browser}` : "Connected")
    : state ? "Not connected" : "Checking…";
  setText($("status-text"), text);
  $("status").classList.toggle("on", connected && !trying);
  $("status").classList.toggle("connecting", !!trying || !state);
  $("stage").classList.toggle("asleep", !online);
  const button = $("reconnect");
  button.classList.toggle("spin", !!trying);
  button.setAttribute("aria-busy", trying ? "true" : "false");
}

// MARK: The tab

function renderTab(page) {
  $("tab").hidden = !page;
  if (!page) return;
  const host = hostOf(page.url);
  setText($("tab-title"), page.title || host || "Untitled page");
  setText($("tab-host"), host || page.url);
  setText($("tab-letter"), (host.replace(/^www\./, "")[0] || "•").toUpperCase());
  const img = $("tab-icon");
  const usable = /^(https?:|data:image\/)/.test(page.icon);
  if (usable && img.getAttribute("src") !== page.icon) img.src = page.icon;
  if (!usable) img.removeAttribute("src");
  img.hidden = !usable || img.dataset.broken === page.icon;
  $("tab-letter").hidden = !img.hidden;
  // Imp can look inside ordinary web pages; the browser keeps its own pages and store to itself.
  const seen = /^https?:/.test(page.url) && !/(chrome\.google\.com\/webstore|chromewebstore\.google\.com|addons\.mozilla\.org)/.test(page.url);
  const sight = $("tab-sight");
  sight.className = `sight ${seen ? "yes" : "no"}`;
  icon($("tab-sight-icon"), seen ? "i-eye" : "i-blind");
  const label = seen ? "Imp can read this page and find things on it, when it needs to."
                     : "The browser keeps this page to itself: Imp only knows its address.";
  sight.title = label;
  sight.setAttribute("aria-label", label);
}

$("tab-icon").addEventListener("error", (e) => {
  e.target.dataset.broken = e.target.getAttribute("src");
  e.target.hidden = true;
  $("tab-letter").hidden = false;
});

async function refreshTab() {
  try {
    const [t] = await api.tabs.query({ active: true, currentWindow: true });
    tab = t?.url ? { url: t.url, title: t.title || "", icon: t.favIconUrl || "" } : null;
  } catch {
    tab = null;
  }
  render();
}

api.tabs.onUpdated.addListener((id, change, t) => {
  if (t.active && (change.url || change.title || change.favIconUrl)) refreshTab();
});

// MARK: What Imp did

let activityKey = "";
let agoCells = [];   // [{ el, at }]

/// What Imp just did. The site is named only when it isn't the tab you're on.
function renderActivity(items) {
  $("activity").hidden = !items;
  if (!items) return;
  $("activity-empty").hidden = items.length > 0;
  const here = tab ? hostOf(tab.url) : "";
  const key = `${here}|${items.map((a) => `${a.at}${a.ok}`).join()}`;
  if (key === activityKey) return;
  activityKey = key;
  agoCells = [];
  $("activity-list").replaceChildren(...items.map((a) => {
    const li = $("row").content.firstElementChild.cloneNode(true);
    const [glyph, what, when] = li.children;
    if (!a.ok) li.className = "missed";
    icon(glyph.querySelector("use"), a.kind === "find" ? (a.ok ? "i-found" : "i-miss") : "i-read");
    if (a.kind === "find") {
      const b = document.createElement("b");
      b.textContent = `“${a.query}”`;
      what.append(a.ok ? "Found " : "Looked for ", b);
    } else {
      what.append(a.ok ? "Read the page" : "Couldn't read the page");
    }
    if (a.host && a.host !== here) what.append(` · ${a.host}`);
    agoCells.push({ el: when, at: a.at });
    return li;
  }));
  tickAgo();
}

function ago(at) {
  const s = Math.max(0, Math.round((Date.now() - at) / 1000));
  if (s < 10) return "now";
  if (s < 60) return `${s}s`;
  if (s < 3600) return `${Math.round(s / 60)}m`;
  return `${Math.round(s / 3600)}h`;
}

function tickAgo() {
  for (const c of agoCells) setText(c.el, ago(c.at));
}

// MARK: The Imps

const cells = [];   // one per Imp on the stage: { root, canvas, name, phone, fig, look, size, mood, rect, wander }

function makeCell(n) {
  const root = document.createElement("div");
  root.className = "imp";
  const canvas = document.createElement("canvas");
  canvas.setAttribute("role", "img");
  const tag = document.createElement("span");
  tag.className = "tag";
  const name = document.createElement("span");
  name.className = "name";
  const phone = document.createElementNS(SVG_NS, "svg");
  phone.classList.add("phone");
  phone.setAttribute("aria-hidden", "true");
  phone.append(document.createElementNS(SVG_NS, "use"));
  icon(phone.firstChild, "i-phone");
  tag.append(name, phone);
  root.append(canvas, tag);
  $("imps").append(root);
  const fig = new ImpCanvas(canvas, { live: !still, phase: n * 1.7 });
  if (!still) clock.add(fig);
  return { root, canvas, tag, name, phone, fig, look: "", size: 0, mood: "", rect: null, wander: null };
}

function removeCell(cell) {
  clock.remove(cell.fig);
  cell.root.remove();
}

function renderImps(list) {
  const shown = list.slice(0, MAX_IMPS);
  const many = shown.length > 2;
  let changed = false;
  while (cells.length > shown.length) { removeCell(cells.pop()); changed = true; }
  shown.forEach((imp, n) => {
    if (!cells[n]) { cells[n] = makeCell(n); changed = true; }
    changed = updateCell(cells[n], imp, many) || changed;
  });
  if (changed) for (const cell of cells) cell.rect = null;   // the layout moved: measure again when needed
}

/// Brings one Imp up to date; true if its size changed. Only what differs is touched.
function updateCell(cell, imp, many) {
  const away = !!imp.away;
  const mood = !online || away ? "sleepy" : imp.mood || "idle";
  if (mood !== cell.mood) { cell.mood = mood; cell.fig.setMood(mood); }

  const look = JSON.stringify([imp.hue, imp.traits]);
  if (look !== cell.look) { cell.look = look; cell.fig.setImp(imp); }

  const size = Math.round((many ? 70 : 88) * clamp(Number(imp.scale) || 1, 0.75, 1.05));
  const resized = size !== cell.size;
  if (resized) { cell.size = size; cell.fig.resize(size); }

  const name = String(imp.name || "");
  const label = away ? `${name} is on your iPhone` : name;
  if (cell.canvas.getAttribute("aria-label") !== (label || "Imp")) cell.canvas.setAttribute("aria-label", label || "Imp");
  cell.root.title = label;
  cell.root.classList.toggle("away", away);
  setText(cell.name, name);
  cell.tag.hidden = !name;
  cell.phone.style.display = away ? "" : "none";
  return resized;
}

// MARK: Looking at the pointer

/// Where the pointer is from an Imp, as -1…1 on both axes (or where it glances while there is none).
function aim(cell) {
  if (!pointer) return cell.fig.setGaze(cell.wander);
  cell.rect ??= cell.canvas.getBoundingClientRect();
  const dx = pointer.x - (cell.rect.left + cell.rect.width / 2);
  const dy = pointer.y - (cell.rect.top + cell.rect.height / 2);
  const d = Math.max(1, Math.hypot(dx, dy));
  const k = Math.min(1, d / 220);
  cell.fig.setGaze([(dx / d) * k, (dy / d) * k]);
}

function aimAll() {
  for (const cell of cells) aim(cell);
}

let wanderTimer = 0;

// Rests when the popup is hidden: no frames, no timers.
function rest() {
  clock.pause(document.hidden);
  clearInterval(wanderTimer);
  if (document.hidden || still) return;
  wanderTimer = setInterval(() => {
    if (pointer) return;
    for (const cell of cells) cell.wander = [(Math.random() - 0.5) * 1.6, (Math.random() - 0.5) * 0.7];
    aimAll();
  }, WANDER_EVERY);
}

if (!still) { // with reduced motion the Imps hold still poses and don't follow the pointer
  document.addEventListener("pointermove", (e) => { pointer = { x: e.clientX, y: e.clientY }; aimAll(); }, { passive: true });
  document.documentElement.addEventListener("pointerleave", () => { pointer = null; aimAll(); });
}
document.addEventListener("visibilitychange", rest);
setInterval(() => { if (!document.hidden) tickAgo(); }, AGO_EVERY);
rest();

// MARK: The background

function connect() {
  try {
    port = api.runtime.connect({ name: "popup" });
  } catch {
    return; // the extension was reloaded under this popup: nothing to talk to
  }
  port.onMessage.addListener((s) => {
    state = s;
    settle();
    render();
  });
  // The background was put to sleep: asking again wakes it.
  port.onDisconnect.addListener(() => { port = null; setTimeout(connect, 300); });
}

/// Ends "trying" once the attempt is over and has been on show long enough to be seen.
function settle() {
  if (!trying) return;
  const waited = performance.now() - trying;
  if (waited >= GIVE_UP || (waited >= MIN_TRYING && !state?.connecting)) trying = 0;
}

const settleAndRender = () => { settle(); render(); };

// Pressing Reconnect changes the screen right now; the background is only told.
$("reconnect").addEventListener("click", () => {
  if (trying) return;
  trying = performance.now();
  if (!port) connect();
  port?.postMessage({ type: "reconnect" });
  setTimeout(settleAndRender, MIN_TRYING);
  setTimeout(settleAndRender, GIVE_UP);
  render();
});

// Opens Imp's window, starting Imp if it isn't running (its imp:// link). The browser may ask
// first; the tab stays where it is.
$("open").addEventListener("click", async () => {
  try {
    const [t] = await api.tabs.query({ active: true, currentWindow: true });
    if (t?.id !== undefined && /^https?:/.test(t.url || "")) await api.tabs.update(t.id, { url: "imp://settings" });
    else await api.tabs.create({ url: "imp://settings" });
  } catch {}
  window.close();
});

render();
connect();
refreshTab();
