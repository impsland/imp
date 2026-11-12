# Motion

Motion is calm and short. It helps the eye follow a change. It is never needed to understand anything.

## Decision

All animations come from a small set of named presets in `design/tokens.json`. Each platform gets its own version from the generator. No screen writes its own timing.

<!-- tokens: motion -->
| Preset | Curve | Length | With Reduce Motion | Used for |
| --- | --- | --- | --- | --- |
| `quick` | easeOut | 0.12 s | no animation | Hover, focus, switches and small changes. |
| `hover` | easeOut | 0.15 s | no animation | A control under the pointer. |
| `press` | snappy | 0.15 s | no animation | A control being pressed. |
| `expand` | snappy | 0.2 s | no animation | A section opening or closing, a list changing. |
| `smooth` | snappy | 0.25 s | no animation | Selections, tabs and other changes you follow with your eyes. |
| `scene` | easeInOut | 0.35 s | fade, 0.15 s | One scene giving way to another. |
| `settle` | spring | 0.35 s | fade, 0.15 s | Bubbles and bars finding their place. |
| `spring` | spring | 0.4 s | fade, 0.15 s | Panels, banners and sheets arriving. |
| `pop` | spring, bounce 0.3 | 0.4 s | fade, 0.15 s | A small reward: a little overshoot. |
| `fade` | easeOut | 0.4 s | no animation | Something coming or going with no movement. |
| `peek` | easeInOut | 0.5 s | fade, 0.15 s | A hidden Imp sliding out from the floor and back. |
<!-- /tokens -->

Two lengths stand behind the presets: `short` (0.12 s) for small changes and `medium` (0.25 s) for things the eye follows.

## Reduce Motion

Every preset says what it becomes when the platform's Reduce Motion setting is on:

- **no animation.** The change just happens. This is for small things like hover and focus.
- **fade.** The change is a short fade (0.15 s) and nothing moves, slides or bounces. This is for panels, bubbles, bars and the peek.

Reduce Motion also:

- stops Zzz and other repeating loops, and shows a still picture,
- replaces the peek with a fade at the edge of the floor,
- makes the flight of an Imp between windows or devices a fade and a jump,
- keeps the Imp's own idle behavior (blinking, looking) calm and small.

Animation must never be the only way to learn something. A state also has a word or a shape.

## Behavior timings

These numbers are shared by every platform.

<!-- tokens: behavior -->
| Name | Value | What it is |
| --- | --- | --- |
| `toastSeconds` | 2.8 | How long a short message at the bottom of the screen stays. |
| `undoBarSeconds` | 6 | How long the Undo bar stays after an Imp is let out, sent home or sent to another device. |
| `peekIntervalMinSeconds` | 45 | The shortest wait before a hidden Imp peeks out. |
| `peekIntervalMaxSeconds` | 90 | The longest wait before a hidden Imp peeks out. |
| `peekShowSeconds` | 1.5 | How long a peeking Imp stays visible. |
| `peekQuietSeconds` | 10 | A peek waits until the user has not typed for this long. |
| `narrowWindowPoints` | 520 | Below this width Imp Settings shows its plain list under the Imp. |
| `dragStripPoints` | 28 | The height of the strip along the top of a desktop window that drags the window. |
| `localProbeTimeoutSeconds` | 2 | How long the first run waits for one local model server to answer before it moves to the next. |
| `brainCheckTimeoutSeconds` | 20 | How long the first run waits for a Brain to answer its first small request. |
| `copiedTickSeconds` | 1.4 | How long a Copy button shows its tick after it copied. |
| `framesPerSecond` | 60 | Frames a second for anything that visibly moves: a head turning, eyes following the cursor or the tilt, a hop, a mood fading. |
| `framesPerSecondSaving` | 30 | The same, in Low Power Mode or when the device runs warm. |
| `calmFramesPerSecond` | 30 | Frames a second for an Imp that only breathes, blinks and floats. Nothing changing means no frames at all. |
| `calmFramesPerSecondSaving` | 20 | The same, in Low Power Mode or when the device runs warm. |
| `sensorHz` | 30 | Motion-sensor readings a second while an Imp follows the tilt. Each frame eases towards the last reading. |
| `sensorHzSaving` | 20 | The same, in Low Power Mode. |
| `settleSeconds` | 1.2 | How long frames stay at the moving rate after the last movement, so a head turning back or a mood fading is drawn to its end. |
<!-- /tokens -->

## Frame rate

Smooth beats cheap for anything the eye follows. The energy rule is "no frames when nothing changes", not "few frames while it changes". One policy (`FramePolicy`, tested in ImpKit) gives every platform the same numbers, and the numbers are in the `behavior` table above.

- **Moving** (a head turning, eyes following the cursor, the tilt or a finger, a hop, a mood fading): `framesPerSecond`, 60. Frames stay at this rate for `settleSeconds` after the last movement, so a head turning back is drawn to its end.
- **Only breathing, blinking and floating**: `calmFramesPerSecond`, 30. The motion is a slow sine of under one point, so 30 looks the same as 60 and costs half.
- **Nothing changes** (asleep, hidden, covered, in the background, screens asleep, a still picture): no frames at all. Reduce Motion also stops the breathing and floating, but what the cursor, tilt or a finger drives still answers.
- **Low Power Mode, a serious or critical heat state** are the platform saying what it can sustain. Moving falls to `framesPerSecondSaving` (30), calm to `calmFramesPerSecondSaving` (20). These are still smooth. A critical heat state also stops the calm loop.
- **Input is read often and eased every frame.** Eyes and head read the cursor on every frame (Mac), or the motion sensor `sensorHz` times a second (30, `sensorHzSaving` 20 when saving), and a spring eases the picture towards it by the real time since the last frame (`SpringStep`). The look is the same at any frame rate and the sensor's rate never shows as steps.
- **No more than the display's 60.** 120 Hz is left off. The motion is slow and soft, nothing in it needs more, and 120 would double the cost on every ProMotion screen. A platform may raise `framesPerSecond` for moving pictures later without changing anything else.
- **No new setting.** Low Power Mode and Reduce Motion are the controls, so Settings stays short.

### Why it looked choppy

Found while tracing eye and head motion (iPhone and Mac).

- iPhone: a calm Imp was drawn at 12 fps, a lively one at 30, and only a finger got 60. Tilting the phone is neither a finger nor calm, so the eyes and lean followed at 30 fps from a sensor read at 20 Hz, the first frames after a tilt came at 12 fps (the pace could only rise after a slow frame noticed the movement), and the springs used a clamped step so a slow frame also ran slow.
- Mac: the eyes were already read on every frame and sprung by real time, but a resting Imp draws no frames, and what wakes it (`ImpLife.lively`) was only set on the inner life's tick, every 100 ms plus up to 50 ms of timer slack. The head started to turn up to 150 ms late and then jumped to speed. Dozing Imps and the Imp in the window were drawn at 12 and 30 fps.
- Fixes: moving is 60 everywhere, the mouse wakes the Imp at once, the tilt wakes the stage as soon as it is large enough to see, the sensor is read at 30 Hz and eased by a frame-rate independent spring, and calm is 30.

## Why

- Presets keep every screen in step and give designers one place to tune.
- Reduce Motion is a promise made in the token file, so each platform keeps it the same way.

## Rejected

Letting each platform pick its own timings from its toolkit's defaults. The app would feel different on each device. A different animation for every control. It adds noise.
