// generated from design/tokens.json, do not edit. Run: node design/generate.mjs
namespace Imp.Design;

/// <summary>Spacing in device independent pixels.</summary>
public static class ImpSpace
{
    /// <summary>Between a line and its own detail.</summary>
    public const double Hairline = 2;
    /// <summary>Inside a control: an icon and its word.</summary>
    public const double Tight = 4;
    /// <summary>Between small things in a row.</summary>
    public const double Snug = 6;
    /// <summary>Between controls in a row.</summary>
    public const double Small = 8;
    /// <summary>Inside a small tile or a chip.</summary>
    public const double Cozy = 10;
    /// <summary>The gap between cards.</summary>
    public const double Medium = 12;
    /// <summary>Inside a card.</summary>
    public const double Roomy = 14;
    /// <summary>Between groups.</summary>
    public const double Large = 16;
    /// <summary>The padding around a page.</summary>
    public const double Page = 20;
    /// <summary>Around a sheet or a big empty state.</summary>
    public const double Wide = 24;
    /// <summary>Between actions that must stay apart.</summary>
    public const double Huge = 28;
    /// <summary>Around a hero picture.</summary>
    public const double Vast = 40;
}

/// <summary>Corner radii.</summary>
public static class ImpRadii
{
    /// <summary>Thumbnails and small marks inside a row.</summary>
    public const double Tiny = 6;
    /// <summary>Fields, small tiles and chips that are not capsules.</summary>
    public const double Small = 10;
    /// <summary>Icon tiles and small cards inside a card.</summary>
    public const double Tile = 12;
    /// <summary>Cards on the desktop, selectable cards and wells.</summary>
    public const double Medium = 16;
    /// <summary>Cards on the phone and big panels.</summary>
    public const double Large = 20;
    /// <summary>Speech bubbles.</summary>
    public const double Bubble = 24;
    /// <summary>Pills and round buttons.</summary>
    public const double Full = 999;
}

/// <summary>Sizes of things you point at, for Windows.</summary>
public static class ImpSizes
{
    /// <summary>How far a short receipt bar sits above the bottom edge, clear of the hidden Imps' floor and the home indicator.</summary>
    public const double ReceiptLift = 84;
    /// <summary>The smallest a control's hit area gets.</summary>
    public const double Hit = 32;
    /// <summary>The height of a text field or a menu button.</summary>
    public const double Control = 32;
    /// <summary>The visible circle of an icon button.</summary>
    public const double Glyph = 28;
    /// <summary>The tile behind a card's or a row's icon.</summary>
    public const double IconTile = 28;
    /// <summary>The width of the menu bar panel.</summary>
    public const double MenuWidth = 300;
    /// <summary>Where a notice in a sheet hangs from the top: below the header, clear of the sheet's grabber.</summary>
    public const double ToastTop = 48;
    /// <summary>The icon tile in a sheet's header.</summary>
    public const double SheetIcon = 32;
    /// <summary>The widest a help tip's text runs.</summary>
    public const double TipWidth = 280;
    /// <summary>The width of a popover that holds a list or a small form.</summary>
    public const double PopoverWidth = 360;
    /// <summary>The fixed width of a browser toolbar popup. Wide enough for a pebble and a button, narrow enough to stay a popup.</summary>
    public const double PopupWidth = 380;
    /// <summary>The tallest a scrolling list grows inside a small popup before it scrolls.</summary>
    public const double PopupListHeight = 300;
    /// <summary>A side panel beside the Imp on a wide screen.</summary>
    public const double PanelWidth = 400;
    /// <summary>The widest a settings column grows. Wider screens centre it.</summary>
    public const double Column = 760;
    /// <summary>The width of a sheet on a desktop.</summary>
    public const double SheetWidth = 560;
    /// <summary>A round tile: an animation's preview, the Imp on the phone's settings.</summary>
    public const double Marker = 44;
    /// <summary>The room of a model's reasoning while it streams in (about three lines): the same all along, so nothing shifts.</summary>
    public const double ThinkingHeight = 54;
    /// <summary>The Imp drawn in a row or a card.</summary>
    public const double ImpPortrait = 40;
    /// <summary>The label column of a form row, so a card's controls line up.</summary>
    public const double FieldLabel = 96;
    /// <summary>A round tick or a status mark.</summary>
    public const double Mark = 20;
    /// <summary>The widest a menu button's title runs before it ends in an ellipsis, so a long name never widens a form.</summary>
    public const double MenuTitle = 160;
    /// <summary>An Imp's face on the kit review's header.</summary>
    public const double HeroFace = 68;
    /// <summary>A status dot or a small marker beside a title.</summary>
    public const double Dot = 6;
    /// <summary>The animation editor's sheet: the stage, the beat's pose and the timeline side by side.</summary>
    public const double EditorWidth = 780;
    /// <summary>The animation editor's stage, where the Imp acts a beat out.</summary>
    public const double StageWidth = 268;
    /// <summary>The height of the animation editor's stage and pose row, above the timeline.</summary>
    public const double EditorTop = 256;
    /// <summary>The width of a switch's track.</summary>
    public const double SwitchTrack = 40;
    /// <summary>The side of the linking QR code.</summary>
    public const double CodeSide = 188;
    /// <summary>The height of the camera view that scans a code.</summary>
    public const double ViewfinderHeight = 220;
    /// <summary>The side of the frame to aim a code at.</summary>
    public const double ViewfinderAim = 150;
    /// <summary>The sleeping Imp on the first-run sheet.</summary>
    public const double HeroImp = 120;
    /// <summary>The round button that starts a game.</summary>
    public const double GameButton = 48;
    /// <summary>The icon place on a game rules card.</summary>
    public const double CoachBadge = 34;
    /// <summary>The icon column of a game message.</summary>
    public const double GameIcon = 26;
    /// <summary>The ring beside the score.</summary>
    public const double GameRing = 16;
    /// <summary>The touch pad of the Echo game.</summary>
    public const double EchoPad = 128;
    /// <summary>The widest a game's results or rules card runs.</summary>
    public const double GameCard = 320;
    /// <summary>The narrowest column of a results stat, before the stats stack.</summary>
    public const double GameStat = 84;
    /// <summary>The bar that counts a special phase down.</summary>
    public const double Meter = 110;
    /// <summary>The widest a door label runs.</summary>
    public const double DoorLabel = 150;
    /// <summary>The widest a speech bubble header runs.</summary>
    public const double BubbleHeader = 220;
    /// <summary>The tallest a picture in a speech bubble gets.</summary>
    public const double ThumbHeight = 110;
    /// <summary>The place held for a picture still loading.</summary>
    public const double ThumbWaitWidth = 80;
    /// <summary>The place held for a picture still loading, its height.</summary>
    public const double ThumbWaitHeight = 60;
    /// <summary>The strip along the bottom edge where a hiding Imp peeks.</summary>
    public const double HiddenStrip = 28;
}

/// <summary>Icon sizes.</summary>
public static class ImpIcons
{
    /// <summary>A chevron inside a menu button.</summary>
    public const double Tiny = 8;
    /// <summary>A status dot or a mark beside small text.</summary>
    public const double Small = 10;
    /// <summary>An icon beside a label, in a chip or a tile.</summary>
    public const double Medium = 12;
    /// <summary>An icon button's glyph and a card's icon.</summary>
    public const double Large = 14;
    /// <summary>A marker or a sheet's icon.</summary>
    public const double Big = 18;
    /// <summary>An empty state's picture.</summary>
    public const double Huge = 30;
}

/// <summary>Opacities.</summary>
public static class ImpOpacities
{
    /// <summary>A control that cannot be used now.</summary>
    public const double Disabled = 0.45;
    /// <summary>Something left out or not chosen.</summary>
    public const double Dimmed = 0.6;
    /// <summary>A soft fill in the Imp's colour, behind an icon or a chosen row.</summary>
    public const double TintFill = 0.16;
    /// <summary>A stronger fill in the Imp's colour: a secondary button on the dark wall.</summary>
    public const double TintFillStrong = 0.34;
    /// <summary>The glow under a chosen Imp.</summary>
    public const double Glow = 0.45;
    /// <summary>A solid fill under the pointer.</summary>
    public const double HoverFill = 0.85;
    /// <summary>The least opaque a translucent speech bubble may be. Below this the text cannot be kept legible over any background.</summary>
    public const double BubbleMin = 0.4;
    /// <summary>How opaque a translucent speech bubble starts.</summary>
    public const double BubbleDefault = 0.75;
}

/// <summary>Font sizes of the type scale (the weight and the rounded design are in ImpTokens.xaml).</summary>
public static class ImpType
{
    /// <summary>A sheet's or screen's title.</summary>
    public const double Title = 17;
    /// <summary>A card's title.</summary>
    public const double CardTitle = 14;
    /// <summary>Ordinary text.</summary>
    public const double Body = 13;
    /// <summary>The label of a button or a chip.</summary>
    public const double Label = 12.5;
    /// <summary>A form label and other quiet lines.</summary>
    public const double Caption = 12.5;
    /// <summary>Small print, statuses and badges.</summary>
    public const double Small = 11.5;
    /// <summary>The one big number of a screen, such as a game's score.</summary>
    public const double Display = 40;
    /// <summary>Code, paths and keys.</summary>
    public const double Mono = 12.5;
}

/// <summary>The named animations. A preset with no reduced duration just happens under Reduce Motion.</summary>
public static class ImpMotion
{
    /// <summary>With Reduce Motion, a preset that fades changes opacity over this long.</summary>
    public static readonly System.TimeSpan ReducedFade = System.TimeSpan.FromSeconds(0.15);

    /// <summary>Hover, focus, switches and small changes.</summary>
    public static readonly System.TimeSpan Quick = System.TimeSpan.FromMilliseconds(120);
    public static readonly System.TimeSpan QuickReduced = System.TimeSpan.FromMilliseconds(0);
    public static readonly (double X1, double Y1, double X2, double Y2) QuickCurve = (0, 0, 0.58, 1);
    /// <summary>A control under the pointer.</summary>
    public static readonly System.TimeSpan Hover = System.TimeSpan.FromMilliseconds(150);
    public static readonly System.TimeSpan HoverReduced = System.TimeSpan.FromMilliseconds(0);
    public static readonly (double X1, double Y1, double X2, double Y2) HoverCurve = (0, 0, 0.58, 1);
    /// <summary>A control being pressed.</summary>
    public static readonly System.TimeSpan Press = System.TimeSpan.FromMilliseconds(150);
    public static readonly System.TimeSpan PressReduced = System.TimeSpan.FromMilliseconds(0);
    public static readonly (double X1, double Y1, double X2, double Y2) PressCurve = (0.2, 0.9, 0.3, 1);
    /// <summary>A section opening or closing, a list changing.</summary>
    public static readonly System.TimeSpan Expand = System.TimeSpan.FromMilliseconds(200);
    public static readonly System.TimeSpan ExpandReduced = System.TimeSpan.FromMilliseconds(0);
    public static readonly (double X1, double Y1, double X2, double Y2) ExpandCurve = (0.2, 0.9, 0.3, 1);
    /// <summary>Selections, tabs and other changes you follow with your eyes.</summary>
    public static readonly System.TimeSpan Smooth = System.TimeSpan.FromMilliseconds(250);
    public static readonly System.TimeSpan SmoothReduced = System.TimeSpan.FromMilliseconds(0);
    public static readonly (double X1, double Y1, double X2, double Y2) SmoothCurve = (0.2, 0.9, 0.3, 1);
    /// <summary>One scene giving way to another.</summary>
    public static readonly System.TimeSpan Scene = System.TimeSpan.FromMilliseconds(350);
    public static readonly System.TimeSpan SceneReduced = System.TimeSpan.FromMilliseconds(150);
    public static readonly (double X1, double Y1, double X2, double Y2) SceneCurve = (0.42, 0, 0.58, 1);
    /// <summary>Bubbles and bars finding their place.</summary>
    public static readonly System.TimeSpan Settle = System.TimeSpan.FromMilliseconds(350);
    public static readonly System.TimeSpan SettleReduced = System.TimeSpan.FromMilliseconds(150);
    public static readonly (double X1, double Y1, double X2, double Y2) SettleCurve = (0.2, 0.8, 0.2, 1);
    /// <summary>Panels, banners and sheets arriving.</summary>
    public static readonly System.TimeSpan Spring = System.TimeSpan.FromMilliseconds(400);
    public static readonly System.TimeSpan SpringReduced = System.TimeSpan.FromMilliseconds(150);
    public static readonly (double X1, double Y1, double X2, double Y2) SpringCurve = (0.2, 0.8, 0.2, 1);
    /// <summary>A small reward: a little overshoot.</summary>
    public static readonly System.TimeSpan Pop = System.TimeSpan.FromMilliseconds(400);
    public static readonly System.TimeSpan PopReduced = System.TimeSpan.FromMilliseconds(150);
    public static readonly (double X1, double Y1, double X2, double Y2) PopCurve = (0.34, 1.56, 0.64, 1);
    /// <summary>Something coming or going with no movement.</summary>
    public static readonly System.TimeSpan Fade = System.TimeSpan.FromMilliseconds(400);
    public static readonly System.TimeSpan FadeReduced = System.TimeSpan.FromMilliseconds(0);
    public static readonly (double X1, double Y1, double X2, double Y2) FadeCurve = (0, 0, 0.58, 1);
    /// <summary>A hidden Imp sliding out from the floor and back.</summary>
    public static readonly System.TimeSpan Peek = System.TimeSpan.FromMilliseconds(500);
    public static readonly System.TimeSpan PeekReduced = System.TimeSpan.FromMilliseconds(150);
    public static readonly (double X1, double Y1, double X2, double Y2) PeekCurve = (0.42, 0, 0.58, 1);
}
