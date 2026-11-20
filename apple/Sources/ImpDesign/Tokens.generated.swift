// generated from design/tokens.json, do not edit. Run: node design/generate.mjs

import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The palette. A colour that differs between Light and Dark follows the appearance of the view it is drawn in.
public enum Tone {
    /// The one surface: every window, sheet and screen sits on it.
    public static let surface = Color(light: (243, 241, 236, 1), dark: (20, 21, 25, 1))
    /// Things that float over the surface for a moment: popovers, menus, bubbles and small panels.
    public static let raised = Color(light: (255, 255, 255, 1), dark: (30, 32, 38, 1))
    /// A row or header on a floating thing, one step lighter.
    public static let raisedHigh = Color(light: (243, 241, 236, 1), dark: (40, 42, 50, 1))
    /// The deepest shade, behind everything.
    public static let deep = Color(light: (230, 227, 220, 1), dark: (13, 14, 17, 1))
    /// An open hole in the floor an Imp hides in.
    public static let doorway = Color(light: (42, 44, 51, 1), dark: (7, 8, 9, 1))
    /// Dark ink on any background, for text on a bright fill.
    public static let ink = Color(red: 23 / 255, green: 24 / 255, blue: 28 / 255)
    /// Light paper on any background, for text over a picture, a scrim or a dark fill.
    public static let paper = Color(red: 242 / 255, green: 240 / 255, blue: 234 / 255)
    /// Ordinary text.
    public static let text = Color(light: (23, 24, 28, 1), dark: (242, 240, 234, 1))
    /// Quiet text.
    public static let muted = Color(light: (23, 24, 28, 0.702), dark: (242, 240, 234, 0.702))
    /// The quietest text and idle icons.
    public static let faint = Color(light: (23, 24, 28, 0.502), dark: (242, 240, 234, 0.451))
    /// A pebble: the soft fill that groups things on the surface. It has no outline.
    public static let card = Color(light: (23, 24, 28, 0.039), dark: (255, 255, 255, 0.059))
    /// A pebble under the pointer.
    public static let cardHover = Color(light: (23, 24, 28, 0.078), dark: (255, 255, 255, 0.102))
    /// A thin line, for tracks and drawings only. Groups and rows are never outlined or divided with it.
    public static let line = Color(light: (23, 24, 28, 0.122), dark: (255, 255, 255, 0.122))
    /// A well for text fields, editors and code.
    public static let well = Color(light: (23, 24, 28, 0.059), dark: (0, 0, 0, 0.278))
    /// The accent when no Imp gives its colour. The chrome is monochrome, the colour belongs to the Imps.
    public static let accent = Color(light: (23, 24, 28, 1), dark: (242, 240, 234, 1))
    /// The accent at its brightest, for a spark or a highlight.
    public static let accentBright = Color(light: (0, 0, 0, 1), dark: (255, 255, 255, 1))
    /// Text and icons on the accent.
    public static let onAccent = Color(light: (242, 240, 234, 1), dark: (23, 24, 28, 1))
    /// A little heart that floats up with the embers.
    public static let heart = Color(red: 255 / 255, green: 115 / 255, blue: 140 / 255)
    /// A link.
    public static let link = Color(light: (31, 95, 191, 1), dark: (158, 197, 255, 1))
    /// A notice that needs a look.
    public static let warnBackground = Color(light: (255, 240, 220, 1), dark: (255, 180, 71, 0.141))
    /// Text in a notice.
    public static let warnText = Color(light: (122, 67, 0, 1), dark: (255, 207, 138, 1))
    /// The line around a notice.
    public static let warnEdge = Color(light: (239, 197, 143, 1), dark: (255, 180, 71, 0.451))
    /// A message that something failed.
    public static let errorBackground = Color(light: (255, 232, 230, 1), dark: (255, 80, 80, 0.141))
    /// The line around an error.
    public static let errorEdge = Color(light: (232, 163, 157, 1), dark: (255, 110, 110, 0.502))
    /// Text and icons of a destructive action or a failure.
    public static let danger = Color(light: (198, 40, 40, 1), dark: (255, 122, 112, 1))
    /// A message that something worked.
    public static let okBackground = Color(light: (230, 246, 234, 1), dark: (110, 210, 140, 0.141))
    /// The line around a success message.
    public static let okEdge = Color(light: (156, 207, 169, 1), dark: (110, 210, 140, 0.451))
    /// The keyboard focus ring when no Imp gives its colour.
    public static let focus = Color(light: (23, 24, 28, 1), dark: (242, 240, 234, 1))
    /// Connected, done, all well.
    public static let good = Color(light: (44, 122, 69, 1), dark: (111, 220, 140, 1))
    /// Switched off or not connected.
    public static let off = Color(red: 138 / 255, green: 140 / 255, blue: 147 / 255)
    /// A dark veil behind small labels over the wall.
    public static let scrim = Color(light: (0, 0, 0, 0.38), dark: (0, 0, 0, 0.4))
    /// Over a picture or tile background behind settings, so the surface stays calm.
    public static let veil = Color(light: (243, 241, 236, 0.8), dark: (20, 21, 25, 0.8))
    /// An ordinary spark of the phone's game: warm orange.
    public static let sparkEmber = Color(red: 255 / 255, green: 158 / 255, blue: 66 / 255)
    /// A cool wisp of smoke or a storm spark.
    public static let sparkWisp = Color(red: 140 / 255, green: 207 / 255, blue: 255 / 255)
    /// A hot spark in the games.
    public static let sparkHot = Color(red: 255 / 255, green: 128 / 255, blue: 61 / 255)
    /// The edge of a smoke puff in the games.
    public static let sparkSmokeEdge = Color(red: 153 / 255, green: 138 / 255, blue: 189 / 255)
    /// The dark core of a smoke puff in the games.
    public static let sparkSmokeCore = Color(red: 23 / 255, green: 15 / 255, blue: 36 / 255)
    /// A golden spark.
    public static let sparkGold = Color(red: 255 / 255, green: 214 / 255, blue: 77 / 255)
    /// The white-hot core of a golden spark.
    public static let sparkGoldCore = Color(red: 255 / 255, green: 247 / 255, blue: 204 / 255)
    /// A pink spark of a ring.
    public static let sparkChain = Color(red: 255 / 255, green: 115 / 255, blue: 158 / 255)
    /// The core of a ring spark.
    public static let sparkChainCore = Color(red: 255 / 255, green: 237 / 255, blue: 217 / 255)
    /// The core of a green kindling spark.
    public static let sparkKindleCore = Color(red: 204 / 255, green: 255 / 255, blue: 209 / 255)
    /// The violet of the Echo game.
    public static let echoAccent = Color(red: 184 / 255, green: 153 / 255, blue: 255 / 255)
}

extension Color {
    /// A colour with a value for Light and one for Dark (red, green and blue in 0...255, alpha in 0...1).
    init(light: (Double, Double, Double, Double), dark: (Double, Double, Double, Double)) {
        #if canImport(UIKit)
        self.init(uiColor: UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0 / 255, green: c.1 / 255, blue: c.2 / 255, alpha: c.3)
        })
        #else
        self.init(nsColor: NSColor(name: nil) { appearance in
            let c = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: c.0 / 255, green: c.1 / 255, blue: c.2 / 255, alpha: c.3)
        })
        #endif
    }
}

/// How a floating thing lifts off the surface.
public enum Elevation {
    /// The lift under a card.
    public static let cardY: CGFloat = 10
    public static let cardBlur: CGFloat = 30
    public static let cardColor = Color(light: (23, 24, 28, 0.141), dark: (0, 0, 0, 0.4))
}

/// Corner radii, one scale for everything.
public enum Radius {
    /// Thumbnails and small marks inside a row.
    public static let tiny: CGFloat = 6
    /// Fields, small tiles and chips that are not capsules.
    public static let small: CGFloat = 10
    /// Icon tiles and small cards inside a card.
    public static let tile: CGFloat = 12
    /// Cards on the desktop, selectable cards and wells.
    public static let medium: CGFloat = 16
    /// Cards on the phone and big panels.
    public static let large: CGFloat = 20
    /// Speech bubbles.
    public static let bubble: CGFloat = 24
    /// Pills and round buttons.
    public static let full: CGFloat = 999
}

/// Spacing, one scale for gaps and padding.
public enum Spacing {
    /// Between a line and its own detail.
    public static let hairline: CGFloat = 2
    /// Inside a control: an icon and its word.
    public static let tight: CGFloat = 4
    /// Between small things in a row.
    public static let snug: CGFloat = 6
    /// Between controls in a row.
    public static let small: CGFloat = 8
    /// Inside a small tile or a chip.
    public static let cozy: CGFloat = 10
    /// The gap between cards.
    public static let medium: CGFloat = 12
    /// Inside a card.
    public static let roomy: CGFloat = 14
    /// Between groups.
    public static let large: CGFloat = 16
    /// The padding around a page.
    public static let page: CGFloat = 20
    /// Around a sheet or a big empty state.
    public static let wide: CGFloat = 24
    /// Between actions that must stay apart.
    public static let huge: CGFloat = 28
    /// Around a hero picture.
    public static let vast: CGFloat = 40
}

/// Line widths.
public enum Stroke {
    /// Card edges and dividers.
    public static let hairline: CGFloat = 1
    /// The keyboard focus ring and a chosen tile's edge.
    public static let focus: CGFloat = 2
}

/// Opacities, one scale for dimming and soft fills.
public enum Opacity {
    /// A control that cannot be used now.
    public static let disabled: Double = 0.45
    /// Something left out or not chosen.
    public static let dimmed: Double = 0.6
    /// A soft fill in the Imp's colour, behind an icon or a chosen row.
    public static let tintFill: Double = 0.16
    /// A stronger fill in the Imp's colour: a secondary button on the dark wall.
    public static let tintFillStrong: Double = 0.34
    /// The glow under a chosen Imp.
    public static let glow: Double = 0.45
    /// A solid fill under the pointer.
    public static let hoverFill: Double = 0.85
    /// The least opaque a translucent speech bubble may be. Below this the text cannot be kept legible over any background.
    public static let bubbleMin: Double = 0.4
    /// How opaque a translucent speech bubble starts.
    public static let bubbleDefault: Double = 0.75
}

/// Sizes of things you point at.
public enum Sizing {
    /// How far a short receipt bar sits above the bottom edge, clear of the hidden Imps' floor and the home indicator.
    public static var receiptLift: CGFloat {
        #if os(iOS)
        84
        #else
        84
        #endif
    }

    /// The smallest a control's hit area gets.
    public static var hit: CGFloat {
        #if os(iOS)
        44
        #else
        28
        #endif
    }

    /// The height of a text field or a menu button.
    public static var control: CGFloat {
        #if os(iOS)
        44
        #else
        30
        #endif
    }

    /// The visible circle of an icon button.
    public static var glyph: CGFloat {
        #if os(iOS)
        32
        #else
        26
        #endif
    }

    /// The tile behind a card's or a row's icon.
    public static var iconTile: CGFloat {
        #if os(iOS)
        30
        #else
        24
        #endif
    }

    /// The width of the menu bar panel.
    public static var menuWidth: CGFloat {
        #if os(iOS)
        300
        #else
        300
        #endif
    }

    /// Where a notice in a sheet hangs from the top: below the header, clear of the sheet's grabber.
    public static var toastTop: CGFloat {
        #if os(iOS)
        70
        #else
        48
        #endif
    }

    /// The icon tile in a sheet's header.
    public static var sheetIcon: CGFloat {
        #if os(iOS)
        36
        #else
        32
        #endif
    }

    /// The widest a help tip's text runs.
    public static var tipWidth: CGFloat {
        #if os(iOS)
        260
        #else
        260
        #endif
    }

    /// The width of a popover that holds a list or a small form.
    public static var popoverWidth: CGFloat {
        #if os(iOS)
        340
        #else
        340
        #endif
    }

    /// The fixed width of a browser toolbar popup. Wide enough for a pebble and a button, narrow enough to stay a popup.
    public static var popupWidth: CGFloat {
        #if os(iOS)
        380
        #else
        380
        #endif
    }

    /// The tallest a scrolling list grows inside a small popup before it scrolls.
    public static var popupListHeight: CGFloat {
        #if os(iOS)
        300
        #else
        300
        #endif
    }

    /// A side panel beside the Imp on a wide screen.
    public static var panelWidth: CGFloat {
        #if os(iOS)
        380
        #else
        380
        #endif
    }

    /// The widest a settings column grows. Wider screens centre it.
    public static var column: CGFloat {
        #if os(iOS)
        720
        #else
        720
        #endif
    }

    /// The width of a sheet on a desktop.
    public static var sheetWidth: CGFloat {
        #if os(iOS)
        520
        #else
        520
        #endif
    }

    /// A round tile: an animation's preview, the Imp on the phone's settings.
    public static var marker: CGFloat {
        #if os(iOS)
        48
        #else
        44
        #endif
    }

    /// The room of a model's reasoning while it streams in (about three lines): the same all along, so nothing shifts.
    public static var thinkingHeight: CGFloat {
        #if os(iOS)
        60
        #else
        54
        #endif
    }

    /// The Imp drawn in a row or a card.
    public static var impPortrait: CGFloat {
        #if os(iOS)
        44
        #else
        36
        #endif
    }

    /// The label column of a form row, so a card's controls line up.
    public static var fieldLabel: CGFloat {
        #if os(iOS)
        96
        #else
        76
        #endif
    }

    /// A round tick or a status mark.
    public static var mark: CGFloat {
        #if os(iOS)
        24
        #else
        20
        #endif
    }

    /// The widest a menu button's title runs before it ends in an ellipsis, so a long name never widens a form.
    public static var menuTitle: CGFloat {
        #if os(iOS)
        180
        #else
        150
        #endif
    }

    /// An Imp's face on the kit review's header.
    public static var heroFace: CGFloat {
        #if os(iOS)
        64
        #else
        68
        #endif
    }

    /// A status dot or a small marker beside a title.
    public static var dot: CGFloat {
        #if os(iOS)
        8
        #else
        6
        #endif
    }

    /// The animation editor's sheet: the stage, the beat's pose and the timeline side by side.
    public static var editorWidth: CGFloat {
        #if os(iOS)
        390
        #else
        780
        #endif
    }

    /// The animation editor's stage, where the Imp acts a beat out.
    public static var stageWidth: CGFloat {
        #if os(iOS)
        320
        #else
        268
        #endif
    }

    /// The height of the animation editor's stage and pose row, above the timeline.
    public static var editorTop: CGFloat {
        #if os(iOS)
        300
        #else
        256
        #endif
    }

    /// The width of a switch's track.
    public static var switchTrack: CGFloat {
        #if os(iOS)
        51
        #else
        42
        #endif
    }

    /// The side of the linking QR code.
    public static var codeSide: CGFloat {
        #if os(iOS)
        200
        #else
        188
        #endif
    }

    /// The height of the camera view that scans a code.
    public static var viewfinderHeight: CGFloat {
        #if os(iOS)
        240
        #else
        220
        #endif
    }

    /// The side of the frame to aim a code at.
    public static var viewfinderAim: CGFloat {
        #if os(iOS)
        160
        #else
        150
        #endif
    }

    /// The sleeping Imp on the first-run sheet.
    public static var heroImp: CGFloat {
        #if os(iOS)
        120
        #else
        120
        #endif
    }

    /// The round button that starts a game.
    public static var gameButton: CGFloat {
        #if os(iOS)
        48
        #else
        48
        #endif
    }

    /// The icon place on a game rules card.
    public static var coachBadge: CGFloat {
        #if os(iOS)
        34
        #else
        34
        #endif
    }

    /// The icon column of a game message.
    public static var gameIcon: CGFloat {
        #if os(iOS)
        26
        #else
        26
        #endif
    }

    /// The ring beside the score.
    public static var gameRing: CGFloat {
        #if os(iOS)
        16
        #else
        16
        #endif
    }

    /// The touch pad of the Echo game.
    public static var echoPad: CGFloat {
        #if os(iOS)
        128
        #else
        128
        #endif
    }

    /// The widest a game's results or rules card runs.
    public static var gameCard: CGFloat {
        #if os(iOS)
        320
        #else
        320
        #endif
    }

    /// The narrowest column of a results stat, before the stats stack.
    public static var gameStat: CGFloat {
        #if os(iOS)
        84
        #else
        84
        #endif
    }

    /// The bar that counts a special phase down.
    public static var meter: CGFloat {
        #if os(iOS)
        110
        #else
        110
        #endif
    }

    /// The widest a door label runs.
    public static var doorLabel: CGFloat {
        #if os(iOS)
        150
        #else
        150
        #endif
    }

    /// The widest a speech bubble header runs.
    public static var bubbleHeader: CGFloat {
        #if os(iOS)
        220
        #else
        220
        #endif
    }

    /// The tallest a picture in a speech bubble gets.
    public static var thumbHeight: CGFloat {
        #if os(iOS)
        110
        #else
        110
        #endif
    }

    /// The place held for a picture still loading.
    public static var thumbWaitWidth: CGFloat {
        #if os(iOS)
        80
        #else
        80
        #endif
    }

    /// The place held for a picture still loading, its height.
    public static var thumbWaitHeight: CGFloat {
        #if os(iOS)
        60
        #else
        60
        #endif
    }

    /// The strip along the bottom edge where a hiding Imp peeks.
    public static var hiddenStrip: CGFloat {
        #if os(iOS)
        28
        #else
        28
        #endif
    }
}

/// The type scale, as named styles. `Typeface` turns them into fonts.
public enum TypeScale {
    /// A sheet's or screen's title.
    public static let title = TypeToken(size: 17, weight: .bold, design: .rounded, style: .title3)
    /// A card's title.
    public static let cardTitle = TypeToken(size: 14, weight: .semibold, design: .rounded, style: .headline)
    /// Ordinary text.
    public static let body = TypeToken(size: 13, weight: .regular, design: .rounded, style: .body)
    /// The label of a button or a chip.
    public static let label = TypeToken(size: 12.5, weight: .semibold, design: .rounded, style: .subheadline)
    /// A form label and other quiet lines.
    public static let caption = TypeToken(size: 12.5, weight: .medium, design: .rounded, style: .footnote)
    /// Small print, statuses and badges.
    public static let small = TypeToken(size: 11.5, weight: .regular, design: .rounded, style: .caption)
    /// The one big number of a screen, such as a game's score.
    public static let display = TypeToken(size: 40, weight: .bold, design: .rounded, style: .largeTitle)
    /// Code, paths and keys.
    public static let mono = TypeToken(size: 12.5, weight: .regular, design: .monospaced, style: .callout)
}

/// Icon sizes. On the iPhone an icon follows Dynamic Type with its text style, on the Mac it is a fixed size.
public enum IconSize: Sendable {
    /// A chevron inside a menu button.
    case tiny
    /// A status dot or a mark beside small text.
    case small
    /// An icon beside a label, in a chip or a tile.
    case medium
    /// An icon button's glyph and a card's icon.
    case large
    /// A marker or a sheet's icon.
    case big
    /// An empty state's picture.
    case huge

    /// The size in points on the Mac, and at the default text size on the iPhone.
    public var points: CGFloat {
        switch self {
        case .tiny: 8
        case .small: 10
        case .medium: 12
        case .large: 14
        case .big: 18
        case .huge: 30
        }
    }

    /// The text style the icon grows with on the iPhone.
    public var textStyle: Font.TextStyle {
        switch self {
        case .tiny: .caption2
        case .small: .caption2
        case .medium: .footnote
        case .large: .body
        case .big: .title3
        case .huge: .largeTitle
        }
    }
}

/// How long things animate.
public enum Timing {
    /// Hover, press, focus and other small changes.
    public static let short = 0.12
    /// Sliding, appearing and other changes you follow with your eyes.
    public static let medium = 0.25
    /// With Reduce Motion, a preset that fades changes opacity over this long.
    public static let reducedFade = 0.15
}

/// The named animations, with what each does when Reduce Motion is on.
public enum Motion {
    /// Hover, focus, switches and small changes.
    public static let quick = MotionPreset(.easeOut(duration: 0.12), reduced: nil)
    /// A control under the pointer.
    public static let hover = MotionPreset(.easeOut(duration: 0.15), reduced: nil)
    /// A control being pressed.
    public static let press = MotionPreset(.snappy(duration: 0.15), reduced: nil)
    /// A section opening or closing, a list changing.
    public static let expand = MotionPreset(.snappy(duration: 0.2), reduced: nil)
    /// Selections, tabs and other changes you follow with your eyes.
    public static let smooth = MotionPreset(.snappy(duration: 0.25), reduced: nil)
    /// One scene giving way to another.
    public static let scene = MotionPreset(.easeInOut(duration: 0.35), reduced: .easeOut(duration: Timing.reducedFade))
    /// Bubbles and bars finding their place.
    public static let settle = MotionPreset(.spring(duration: 0.35, bounce: 0), reduced: .easeOut(duration: Timing.reducedFade))
    /// Panels, banners and sheets arriving.
    public static let spring = MotionPreset(.spring(duration: 0.4, bounce: 0), reduced: .easeOut(duration: Timing.reducedFade))
    /// A small reward: a little overshoot.
    public static let pop = MotionPreset(.spring(duration: 0.4, bounce: 0.3), reduced: .easeOut(duration: Timing.reducedFade))
    /// Something coming or going with no movement.
    public static let fade = MotionPreset(.easeOut(duration: 0.4), reduced: nil)
    /// A hidden Imp sliding out from the floor and back.
    public static let peek = MotionPreset(.easeInOut(duration: 0.5), reduced: .easeOut(duration: Timing.reducedFade))
}

/// Numbers that behaviour rules share on every platform.
public enum Behavior {
    /// How long a short message at the bottom of the screen stays.
    public static let toastSeconds = 2.8
    /// How long a floating notice (a failure's details) stays before it goes away by itself.
    public static let noticeSeconds = 5
    /// How long the Undo bar stays after an Imp is let out, sent home or sent to another device.
    public static let undoBarSeconds = 6
    /// The shortest wait before a hidden Imp peeks out.
    public static let peekIntervalMinSeconds = 45
    /// The longest wait before a hidden Imp peeks out.
    public static let peekIntervalMaxSeconds = 90
    /// How long a peeking Imp stays visible.
    public static let peekShowSeconds = 1.5
    /// A peek waits until the user has not typed for this long.
    public static let peekQuietSeconds = 10
    /// Below this width a settings rail shows its icons alone.
    public static let narrowWindowPoints = 520
    /// The height of the strip along the top of a desktop window that drags the window.
    public static let dragStripPoints = 28
    /// How long the first run waits for one local model server to answer before it moves to the next.
    public static let localProbeTimeoutSeconds = 2
    /// How long the first run waits for a service to list its models before it says so and lets the model be typed.
    public static let modelListTimeoutSeconds = 8
    /// How long a carried Imp must rest near a side of the desktop before the names of the devices behind it show. A quick move to a side shows nothing.
    public static let deskDoorDelaySeconds = 0.5
    /// How long the first run waits for a Brain to answer its first small request.
    public static let brainCheckTimeoutSeconds = 20
    /// How long a carried Imp must stay near a side of the phone before the names of the devices behind it show. A quick move to a side shows nothing.
    public static let edgeHintDelaySeconds = 0.5
    /// A carried Imp moving towards a side faster than this (points a second) is being thrown, so no device names show. Equal to the core's throw speed (PHONE_SPEED in engine/src/link/toss.rs), so the names hide exactly when a throw happens.
    public static let edgeHintMaxSpeedPoints = 900
    /// How close to a side of the phone (points from it, to the middle of the Imp) a carried Imp must come, heading for that side, for the tick that says a door is there. Moving back from the side never ticks.
    public static let edgeTickDistancePoints = 40
    /// How long a Copy button shows its tick after it copied.
    public static let copiedTickSeconds = 1.4
    /// How far an Imp is pulled sideways by a full tilt, in points. It springs back when the phone is level. The first screen and the home screen use it.
    public static let tiltSlide = 34
    /// How far an Imp leans into a full tilt, in degrees. The first screen and the home screen use it.
    public static let tiltLean = 16
    /// Frames a second for anything that visibly moves: a head turning, eyes following the cursor or the tilt, a hop, a mood fading.
    public static let framesPerSecond = 60
    /// The same, in Low Power Mode or when the device runs warm.
    public static let framesPerSecondSaving = 30
    /// Frames a second for an Imp that only breathes, blinks and floats. Nothing changing means no frames at all.
    public static let calmFramesPerSecond = 30
    /// The same, in Low Power Mode or when the device runs warm.
    public static let calmFramesPerSecondSaving = 20
    /// Motion-sensor readings a second while an Imp follows the tilt. Each frame eases towards the last reading.
    public static let sensorHz = 30
    /// The same, in Low Power Mode.
    public static let sensorHzSaving = 20
    /// How long frames stay at the moving rate after the last movement, so a head turning back or a mood fading is drawn to its end.
    public static let settleSeconds = 1.2
    /// The spring that brings an Imp up into the free room when its sheet opens: how hard it pulls.
    public static let summonStiffness = 40
    /// The spring that brings an Imp up into the free room when its sheet opens: how fast it calms. A little under critical, so the Imp arrives with a small overshoot.
    public static let summonDamping = 11
    /// How far down the free room above a sheet the Imp waits (0 top, 1 bottom), so its speech bubble has room above it.
    public static let summonHeight = 0.6
    /// The share of the screen a sheet resting at half height covers.
    public static let sheetHalfCover = 0.5
}
