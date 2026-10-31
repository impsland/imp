// Imp on a canvas, for the popup. A trimmed port of the app's own renderer (Face, Motion, Head,
// Horn, Palette, Extras), the same one the Imp server's web gallery uses, so an Imp here has the
// head, curled horns, eyes, colours and idle life it has on the Mac and the iPhone. Only what the
// popup needs: a mood, breathing, blinking and looking at the pointer (no animations, no glyphs).

const TAU = Math.PI * 2;

export const MOODS = ['idle', 'happy', 'love', 'content', 'giggly', 'excited', 'surprised', 'curious', 'thinking',
  'shy', 'sad', 'scared', 'bored', 'sleepy', 'annoyed', 'mean', 'dizzy', 'error', 'listening', 'working'];

const TRAIT_RANGES = {
  lids: [0, 0.6], slant: [-1, 1], eyes: [-0.4, 0.4], squint: [-1, 1], horns: [-30, 30],
  blush: [0, 1], tilt: [-12, 12], tempo: [0.6, 1.6],
};

const clamp = (x, lo, hi) => Math.min(Math.max(x, lo), hi);
const finite = (v, fallback) => (typeof v === 'number' && Number.isFinite(v) ? v : fallback);

export function reducedMotion() {
  return matchMedia('(prefers-reduced-motion: reduce)').matches;
}

// Whatever the Mac sends is clamped here, so a odd value can't break the drawing.
function normalizeTraits(raw) {
  const source = raw !== null && typeof raw === 'object' ? raw : {};
  const out = {};
  for (const [key, [lo, hi]] of Object.entries(TRAIT_RANGES)) {
    out[key] = clamp(finite(source[key], key === 'tempo' ? 1 : 0), lo, hi);
  }
  return out;
}

// ---------------------------------------------------------------- colour

function hsv(h, s, v) {
  const h6 = (h - Math.floor(h)) * 6;
  const i = Math.floor(h6);
  const f = h6 - i;
  const p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f));
  return [[v, t, p], [q, v, p], [p, v, t], [p, q, v], [t, p, v], [v, p, q]][i % 6];
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

function faceTarget(mood, gaze, t) {
  const f = { ...FACE0, ...(MOOD_FACES[mood] || {}) };
  if (gaze && WATCHES_CURSOR.has(mood)) {
    f.lookX = gaze[0];
    f.lookY = gaze[1];
  }
  f.lid = Math.min(0.9, f.lid + t.lids * (1 - f.lid));
  f.slant += t.slant * 0.6;
  f.eyeW *= 1 + t.eyes;
  f.eyeH *= 1 + t.eyes;
  f.squint = clamp(f.squint + t.squint * 0.6, -1, 1);
  f.horn += t.horns;
  f.blush = Math.max(f.blush, t.blush);
  f.tilt += t.tilt;
  return f;
}

// Springs every face parameter toward its target: slightly bouncy, alive.
class FaceAnimator {
  constructor() {
    this.face = { ...FACE0 };
    this.velocity = new Array(FACE_FIELDS.length).fill(0);
    this.last = null;
  }

  snap(target) {
    this.face = { ...target };
    this.velocity.fill(0);
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

  reset(mood) {
    this.weights = new Map([[mood, 1]]);
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
}

// ---------------------------------------------------------------- motion

const BREATH_RATE = 1.7;
const MOTION_KEYS = ['blink', 'bob', 'squash', 'shakeX', 'tilt', 'hornL', 'hornR', 'ripple'];

const newMotion = (t) => ({ t, blink: 0, bob: 0, squash: 0, shakeX: 0, tilt: 0, hornL: 0, hornR: 0, ripple: 0 });

function blinkAt(t) {
  const period = 4.3, duration = 0.16;
  const cycle = Math.floor(t / period);
  const r = Math.abs((Math.sin(cycle * 12.9898) * 43758.5453) % 1);
  const p = t - (cycle * period + r * (period - 0.6));
  if (p >= 0 && p < duration) return Math.sin((p / duration) * Math.PI);
  if (r > 0.8 && p >= 0.24 && p < 0.24 + duration) return Math.sin(((p - 0.24) / duration) * Math.PI);
  return 0;
}

function motionAt(t, mood) {
  const m = newMotion(t);
  const b0 = Math.sin(t * BREATH_RATE);
  m.bob = b0 * 0.7;
  m.squash = b0 * 0.016;
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

function motionOf(weights, t) {
  if (weights.size === 1) return motionAt(t, weights.keys().next().value);
  const m = newMotion(t);
  for (const [mood, w] of weights) {
    const p = motionAt(t, mood);
    for (const k of MOTION_KEYS) m[k] += p[k] * w;
  }
  return m;
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

function makePose(f) {
  const yaw = f.lookX * 0.72;
  const pitch = f.lookY * 0.62;
  const cy = Math.cos(yaw), sy = Math.sin(yaw), cp = Math.cos(pitch), sp = Math.sin(pitch);
  return (v) => {
    const ax = v[0] * cy + v[2] * sy, az = -v[0] * sy + v[2] * cy;
    return [ax, v[1] * cp + az * sp, -v[1] * sp + az * cp];
  };
}

function makeHead(p) {
  const head = { ...p };
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
    d += (i === 0 ? 'M' : 'L') + pt[0].toFixed(2) + ' ' + pt[1].toFixed(2);
  }
  head.path = new Path2D(d + 'Z');
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

function hullPath(hulls) {
  const path = new Path2D();
  for (const h of hulls) {
    if (!h.length) continue;
    path.moveTo(h[0][0], h[0][1]);
    for (let i = 1; i < h.length; i++) path.lineTo(h[i][0], h[i][1]);
    path.closePath();
  }
  return path;
}

const HORN_RINGS = 14, HORN_SEGMENTS = 16, HORN_EMBED = 0.5;

// A curled horn built as a ring of hulls along its spine, split into the part behind the head and
// the part in front of it. Same maths as the app's `Horn`.
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
    front: hullPath(front), back: hullPath(back), hasFront: front.length > 0,
    facing: clamp(rootR[2] * 4, 0, 1), base: origin, baseR,
    light: [mid[0] - baseR * 0.35, mid[1] - baseR * 0.3],
  };
}

// 2D matrices as [a, b, c, d, e, f], the order a canvas takes.
const mmul = (a, b) => [
  a[0] * b[0] + a[2] * b[1], a[1] * b[0] + a[3] * b[1],
  a[0] * b[2] + a[2] * b[3], a[1] * b[2] + a[3] * b[3],
  a[0] * b[4] + a[2] * b[5] + a[4], a[1] * b[4] + a[3] * b[5] + a[5],
];
const mT = (x, y) => [1, 0, 0, 1, x, y];
const mS = (x, y) => [x, 0, 0, y, 0, 0];
const mR = (deg) => { const r = (deg * Math.PI) / 180, c = Math.cos(r), s = Math.sin(r); return [c, s, -s, c, 0, 0]; };

// ---------------------------------------------------------------- drawing

const EYE_WHITE = '#fffdfa';
const FONT = 'ui-rounded, system-ui, -apple-system, Segoe UI, sans-serif';
// The drawing is 100 units square; the canvas shows a margin around it for horns, hops and z's.
const VIEW = 120, MARGIN = 10;

function starPath(cx, cy, r) {
  return new Path2D(`M${cx} ${cy - r}Q${cx} ${cy} ${cx + r} ${cy}Q${cx} ${cy} ${cx} ${cy + r}Q${cx} ${cy} ${cx - r} ${cy}Q${cx} ${cy} ${cx} ${cy - r}Z`);
}

function heartPath(x, y, q) {
  const n = (v) => v.toFixed(2);
  return new Path2D(
    `M${n(x)} ${n(y + q * 1.1)}C${n(x - q * 0.4)} ${n(y + q * 0.6)} ${n(x - q * 1.2)} ${n(y + q * 0.3)} ${n(x - q * 1.2)} ${n(y - q * 0.3)}` +
    `A${n(q * 0.6)} ${n(q * 0.6)} 0 0 1 ${n(x)} ${n(y - q * 0.35)}` +
    `A${n(q * 0.6)} ${n(q * 0.6)} 0 0 1 ${n(x + q * 1.2)} ${n(y - q * 0.3)}` +
    `C${n(x + q * 1.2)} ${n(y + q * 0.3)} ${n(x + q * 0.4)} ${n(y + q * 0.6)} ${n(x)} ${n(y + q * 1.1)}Z`);
}

function stops(grad, list) {
  for (const [at, color] of list) grad.addColorStop(at, color);
  return grad;
}

// One Imp on one canvas. `live` breathes and blinks; without it (reduced motion) it holds a still pose.
export class ImpCanvas {
  constructor(canvas, { live = true, phase = 0 } = {}) {
    this.canvas = canvas;
    this.ctx = canvas.getContext('2d');
    this.live = live;
    this.phase = phase;      // offsets the clock, so Imps side by side don't blink together
    this.mood = 'idle';
    this.gaze = null;
    this.animator = new FaceAnimator();
    this.blend = new BlendWeights(0.35);
    this.lastDrawn = -1;
    this.traits = normalizeTraits(null);
    this.setLook(0);
    const ctx = this.ctx;
    // Unit gradients, reused for every shadow and contact blob (scaled by the transform).
    this.shadowFill = stops(ctx.createRadialGradient(0, 0, 0, 0, 0, 1),
      [[0, 'rgba(0,0,0,1)'], [0.55, 'rgba(0,0,0,0.4)'], [1, 'rgba(0,0,0,0)']]);
    this.contactFill = stops(ctx.createRadialGradient(0, 0, 0, 0, 0, 1),
      [[0, 'rgba(102,8,13,0.18)'], [1, 'rgba(102,8,13,0)']]);
    this.snap();
  }

  // Sets the canvas to `px` CSS pixels square (sharp on dense screens).
  resize(px) {
    const size = Math.round(px * (devicePixelRatio || 1));
    if (this.canvas.width !== size) {
      this.canvas.width = size;
      this.canvas.height = size;
    }
    this.canvas.style.width = this.canvas.style.height = `${px}px`;
    if (!this.live) this.paint(0);
  }

  setLook(hue) {
    this.palette = makePalette(clamp(finite(hue, 0), 0, 1));
    this.accent = hex(this.palette.skin);
  }

  setImp({ hue, traits }) {
    this.setLook(hue);
    this.traits = normalizeTraits(traits);
    this.settle();
  }

  setMood(mood) {
    this.mood = MOODS.includes(mood) ? mood : 'idle';
    this.settle();
  }

  // Where the pointer is, as -1…1 on both axes from the Imp (or null: nowhere).
  setGaze(gaze) {
    this.gaze = gaze;
    if (!this.live) this.settle();
  }

  snap() {
    this.animator.snap(faceTarget(this.mood, this.gaze, this.traits));
    this.blend.reset(this.mood);
  }

  // A held pose changes at once; a live Imp springs to it on its own.
  settle() {
    if (this.live) return;
    this.snap();
    this.paint(0);
  }

  // Called every animation frame; draws about thirty times a second.
  frame(now) {
    if (now - this.lastDrawn < 0.028) return;
    this.lastDrawn = now;
    this.paint(now);
  }

  paint(now) {
    const live = this.live;
    const t = now + this.phase;
    this.blend.advance(this.mood, now);
    const f = live ? this.animator.step(faceTarget(this.mood, this.gaze, this.traits), now) : this.animator.face;
    const m = live ? motionOf(this.blend.weights, t) : newMotion(t);

    const rx = SIZE.rx * f.headW;
    const top = SIZE.top * f.headH, base = SIZE.base * f.headH;
    const head = makeHead({
      cx: SIZE.cx, cy: SIZE.bottom - base, rx, top, bottom: base, square: f.square, sag: f.sag, peak: f.peak,
      wobble: f.wobble + m.ripple, lean: f.lookX, t,
    });
    const rotate = makePose(f);
    const horns = [makeHorn(-1, head, rotate, f, m.hornL), makeHorn(1, head, rotate, f, m.hornR)];
    const body = mmul(mmul(mmul(mT(SIZE.cx + m.shakeX, SIZE.bottom + m.bob), mR(f.tilt + m.tilt)),
      mS(1 + m.squash, 1 - m.squash)), mT(-SIZE.cx, -SIZE.bottom));

    const ctx = this.ctx;
    const k = this.canvas.width / VIEW;
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, this.canvas.width, this.canvas.height);
    ctx.setTransform(k, 0, 0, k, MARGIN * k, MARGIN * k);

    this.paintShadow(f, rx, m);
    ctx.save();
    ctx.transform(...body);
    this.paintBody(head, horns, f, rotate);
    this.paintEyes(head, f, m, rotate);
    this.paintHornsFront(head, horns);
    this.paintExtras(head, f, t);
    ctx.restore();
  }

  blob(cx, cy, rx, ry, fill, alpha) {
    const ctx = this.ctx;
    ctx.save();
    ctx.translate(cx, cy);
    ctx.scale(rx, ry);
    ctx.globalAlpha = alpha;
    ctx.fillStyle = fill;
    ctx.beginPath();
    ctx.arc(0, 0, 1, 0, TAU);
    ctx.fill();
    ctx.restore();
  }

  paintShadow(f, rx, m) {
    const w = rx * (0.85 + f.sag * 0.08);
    const k = Math.max(0.4, 1 - Math.max(0, -m.bob) * 0.08);
    const y = SIZE.bottom + 1.5;
    this.blob(SIZE.cx, y, w + 4, (w + 4) * 0.17, this.shadowFill, 0.2 * k);
    this.blob(SIZE.cx, y, w * 0.62, w * 0.62 * 0.2, this.shadowFill, 0.2 * k);
  }

  hornFill(h) {
    const ctx = this.ctx, p = this.palette;
    const r = h.baseR * 1.7;
    return stops(ctx.createRadialGradient(h.light[0], h.light[1], 0, h.light[0], h.light[1], r),
      [[0, p.hornLight], [1, p.hornDark]]);
  }

  // Back of the horns, the head (skin, light, shade, blush), all clipped to the head.
  paintBody(head, horns, f, rotate) {
    const ctx = this.ctx, p = this.palette;
    for (const h of horns) {
      ctx.fillStyle = this.hornFill(h);
      ctx.fill(h.back);
    }
    const y0 = head.cy - head.top, y1 = head.cy + head.bottom;
    const flush = f.flush;
    const skin = ctx.createLinearGradient(50, y0, 50, y1);
    skin.addColorStop(0, hex(mixRGB(p.skinTop, p.flushTop, flush)));
    skin.addColorStop(0.5, hex(mixRGB(p.skin, mixRGB(p.skin, p.flushBottom, 0.6), flush)));
    skin.addColorStop(1, hex(mixRGB(p.skinBottom, p.flushBottom, flush)));
    ctx.fillStyle = skin;
    ctx.fill(head.path);

    ctx.save();
    ctx.clip(head.path);
    const lc = head.project(rotate(onBall(-0.35, -0.5)));
    ctx.fillStyle = stops(ctx.createRadialGradient(lc[0], lc[1], 0, lc[0], lc[1], head.rx * 0.8),
      [[0, 'rgba(255,255,255,0.14)'], [0.5, 'rgba(255,255,255,0.05)'], [1, 'rgba(255,255,255,0)']]);
    ctx.fill(head.path);
    ctx.fillStyle = stops(ctx.createLinearGradient(0, head.cy + head.bottom * 0.35, 0, y1),
      [[0, 'rgba(0,0,0,0)'], [1, 'rgba(0,0,0,0.07)']]);
    ctx.fill(head.path);
    ctx.fillStyle = p.blush;
    for (const side of [-1, 1]) {
      const n = rotate(onBall(side * 0.7, 0.45));
      if (f.blush <= 0.03 || n[2] <= 0.1) continue;
      const c = head.project(n);
      ctx.globalAlpha = f.blush * 0.85 * Math.min(1, n[2] * 2);
      for (let j = 0; j < 3; j++) {
        ctx.beginPath();
        ctx.arc(c[0] + (j - 1) * 2.1, c[1] + (j === 1 ? -0.8 : 0), 0.75, 0, TAU);
        ctx.fill();
      }
    }
    ctx.restore();
  }

  paintEyes(head, f, m, rotate) {
    const ctx = this.ctx;
    ctx.save();
    ctx.clip(head.path);
    ctx.strokeStyle = EYE_WHITE;
    ctx.fillStyle = EYE_WHITE;
    ctx.lineCap = ctx.lineJoin = 'round';
    const open = Math.max(0, 1 - m.blink * 0.93);
    const arc = clamp(f.arc, 0, 1);
    const opening = 1 - arc;
    const filled = Math.max(0, 1 - Math.max(f.squeeze, f.spiral));
    for (const side of [-1, 1]) {
      const n = rotate(onBall(side * 0.46, 0.12));
      if (n[2] <= 0.02) continue;
      const center = head.project(n);
      const squint = side < 0 ? f.squint : 0;
      const rx = (6.6 * f.eyeW * head.rx) / SIZE.rx;
      const ry = 9 * f.eyeH;
      const phi = Math.atan2(n[1], n[0]);
      const visible = Math.min(1, (n[2] - 0.02) / 0.3);

      ctx.save();
      ctx.translate(center[0], center[1]);
      ctx.rotate(phi);
      ctx.scale(Math.max(0.2, n[2]), 1);
      ctx.rotate(-phi);

      if (filled > 0.01 && opening > 0.04) {
        const h = Math.max(0.01, ry * open * (1 - squint * 0.3) * opening);
        const lid = Math.min(0.92, f.lid + squint * 0.3);
        // The lid: everything above a (slanted) line is cut off.
        ctx.save();
        const at = ctx.getTransform();
        ctx.translate(0, -h + 2 * h * Math.max(0, lid));
        ctx.rotate(-side * f.slant * 0.6);
        ctx.beginPath();
        ctx.rect(-30, 0, 60, 40);
        ctx.setTransform(at);
        ctx.clip();
        ctx.globalAlpha = filled * visible;
        ctx.beginPath();
        ctx.ellipse(0, 0, rx, h, 0, 0, TAU);
        ctx.fill();
        ctx.restore();
      }
      if (f.arc > 0.01) {
        const w = rx * 1.05, y0 = f.bend * ry * 0.25;
        ctx.globalAlpha = clamp((arc - 0.3) / 0.45, 0, 1) * (1 - f.squeeze) * visible;
        ctx.lineWidth = 3;
        ctx.beginPath();
        ctx.moveTo(-w, y0);
        ctx.quadraticCurveTo(0, y0 - f.bend * ry * 1.05, w, y0);
        ctx.stroke();
      }
      if (f.spiral > 0.01) {
        const turns = 2.3, steps = 48, spin = m.t * 7 * side;
        ctx.globalAlpha = f.spiral * visible;
        ctx.lineWidth = 2.4;
        ctx.beginPath();
        for (let j = 0; j <= steps; j++) {
          const q = j / steps, a = q * turns * TAU + spin;
          const x = Math.cos(a) * rx * 1.2 * q, y = Math.sin(a) * ry * 0.95 * q;
          if (j === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
        }
        ctx.stroke();
      }
      if (f.squeeze > 0.01) {
        const w = rx * 0.95, h = ry * 0.5;
        ctx.globalAlpha = f.squeeze * visible;
        ctx.lineWidth = 3;
        ctx.beginPath();
        ctx.moveTo(side * w, -h);
        ctx.lineTo(-side * w, 0);
        ctx.lineTo(side * w, h);
        ctx.stroke();
      }
      ctx.restore();
    }
    ctx.restore();
  }

  paintHornsFront(head, horns) {
    const ctx = this.ctx;
    for (const h of horns) {
      ctx.fillStyle = this.hornFill(h);
      ctx.fill(h.front);
    }
    // Where a horn meets the head it casts a faint shadow on the skin.
    ctx.save();
    ctx.clip(head.path);
    for (const h of horns) {
      if (!h.hasFront) continue;
      const r = h.baseR * 1.7;
      this.blob(h.base[0], h.base[1] + r * 0.45, r, r, this.contactFill, h.facing);
    }
    ctx.restore();
  }

  paintExtras(head, f, t) {
    const ctx = this.ctx, accent = this.accent;
    ctx.fillStyle = ctx.strokeStyle = accent;
    if (f.burst > 0.03) { // "!" ticks
      const pulse = 0.85 + 0.15 * Math.sin(t * 9);
      ctx.lineWidth = 1.6;
      ctx.lineCap = 'round';
      ctx.globalAlpha = Math.min(1, f.burst);
      ctx.beginPath();
      for (const side of [-1, 1]) {
        [1, 1.3, 1.6].forEach((ang, k) => {
          const o = head.point(-Math.PI / 2 + side * ang);
          const dx = o[0] - head.cx, dy = o[1] - head.cy;
          const len = Math.max(1, Math.hypot(dx, dy));
          const start = 4.5 + (k % 2) * 1.2;
          const l = (k === 1 ? 3.6 : 2.6) * pulse * f.burst;
          ctx.moveTo(o[0] + (dx / len) * start, o[1] + (dy / len) * start);
          ctx.lineTo(o[0] + (dx / len) * (start + l), o[1] + (dy / len) * (start + l));
        });
      }
      ctx.stroke();
    }
    if (f.sparkle > 0.03) {
      [[0.95, -1, 3.4, 0], [1.15, -0.65, 2, 1.7], [0.78, -1.25, 1.6, 3.1]].forEach(([x, y, rad, ph]) => {
        const tw = 0.55 + 0.45 * Math.sin(t * 5 + ph);
        ctx.globalAlpha = f.sparkle * tw;
        ctx.fill(starPath((head.cx + head.rx * x).toFixed(2), (head.cy + head.top * y).toFixed(2), (rad * (0.8 + 0.2 * tw)).toFixed(2)));
      });
    }
    if (f.heart > 0.03) {
      const phase = (t * 0.6) % 1;
      ctx.globalAlpha = f.heart * (1 - phase * 0.6);
      ctx.fill(heartPath(head.cx + head.rx * 0.95 + Math.sin(phase * 6) * 1.5, head.cy - head.top - phase * 8, 2.6));
    }
    if (f.sleep > 0.3) { // z's
      ctx.textAlign = 'center';
      ctx.textBaseline = 'middle';
      for (let k = 0; k < 3; k++) {
        const phase = (t * 0.35 + k / 3) % 1;
        ctx.globalAlpha = Math.sin(phase * Math.PI) * 0.75 * ((f.sleep - 0.3) / 0.7);
        ctx.font = `800 ${(6 + phase * 6).toFixed(2)}px ${FONT}`;
        ctx.fillText('z', head.cx + head.rx * 0.8 + phase * 12 + Math.sin(phase * 7) * 2, head.cy - head.top * 0.5 - phase * 26);
      }
    }
    if (f.spiral > 0.05) { // stars circling a dizzy head
      ctx.fillStyle = '#ffc733';
      for (let k = 0; k < 3; k++) {
        const a = t * 4 + (k * TAU) / 3;
        const depth = (Math.sin(a) + 1) / 2;
        ctx.globalAlpha = f.spiral * (0.45 + 0.55 * depth);
        ctx.fill(starPath((head.cx + Math.cos(a) * head.rx * 0.75).toFixed(2),
          (head.cy - head.top * 1.12 + Math.sin(a) * 3.5).toFixed(2), (2.2 + depth * 1.4).toFixed(2)));
      }
    }
    ctx.globalAlpha = 1;
  }
}

// ---------------------------------------------------------------- the clock

// One animation-frame loop for all the Imps on screen; it stops when nothing is live or the popup is hidden.
export class Clock {
  constructor() {
    this.figures = new Set();
    this.handle = 0;
    this.paused = false;
    this.tick = (ts) => {
      this.handle = 0;
      for (const fig of this.figures) fig.frame(ts / 1000);
      this.schedule();
    };
  }

  add(fig) { this.figures.add(fig); this.schedule(); }
  remove(fig) { this.figures.delete(fig); }

  pause(paused) {
    this.paused = paused;
    if (paused) {
      cancelAnimationFrame(this.handle);
      this.handle = 0;
    } else {
      this.schedule();
    }
  }

  schedule() {
    if (!this.handle && !this.paused && this.figures.size) this.handle = requestAnimationFrame(this.tick);
  }
}
