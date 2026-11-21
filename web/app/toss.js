// Telling a throw from a carry, by the rules the Mac and the iPhone use (engine/src/link/toss.rs). An Imp
// only leaves the page when it is flung hard at a side. Letting it go near a side, however close, is a drop.
//
// With a mouse it is the Mac's rule: a fast sideways push while the pointer is at a side. Letting go never
// throws. With a finger or a pen it is the iPhone's: a fast sideways drag at a side, or a flick that would
// carry it off the page when let go.

/** Sideways speed (pixels a second) a throw with a mouse needs. A brisk carry stays well below it. */
export const DESKTOP_SPEED = 1400;
/** How close to a side the pointer must be when the throw is noticed. */
export const DESKTOP_ZONE = 36;
/** Flick speed with a finger. */
export const PHONE_SPEED = 900;
/** How close to a side the finger must be for a fast drag to throw while still dragging. */
export const PHONE_ZONE = 28;
/** How far ahead (seconds of the flick's speed) a let-go finger is looked for, as UIKit predicts it. */
export const PHONE_AHEAD = 0.25;

/** Fast enough, and more sideways than up or down. */
export function sideways(vx, vy, speed) {
  return Math.abs(vx) >= speed && Math.abs(vx) >= Math.abs(vy) * 1.2;
}

function exit(vx, y, height) {
  return { side: vx < 0 ? 'left' : 'right', height: height > 0 ? Math.min(Math.max(y / height, 0), 1) : 0.5 };
}

/**
 * A throw while carrying: the pointer at (x, y) in a `width` x `height` page, moving at (vx, vy) pixels a
 * second. `touch` picks the iPhone's rule. `{ side, height }` (0 top, 1 bottom) or null.
 * A pointer past the side (outside the window while carrying) counts as at it.
 */
export function carryExit({ x, y, vx, vy, width, height, touch = false }) {
  const speed = touch ? PHONE_SPEED : DESKTOP_SPEED;
  const zone = touch ? PHONE_ZONE : DESKTOP_ZONE;
  if (!sideways(vx, vy, speed) || width <= 0) return null;
  const near = vx < 0 ? x <= zone : x >= width - zone;
  return near ? exit(vx, y, height) : null;
}

/** A throw when a finger lets go: where the flick would carry it leaves the page sideways. Never with a mouse. */
export function releaseExit({ x, y, vx, vy, width, height, touch = false }) {
  if (!touch || !sideways(vx, vy, PHONE_SPEED) || width <= 0) return null;
  const ahead = x + vx * PHONE_AHEAD;
  const out = vx < 0 ? ahead < 0 : ahead > width;
  return out ? exit(vx, y, height) : null;
}

/** The side a carried pointer is heading for, within `distance`: where the way out is shown. */
export function approach({ x, width, distance }) {
  if (x <= distance) return 'left';
  if (x >= width - distance) return 'right';
  return null;
}

/**
 * The hand's speed from pointer moves, smoothed as the Mac smooths the mouse's (`push`). Feed it each
 * move. `velocity` is pixels a second.
 */
export class Hand {
  constructor() {
    this.vx = 0;
    this.vy = 0;
    this.last = null;
  }

  move(x, y, t) {
    if (this.last) {
      const dt = Math.max((t - this.last.t) / 1000, 0.004);
      const vx = (x - this.last.x) / dt;
      const vy = (y - this.last.y) / dt;
      this.vx = this.vx * 0.55 + vx * 0.45;
      this.vy = this.vy * 0.55 + vy * 0.45;
    }
    this.last = { x, y, t };
  }

  /** The speed now: a hand that stopped a while ago is still. */
  velocity(t) {
    if (!this.last || t - this.last.t > 80) return { vx: 0, vy: 0 };
    return { vx: this.vx, vy: this.vy };
  }
}

/** Spots a shake: four quick turns back and forth while carrying. */
export class Shake {
  constructor() {
    this.turns = [];
    this.sign = 0;
  }

  /** True once when the hand shook. */
  move(vx, t) {
    if (Math.abs(vx) < 500) return false;
    const sign = Math.sign(vx);
    if (sign !== this.sign) {
      this.sign = sign;
      this.turns = this.turns.filter((at) => t - at < 700);
      this.turns.push(t);
      if (this.turns.length >= 4) {
        this.turns = [];
        return true;
      }
    }
    return false;
  }
}
