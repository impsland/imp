// generated from design/tokens.json, do not edit. Run: node design/generate.mjs
package app.imp.design

import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.TweenSpec
import androidx.compose.animation.core.tween
import android.provider.Settings
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** The colours of one appearance. */
class ImpPalette(
    val surface: Color,
    val raised: Color,
    val raisedHigh: Color,
    val deep: Color,
    val doorway: Color,
    val ink: Color,
    val paper: Color,
    val text: Color,
    val muted: Color,
    val faint: Color,
    val card: Color,
    val cardHover: Color,
    val line: Color,
    val well: Color,
    val accent: Color,
    val accentBright: Color,
    val onAccent: Color,
    val heart: Color,
    val link: Color,
    val warnBackground: Color,
    val warnText: Color,
    val warnEdge: Color,
    val errorBackground: Color,
    val errorEdge: Color,
    val danger: Color,
    val okBackground: Color,
    val okEdge: Color,
    val focus: Color,
    val good: Color,
    val off: Color,
    val scrim: Color,
    val veil: Color,
    val sparkEmber: Color,
    val sparkWisp: Color,
    val sparkHot: Color,
    val sparkSmokeEdge: Color,
    val sparkSmokeCore: Color,
    val sparkGold: Color,
    val sparkGoldCore: Color,
    val sparkChain: Color,
    val sparkChainCore: Color,
    val sparkKindleCore: Color,
    val echoAccent: Color,
)

val ImpDarkPalette = ImpPalette(
    surface = Color(0xFF141519),
    raised = Color(0xFF1E2026),
    raisedHigh = Color(0xFF282A32),
    deep = Color(0xFF0D0E11),
    doorway = Color(0xFF070809),
    ink = Color(0xFF17181C),
    paper = Color(0xFFF2F0EA),
    text = Color(0xFFF2F0EA),
    muted = Color(0xB3F2F0EA),
    faint = Color(0x73F2F0EA),
    card = Color(0x0FFFFFFF),
    cardHover = Color(0x1AFFFFFF),
    line = Color(0x1FFFFFFF),
    well = Color(0x47000000),
    accent = Color(0xFFF2F0EA),
    accentBright = Color(0xFFFFFFFF),
    onAccent = Color(0xFF17181C),
    heart = Color(0xFFFF738C),
    link = Color(0xFF9EC5FF),
    warnBackground = Color(0x24FFB447),
    warnText = Color(0xFFFFCF8A),
    warnEdge = Color(0x73FFB447),
    errorBackground = Color(0x24FF5050),
    errorEdge = Color(0x80FF6E6E),
    danger = Color(0xFFFF7A70),
    okBackground = Color(0x246ED28C),
    okEdge = Color(0x736ED28C),
    focus = Color(0xFFF2F0EA),
    good = Color(0xFF6FDC8C),
    off = Color(0xFF8A8C93),
    scrim = Color(0x66000000),
    veil = Color(0xCC141519),
    sparkEmber = Color(0xFFFF9E42),
    sparkWisp = Color(0xFF8CCFFF),
    sparkHot = Color(0xFFFF803D),
    sparkSmokeEdge = Color(0xFF998ABD),
    sparkSmokeCore = Color(0xFF170F24),
    sparkGold = Color(0xFFFFD64D),
    sparkGoldCore = Color(0xFFFFF7CC),
    sparkChain = Color(0xFFFF739E),
    sparkChainCore = Color(0xFFFFEDD9),
    sparkKindleCore = Color(0xFFCCFFD1),
    echoAccent = Color(0xFFB899FF),
)

val ImpLightPalette = ImpPalette(
    surface = Color(0xFFF3F1EC),
    raised = Color(0xFFFFFFFF),
    raisedHigh = Color(0xFFF3F1EC),
    deep = Color(0xFFE6E3DC),
    doorway = Color(0xFF2A2C33),
    ink = Color(0xFF17181C),
    paper = Color(0xFFF2F0EA),
    text = Color(0xFF17181C),
    muted = Color(0xB317181C),
    faint = Color(0x8017181C),
    card = Color(0x0A17181C),
    cardHover = Color(0x1417181C),
    line = Color(0x1F17181C),
    well = Color(0x0F17181C),
    accent = Color(0xFF17181C),
    accentBright = Color(0xFF000000),
    onAccent = Color(0xFFF2F0EA),
    heart = Color(0xFFFF738C),
    link = Color(0xFF1F5FBF),
    warnBackground = Color(0xFFFFF0DC),
    warnText = Color(0xFF7A4300),
    warnEdge = Color(0xFFEFC58F),
    errorBackground = Color(0xFFFFE8E6),
    errorEdge = Color(0xFFE8A39D),
    danger = Color(0xFFC62828),
    okBackground = Color(0xFFE6F6EA),
    okEdge = Color(0xFF9CCFA9),
    focus = Color(0xFF17181C),
    good = Color(0xFF2C7A45),
    off = Color(0xFF8A8C93),
    scrim = Color(0x61000000),
    veil = Color(0xCCF3F1EC),
    sparkEmber = Color(0xFFFF9E42),
    sparkWisp = Color(0xFF8CCFFF),
    sparkHot = Color(0xFFFF803D),
    sparkSmokeEdge = Color(0xFF998ABD),
    sparkSmokeCore = Color(0xFF170F24),
    sparkGold = Color(0xFFFFD64D),
    sparkGoldCore = Color(0xFFFFF7CC),
    sparkChain = Color(0xFFFF739E),
    sparkChainCore = Color(0xFFFFEDD9),
    sparkKindleCore = Color(0xFFCCFFD1),
    echoAccent = Color(0xFFB899FF),
)

/** The palette of the current appearance. Read colours from here, never as a literal. */
val LocalImpPalette = staticCompositionLocalOf { ImpDarkPalette }

/** Gives everything inside the right palette: dark or light, following the system unless told. */
@Composable
fun ImpTheme(dark: Boolean = isSystemInDarkTheme(), content: @Composable () -> Unit) {
    CompositionLocalProvider(LocalImpPalette provides if (dark) ImpDarkPalette else ImpLightPalette, content = content)
}

/** True when the person turned animations off in the system settings (Reduce Motion). */
@Composable
fun rememberReduceMotion(): Boolean {
    val resolver = LocalContext.current.contentResolver
    return remember { Settings.Global.getFloat(resolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f }
}

/** How a floating thing lifts off the surface. */
class ImpShadow(val y: Dp, val blur: Dp, val dark: Color, val light: Color) {
    fun color(isDark: Boolean) = if (isDark) dark else light
}

object ImpShadows {
    val card = ImpShadow(10.dp, 30.dp, Color(0x66000000), Color(0x2417181C))
}

object ImpSpacing {
    val hairline = 2.dp
    val tight = 4.dp
    val snug = 6.dp
    val small = 8.dp
    val cozy = 10.dp
    val medium = 12.dp
    val roomy = 14.dp
    val large = 16.dp
    val page = 20.dp
    val wide = 24.dp
    val huge = 28.dp
    val vast = 40.dp
}

object ImpRadius {
    val tiny = 6.dp
    val small = 10.dp
    val tile = 12.dp
    val medium = 16.dp
    val large = 20.dp
    val bubble = 24.dp
    val full = 999.dp
}

object ImpStroke {
    val hairline = 1.dp
    val focus = 2.dp
}

object ImpOpacity {
    const val disabled = 0.45f
    const val dimmed = 0.6f
    const val tintFill = 0.16f
    const val tintFillStrong = 0.34f
    const val glow = 0.45f
    const val hoverFill = 0.85f
    const val bubbleMin = 0.4f
    const val bubbleDefault = 0.75f
}

object ImpSizing {
    /** How far a short receipt bar sits above the bottom edge, clear of the hidden Imps' floor and the home indicator. */
    val receiptLift = 84.dp
    /** The smallest a control's hit area gets. */
    val hit = 48.dp
    /** The height of a text field or a menu button. */
    val control = 48.dp
    /** The visible circle of an icon button. */
    val glyph = 40.dp
    /** The tile behind a card's or a row's icon. */
    val iconTile = 32.dp
    /** The width of the menu bar panel. */
    val menuWidth = 300.dp
    /** Where a notice in a sheet hangs from the top: below the header, clear of the sheet's grabber. */
    val toastTop = 72.dp
    /** The icon tile in a sheet's header. */
    val sheetIcon = 40.dp
    /** The widest a help tip's text runs. */
    val tipWidth = 280.dp
    /** The width of a popover that holds a list or a small form. */
    val popoverWidth = 360.dp
    /** The fixed width of a browser toolbar popup. Wide enough for a pebble and a button, narrow enough to stay a popup. */
    val popupWidth = 380.dp
    /** The tallest a scrolling list grows inside a small popup before it scrolls. */
    val popupListHeight = 300.dp
    /** A side panel beside the Imp on a wide screen. */
    val panelWidth = 400.dp
    /** The widest a settings column grows. Wider screens centre it. */
    val column = 720.dp
    /** The width of a sheet on a desktop. */
    val sheetWidth = 560.dp
    /** A round tile: an animation's preview, the Imp on the phone's settings. */
    val marker = 56.dp
    /** The room of a model's reasoning while it streams in (about three lines): the same all along, so nothing shifts. */
    val thinkingHeight = 60.dp
    /** The Imp drawn in a row or a card. */
    val impPortrait = 48.dp
    /** The label column of a form row, so a card's controls line up. */
    val fieldLabel = 104.dp
    /** A round tick or a status mark. */
    val mark = 24.dp
    /** The widest a menu button's title runs before it ends in an ellipsis, so a long name never widens a form. */
    val menuTitle = 180.dp
    /** An Imp's face on the kit review's header. */
    val heroFace = 72.dp
    /** A status dot or a small marker beside a title. */
    val dot = 8.dp
    /** The animation editor's sheet: the stage, the beat's pose and the timeline side by side. */
    val editorWidth = 390.dp
    /** The animation editor's stage, where the Imp acts a beat out. */
    val stageWidth = 320.dp
    /** The height of the animation editor's stage and pose row, above the timeline. */
    val editorTop = 300.dp
    /** The width of a switch's track. */
    val switchTrack = 52.dp
    /** The side of the linking QR code. */
    val codeSide = 200.dp
    /** The height of the camera view that scans a code. */
    val viewfinderHeight = 240.dp
    /** The side of the frame to aim a code at. */
    val viewfinderAim = 160.dp
    /** The sleeping Imp on the first-run sheet. */
    val heroImp = 120.dp
    /** The round button that starts a game. */
    val gameButton = 48.dp
    /** The icon place on a game rules card. */
    val coachBadge = 34.dp
    /** The icon column of a game message. */
    val gameIcon = 26.dp
    /** The ring beside the score. */
    val gameRing = 16.dp
    /** The touch pad of the Echo game. */
    val echoPad = 128.dp
    /** The widest a game's results or rules card runs. */
    val gameCard = 320.dp
    /** The narrowest column of a results stat, before the stats stack. */
    val gameStat = 84.dp
    /** The bar that counts a special phase down. */
    val meter = 110.dp
    /** The widest a door label runs. */
    val doorLabel = 150.dp
    /** The widest a speech bubble header runs. */
    val bubbleHeader = 220.dp
    /** The tallest a picture in a speech bubble gets. */
    val thumbHeight = 110.dp
    /** The place held for a picture still loading. */
    val thumbWaitWidth = 80.dp
    /** The place held for a picture still loading, its height. */
    val thumbWaitHeight = 60.dp
    /** The strip along the bottom edge where a hiding Imp peeks. */
    val hiddenStrip = 28.dp
    /** The camera's round shutter button. */
    val shutter = 78.dp
    /** How far the full-screen camera's top buttons and photo sit below the screen's edge, clear of the status bar and the camera cutout. */
    val cameraTop = 48.dp
    /** How far the full-screen camera's shutter and photo buttons sit above the screen's edge, clear of the home indicator. */
    val cameraBottom = 32.dp
    /** The side of a photo or video waiting to be sent under the message box, and the height of a sound or file. */
    val attachmentChip = 64.dp
    /** The widest a file's name gets in a chip under the message box. */
    val attachmentName = 120.dp
}

/** Icon sizes (dp at the default font scale). */
object ImpIcon {
    val tiny = 8.dp
    val small = 10.dp
    val medium = 12.dp
    val large = 14.dp
    val big = 18.dp
    val huge = 30.dp
}

/** One text style: size in sp (the phone size follows the system font scale), weight and design. */
class ImpTextStyle(val size: androidx.compose.ui.unit.TextUnit, val weight: FontWeight, val design: String)

object ImpType {
    val title = ImpTextStyle(20.sp, FontWeight(700), "rounded")
    val cardTitle = ImpTextStyle(17.sp, FontWeight(600), "rounded")
    val body = ImpTextStyle(17.sp, FontWeight(400), "rounded")
    val label = ImpTextStyle(15.sp, FontWeight(600), "rounded")
    val caption = ImpTextStyle(13.sp, FontWeight(500), "rounded")
    val small = ImpTextStyle(12.sp, FontWeight(400), "rounded")
    val display = ImpTextStyle(52.sp, FontWeight(700), "rounded")
    val mono = ImpTextStyle(16.sp, FontWeight(400), "mono")
}

/** One animation. With Reduce Motion it takes `reducedDurationMillis` (0 means it just happens). */
class ImpMotion(val durationMillis: Int, val easing: CubicBezierEasing, val reducedDurationMillis: Int) {
    fun <T> spec(reduceMotion: Boolean): TweenSpec<T> =
        tween(if (reduceMotion) reducedDurationMillis else durationMillis, easing = easing)
}

object ImpMotions {
    val quick = ImpMotion(120, CubicBezierEasing(0f, 0f, 0.58f, 1f), 0)
    val hover = ImpMotion(150, CubicBezierEasing(0f, 0f, 0.58f, 1f), 0)
    val press = ImpMotion(150, CubicBezierEasing(0.2f, 0.9f, 0.3f, 1f), 0)
    val expand = ImpMotion(200, CubicBezierEasing(0.2f, 0.9f, 0.3f, 1f), 0)
    val smooth = ImpMotion(250, CubicBezierEasing(0.2f, 0.9f, 0.3f, 1f), 0)
    val scene = ImpMotion(350, CubicBezierEasing(0.42f, 0f, 0.58f, 1f), 150)
    val settle = ImpMotion(350, CubicBezierEasing(0.2f, 0.8f, 0.2f, 1f), 150)
    val spring = ImpMotion(400, CubicBezierEasing(0.2f, 0.8f, 0.2f, 1f), 150)
    val pop = ImpMotion(400, CubicBezierEasing(0.34f, 1.56f, 0.64f, 1f), 150)
    val fade = ImpMotion(400, CubicBezierEasing(0f, 0f, 0.58f, 1f), 0)
    val peek = ImpMotion(500, CubicBezierEasing(0.42f, 0f, 0.58f, 1f), 150)
}

object ImpBehavior {
    val toastSeconds = 2.8f
    val noticeSeconds = 5
    val undoBarSeconds = 6
    val peekIntervalMinSeconds = 45
    val peekIntervalMaxSeconds = 90
    val peekShowSeconds = 1.5f
    val peekQuietSeconds = 10
    val narrowWindowPoints = 520
    val dragStripPoints = 28
    val localProbeTimeoutSeconds = 2
    val modelListTimeoutSeconds = 8
    val deskDoorDelaySeconds = 0.5f
    val brainCheckTimeoutSeconds = 20
    val edgeHintDelaySeconds = 0.5f
    val edgeHintMaxSpeedPoints = 900
    val edgeTickDistancePoints = 40
    val copiedTickSeconds = 1.4f
    val tiltSlide = 34
    val tiltLean = 16
    val framesPerSecond = 60
    val framesPerSecondSaving = 30
    val calmFramesPerSecond = 30
    val calmFramesPerSecondSaving = 20
    val sensorHz = 30
    val sensorHzSaving = 20
    val settleSeconds = 1.2f
    val summonStiffness = 40
    val summonDamping = 11
    val summonHeight = 0.6f
    val sheetHalfCover = 0.5f
}
