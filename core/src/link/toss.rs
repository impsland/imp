//! Telling a throw from a carry. An Imp leaves a screen when it is flung hard at one of its outer sides:
//! an edge with no other screen beyond it. With several displays side by side, carrying an Imp across
//! from one to the next is just a carry, however fast. Also the jolt detector for a throw with the phone.

use crate::link::messages::{LinkEntry, LinkSide};

/// Sideways speed (points a second) a throw needs. A brisk carry stays well below it.
pub const DESKTOP_SPEED: f64 = 1_400.0;
/// How close to the edge the pointer must be when the throw is noticed.
pub const DESKTOP_ZONE: f64 = 36.0;
/// Flick speed on the phone (points a second).
pub const PHONE_SPEED: f64 = 900.0;
/// How close to the side the finger must be when a fast drag counts as a throw while still dragging.
pub const PHONE_ZONE: f64 = 28.0;

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Point {
    pub x: f64,
    pub y: f64,
}

/// A display's frame, in one global space with y up as in Cocoa.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl Rect {
    pub fn min_x(&self) -> f64 {
        self.x
    }
    pub fn max_x(&self) -> f64 {
        self.x + self.width
    }
    pub fn max_y(&self) -> f64 {
        self.y + self.height
    }
    fn contains(&self, p: Point, slack: f64) -> bool {
        p.x >= self.x - slack
            && p.x <= self.max_x() + slack
            && p.y >= self.y - slack
            && p.y <= self.max_y() + slack
    }
    fn contains_strict(&self, p: Point) -> bool {
        p.x >= self.x && p.x < self.max_x() && p.y >= self.y && p.y < self.max_y()
    }
}

/// Where a throw leaves a screen: the side and how far down it (0 top, 1 bottom).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Exit {
    pub side: LinkSide,
    pub height: f64,
}

fn sideways(vx: f64, vy: f64, speed: f64) -> bool {
    vx.abs() >= speed && vx.abs() >= vy.abs() * 1.2
}

fn side_of(vx: f64) -> LinkSide {
    if vx < 0.0 {
        LinkSide::Left
    } else {
        LinkSide::Right
    }
}

fn edge(side: LinkSide, screen: &Rect) -> f64 {
    if side == LinkSide::Left {
        screen.min_x()
    } else {
        screen.max_x()
    }
}

fn screen_at(cursor: Point, screens: &[Rect]) -> Option<&Rect> {
    screens.iter().find(|s| s.contains(cursor, 1.0))
}

/// Whether `side` of `screen` is an outer side at height `y`: no other screen just past it.
fn is_outer(side: LinkSide, screen: &Rect, y: f64, screens: &[Rect]) -> bool {
    let e = edge(side, screen);
    let beyond = Point {
        x: if side == LinkSide::Left {
            e - 2.0
        } else {
            e + 2.0
        },
        y,
    };
    !screens.iter().any(|s| s.contains_strict(beyond))
}

/// A throw off the desktop: the pointer at `cursor` moving at `velocity`, with the displays' frames.
pub fn desktop_exit(cursor: Point, velocity: (f64, f64), screens: &[Rect]) -> Option<Exit> {
    if !sideways(velocity.0, velocity.1, DESKTOP_SPEED) {
        return None;
    }
    let screen = screen_at(cursor, screens)?;
    let side = side_of(velocity.0);
    if (cursor.x - edge(side, screen)).abs() > DESKTOP_ZONE
        || !is_outer(side, screen, cursor.y, screens)
    {
        return None;
    }
    let height = if screen.height > 0.0 {
        (screen.max_y() - cursor.y) / screen.height
    } else {
        0.5
    };
    Some(Exit {
        side,
        height: height.clamp(0.0, 1.0),
    })
}

/// The outer side of the desktop a carried Imp is heading for.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Approach {
    pub side: LinkSide,
    pub screen: Rect,
    pub height: f64,
    pub gap: f64,
}

/// The outer side the pointer at `cursor` is within `distance` of, if any.
pub fn desktop_approach(cursor: Point, distance: f64, screens: &[Rect]) -> Option<Approach> {
    let screen = screen_at(cursor, screens).filter(|s| s.height > 0.0)?;
    let height = ((screen.max_y() - cursor.y) / screen.height).clamp(0.0, 1.0);
    let mut nearest: Option<(LinkSide, f64)> = None;
    for side in [LinkSide::Left, LinkSide::Right] {
        let gap = (cursor.x - edge(side, screen)).abs();
        if gap <= distance
            && gap < nearest.map_or(f64::INFINITY, |n| n.1)
            && is_outer(side, screen, cursor.y, screens)
        {
            nearest = Some((side, gap));
        }
    }
    nearest.map(|(side, gap)| Approach {
        side,
        screen: *screen,
        height,
        gap,
    })
}

/// Where an Imp tossed onto the desktop comes in: the screen furthest out on that side (the tallest, so
/// the height maps onto a whole display) and the point on its edge (y up).
pub fn desktop_entry(entry: &LinkEntry, screens: &[Rect]) -> Option<(Rect, Point)> {
    let left = entry.side == LinkSide::Left;
    let value = |s: &Rect| if left { s.min_x() } else { s.max_x() };
    let outermost = screens
        .iter()
        .map(value)
        .fold(None, |best: Option<f64>, v| {
            Some(best.map_or(v, |b| if left { b.min(v) } else { b.max(v) }))
        })?;
    let screen =
        screens
            .iter()
            .filter(|s| value(s) == outermost)
            .fold(None, |best: Option<&Rect>, s| match best {
                Some(b) if b.height >= s.height => Some(b),
                _ => Some(s),
            })?;
    let y = screen.max_y() - entry.height * screen.height;
    Some((*screen, Point { x: outermost, y }))
}

fn phone_height(y: f64, height: f64) -> f64 {
    if height > 0.0 {
        (y / height).clamp(0.0, 1.0)
    } else {
        0.5
    }
}

/// A throw off the phone's screen while dragging: the finger at `point` in a view of `width` x `height`
/// (y down), moving at `velocity`.
pub fn phone_exit(point: Point, velocity: (f64, f64), width: f64, height: f64) -> Option<Exit> {
    if !sideways(velocity.0, velocity.1, PHONE_SPEED) || width <= 0.0 {
        return None;
    }
    let side = side_of(velocity.0);
    let near = if side == LinkSide::Left {
        point.x <= PHONE_ZONE
    } else {
        point.x >= width - PHONE_ZONE
    };
    near.then(|| Exit {
        side,
        height: phone_height(point.y, height),
    })
}

/// A throw when letting go: where the flick would carry the Imp (`predicted`) leaves the screen
/// sideways, fast enough.
pub fn phone_release(
    point: Point,
    predicted: Point,
    velocity: (f64, f64),
    width: f64,
    height: f64,
) -> Option<Exit> {
    if !sideways(velocity.0, velocity.1, PHONE_SPEED) || width <= 0.0 {
        return None;
    }
    let side = side_of(velocity.0);
    let out = if side == LinkSide::Left {
        predicted.x < 0.0
    } else {
        predicted.x > width
    };
    out.then(|| Exit {
        side,
        height: phone_height(point.y, height),
    })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Jolt {
    Thrown(LinkSide),
    Shaken,
}

/// Spots a throw with the whole phone: a sharp sideways jolt. Fed the device's user acceleration along
/// its x axis (g, positive toward the right edge in portrait) many times a second.
///
/// A throw is the first strong push sideways (the hand speeds up toward the target, and the stop that
/// follows pushes the other way and is ignored). A shake is several pushes back and forth in a row.
#[derive(Debug, Clone)]
pub struct JoltDetector {
    /// Acceleration (g) a push needs to count.
    pub threshold: f64,
    /// Pushes this close together (seconds) belong to one movement.
    pub window: f64,
    /// Pushes back and forth that make a shake.
    pub shake_count: usize,
    /// Quiet time (seconds) after an event before the next.
    pub cooldown: f64,
    pushes: Vec<(f64, i32)>,
    last_sign: i32,
    quiet_until: f64,
    pending: Option<(f64, LinkSide)>,
    shake_start: Option<LinkSide>,
}

impl Default for JoltDetector {
    fn default() -> Self {
        Self::new(2.0, 0.45, 4, 1.0)
    }
}

impl JoltDetector {
    pub fn new(threshold: f64, window: f64, shake_count: usize, cooldown: f64) -> Self {
        Self {
            threshold,
            window,
            shake_count,
            cooldown,
            pushes: Vec::new(),
            last_sign: 0,
            quiet_until: f64::NEG_INFINITY,
            pending: None,
            shake_start: None,
        }
    }

    /// The way the last shake began (its first push), for rules that care which side it went.
    pub fn shake_start(&self) -> Option<LinkSide> {
        self.shake_start
    }

    /// One sample. Returns a throw once the movement is over (no shake followed), or a shake.
    pub fn feed(&mut self, x: f64, t: f64) -> Option<Jolt> {
        if !x.is_finite() || !t.is_finite() || t < self.quiet_until {
            return None;
        }
        let window = self.window;
        self.pushes.retain(|p| t - p.0 <= window);
        let sign = if x.abs() >= self.threshold {
            if x > 0.0 { 1 } else { -1 }
        } else {
            0
        };
        if sign != 0 && sign != self.last_sign {
            self.pushes.push((t, sign));
            if self.pending.is_none() && self.pushes.len() == 1 {
                self.pending = Some((
                    t,
                    if sign > 0 {
                        LinkSide::Right
                    } else {
                        LinkSide::Left
                    },
                ));
            }
            if self.pushes.len() >= self.shake_count {
                self.shake_start = self.pending.map(|p| p.1);
                self.reset(t + self.cooldown);
                return Some(Jolt::Shaken);
            }
        }
        if sign != 0 || x.abs() < self.threshold * 0.5 {
            self.last_sign = sign;
        }
        // The movement settled without turning into a shake: it was a throw.
        if let Some((started, side)) = self.pending
            && t - started > self.window
            && self.pushes.len() < self.shake_count
        {
            self.reset(t + self.cooldown);
            return Some(Jolt::Thrown(side));
        }
        None
    }

    fn reset(&mut self, until: f64) {
        self.pushes.clear();
        self.pending = None;
        self.last_sign = 0;
        self.quiet_until = until;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn screen(x: f64, y: f64, w: f64, h: f64) -> Rect {
        Rect {
            x,
            y,
            width: w,
            height: h,
        }
    }

    fn pair() -> Vec<Rect> {
        vec![
            screen(0.0, 0.0, 1000.0, 800.0),
            screen(1000.0, 0.0, 1000.0, 800.0),
        ]
    }

    #[test]
    fn a_fast_fling_at_an_outer_edge_is_a_throw() {
        let exit = desktop_exit(
            Point {
                x: 1995.0,
                y: 200.0,
            },
            (2000.0, 100.0),
            &pair(),
        )
        .unwrap();
        assert_eq!(exit.side, LinkSide::Right);
        assert!((exit.height - 0.75).abs() < 1e-9);
        let left = desktop_exit(Point { x: 3.0, y: 800.0 }, (-1500.0, 0.0), &pair()).unwrap();
        assert_eq!((left.side, left.height), (LinkSide::Left, 0.0));
    }

    #[test]
    fn a_carry_between_displays_or_a_slow_or_diagonal_move_is_not() {
        let screens = pair();
        assert!(desktop_exit(Point { x: 998.0, y: 200.0 }, (3000.0, 0.0), &screens).is_none());
        assert!(
            desktop_exit(
                Point {
                    x: 1995.0,
                    y: 200.0
                },
                (1000.0, 0.0),
                &screens
            )
            .is_none()
        );
        assert!(
            desktop_exit(
                Point {
                    x: 1995.0,
                    y: 200.0
                },
                (2000.0, 2000.0),
                &screens
            )
            .is_none()
        );
        assert!(
            desktop_exit(
                Point {
                    x: 1900.0,
                    y: 200.0
                },
                (2000.0, 0.0),
                &screens
            )
            .is_none()
        );
        assert!(
            desktop_exit(
                Point {
                    x: 5000.0,
                    y: 200.0
                },
                (2000.0, 0.0),
                &screens
            )
            .is_none()
        );
    }

    #[test]
    fn a_display_beside_only_part_of_an_edge_leaves_the_rest_outer() {
        let screens = vec![
            screen(0.0, 0.0, 1000.0, 800.0),
            screen(1000.0, 0.0, 1000.0, 400.0),
        ];
        assert!(desktop_exit(Point { x: 998.0, y: 100.0 }, (3000.0, 0.0), &screens).is_none());
        assert!(desktop_exit(Point { x: 998.0, y: 600.0 }, (3000.0, 0.0), &screens).is_some());
    }

    #[test]
    fn approaching_an_outer_side_names_it_and_how_near() {
        let screens = pair();
        let near = desktop_approach(
            Point {
                x: 1980.0,
                y: 400.0,
            },
            40.0,
            &screens,
        )
        .unwrap();
        assert_eq!(near.side, LinkSide::Right);
        assert!((near.gap - 20.0).abs() < 1e-9 && (near.height - 0.5).abs() < 1e-9);
        assert!(
            desktop_approach(
                Point {
                    x: 1000.0,
                    y: 400.0
                },
                40.0,
                &screens
            )
            .is_none()
        );
        assert!(desktop_approach(Point { x: 500.0, y: 400.0 }, 40.0, &screens).is_none());
    }

    #[test]
    fn a_toss_comes_in_at_the_outermost_tallest_screen() {
        let screens = vec![
            screen(0.0, 0.0, 1000.0, 800.0),
            screen(1000.0, 0.0, 1000.0, 400.0),
            screen(1000.0, 400.0, 1000.0, 600.0),
        ];
        let (found, point) =
            desktop_entry(&LinkEntry::new(LinkSide::Right, 0.5, 900.0), &screens).unwrap();
        assert_eq!(found.height, 600.0);
        assert_eq!((point.x, point.y), (2000.0, 1000.0 - 300.0));
        let (found, point) =
            desktop_entry(&LinkEntry::new(LinkSide::Left, 0.0, 0.0), &screens).unwrap();
        assert_eq!((found.x, point.x, point.y), (0.0, 0.0, 800.0));
        assert!(desktop_entry(&LinkEntry::new(LinkSide::Left, 0.0, 0.0), &[]).is_none());
    }

    #[test]
    fn the_phone_notices_a_fling_while_dragging_and_on_release() {
        let near = phone_exit(Point { x: 380.0, y: 200.0 }, (1200.0, 0.0), 390.0, 800.0).unwrap();
        assert_eq!((near.side, near.height), (LinkSide::Right, 0.25));
        assert!(phone_exit(Point { x: 200.0, y: 200.0 }, (1200.0, 0.0), 390.0, 800.0).is_none());
        assert!(phone_exit(Point { x: 380.0, y: 200.0 }, (500.0, 0.0), 390.0, 800.0).is_none());
        assert!(phone_exit(Point { x: 380.0, y: 200.0 }, (1200.0, 0.0), 0.0, 800.0).is_none());
        let release = phone_release(
            Point { x: 100.0, y: 900.0 },
            Point { x: -50.0, y: 900.0 },
            (-1200.0, 0.0),
            390.0,
            800.0,
        )
        .unwrap();
        assert_eq!((release.side, release.height), (LinkSide::Left, 1.0));
        assert!(
            phone_release(
                Point { x: 100.0, y: 0.0 },
                Point { x: 50.0, y: 0.0 },
                (-1200.0, 0.0),
                390.0,
                800.0
            )
            .is_none()
        );
    }

    fn run(samples: &[(f64, f64)]) -> Vec<Jolt> {
        let mut d = JoltDetector::default();
        samples.iter().filter_map(|(t, x)| d.feed(*x, *t)).collect()
    }

    #[test]
    fn one_push_then_quiet_is_a_throw_toward_that_side() {
        let mut samples = vec![(0.0, 0.0), (0.05, 2.5), (0.1, -0.1)];
        samples.extend((3..40).map(|n| (n as f64 * 0.05, 0.0)));
        assert_eq!(run(&samples), vec![Jolt::Thrown(LinkSide::Right)]);
    }

    #[test]
    fn the_stop_after_a_throw_does_not_make_a_second_event() {
        let mut samples = vec![(0.05, -2.5), (0.1, 0.0), (0.2, 2.4), (0.25, 0.0)];
        samples.extend((6..60).map(|n| (n as f64 * 0.05, 0.0)));
        let events = run(&samples);
        assert_eq!(events.len(), 1);
    }

    #[test]
    fn pushes_back_and_forth_make_a_shake() {
        let samples: Vec<(f64, f64)> = (0..8)
            .flat_map(|n| {
                let t = n as f64 * 0.1;
                let x = if n % 2 == 0 { 3.0 } else { -3.0 };
                [(t, x), (t + 0.05, 0.0)]
            })
            .collect();
        let mut d = JoltDetector::default();
        let events: Vec<_> = samples.iter().filter_map(|(t, x)| d.feed(*x, *t)).collect();
        assert_eq!(events, vec![Jolt::Shaken]);
        assert_eq!(d.shake_start(), Some(LinkSide::Right));
    }

    #[test]
    fn small_movement_and_bad_samples_do_nothing() {
        let mut d = JoltDetector::default();
        assert_eq!(d.feed(1.0, 0.0), None);
        assert_eq!(d.feed(f64::NAN, 0.1), None);
        assert_eq!(d.feed(5.0, f64::INFINITY), None);
        assert_eq!(d.feed(0.0, 2.0), None);
    }
}
