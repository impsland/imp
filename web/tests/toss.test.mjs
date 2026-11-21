// The page's throw rules (web/app/toss.js) against the Mac's and the iPhone's (engine/src/link/toss.rs).
// Run: node --test web/tests/*.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { Hand, Shake, approach, carryExit, releaseExit } from '../app/toss.js';

const page = { width: 1200, height: 800 };

test('a slow carry to a side and letting go there is a drop, never a throw', () => {
  assert.equal(carryExit({ ...page, x: 2, y: 400, vx: -300, vy: 0 }), null);
  assert.equal(releaseExit({ ...page, x: 2, y: 400, vx: -300, vy: 0 }), null);
  // Even a fast mouse let go at the side: only the push while carrying throws.
  assert.equal(releaseExit({ ...page, x: 2, y: 400, vx: -3000, vy: 0 }), null);
});

test('a hard sideways push at a side throws with a mouse', () => {
  assert.deepEqual(carryExit({ ...page, x: 20, y: 200, vx: -1500, vy: 100 }), { side: 'left', height: 0.25 });
  assert.deepEqual(carryExit({ ...page, x: 1190, y: 400, vx: 1500, vy: 0 }), { side: 'right', height: 0.5 });
  // Past the side (the pointer left the window while carrying) counts as at it.
  assert.equal(carryExit({ ...page, x: -40, y: 400, vx: -2000, vy: 0 })?.side, 'left');
});

test('a fast push away from the sides, or toward the other side, or mostly up and down, is a carry', () => {
  assert.equal(carryExit({ ...page, x: 600, y: 400, vx: -3000, vy: 0 }), null);
  assert.equal(carryExit({ ...page, x: 20, y: 400, vx: 3000, vy: 0 }), null);
  assert.equal(carryExit({ ...page, x: 20, y: 400, vx: -1500, vy: 1400 }), null);
  assert.equal(carryExit({ ...page, x: 50, y: 400, vx: -1500, vy: 0 }), null);
});

test('a finger throws by the iPhone rule: slower, closer, or a flick off the page', () => {
  assert.equal(carryExit({ ...page, x: 20, y: 400, vx: -1000, vy: 0, touch: true })?.side, 'left');
  assert.equal(carryExit({ ...page, x: 20, y: 400, vx: -1000, vy: 0 }), null);
  assert.equal(releaseExit({ ...page, x: 150, y: 400, vx: -1000, vy: 0, touch: true })?.side, 'left');
  assert.equal(releaseExit({ ...page, x: 600, y: 400, vx: -1000, vy: 0, touch: true }), null);
  assert.equal(releaseExit({ ...page, x: 150, y: 400, vx: -500, vy: 0, touch: true }), null);
});

test('the way out shows near a side', () => {
  assert.equal(approach({ x: 80, width: 1200, distance: 110 }), 'left');
  assert.equal(approach({ x: 1150, width: 1200, distance: 110 }), 'right');
  assert.equal(approach({ x: 600, width: 1200, distance: 110 }), null);
});

test('the hand is smoothed and still after a pause', () => {
  const hand = new Hand();
  for (let i = 0; i <= 10; i++) hand.move(600 - i * 20, 400, i * 10);
  assert.ok(hand.velocity(100).vx < -1500);
  assert.deepEqual(hand.velocity(400), { vx: 0, vy: 0 });
});

test('four quick turns are a shake', () => {
  const shake = new Shake();
  const hits = [800, -800, 800, -800].map((vx, i) => shake.move(vx, i * 100));
  assert.deepEqual(hits, [false, false, false, true]);
});
