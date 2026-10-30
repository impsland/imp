// Imp in the browser: draws an Imp and plays animations from a kit's JSON alone.
// A port of the app's own renderer (Face, Motion, Head, Horn, Extras), so what plays here
// is what plays on the Mac and the iPhone. Everything is built with the DOM API: nothing is
// parsed from text, and nothing the kit says reaches the page as markup.

const SVGNS = 'http://www.w3.org/2000/svg';
const TAU = Math.PI * 2;

export const MOODS = ['idle', 'happy', 'love', 'content', 'giggly', 'excited', 'surprised', 'curious', 'thinking',
  'shy', 'sad', 'scared', 'bored', 'sleepy', 'annoyed', 'mean', 'dizzy', 'error', 'listening', 'working'];
export const GLYPHS = ['notes', 'question', 'exclaim', 'idea', 'sweat', 'heart', 'sparkles'];
export const MOVES = ['spin', 'flip', 'roll', 'bounce', 'shake', 'sway', 'wobble', 'float', 'nod', 'headshake'];
export const DEFAULT_IMP = Object.freeze({ name: 'Imp', hue: 0, scale: 1, traits: Object.freeze({}) });

const TRAIT_RANGES = {
  lids: [0, 0.6], slant: [-1, 1], eyes: [-0.4, 0.4], squint: [-1, 1], horns: [-30, 30],
  blush: [0, 1], tilt: [-12, 12], tempo: [0.6, 1.6],
};
const MAX_BEATS = 24;
const MAX_DURATION = 20;

const clamp = (x, lo, hi) => Math.min(Math.max(x, lo), hi);
const finite = (v, fallback) => (typeof v === 'number' && Number.isFinite(v) ? v : fallback);
const isObject = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);

export function reducedMotion() {
  return typeof matchMedia === 'function' && matchMedia('(prefers-reduced-motion: reduce)').matches;
}

// ---------------------------------------------------------------- reading a kit

export function defaultTimes(move) {
  if (move === 'bounce' || move === 'wobble') return 3;
  if (move === 'shake') return 4;
  if (move === 'sway' || move === 'float' || move === 'nod' || move === 'headshake') return 2;
  return 1;
}

export function normalizeBeat(raw) {
  if (!isObject(raw)) return null;
  const duration = clamp(finite(raw.duration, 0.5), 0.05, 6);
  let look = null;
  if (Array.isArray(raw.look) && raw.look.length === 2 && raw.look.every((n) => typeof n === 'number')) {
    look = [raw.look[0], raw.look[1]];
  } else if (isObject(raw.look)) {
    look = [finite(raw.look.x, 0), finite(raw.look.y, 0)];
  } else if (typeof raw.lookX === 'number' || typeof raw.lookY === 'number') {
    look = [finite(raw.lookX, 0), finite(raw.lookY, 0)];
  }
  if (look) look = look.map((n) => clamp(finite(n, 0), -1, 1));
  const lower = (v) => (typeof v === 'string' ? v.toLowerCase() : null);
  const mood = MOODS.includes(lower(raw.mood)) ? lower(raw.mood) : null;
  const glyph = GLYPHS.includes(lower(raw.glyph)) ? lower(raw.glyph) : null;
  const move = MOVES.includes(lower(raw.move)) ? lower(raw.move) : null;
  const beat = {
    duration, look, mood, glyph,
    tilt: clamp(finite(raw.tilt, 0), -30, 30),
    hop: raw.hop === true,
    stretch: clamp(finite(raw.stretch, 0), -0.3, 0.3),
    move, times: null, reverse: false,
  };
  if (move) {
    const n = Math.round(clamp(finite(raw.times, defaultTimes(move)), 1, 8));
    beat.times = n;
    beat.reverse = raw.reverse === true;
  }
  return beat;
}

export function normalizeAnimation(raw) {
  if (!isObject(raw) || !Array.isArray(raw.beats)) return null;
  const beats = raw.beats.slice(0, MAX_BEATS).map(normalizeBeat).filter(Boolean);
  if (!beats.length) return null;
  const total = beats.reduce((sum, b) => sum + b.duration, 0);
  if (total > MAX_DURATION) {
    const k = MAX_DURATION / total;
    for (const b of beats) b.duration = Math.max(0.05, b.duration * k);
  }
  const text = (v, max) => (typeof v === 'string' ? v.trim().slice(0, max) : '');
  return {
    name: text(raw.name, 40),
    about: text(raw.about, 200),
    replaces: text(raw.replaces, 40),
    starts: Array.isArray(raw.starts) ? raw.starts.filter((s) => typeof s === 'string').slice(0, 20) : [],
    enabled: raw.enabled !== false,
    beats,
    duration: beats.reduce((sum, b) => sum + b.duration, 0),
  };
}

export function normalizeTraits(raw) {
  const out = {};
  const source = isObject(raw) ? raw : {};
  for (const [key, [lo, hi]] of Object.entries(TRAIT_RANGES)) {
    out[key] = clamp(finite(source[key], key === 'tempo' ? 1 : 0), lo, hi);
  }
  return out;
}

export function normalizeImp(raw) {
  const source = isObject(raw) ? raw : {};
  return {
    name: typeof source.name === 'string' && source.name.trim() ? source.name.trim().slice(0, 60) : 'Imp',
    hue: clamp(finite(source.hue, 0), 0, 1),
    scale: clamp(finite(source.scale, 1), 0.5, 2),
    traits: normalizeTraits(source.traits),
  };
}

export function hueName(h) {
  const hue = ((h % 1) + 1) % 1;
  const names = [[0.04, 'red'], [0.12, 'orange'], [0.19, 'amber'], [0.28, 'yellow-green'], [0.45, 'green'],
    [0.53, 'teal'], [0.66, 'blue'], [0.74, 'indigo'], [0.82, 'purple'], [0.93, 'pink'], [1.01, 'red']];
  return names.find(([limit]) => hue < limit)[1];
}

export function traitsSummary(raw) {
  const t = normalizeTraits(raw);
  const parts = [];
  if (t.lids >= 0.15) parts.push('heavy lids');
  if (t.slant >= 0.2) parts.push('cross brows');
  else if (t.slant <= -0.2) parts.push('worried brows');
  if (t.eyes >= 0.1) parts.push('big eyes');
  else if (t.eyes <= -0.1) parts.push('small eyes');
  if (Math.abs(t.squint) >= 0.25) parts.push('a squint');
  if (t.horns >= 8) parts.push('perky horns');
  else if (t.horns <= -8) parts.push('droopy horns');
  if (t.blush >= 0.3) parts.push('rosy cheeks');
  if (Math.abs(t.tilt) >= 3) parts.push('a cocked head');
  if (t.tempo <= 0.85) parts.push('slow');
  else if (t.tempo >= 1.2) parts.push('quick');
  if (!parts.length) return 'Plain';
  return [parts[0][0].toUpperCase() + parts[0].slice(1), ...parts.slice(1)].join(', ');
}

// ---------------------------------------------------------------- colour

function hsv(h, s, v) {
  const h6 = (h - Math.floor(h)) * 6;
  const i = Math.floor(h6);
  const f = h6 - i;
  const p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f));
  const table = [[v, t, p], [q, v, p], [p, v, t], [p, q, v], [t, p, v], [v, p, q]];
  return table[i % 6];
}

const mixRGB = (a, b, k) => {
  const t = clamp(k, 0, 1);
  return [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t];
};

const hex = (rgb) => '#' + rgb.map((c) => Math.round(clamp(c, 0, 1) * 255).toString(16).padStart(2, '0')).join('');

function makePalette(h) {
  return {
    skinTop: hsv(h + 0.0077, 0.684, 0.95), skin: hsv(h + 0.0025, 0.733, 0.9), skinBottom: hsv(h - 0.0026, 0.778, 0.81),
    flushTop: hsv(h + 0.0083, 0.816, 0.98), flushBottom: hsv(h - 0.007, 0.895, 0.76),
    hornLight: hex(hsv(h + 0.0048, 0.673, 0.52)), hornDark: hex(hsv(h - 0.009, 0.73, 0.26)),
    blush: hex(hsv(h, 0.45, 1)),
  };
}

// ---------------------------------------------------------------- the face

const FACE0 = Object.freeze({
  headW: 1, headH: 1, square: 2, sag: 0, peak: 0, wobble: 0, tilt: 0, lookX: 0, lookY: 0,
  eyeW: 1, eyeH: 1, lid: 0, slant: 0, squint: 0, arc: 0, bend: 1, squeeze: 0, spiral: 0,
  horn: 0, hornSize: 1, flush: 0, blush: 0, burst: 0, sparkle: 0, heart: 0, sleep: 0,
});
const FACE_FIELDS = Object.keys(FACE0);
const BEND_INDEX = FACE_FIELDS.indexOf('bend');

const MOOD_FACES = {
  idle: {},
  listening: { headH: 1.05, headW: 0.97, peak: 0.15, eyeH: 1.14, eyeW: 1.06, horn: 10, lookY: -0.15 },
  thinking: { lookX: -0.55, lookY: -0.55, tilt: -6, lid: 0.3, slant: -0.12, squint: 0.6, wobble: 0.2 },
  happy: { arc: 1, blush: 1, sag: 0.5, headW: 1.06, headH: 0.94, peak: 0.1, horn: 8, sparkle: 0.8 },
  love: { arc: 1, blush: 1, sag: 0.35, headW: 1.04, headH: 0.96, lookX: 0.3, tilt: 6, horn: 6, heart: 1 },
  sad: { lid: 0.34, slant: -0.7, sag: 0.7, headW: 1.05, headH: 0.93, horn: -20, lookY: 0.25, eyeH: 1.05 },
  error: { squeeze: 1, headW: 1.07, headH: 0.91, sag: 0.3, burst: 0.7, horn: -8, tilt: -4 },
  sleepy: { arc: 1, bend: -1, sag: 0.6, headH: 0.88, headW: 1.08, lookY: 0.3, horn: -14, sleep: 1 },
  annoyed: { lid: 0.5, slant: 0.75, flush: 1, square: 2.6, headW: 1.04, burst: 1, horn: 6, hornSize: 1.12, lookY: 0.1 },
  surprised: { headH: 1.1, headW: 0.94, peak: 1, eyeW: 1.12, eyeH: 1.26, horn: 16, hornSize: 1.05, burst: 1 },
  dizzy: { spiral: 1, wobble: 0.45, sag: 0.3, headW: 1.03, headH: 0.96, horn: -10 },
  working: { lookX: 0.3, lookY: 0.5, lid: 0.16, eyeH: 0.92, headW: 1.02, horn: 6 },
  mean: { lid: 0.56, slant: 0.3, squint: 0.55, flush: 0.25, tilt: -4, horn: 12, hornSize: 1.06, lookY: 0.05, headH: 0.97 },
  content: { arc: 1, bend: 0.55, blush: 1, sag: 0.6, headW: 1.07, headH: 0.93, horn: -6, lookY: -0.1 },
  giggly: { squeeze: 1, blush: 1, headW: 1.05, headH: 0.95, wobble: 0.3, horn: 10, sparkle: 0.5 },
  scared: { eyeW: 0.72, eyeH: 1.08, lid: 0.16, slant: -0.6, horn: -26, hornSize: 0.95, headH: 0.9, headW: 0.99, sag: 0.1, lookY: 0.15 },
  curious: { tilt: 10, squint: -0.6, eyeH: 1.08, peak: 0.35, horn: 12, headH: 1.04, headW: 0.98, lookY: -0.1 },
  shy: { blush: 1, eyeH: 0.74, eyeW: 0.9, lid: 0.18, slant: -0.25, lookX: 0.55, lookY: 0.45, tilt: 7, horn: -8, headH: 0.95, sag: 0.3 },
  excited: { eyeW: 1.12, eyeH: 1.2, sparkle: 1, peak: 0.5, horn: 18, hornSize: 1.06, headH: 1.06, headW: 0.97, lookY: -0.15 },
  bored: { lid: 0.55, eyeH: 0.95, sag: 0.45, headH: 0.94, headW: 1.05, horn: -10, lookX: -0.45, lookY: 0.15, tilt: -4 },
};

const EYES_CLOSED = new Set(['happy', 'love', 'sleepy', 'error', 'dizzy', 'content', 'giggly']);
const WATCHES_CURSOR = new Set(['idle', 'surprised', 'annoyed', 'curious', 'scared', 'excited']);

function faceFor(mood) {
  return { ...FACE0, ...(MOOD_FACES[mood] || {}) };
}

function applyTraits(t, f) {
  f.lid = Math.min(0.9, f.lid + t.lids * (1 - f.lid));
  f.slant += t.slant * 0.6;
  f.eyeW *= 1 + t.eyes;
  f.eyeH *= 1 + t.eyes;
  f.squint = clamp(f.squint + t.squint * 0.6, -1, 1);
  f.horn += t.horns;
  f.blush = Math.max(f.blush, t.blush);
  f.tilt += t.tilt;
}

function faceTarget(mood, step, gaze, traits, attentive) {
  const f = faceFor(mood);
  if (step && step.look) {
    f.lookX = step.look[0];
    f.lookY = step.look[1];
  } else if (gaze && WATCHES_CURSOR.has(mood)) {
    f.lookX = gaze[0];
    f.lookY = gaze[1];
    if (attentive) {
      f.horn += 8;
      f.eyeH *= 1.05;
    }
  }
  if (step) {
    f.tilt += step.tilt;
    f.headH *= 1 + step.stretch;
    f.headW *= 1 - step.stretch * 0.6;
  }
  applyTraits(traits, f);
  return f;
}

// Springs every face parameter toward its target: slightly bouncy, alive.
class FaceAnimator {
  constructor() {
    this.face = faceFor('idle');
    this.velocity = new Array(FACE_FIELDS.length).fill(0);
    this.last = null;
    this.settled = false;
  }

  snap(target) {
    this.face = { ...target };
    this.velocity.fill(0);
    this.settled = true;
  }

  step(target, t) {
    const gap = Math.max(0, t - (this.last ?? t));
    const dt = gap > 0.1 ? 1 / 60 : Math.min(1 / 20, gap);
    this.last = t;
    if (dt <= 0) return this.face;
    const goal = { ...target };
    if (goal.arc < 0.01) goal.bend = this.face.bend;
    if (this.face.arc < 0.3) {
      this.face.bend = goal.bend;
      this.velocity[BEND_INDEX] = 0;
    }
    const n = Math.ceil(dt / (1 / 120));
    const h = dt / n;
    const stiffness = 210, damping = 17;
    for (let s = 0; s < n; s++) {
      for (let i = 0; i < FACE_FIELDS.length; i++) {
        const k = FACE_FIELDS[i];
        const x = this.face[k];
        const v = this.velocity[i] + ((goal[k] - x) * stiffness - this.velocity[i] * damping) * h;
        this.velocity[i] = v;
        this.face[k] = x + v * h;
      }
    }
    let settled = true;
    for (let i = 0; i < FACE_FIELDS.length; i++) {
      const k = FACE_FIELDS[i];
      if (Math.abs(this.face[k] - goal[k]) > 0.002 || Math.abs(this.velocity[i]) > 0.01) { settled = false; break; }
    }
    this.settled = settled;
    return this.face;
  }
}

// Moods fade into each other over a third of a second, so the body never jumps.
class BlendWeights {
  constructor(duration) {
    this.duration = duration;
    this.weights = new Map();
    this.last = null;
  }

  advance(current, t) {
    if (this.last === null || t < this.last || this.weights.size === 0) {
      this.weights = new Map([[current, 1]]);
      this.last = t;
      return;
    }
    const gap = t - this.last;
    const step = (gap > 0.1 ? 1 / 60 : gap) / this.duration;
    this.last = t;
    let total = 0;
    for (const [key, w] of this.weights) if (key !== current) total += w;
    const moved = Math.min(step, total);
    if (total <= 1e-9 || moved >= total) {
      this.weights = new Map([[current, 1]]);
      return;
    }
    const next = new Map();
    for (const [key, w] of this.weights) if (key !== current) next.set(key, (w * (total - moved)) / total);
    next.set(current, 1 - (total - moved));
    this.weights = next;
  }

  get settled() {
    return this.weights.size <= 1;
  }
}

// ---------------------------------------------------------------- motion

const HOP_LENGTH = 0.75;
const HOP_HEIGHT = 15;
const BREATH_RATE = 1.7;

const smooth = (x) => { const k = clamp(x, 0, 1); return k * k * (3 - 2 * k); };
const ease = (x) => { const k = clamp(x, 0, 1); return k < 0.5 ? 4 * k * k * k : 1 - Math.pow(-2 * k + 2, 3) / 2; };
const edge = (p) => Math.max(0, 1 - Math.min(p, 1 - p) / 0.12) * Math.min(1, Math.min(p, 1 - p) / 0.04);

function newMotion(t) {
  return { t, blink: 0, bob: 0, squash: 0, shakeX: 0, tilt: 0, hornL: 0, hornR: 0, ripple: 0, lift: 0, spin: 0, pitch: 0, roll: 0 };
}

function blinkAt(t) {
  const period = 4.3, duration = 0.16;
  const cycle = Math.floor(t / period);
  const r = Math.abs((Math.sin(cycle * 12.9898) * 43758.5453) % 1);
  const p = t - (cycle * period + r * (period - 0.6));
  if (p >= 0 && p < duration) return Math.sin((p / duration) * Math.PI);
  if (r > 0.8 && p >= 0.24 && p < 0.24 + duration) return Math.sin(((p - 0.24) / duration) * Math.PI);
  return 0;
}

function motionAt(t, mood, breathing) {
  const m = newMotion(t);
  if (breathing) {
    const b = Math.sin(t * BREATH_RATE);
    m.bob = b * 0.7;
    m.squash = b * 0.016;
  }
  if (!EYES_CLOSED.has(mood)) m.blink = blinkAt(t);
  const s = Math.sin;
  switch (mood) {
    case 'thinking': m.hornL = s(t * 5.5) * 8; m.hornR = -m.hornL; break;
    case 'happy': case 'love': {
      const b = Math.abs(s(t * 7));
      m.bob -= b * 3.5; m.squash = (1 - b) * 0.08 - 0.02; m.hornL = s(t * 14) * 5; m.hornR = -m.hornL;
      break;
    }
    case 'annoyed': m.shakeX = s(t * 48) * 1.2; break;
    case 'error': m.shakeX = s(t * 30) * 0.8; m.squash = 0.05; break;
    case 'surprised': m.bob -= 2.5; m.squash = -0.05; break;
    case 'sleepy': m.bob = s(t * 0.9); m.squash = 0.03 + s(t * 0.9) * 0.03; break;
    case 'sad': m.squash = 0.04; break;
    case 'dizzy':
      m.tilt = s(t * 3.2) * 9; m.shakeX = s(t * 3.2 + 1.2) * 1.4; m.hornL = s(t * 3.2) * 6; m.hornR = m.hornL;
      break;
    case 'mean': m.squash = 0.02; break;
    case 'working': {
      const tap = Math.abs(s(t * 9));
      m.bob -= tap * 1.1; m.hornL = s(t * 9) * 4; m.hornR = -m.hornL;
      break;
    }
    case 'content': m.tilt = s(t * 2.2) * 3; m.ripple = 0.12; m.hornL = s(t * 2.2) * 3; m.hornR = m.hornL; break;
    case 'giggly': {
      const b = Math.abs(s(t * 11));
      m.bob -= b * 2.5; m.squash = (1 - b) * 0.06 - 0.02; m.tilt = s(t * 9) * 4;
      break;
    }
    case 'scared':
      m.shakeX = s(t * 55) * 0.9; m.squash = 0.05; m.bob += 1; m.hornL = s(t * 40) * 2; m.hornR = -m.hornL;
      break;
    case 'curious': m.tilt = s(t * 1.6) * 2.5; m.hornL = Math.max(0, s(t * 3)) * 6; break;
    case 'shy': m.shakeX = s(t * 2.5) * 0.8; m.squash = 0.02; break;
    case 'excited': {
      const b = Math.abs(s(t * 9));
      m.bob -= b * 4; m.squash = (1 - b) * 0.07 - 0.03; m.hornL = s(t * 18) * 6; m.hornR = -m.hornL;
      break;
    }
    case 'bored': m.squash = 0.03; break;
    default: break;
  }
  return m;
}

const MOTION_KEYS = ['blink', 'bob', 'squash', 'shakeX', 'tilt', 'hornL', 'hornR', 'ripple', 'lift', 'spin', 'pitch', 'roll'];

function blendMotions(parts, t) {
  const m = newMotion(t);
  for (const [p, w] of parts) for (const k of MOTION_KEYS) m[k] += p[k] * w;
  return m;
}

function hop(m, since) {
  if (since < 0 || since >= HOP_LENGTH) return;
  if (since < 0.12) {
    m.squash += 0.09 * Math.sin((since / 0.12) * Math.PI / 2);
  } else if (since < 0.56) {
    const k = (since - 0.12) / 0.44;
    const release = 1 - smooth(k / 0.2);
    m.lift += HOP_HEIGHT * Math.sin(k * Math.PI);
    m.squash += 0.09 * release - 0.07 * Math.sin(Math.min(1, k / 0.5) * Math.PI) * (1 - release);
  } else {
    m.squash += 0.1 * Math.sin(((since - 0.56) / 0.19) * Math.PI);
  }
}

function perform(m, beat, elapsed) {
  const duration = beat.duration;
  if (!beat.move || duration <= 0) return;
  const p = clamp(elapsed / duration, 0, 1);
  const n = beat.times, dir = beat.reverse ? -1 : 1;
  const arc = Math.sin(p * Math.PI);
  const wave = Math.sin(p * n * TAU);
  switch (beat.move) {
    case 'spin': m.spin += dir * n * TAU * ease(p); m.squash -= 0.05 * arc; break;
    case 'flip':
      m.pitch += dir * n * TAU * ease(p); m.lift += HOP_HEIGHT * 1.2 * arc; m.squash += 0.06 * edge(p) - 0.05 * arc;
      break;
    case 'roll': m.roll += dir * n * 360 * ease(p); m.lift += HOP_HEIGHT * 1.1 * Math.pow(arc, 0.6); break;
    case 'bounce': {
      const k = (p * n) % 1;
      const up = Math.sin(k * Math.PI);
      m.lift += HOP_HEIGHT * 0.75 * up;
      m.squash += (0.08 * Math.pow(1 - up, 6) - 0.05 * up) * Math.pow(arc, 0.35);
      break;
    }
    case 'shake': m.shakeX += dir * 3.2 * wave; m.tilt += dir * 2.5 * wave; break;
    case 'sway': m.tilt += dir * 13 * wave; m.shakeX += dir * 1.2 * wave; break;
    case 'wobble': m.squash += 0.13 * wave * (1 - p); m.ripple += 0.7 * arc; break;
    case 'float': {
      const rise = smooth(p / 0.25) * smooth((1 - p) / 0.25);
      m.lift += (HOP_HEIGHT * 0.9 + 2.5 * wave) * rise;
      m.squash -= 0.03 * rise;
      break;
    }
    case 'nod': {
      const k = Math.sin(p * n * Math.PI);
      m.pitch += 0.55 * k * k;
      break;
    }
    case 'headshake': m.spin += dir * 0.6 * wave * Math.pow(arc, 0.5); break;
    default: break;
  }
}

// ---------------------------------------------------------------- geometry

const SIZE = { cx: 50, bottom: 84, rx: 33, top: 33, base: 19 };

const vadd = (a, b) => [a[0] + b[0], a[1] + b[1], a[2] + b[2]];
const vsub = (a, b) => [a[0] - b[0], a[1] - b[1], a[2] - b[2]];
const vmul = (a, k) => [a[0] * k, a[1] * k, a[2] * k];
const vdot = (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
const vcross = (a, b) => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
const vnorm = (a) => vmul(a, 1 / Math.max(1e-9, Math.sqrt(vdot(a, a))));
const onBall = (lon, lat) => [Math.cos(lat) * Math.sin(lon), Math.sin(lat), Math.cos(lat) * Math.cos(lon)];

function makePose(f, spin, tumble) {
  const yaw = f.lookX * 0.72 + spin;
  const pitch = f.lookY * 0.62 + tumble;
  const cy = Math.cos(yaw), sy = Math.sin(yaw), cp = Math.cos(pitch), sp = Math.sin(pitch);
  return (v) => {
    const ax = v[0] * cy + v[2] * sy, az = -v[0] * sy + v[2] * cy;
    return [ax, v[1] * cp + az * sp, -v[1] * sp + az * cp];
  };
}

function makeHead(p) {
  const head = { ...p, pts: [] };
  const ripple = (theta) => 1 + p.wobble * (0.03 * Math.sin(3 * theta + p.t * 4.2) + 0.018 * Math.sin(5 * theta - p.t * 6.1));
  const shear = (y) => p.lean * 1.8 * Math.max(0, -y / p.top);
  head.point = (theta) => {
    const c = Math.cos(theta), s = Math.sin(theta);
    const k = Math.pow(Math.max(0, s), 1.5);
    const ex = 2 / (p.square + 0.25 * k), ey = 2 / (p.square + 1.6 * k);
    let x = p.rx * Math.sign(c) * Math.pow(Math.abs(c), ex);
    let y = (s < 0 ? p.top : p.bottom) * Math.sign(s) * Math.pow(Math.abs(s), ey);
    if (s > 0) x *= 1 + p.sag * 0.08 * Math.exp(-Math.pow((y / p.bottom - 0.45) / 0.35, 2));
    const raw = theta + Math.PI / 2;
    const d = raw - TAU * Math.round(raw / TAU);
    y -= p.peak * p.top * 0.12 * Math.exp((-d * d) / 0.08);
    const w = ripple(theta);
    return [p.cx + x * w + shear(y), p.cy + y * w];
  };
  head.project = (v) => {
    const x = p.rx * v[0], y = v[1] * (v[1] < 0 ? p.top : p.bottom);
    const w = p.wobble === 0 ? 1 : ripple(Math.atan2(v[1], v[0]));
    return [p.cx + x * w + shear(y), p.cy + y * w];
  };
  const n = 96;
  let d = '';
  for (let i = 0; i < n; i++) {
    const pt = head.point(-Math.PI / 2 + (i / n) * TAU);
    head.pts.push(pt);
    d += (i === 0 ? 'M' : 'L') + pt[0].toFixed(2) + ' ' + pt[1].toFixed(2);
  }
  head.d = d + 'Z';
  return head;
}

function hullOf(points) {
  const p = points.slice().sort((a, b) => (a[0] === b[0] ? a[1] - b[1] : a[0] - b[0]));
  if (p.length < 3) return [];
  const cross = (o, a, b) => (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0]);
  const chain = (seq) => {
    const h = [];
    for (const pt of seq) {
      while (h.length >= 2 && cross(h[h.length - 2], h[h.length - 1], pt) <= 0) h.pop();
      h.push(pt);
    }
    h.pop();
    return h;
  };
  return chain(p).concat(chain(p.slice().reverse()));
}

const hullPath = (hulls) => hulls.map((h) => (h.length ? 'M' + h.map((q) => q[0].toFixed(1) + ' ' + q[1].toFixed(1)).join('L') + 'Z' : '')).join('');

const HORN_RINGS = 14, HORN_SEGMENTS = 16, HORN_EMBED = 0.5;

function makeHorn(side, head, rotate, f, wiggle) {
  const root = onBall(side * 0.9, -0.6);
  let axis = vnorm(vadd(vmul(root, 0.62), [0, -0.38, 0]));
  const sideways = [side, 0, 0];
  let out = vnorm(vsub(sideways, vmul(axis, vdot(sideways, axis))));
  const lean = ((-f.horn + wiggle) * Math.PI) / 180;
  const c = Math.cos(lean), s = Math.sin(lean);
  const nextAxis = vadd(vmul(axis, c), vmul(out, s));
  out = vsub(vmul(out, c), vmul(axis, s));
  axis = nextAxis;

  const k = f.hornSize;
  const length = 0.23 * k, curl = -0.085 * k, rBase = 0.145 * k, rTip = 0.042 * k;
  const rootR = rotate(root);
  const origin = head.project(rootR);
  const scale = head.rx;
  const screen = (p) => {
    const r = vsub(rotate(p), rootR);
    return [origin[0] + r[0] * scale, origin[1] + r[1] * scale];
  };
  const spine = (t) => vadd(vadd(root, vmul(axis, length * t)), vmul(out, curl * Math.pow(Math.max(0, t), 2.6)));
  const tangent = (t) => vnorm(vadd(vmul(axis, length), vmul(out, curl * 2.6 * Math.pow(Math.max(0, t), 1.6))));
  const radius = (t) => {
    const q = Math.max(0, t);
    return rTip + (rBase - rTip) * (1 - Math.pow(q, 1.4)) * (1 - 0.25 * q);
  };
  const ts = [-HORN_EMBED];
  for (let i = 0; i <= HORN_RINGS; i++) ts.push(1 - Math.pow(1 - i / HORN_RINGS, 1.3));
  const rings = ts.map((t) => {
    const center = spine(t), tan = tangent(t);
    const u = vnorm(vsub(out, vmul(tan, vdot(out, tan))));
    const w = vcross(tan, u);
    const ring = [];
    for (let j = 0; j < HORN_SEGMENTS; j++) {
      const phi = (j / HORN_SEGMENTS) * TAU;
      ring.push(screen(vadd(center, vmul(vadd(vmul(u, Math.cos(phi)), vmul(w, Math.sin(phi))), radius(t)))));
    }
    return ring;
  });
  const front = [], back = [];
  const isFront = (t) => {
    const p = spine(t);
    return vdot(p, p) > 1 && rotate(p)[2] > 0;
  };
  const add = (points, t) => (isFront(t) ? front : back).push(hullOf(points));
  for (let i = 0; i < ts.length - 1; i++) add(rings[i].concat(rings[i + 1]), (ts[i] + ts[i + 1]) / 2);
  const tip = screen(spine(1)), tr = rTip * scale;
  const cap = [];
  for (let j = 0; j < HORN_SEGMENTS; j++) {
    const phi = (j / HORN_SEGMENTS) * TAU;
    cap.push([tip[0] + tr * Math.cos(phi), tip[1] + tr * Math.sin(phi)]);
  }
  add(cap, 1);
  const mid = screen(spine(0.4));
  const baseR = rBase * scale;
  return {
    front: hullPath(front), back: hullPath(back), facing: clamp(rootR[2] * 4, 0, 1), base: origin, baseR,
    light: [mid[0] - baseR * 0.35, mid[1] - baseR * 0.3], tip, tipR: tr,
  };
}

// ---------------------------------------------------------------- 2D matrices

const mmul = (a, b) => [
  a[0] * b[0] + a[2] * b[1], a[1] * b[0] + a[3] * b[1],
  a[0] * b[2] + a[2] * b[3], a[1] * b[2] + a[3] * b[3],
  a[0] * b[4] + a[2] * b[5] + a[4], a[1] * b[4] + a[3] * b[5] + a[5],
];
const mT = (x, y) => [1, 0, 0, 1, x, y];
const mS = (x, y) => [x, 0, 0, y, 0, 0];
const mR = (deg) => { const r = (deg * Math.PI) / 180, c = Math.cos(r), s = Math.sin(r); return [c, s, -s, c, 0, 0]; };
const mapPoint = (m, p) => [m[0] * p[0] + m[2] * p[1] + m[4], m[1] * p[0] + m[3] * p[1] + m[5]];

// ---------------------------------------------------------------- SVG building

let uidCounter = 0;

function node(name, attrs, parent) {
  const e = document.createElementNS(SVGNS, name);
  if (attrs) for (const [k, v] of Object.entries(attrs)) e.setAttribute(k, v);
  if (parent) parent.appendChild(e);
  return e;
}

const EYE_WHITE = '#fffdfa';

function starPath(cx, cy, r) {
  return `M${cx} ${cy - r}Q${cx} ${cy} ${cx + r} ${cy}Q${cx} ${cy} ${cx} ${cy + r}Q${cx} ${cy} ${cx - r} ${cy}Q${cx} ${cy} ${cx} ${cy - r}Z`;
}

function gradientStops(grad, stops) {
  return stops.map(([offset, color, opacity]) => {
    const attrs = { offset, 'stop-color': color };
    if (opacity !== undefined) attrs['stop-opacity'] = opacity;
    return node('stop', attrs, grad);
  });
}

function buildGlyph(kind, accent, parent) {
  const g = node('g', null, parent);
  const parts = { g, kind };
  const yellow = '#ffc733', spark = '#ffd14d';
  switch (kind) {
    case 'question': case 'exclaim': {
      const text = node('text', {
        'text-anchor': 'middle', 'dominant-baseline': 'central', 'font-weight': '900', fill: accent,
        'font-family': 'ui-rounded, system-ui, -apple-system, Segoe UI, sans-serif', 'font-size': '14',
      }, g);
      text.textContent = kind === 'question' ? '?' : '!';
      break;
    }
    case 'idea':
      node('circle', { cx: 0, cy: -1.2, r: 4.6, fill: yellow }, g);
      node('rect', { x: -2.4, y: 2.8, width: 4.8, height: 3.2, rx: 1, fill: yellow }, g);
      node('path', { d: 'M-2.2 7.4H2.2', stroke: yellow, 'stroke-width': 1.2, 'stroke-linecap': 'round' }, g);
      break;
    case 'heart':
      node('path', { d: 'M0 4.8C-1 4 -5 1.4 -5 -1.6A2.7 2.7 0 0 1 0 -2.9A2.7 2.7 0 0 1 5 -1.6C5 1.4 1 4 0 4.8Z', fill: accent }, g);
      break;
    case 'sparkles':
      node('path', { d: starPath(0, 0, 5.5), fill: spark }, g);
      node('path', { d: starPath(5, -4.5, 2.6), fill: spark }, g);
      node('path', { d: starPath(-4.5, 4.5, 2), fill: spark }, g);
      break;
    case 'sweat':
      node('path', { d: 'M0 -4.4C2.2 -1.4 3.2 0.4 3.2 1.8A3.2 3.2 0 0 1 -3.2 1.8C-3.2 0.4 -2.2 -1.4 0 -4.4Z', fill: '#8ccfff' }, g);
      break;
    case 'notes': {
      parts.notes = [];
      for (let k = 0; k < 3; k++) {
        const text = node('text', {
          'text-anchor': 'middle', 'dominant-baseline': 'central', fill: accent, 'font-weight': '800',
          'font-family': 'ui-rounded, system-ui, -apple-system, Segoe UI, sans-serif',
        }, g);
        text.textContent = k % 2 === 0 ? '♪' : '♫';
        parts.notes.push(text);
      }
      break;
    }
    default: break;
  }
  return parts;
}

// ---------------------------------------------------------------- the figure

const active = new Set();
let frameHandle = 0;

function schedule() {
  if (!frameHandle && active.size) frameHandle = requestAnimationFrame(tick);
}

function tick(ts) {
  frameHandle = 0;
  const now = ts / 1000;
  for (const fig of Array.from(active)) fig.frame(now);
  schedule();
}

const clockNow = () => performance.now() / 1000;

class Figure {
  constructor(svg, imp, opts) {
    this.svg = svg;
    this.opts = opts;
    this.mood = 'idle';
    this.gaze = null;
    this.perf = null;
    this.animator = new FaceAnimator();
    this.blend = new BlendWeights(0.35);
    this.live = opts.live === true && !reducedMotion();
    this.lastDrawn = -1;
    this.glyph = null;
    this.held = null;
    this.destroyed = false;
    this.pointerHandler = null;
    this.setImp(imp);
    if (opts.mood && MOODS.includes(opts.mood)) this.mood = opts.mood;
    if (opts.follow && !reducedMotion()) this.followPointer();
    this.settle();
  }

  setImp(raw) {
    this.imp = normalizeImp(raw);
    this.palette = makePalette(this.imp.hue);
    this.accent = hex(this.palette.skin);
    this.finishPerformance(true);
    this.held = null;
    this.build();
    if (this.r) this.settle();
  }

  build() {
    const svg = this.svg;
    const uid = `imp${++uidCounter}`;
    svg.replaceChildren();
    svg.setAttribute('viewBox', '0 0 100 100');
    svg.setAttribute('role', 'img');
    svg.setAttribute('focusable', 'false');
    const label = `${this.imp.name}, a ${hueName(this.imp.hue)} Imp`;
    svg.setAttribute('aria-label', label);
    const title = node('title', null, svg);
    title.textContent = label;
    const p = this.palette;
    const defs = node('defs', null, svg);
    const r = {};
    r.skinGrad = node('linearGradient', { id: `${uid}s`, gradientUnits: 'userSpaceOnUse', x1: 50, x2: 50 }, defs);
    r.skinStops = gradientStops(r.skinGrad, [[0, hex(p.skinTop)], [0.5, hex(p.skin)], [1, hex(p.skinBottom)]]);
    r.lightGrad = node('radialGradient', { id: `${uid}l`, gradientUnits: 'userSpaceOnUse' }, defs);
    gradientStops(r.lightGrad, [[0, '#fff', 0.14], [0.5, '#fff', 0.05], [1, '#fff', 0]]);
    r.occGrad = node('linearGradient', { id: `${uid}o`, gradientUnits: 'userSpaceOnUse', x1: 0, x2: 0 }, defs);
    gradientStops(r.occGrad, [[0, '#000', 0], [1, '#000', 0.07]]);
    const shadowGrad = node('radialGradient', { id: `${uid}w` }, defs);
    gradientStops(shadowGrad, [[0, '#000', 1], [0.55, '#000', 0.4], [1, '#000', 0]]);
    const contactGrad = node('radialGradient', { id: `${uid}k` }, defs);
    gradientStops(contactGrad, [[0, '#66080d', 0.18], [1, '#66080d', 0]]);
    r.headClip = node('path', null, node('clipPath', { id: `${uid}c` }, defs));
    r.hornGrads = [-1, 1].map((side) => {
      const grad = node('radialGradient', { id: `${uid}h${side < 0 ? 'a' : 'b'}`, gradientUnits: 'userSpaceOnUse' }, defs);
      gradientStops(grad, [[0, p.hornLight], [1, p.hornDark]]);
      return grad;
    });
    r.eyeClips = [-1, 1].map((side) => {
      const clip = node('clipPath', { id: `${uid}e${side < 0 ? 'a' : 'b'}` }, defs);
      return node('rect', { x: -30, y: 0, width: 60, height: 40 }, clip);
    });

    r.shadowWide = node('ellipse', { fill: `url(#${uid}w)` }, svg);
    r.shadowCore = node('ellipse', { fill: `url(#${uid}w)` }, svg);
    r.body = node('g', null, svg);
    r.hornBack = r.hornGrads.map((_, i) => node('path', { fill: `url(#${uid}h${i === 0 ? 'a' : 'b'})` }, r.body));
    r.skin = node('path', { fill: `url(#${uid}s)` }, r.body);
    const inside = node('g', { 'clip-path': `url(#${uid}c)` }, r.body);
    r.light = node('path', { fill: `url(#${uid}l)` }, inside);
    r.occ = node('path', { fill: `url(#${uid}o)` }, inside);
    r.blush = [-1, 1].map(() => {
      const g = node('g', { fill: p.blush }, inside);
      for (let k = 0; k < 3; k++) node('circle', { r: 0.75 }, g);
      return g;
    });
    const eyes = node('g', { 'clip-path': `url(#${uid}c)` }, r.body);
    r.eyes = [-1, 1].map((side, i) => {
      const g = node('g', null, eyes);
      const fill = node('ellipse', { fill: EYE_WHITE, 'clip-path': `url(#${uid}e${i === 0 ? 'a' : 'b'})` }, g);
      const stroke = { fill: 'none', stroke: EYE_WHITE, 'stroke-linecap': 'round', 'stroke-linejoin': 'round' };
      const arc = node('path', { ...stroke, 'stroke-width': 3 }, g);
      const spiral = node('path', { ...stroke, 'stroke-width': 2.4 }, g);
      const squeeze = node('path', { ...stroke, 'stroke-width': 3 }, g);
      return { g, fill, arc, spiral, squeeze, side };
    });
    r.hornFront = r.hornGrads.map((_, i) => node('path', { fill: `url(#${uid}h${i === 0 ? 'a' : 'b'})` }, r.body));
    r.contact = [0, 1].map(() => {
      const holder = node('g', { 'clip-path': `url(#${uid}c)` }, r.body);
      return node('circle', { fill: `url(#${uid}k)` }, holder);
    });
    const extras = node('g', { fill: this.accent }, r.body);
    r.burst = Array.from({ length: 6 }, () => node('line', { stroke: this.accent, 'stroke-width': 1.6, 'stroke-linecap': 'round' }, extras));
    r.sparkles = Array.from({ length: 3 }, () => node('path', { fill: this.accent }, extras));
    r.heart = node('path', { fill: this.accent }, extras);
    r.zs = Array.from({ length: 3 }, () => {
      const z = node('text', {
        'text-anchor': 'middle', 'dominant-baseline': 'central', fill: this.accent, 'font-weight': '800',
        'font-family': 'ui-rounded, system-ui, -apple-system, Segoe UI, sans-serif',
      }, extras);
      z.textContent = 'z';
      return z;
    });
    r.orbit = Array.from({ length: 3 }, () => node('path', { fill: '#ffc733' }, extras));
    r.glyphHost = node('g', null, extras);
    this.r = r;
    this.glyph = null;
    this.lastDrawn = -1;
  }

  settle() {
    const target = this.targetFace(null);
    this.animator.snap(target);
    this.blend.weights = new Map([[this.moodNow(null), 1]]);
    this.draw(clockNow(), true);
  }

  moodNow(beat) {
    return (beat && beat.mood) || this.mood;
  }

  targetFace(beat) {
    return faceTarget(this.moodNow(beat), beat, this.gaze, this.imp.traits, false);
  }

  // The beat playing at time `now`: its index, how far into it, the glyph and the last hop.
  beatAt(now) {
    const perf = this.perf;
    if (!perf) return null;
    let t = now - perf.start;
    if (t < 0) return null;
    let hopSince = null;
    const steps = perf.steps;
    for (let i = 0; i < steps.length; i++) {
      const step = steps[i];
      if (step.hop && (hopSince === null || hopSince >= HOP_LENGTH)) hopSince = 0;
      if (t < step.duration) {
        let glyph = null;
        if (step.glyph) {
          let age = t, remaining = step.duration - t;
          for (let j = i - 1; j >= 0 && steps[j].glyph === step.glyph; j--) age += steps[j].duration;
          for (let j = i + 1; j < steps.length && steps[j].glyph === step.glyph; j++) remaining += steps[j].duration;
          glyph = { kind: step.glyph, age, remaining };
        }
        return { index: i, step, elapsed: t, glyph, hopSince: hopSince === null ? null : hopSince + t };
      }
      t -= step.duration;
      if (hopSince !== null) hopSince += step.duration;
    }
    return null;
  }

  frame(now) {
    if (this.destroyed) return;
    const beat = this.beatAt(now);
    if (this.perf) {
      const index = beat ? beat.index : -1;
      if (index !== this.perf.index) {
        this.perf.index = index;
        if (this.perf.onBeat) this.perf.onBeat(index);
      }
      if (!beat && now - this.perf.start >= this.perf.total) this.finishPerformance(false);
    }
    const idleOnly = !this.perf && this.animator.settled && this.blend.settled;
    if (idleOnly && this.live && now - this.lastDrawn < 1 / 30) return;
    this.draw(now, false, beat);
    if (!this.live && !this.perf && this.animator.settled && this.blend.settled) {
      active.delete(this);
      this.draw(now, true);
    }
  }

  finishPerformance(stopped) {
    const perf = this.perf;
    if (!perf) return;
    this.perf = null;
    if (perf.onBeat) perf.onBeat(-1);
    perf.resolve(stopped ? 'stopped' : 'finished');
    if (perf.onEnd) perf.onEnd(stopped);
  }

  wake() {
    if (this.destroyed) return;
    active.add(this);
    schedule();
  }

  // Draws one frame. `still` draws the settled pose without breathing or blinking.
  draw(now, still, beat = null) {
    const r = this.r;
    const step = beat ? beat.step : this.held;
    const mood = this.moodNow(step);
    this.blend.advance(mood, now);
    const target = faceTarget(mood, step, this.gaze, this.imp.traits, false);
    const f = still && this.animator.settled ? this.animator.face : this.animator.step(target, now);
    let m;
    const breathing = this.live && !still;
    if (still) {
      m = motionAt(now, mood, false);
      m.blink = 0;
      if (!this.live) { m.bob = 0; m.squash = 0; m.hornL = 0; m.hornR = 0; m.tilt = 0; m.shakeX = 0; m.ripple = 0; }
    } else if (this.blend.weights.size === 1) {
      m = motionAt(now, mood, breathing);
    } else {
      m = blendMotions(Array.from(this.blend.weights, ([k, w]) => [motionAt(now, k, breathing), w]), now);
    }
    if (beat && !still) {
      if (beat.hopSince !== null) hop(m, beat.hopSince);
      perform(m, beat.step, beat.elapsed);
    }
    this.lastDrawn = now;

    const rx = SIZE.rx * f.headW;
    const top = SIZE.top * f.headH, base = SIZE.base * f.headH;
    const head = makeHead({
      cx: SIZE.cx, cy: SIZE.bottom - base, rx, top, bottom: base, square: f.square, sag: f.sag, peak: f.peak,
      wobble: f.wobble + m.ripple, lean: f.lookX, t: m.t,
    });
    const rotate = makePose(f, m.spin, m.pitch);
    const horns = [makeHorn(-1, head, rotate, f, m.hornL), makeHorn(1, head, rotate, f, m.hornR)];

    const middle = head.cy + (base - top) / 2;
    const bodyMatrix = (lift) => {
      let t = mmul(mmul(mmul(mT(SIZE.cx + m.shakeX, SIZE.bottom + m.bob - lift), mR(f.tilt + m.tilt)), mS(1 + m.squash, 1 - m.squash)), mT(-SIZE.cx, -SIZE.bottom));
      if (m.roll !== 0) t = mmul(mmul(mmul(t, mT(SIZE.cx, middle)), mR(m.roll)), mT(-SIZE.cx, -middle));
      return t;
    };
    let lift = 0;
    if (m.lift > 0) {
      const at = bodyMatrix(0);
      let highest = Infinity;
      for (const pt of head.pts) highest = Math.min(highest, mapPoint(at, pt)[1]);
      for (const h of horns) highest = Math.min(highest, mapPoint(at, [h.tip[0], h.tip[1] - h.tipR])[1]);
      const room = Math.max(0, highest - 1.5);
      lift = m.lift * Math.min(1, room / HOP_HEIGHT);
    }
    const w = rx * (0.85 + f.sag * 0.08);
    const k = Math.max(0.4, 1 - Math.max(0, lift - m.bob) * 0.08);
    const sy = SIZE.bottom + 1.5;
    r.shadowWide.setAttribute('cx', SIZE.cx); r.shadowWide.setAttribute('cy', sy);
    r.shadowWide.setAttribute('rx', (w + 4).toFixed(2)); r.shadowWide.setAttribute('ry', ((w + 4) * 0.17).toFixed(2));
    r.shadowWide.setAttribute('opacity', (0.2 * k).toFixed(3));
    r.shadowCore.setAttribute('cx', SIZE.cx); r.shadowCore.setAttribute('cy', sy);
    r.shadowCore.setAttribute('rx', (w * 0.62).toFixed(2)); r.shadowCore.setAttribute('ry', (w * 0.62 * 0.2).toFixed(2));
    r.shadowCore.setAttribute('opacity', (0.2 * k).toFixed(3));
    r.body.setAttribute('transform', `matrix(${bodyMatrix(lift).map((v) => v.toFixed(5)).join(' ')})`);

    this.drawSkin(r, head, f, rotate);
    this.drawEyes(r, head, f, m, rotate);
    horns.forEach((h, i) => {
      r.hornBack[i].setAttribute('d', h.back);
      r.hornFront[i].setAttribute('d', h.front);
      const grad = r.hornGrads[i];
      grad.setAttribute('cx', h.light[0].toFixed(2)); grad.setAttribute('cy', h.light[1].toFixed(2));
      grad.setAttribute('r', (h.baseR * 1.7).toFixed(2));
      const rr = h.baseR * 1.7;
      const c = r.contact[i];
      c.setAttribute('cx', h.base[0].toFixed(2)); c.setAttribute('cy', (h.base[1] + rr * 0.45).toFixed(2));
      c.setAttribute('r', rr.toFixed(2));
      c.setAttribute('opacity', h.front ? h.facing.toFixed(3) : '0');
    });
    this.drawExtras(r, head, f, m, beat);
  }

  drawSkin(r, head, f, rotate) {
    const p = this.palette;
    r.headClip.setAttribute('d', head.d);
    r.skin.setAttribute('d', head.d);
    r.light.setAttribute('d', head.d);
    r.occ.setAttribute('d', head.d);
    const y0 = head.cy - head.top, y1 = head.cy + head.bottom;
    r.skinGrad.setAttribute('y1', y0.toFixed(2)); r.skinGrad.setAttribute('y2', y1.toFixed(2));
    const flush = f.flush;
    const colors = [
      mixRGB(p.skinTop, p.flushTop, flush),
      mixRGB(p.skin, mixRGB(p.skin, p.flushBottom, 0.6), flush),
      mixRGB(p.skinBottom, p.flushBottom, flush),
    ];
    r.skinStops.forEach((stop, i) => stop.setAttribute('stop-color', hex(colors[i])));
    const lc = head.project(rotate(onBall(-0.35, -0.5)));
    r.lightGrad.setAttribute('cx', lc[0].toFixed(2)); r.lightGrad.setAttribute('cy', lc[1].toFixed(2));
    r.lightGrad.setAttribute('r', (head.rx * 0.8).toFixed(2));
    r.occGrad.setAttribute('y1', (head.cy + head.bottom * 0.35).toFixed(2)); r.occGrad.setAttribute('y2', y1.toFixed(2));
    [-1, 1].forEach((side, i) => {
      const g = r.blush[i];
      const n = rotate(onBall(side * 0.7, 0.45));
      if (f.blush <= 0.03 || n[2] <= 0.1) { g.setAttribute('opacity', '0'); return; }
      const c = head.project(n);
      g.setAttribute('opacity', (f.blush * 0.85 * Math.min(1, n[2] * 2)).toFixed(3));
      Array.from(g.children).forEach((dot, j) => {
        dot.setAttribute('cx', (c[0] + (j - 1) * 2.1).toFixed(2));
        dot.setAttribute('cy', (c[1] + (j === 1 ? -0.8 : 0)).toFixed(2));
      });
    });
  }

  drawEyes(r, head, f, m, rotate) {
    const open = Math.max(0, 1 - m.blink * 0.93);
    const arc = clamp(f.arc, 0, 1);
    const opening = 1 - arc;
    const filled = Math.max(0, 1 - Math.max(f.squeeze, f.spiral));
    r.eyes.forEach((eye, i) => {
      const side = eye.side;
      const n = rotate(onBall(side * 0.46, 0.12));
      if (n[2] <= 0.02) { eye.g.setAttribute('opacity', '0'); return; }
      const center = head.project(n);
      const squint = side < 0 ? f.squint : 0;
      const rx = (6.6 * f.eyeW * head.rx) / SIZE.rx;
      const ry = 9 * f.eyeH;
      const phi = (Math.atan2(n[1], n[0]) * 180) / Math.PI;
      eye.g.setAttribute('opacity', Math.min(1, (n[2] - 0.02) / 0.3).toFixed(3));
      eye.g.setAttribute('transform',
        `translate(${center[0].toFixed(2)} ${center[1].toFixed(2)}) rotate(${phi.toFixed(2)}) scale(${Math.max(0.2, n[2]).toFixed(3)} 1) rotate(${(-phi).toFixed(2)})`);

      if (filled > 0.01 && opening > 0.04) {
        const h = Math.max(0.01, ry * open * (1 - squint * 0.3) * opening);
        const lid = Math.min(0.92, f.lid + squint * 0.3);
        const clip = r.eyeClips[i];
        const slantDeg = ((-side * f.slant * 0.6) * 180) / Math.PI;
        clip.setAttribute('transform', `translate(0 ${(-h + 2 * h * Math.max(0, lid)).toFixed(3)}) rotate(${slantDeg.toFixed(2)})`);
        eye.fill.setAttribute('rx', rx.toFixed(2)); eye.fill.setAttribute('ry', h.toFixed(2));
        eye.fill.setAttribute('opacity', filled.toFixed(3));
      } else {
        eye.fill.setAttribute('opacity', '0');
      }
      if (f.arc > 0.01) {
        const w = rx * 1.05, y0 = f.bend * ry * 0.25;
        eye.arc.setAttribute('d', `M${-w.toFixed(2)} ${y0.toFixed(2)}Q0 ${(y0 - f.bend * ry * 1.05).toFixed(2)} ${w.toFixed(2)} ${y0.toFixed(2)}`);
        eye.arc.setAttribute('opacity', (clamp((arc - 0.3) / 0.45, 0, 1) * (1 - f.squeeze)).toFixed(3));
      } else {
        eye.arc.setAttribute('opacity', '0');
      }
      if (f.spiral > 0.01) {
        const turns = 2.3, steps = 48, spin = m.t * 7 * side;
        let d = '';
        for (let j = 0; j <= steps; j++) {
          const k = j / steps, a = k * turns * TAU + spin;
          d += (j === 0 ? 'M' : 'L') + (Math.cos(a) * rx * 1.2 * k).toFixed(2) + ' ' + (Math.sin(a) * ry * 0.95 * k).toFixed(2);
        }
        eye.spiral.setAttribute('d', d);
        eye.spiral.setAttribute('opacity', f.spiral.toFixed(3));
      } else {
        eye.spiral.setAttribute('opacity', '0');
      }
      if (f.squeeze > 0.01) {
        const w = rx * 0.95, h = ry * 0.5;
        eye.squeeze.setAttribute('d', `M${(side * w).toFixed(2)} ${-h.toFixed(2)}L${(-side * w).toFixed(2)} 0L${(side * w).toFixed(2)} ${h.toFixed(2)}`);
        eye.squeeze.setAttribute('opacity', f.squeeze.toFixed(3));
      } else {
        eye.squeeze.setAttribute('opacity', '0');
      }
    });
  }

  drawExtras(r, head, f, m, beat) {
    const t = m.t;
    // "!" ticks
    const showBurst = f.burst > 0.03;
    const pulse = 0.85 + 0.15 * Math.sin(t * 9);
    let line = 0;
    for (const side of [-1, 1]) {
      [1, 1.3, 1.6].forEach((ang, k) => {
        const el = r.burst[line++];
        if (!showBurst) { el.setAttribute('opacity', '0'); return; }
        const o = head.point(-Math.PI / 2 + side * ang);
        const dx = o[0] - head.cx, dy = o[1] - head.cy;
        const len = Math.max(1, Math.hypot(dx, dy));
        const start = 4.5 + (k % 2) * 1.2;
        const l = (k === 1 ? 3.6 : 2.6) * pulse * f.burst;
        el.setAttribute('x1', (o[0] + (dx / len) * start).toFixed(2)); el.setAttribute('y1', (o[1] + (dy / len) * start).toFixed(2));
        el.setAttribute('x2', (o[0] + (dx / len) * (start + l)).toFixed(2)); el.setAttribute('y2', (o[1] + (dy / len) * (start + l)).toFixed(2));
        el.setAttribute('opacity', Math.min(1, f.burst).toFixed(3));
      });
    }
    // sparkles
    [[0.95, -1, 3.4, 0], [1.15, -0.65, 2, 1.7], [0.78, -1.25, 1.6, 3.1]].forEach(([x, y, rad, ph], i) => {
      const el = r.sparkles[i];
      if (f.sparkle <= 0.03) { el.setAttribute('opacity', '0'); return; }
      const tw = 0.55 + 0.45 * Math.sin(t * 5 + ph);
      el.setAttribute('d', starPath((head.cx + head.rx * x).toFixed(2), (head.cy + head.top * y).toFixed(2), (rad * (0.8 + 0.2 * tw)).toFixed(2)));
      el.setAttribute('opacity', (f.sparkle * tw).toFixed(3));
    });
    // heart
    if (f.heart > 0.03) {
      const phase = (t * 0.6) % 1;
      const x = head.cx + head.rx * 0.95 + Math.sin(phase * 6) * 1.5;
      const y = head.cy - head.top - phase * 8;
      const q = 2.6;
      r.heart.setAttribute('d',
        `M${x.toFixed(2)} ${(y + q * 1.1).toFixed(2)}C${(x - q * 0.4).toFixed(2)} ${(y + q * 0.6).toFixed(2)} ${(x - q * 1.2).toFixed(2)} ${(y + q * 0.3).toFixed(2)} ${(x - q * 1.2).toFixed(2)} ${(y - q * 0.3).toFixed(2)}` +
        `A${(q * 0.6).toFixed(2)} ${(q * 0.6).toFixed(2)} 0 0 1 ${x.toFixed(2)} ${(y - q * 0.35).toFixed(2)}` +
        `A${(q * 0.6).toFixed(2)} ${(q * 0.6).toFixed(2)} 0 0 1 ${(x + q * 1.2).toFixed(2)} ${(y - q * 0.3).toFixed(2)}` +
        `C${(x + q * 1.2).toFixed(2)} ${(y + q * 0.3).toFixed(2)} ${(x + q * 0.4).toFixed(2)} ${(y + q * 0.6).toFixed(2)} ${x.toFixed(2)} ${(y + q * 1.1).toFixed(2)}Z`);
      r.heart.setAttribute('opacity', (f.heart * (1 - phase * 0.6)).toFixed(3));
    } else {
      r.heart.setAttribute('opacity', '0');
    }
    // z's
    r.zs.forEach((z, k) => {
      if (f.sleep <= 0.3) { z.setAttribute('opacity', '0'); return; }
      const phase = (t * 0.35 + k / 3) % 1;
      z.setAttribute('x', (head.cx + head.rx * 0.8 + phase * 12 + Math.sin(phase * 7) * 2).toFixed(2));
      z.setAttribute('y', (head.cy - head.top * 0.5 - phase * 26).toFixed(2));
      z.setAttribute('font-size', (6 + phase * 6).toFixed(2));
      z.setAttribute('opacity', (Math.sin(phase * Math.PI) * 0.75 * ((f.sleep - 0.3) / 0.7)).toFixed(3));
    });
    // stars circling a dizzy head
    r.orbit.forEach((star, k) => {
      if (f.spiral <= 0.05) { star.setAttribute('opacity', '0'); return; }
      const a = t * 4 + (k * TAU) / 3;
      const depth = (Math.sin(a) + 1) / 2;
      star.setAttribute('d', starPath((head.cx + Math.cos(a) * head.rx * 0.75).toFixed(2),
        (head.cy - head.top * 1.12 + Math.sin(a) * 3.5).toFixed(2), (2.2 + depth * 1.4).toFixed(2)));
      star.setAttribute('opacity', (f.spiral * (0.45 + 0.55 * depth)).toFixed(3));
    });
    this.drawGlyph(r, head, t, beat);
  }

  drawGlyph(r, head, t, beat) {
    let info = beat && beat.glyph ? beat.glyph : null;
    if (!info && !beat && this.held && this.held.glyph) info = { kind: this.held.glyph, age: 1, remaining: 99 };
    if (!info) {
      if (this.glyph) this.glyph.g.setAttribute('opacity', '0');
      return;
    }
    if (!this.glyph || this.glyph.kind !== info.kind) {
      r.glyphHost.replaceChildren();
      this.glyph = buildGlyph(info.kind, this.accent, r.glyphHost);
    }
    const g = this.glyph;
    const age = info.age;
    const pop = Math.min(1, age * 5) * (1 + 0.25 * Math.sin(Math.min(1, age * 3) * Math.PI) * Math.exp(-age * 3));
    const fade = clamp(info.remaining / 0.5, 0, 1);
    g.g.setAttribute('opacity', fade.toFixed(3));
    if (info.kind === 'notes') {
      g.notes.forEach((note, k) => {
        const phase = (age * 0.55 + k / 3) % 1;
        note.setAttribute('x', (head.cx + head.rx * (0.7 + phase * 0.4) + Math.sin(phase * 6) * 2.5).toFixed(2));
        note.setAttribute('y', (head.cy - head.top * (0.6 + phase * 0.9)).toFixed(2));
        note.setAttribute('font-size', ((8 + phase * 3) * 1.4 * pop).toFixed(2));
        note.setAttribute('opacity', Math.sin(phase * Math.PI).toFixed(3));
      });
      g.g.removeAttribute('transform');
      return;
    }
    let x = head.cx + head.rx * 0.95, y = head.cy - head.top * 1.1 + Math.sin(t * 3) * 1.2;
    if (info.kind === 'sweat') {
      const slide = Math.min(1, age * 0.6);
      x = head.cx - head.rx * 0.95;
      y = head.cy - head.top * (0.75 - 0.25 * slide);
    }
    g.g.setAttribute('transform', `translate(${x.toFixed(2)} ${y.toFixed(2)}) scale(${Math.max(0.001, pop).toFixed(3)})`);
  }

  followPointer() {
    this.pointerHandler = (event) => {
      if (this.perf || this.destroyed) return;
      const box = this.svg.getBoundingClientRect();
      if (!box.width) return;
      const cx = box.left + box.width * 0.5, cy = box.top + box.height * 0.5;
      const dx = event.clientX - cx, dy = event.clientY - cy;
      const d = Math.max(1, Math.hypot(dx, dy));
      const k = Math.min(1, d / 220);
      this.gaze = [(dx / d) * k, (dy / d) * k];
      this.wake();
    };
    window.addEventListener('pointermove', this.pointerHandler, { passive: true });
  }

  setMood(mood) {
    this.mood = MOODS.includes(mood) ? mood : 'idle';
    this.held = null;
    if (reducedMotion()) this.pose({ mood: this.mood });
    else this.wake();
  }

  // Shows a pose with no motion at all (a beat, or just a mood).
  pose(raw) {
    this.stop();
    const beat = normalizeBeat({ duration: 1, ...raw });
    const mood = (beat && beat.mood) || this.mood;
    this.held = beat;
    const target = faceTarget(mood, beat, null, this.imp.traits, false);
    this.animator.snap(target);
    this.blend.weights = new Map([[mood, 1]]);
    this.draw(clockNow(), true);
  }

  stop() {
    this.finishPerformance(true);
  }

  play(animation, opts = {}) {
    const anim = animation && Array.isArray(animation.beats) && animation.duration !== undefined ? animation : normalizeAnimation(animation);
    this.finishPerformance(true);
    this.held = null;
    if (!anim || reducedMotion()) {
      return { stop() {}, done: Promise.resolve('skipped'), skipped: true };
    }
    const tempo = this.imp.traits.tempo;
    const steps = anim.beats.map((b) => ({ ...b, duration: b.duration / tempo }));
    let resolve;
    const done = new Promise((res) => { resolve = res; });
    const perf = {
      start: clockNow(), steps, total: steps.reduce((s, b) => s + b.duration, 0), index: -2,
      onBeat: opts.onBeat, onEnd: opts.onEnd, resolve,
    };
    this.perf = perf;
    this.wake();
    const figure = this;
    return {
      done,
      skipped: false,
      stop() { if (figure.perf === perf) figure.finishPerformance(true); },
    };
  }

  destroy() {
    this.destroyed = true;
    active.delete(this);
    this.finishPerformance(true);
    if (this.pointerHandler) window.removeEventListener('pointermove', this.pointerHandler);
  }
}

// ---------------------------------------------------------------- public API

// Draws `imp` (an Imp object from a kit, or nothing for the default red Imp) into `svg`.
// opts: { live: breathe and blink forever, follow: look at the pointer, mood }.
// Returns the figure: setMood(name), pose(beat), play(animation, { onBeat, onEnd }), stop(), setImp(imp), destroy().
export function drawImp(svg, imp, opts = {}) {
  return new Figure(svg, imp || DEFAULT_IMP, opts);
}

export function setMood(figure, mood) {
  figure.setMood(mood);
}

// Plays an animation (as a kit writes it) on a figure. Returns { stop(), done: Promise, skipped }.
// With reduced motion nothing moves: `skipped` is true and the caller shows poses instead.
export function play(animation, figure, opts = {}) {
  return figure.play(animation, opts);
}
