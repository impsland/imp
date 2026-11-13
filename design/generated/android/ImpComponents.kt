// generated from design/components.json, do not edit. Run: node design/generate.mjs
package app.imp.design

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp

/** The Pebble components as specs: tokens in, no behaviour. Colours are functions of the palette, so one spec serves light and dark. */
object ImpComponents {
    /** A group: a soft fill with big corners. Never an outline, never a divider inside, never a gradient or a shadow. */
    object Pebble {
        val fill: (ImpPalette) -> Color = { it.card }
        val fillHover: (ImpPalette) -> Color = { it.cardHover }
        val radius: Dp = ImpRadius.medium
        val padding: Dp = ImpSpacing.large
        val gap: Dp = ImpSpacing.snug
        const val border: String = "none"
        const val shadow: String = "none"
    }

    /** The one background of every window, screen and sheet. A sheet has exactly the same background as the app. */
    object Surface {
        val fill: (ImpPalette) -> Color = { it.surface }
        val text: (ImpPalette) -> Color = { it.text }
        const val border: String = "none"
        const val gradient: String = "none"
    }

    /** One setting: a picture, one to three plain words and a control. A help question mark only when the title cannot be understood without it. */
    object Row {
        val minHeight: Dp = ImpSizing.hit
        val iconTile: Dp = ImpSizing.iconTile
        val iconSize: Dp = ImpIcon.small
        val gap: Dp = ImpSpacing.cozy
        val title: ImpTextStyle = ImpType.body
        val titleColor: (ImpPalette) -> Color = { it.text }
        val helpColor: (ImpPalette) -> Color = { it.muted }
        const val divider: String = "none"
    }

    /** The header of a card, a section or a sheet: the picture and the title on the leading edge, an optional control and then the help question mark on the trailing edge. The help is always the last thing on the right, so the header is balanced and the question mark is in the same place on every card. */
    object SectionHeader {
        val minHeight: Dp = ImpSizing.iconTile
        val iconTile: Dp = ImpSizing.iconTile
        val gap: Dp = ImpSpacing.small
        val title: ImpTextStyle = ImpType.cardTitle
        val titleColor: (ImpPalette) -> Color = { it.text }
        val helpColor: (ImpPalette) -> Color = { it.muted }
    }

    /** How an icon button sits in a corner (a close button, a back button, a settings gear). */
    object CornerInset {
        val hit: Dp = ImpSizing.hit
        val glyph: Dp = ImpSizing.glyph
    }

    /** How a result is shown without moving anything. Never a line inserted into the page. */
    object Notice {
        val fill: (ImpPalette) -> Color = { it.raised }
        val text: (ImpPalette) -> Color = { it.text }
        val radius: Dp = ImpRadius.full
        val padding: Dp = ImpSpacing.large
        val shadow: ImpShadow = ImpShadows.card
        val motion: ImpMotion = ImpMotions.expand
    }

    /** A round bead behind an icon. */
    object IconTile {
        val size: Dp = ImpSizing.iconTile
        val radius: Dp = ImpRadius.full
        val fill: (ImpPalette) -> Color = { it.card }
        val iconColor: (ImpPalette) -> Color = { it.text }
        val iconSize: Dp = ImpIcon.small
    }

    /** The one main action of a screen. Filled with the accent (the Imp's colour inside an Imp's context). */
    object ButtonPrimary {
        val fill: (ImpPalette) -> Color = { it.accent }
        val text: (ImpPalette) -> Color = { it.onAccent }
        val radius: Dp = ImpRadius.full
        val paddingX: Dp = ImpSpacing.large
        val paddingY: Dp = ImpSpacing.small
        val minHeight: Dp = ImpSizing.hit
        val type: ImpTextStyle = ImpType.label
        val motionHover: ImpMotion = ImpMotions.hover
        val motionPress: ImpMotion = ImpMotions.press
    }

    /** A second action next to the primary one. */
    object ButtonSecondary {
        val fill: (ImpPalette) -> Color = { it.card }
        val fillHover: (ImpPalette) -> Color = { it.cardHover }
        val text: (ImpPalette) -> Color = { it.text }
        val radius: Dp = ImpRadius.full
        val paddingX: Dp = ImpSpacing.large
        val paddingY: Dp = ImpSpacing.small
        val minHeight: Dp = ImpSizing.hit
        val type: ImpTextStyle = ImpType.label
        const val border: String = "none"
    }

    /** A text or icon button without a fill until hovered. */
    object ButtonQuiet {
        const val fill: String = "none"
        val fillHover: (ImpPalette) -> Color = { it.cardHover }
        val text: (ImpPalette) -> Color = { it.muted }
        val textHover: (ImpPalette) -> Color = { it.text }
        val radius: Dp = ImpRadius.full
        val paddingX: Dp = ImpSpacing.medium
        val paddingY: Dp = ImpSpacing.small
        val minHeight: Dp = ImpSizing.hit
        val type: ImpTextStyle = ImpType.label
    }

    /** An action that removes something. */
    object ButtonDestructive {
        val fill: (ImpPalette) -> Color = { it.errorBackground }
        val text: (ImpPalette) -> Color = { it.danger }
        val radius: Dp = ImpRadius.full
        val paddingX: Dp = ImpSpacing.large
        val paddingY: Dp = ImpSpacing.small
        val minHeight: Dp = ImpSizing.hit
        val type: ImpTextStyle = ImpType.label
        const val border: String = "none"
    }

    /** A choice of two to five exclusive options in one pebble. */
    object Segmented {
        val track: (ImpPalette) -> Color = { it.card }
        val selectedFill: (ImpPalette) -> Color = { it.accent }
        val selectedText: (ImpPalette) -> Color = { it.onAccent }
        val text: (ImpPalette) -> Color = { it.muted }
        val radius: Dp = ImpRadius.full
        val padding: Dp = ImpSpacing.tight
        val segmentMinHeight: Dp = ImpSizing.control
        val type: ImpTextStyle = ImpType.label
    }

    /** An on/off control. */
    object Switch {
        val trackWidth: Dp = ImpSizing.switchTrack
        val trackOff: (ImpPalette) -> Color = { it.card }
        val trackOn: (ImpPalette) -> Color = { it.accent }
        val knob: (ImpPalette) -> Color = { it.onAccent }
        val hit: Dp = ImpSizing.hit
        val motion: ImpMotion = ImpMotions.quick
    }

    /** A text field. */
    object Field {
        val fill: (ImpPalette) -> Color = { it.well }
        val radius: Dp = ImpRadius.small
        val paddingX: Dp = ImpSpacing.cozy
        val height: Dp = ImpSizing.control
        val text: (ImpPalette) -> Color = { it.text }
        val placeholder: (ImpPalette) -> Color = { it.faint }
        val type: ImpTextStyle = ImpType.body
        const val border: String = "none"
        val focusRing: Dp = ImpStroke.focus
    }

    /** An action inside a field: a quiet glyph at the field's trailing edge. */
    object FieldAction {
        val inset: Dp = ImpSpacing.tight
        val radius: Dp = ImpRadius.small
        val icon: Dp = ImpIcon.medium
        val text: (ImpPalette) -> Color = { it.muted }
        val textHover: (ImpPalette) -> Color = { it.text }
        val fillHover: (ImpPalette) -> Color = { it.cardHover }
        val fillPressed: (ImpPalette) -> Color = { it.line }
        const val border: String = "none"
    }

    /** The help question mark and the popover it opens. One or two short sentences for a child. */
    object InfoTip {
        val button: Dp = ImpSizing.hit
        val glyph: Dp = ImpIcon.tiny
        val glyphColor: (ImpPalette) -> Color = { it.muted }
        val maxWidth: Dp = ImpSizing.tipWidth
        val fill: (ImpPalette) -> Color = { it.raised }
        val radius: Dp = ImpRadius.medium
        val padding: Dp = ImpSpacing.cozy
        val text: (ImpPalette) -> Color = { it.text }
        val type: ImpTextStyle = ImpType.caption
        val shadow: ImpShadow = ImpShadows.card
    }

    /** The fill of a coloured control (a filled button, the selected segment, a switch that is on, a badge on an Imp's colour). */
    object TintFill {
        val ink: (ImpPalette) -> Color = { it.ink }
        val paper: (ImpPalette) -> Color = { it.paper }
        const val least: Float = 4.5f
    }

    /** Text, an icon or a switch knob on a 'tintFill'. */
    object OnTint {
        val ink: (ImpPalette) -> Color = { it.ink }
        val paper: (ImpPalette) -> Color = { it.paper }
        const val least: Float = 4.5f
    }

    /** An Imp's colour used as a foreground (text, an icon, a link) on the surface or a raised surface. */
    object LegibleTint {
        const val least: Float = 4.5f
        val ground: (ImpPalette) -> Color = { it.surface }
        val raisedGround: (ImpPalette) -> Color = { it.raised }
    }

    /** The one sheet over the room on a phone. The room stays under it, and alive above it while the sheet rests at half height. */
    object Sheet {
        val fill: (ImpPalette) -> Color = { it.surface }
        val barInsetX: Dp = ImpSpacing.medium
        val barInsetTop: Dp = ImpSpacing.medium
        val contentInsetX: Dp = ImpSpacing.page
        val gap: Dp = ImpSpacing.medium
        val portrait: Dp = ImpSizing.impPortrait
        val name: ImpTextStyle = ImpType.cardTitle
        val state: ImpTextStyle = ImpType.small
        val stateColor: (ImpPalette) -> Color = { it.muted }
        const val glow: Float = ImpOpacity.glow
        val motion: ImpMotion = ImpMotions.spring
        const val border: String = "none"
        const val shadow: String = "none"
    }

    /** The top bar of every modal flow and sheet: Back leading, a centred title or step indicator, Close trailing. */
    object SheetBar {
        val height: Dp = ImpSizing.hit
        val gap: Dp = ImpSpacing.cozy
        val glyph: Dp = ImpIcon.small
        val glyphColor: (ImpPalette) -> Color = { it.muted }
        val title: ImpTextStyle = ImpType.cardTitle
        const val background: String = "none"
    }

    /** Round marks for the steps of a flow, the current one filled with the Imp's colour. */
    object StepIndicator {
        val mark: Dp = ImpIcon.tiny
        val gap: Dp = ImpSpacing.small
        val done: (ImpPalette) -> Color = { it.muted }
        val todo: (ImpPalette) -> Color = { it.faint }
        val current: (ImpPalette) -> Color = { it.accent }
        val hit: Dp = ImpSizing.hit
    }

    /** The sections of a settings screen, always one tap away. */
    object SectionRail {
        val itemMinHeight: Dp = ImpSizing.hit
        val itemRadius: Dp = ImpRadius.tile
        val selectedFill: (ImpPalette) -> Color = { it.card }
        val hover: (ImpPalette) -> Color = { it.cardHover }
        val icon: Dp = ImpIcon.small
        val gap: Dp = ImpSpacing.tight
        val type: ImpTextStyle = ImpType.body
    }

    /** Evenly sized choices (the service choices, Remote and Local) as tiles in a grid, each with a link to the provider's page. */
    object PresetGrid {
        val minColumn: Dp = ImpSizing.menuTitle
        val gap: Dp = ImpSpacing.small
        val radius: Dp = ImpRadius.tile
        val fill: (ImpPalette) -> Color = { it.card }
        val selectedFill: (ImpPalette) -> Color = { it.accent }
        val selectedText: (ImpPalette) -> Color = { it.onAccent }
        val minHeight: Dp = ImpSizing.hit
    }

    /** The Imp's speech bubble on the desktop. */
    object Bubble {
        val fill: (ImpPalette) -> Color = { it.raised }
        val text: (ImpPalette) -> Color = { it.text }
        val radius: Dp = ImpRadius.bubble
        val padding: Dp = ImpSpacing.medium
        val shadow: ImpShadow = ImpShadows.card
        val type: ImpTextStyle = ImpType.body
    }

    /** A small floating panel with a list or a small form. */
    object Popover {
        val fill: (ImpPalette) -> Color = { it.raised }
        val radius: Dp = ImpRadius.medium
        val padding: Dp = ImpSpacing.medium
        val width: Dp = ImpSizing.popoverWidth
        val shadow: ImpShadow = ImpShadows.card
        const val border: String = "none"
    }

    /** The menu of the menu bar or tray icon: the Imps that are out and a few actions. */
    object BarMenu {
        val fill: (ImpPalette) -> Color = { it.raised }
        val radius: Dp = ImpRadius.medium
        val padding: Dp = ImpSpacing.small
        val rowMinHeight: Dp = ImpSizing.hit
        val rowRadius: Dp = ImpRadius.tile
        val rowHover: (ImpPalette) -> Color = { it.cardHover }
        val iconSize: Dp = ImpIcon.small
        val gap: Dp = ImpSpacing.cozy
        val type: ImpTextStyle = ImpType.body
        val width: Dp = ImpSizing.popoverWidth
    }

    /** A bar that floats at the bottom after something was removed. */
    object UndoBar {
        val fill: (ImpPalette) -> Color = { it.raised }
        val text: (ImpPalette) -> Color = { it.text }
        val radius: Dp = ImpRadius.full
        val padding: Dp = ImpSpacing.medium
        val shadow: ImpShadow = ImpShadows.card
        val motion: ImpMotion = ImpMotions.expand
    }

    /** A tiny status label or count. */
    object Badge {
        val fill: (ImpPalette) -> Color = { it.card }
        val text: (ImpPalette) -> Color = { it.muted }
        val radius: Dp = ImpRadius.full
        val paddingX: Dp = ImpSpacing.snug
        val paddingY: Dp = ImpSpacing.tight
        val type: ImpTextStyle = ImpType.small
    }

    /** The keyboard focus ring of every control. */
    object Focus {
        val color: (ImpPalette) -> Color = { it.focus }
        val width: Dp = ImpStroke.focus
        val offset: Dp = ImpSpacing.hairline
    }
}
