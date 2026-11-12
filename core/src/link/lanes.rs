//! What one device may have an Imp here work on for it at a time: one answer runs, a few wait, and the
//! rest are told it is busy, so another device cannot pile work up.

use std::collections::VecDeque;

/// How many may wait behind the one that runs.
pub const WAITING: usize = 3;
/// How many files one device may be sent at once.
pub const FILES: usize = 2;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Admission {
    /// Start it now.
    Run,
    /// It was queued.
    Wait,
    /// It is turned away.
    Busy,
}

#[derive(Debug)]
pub struct Lane<Job> {
    running: bool,
    queue: VecDeque<Job>,
}

impl<Job> Default for Lane<Job> {
    fn default() -> Self {
        Self {
            running: false,
            queue: VecDeque::new(),
        }
    }
}

/// What happens to a job offered to a lane that is `running` a job with `queued` others waiting.
pub fn admit(running: bool, queued: usize) -> Admission {
    if !running {
        Admission::Run
    } else if queued >= WAITING {
        Admission::Busy
    } else {
        Admission::Wait
    }
}

impl<Job> Lane<Job> {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn submit(&mut self, job: Job) -> Admission {
        let admission = admit(self.running, self.queue.len());
        match admission {
            Admission::Run => self.running = true,
            Admission::Wait => self.queue.push_back(job),
            Admission::Busy => {}
        }
        admission
    }

    /// The running job ended: the next one to start, if any waits.
    pub fn finish(&mut self) -> Option<Job> {
        let next = self.queue.pop_front();
        self.running = next.is_some();
        next
    }

    /// Drops everything waiting (the device went away). What runs goes on.
    pub fn clear(&mut self) -> Vec<Job> {
        self.queue.drain(..).collect()
    }

    pub fn is_running(&self) -> bool {
        self.running
    }

    pub fn is_idle(&self) -> bool {
        !self.running && self.queue.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn one_runs_three_wait_the_rest_are_busy() {
        let mut lane = Lane::new();
        assert!(lane.is_idle());
        assert_eq!(lane.submit(0), Admission::Run);
        for n in 1..=3 {
            assert_eq!(lane.submit(n), Admission::Wait);
        }
        assert_eq!(lane.submit(4), Admission::Busy);
        assert_eq!(lane.finish(), Some(1));
        assert_eq!(lane.submit(5), Admission::Wait);
        assert_eq!(lane.clear(), vec![2, 3, 5]);
        assert!(lane.is_running());
        assert_eq!(lane.finish(), None);
        assert!(lane.is_idle());
    }
}
