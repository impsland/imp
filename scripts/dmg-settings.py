# dmgbuild settings for the installer disk image: Imp.app next to an Applications link, on a
# background rendered by the app (Imp --render-dmg-background). Used by `make dist`:
#   dmgbuild -s scripts/dmg-settings.py -D app=build/Imp.app -D background=<dir>/background.png Imp build/Imp.dmg
# Window size, icon size and icon centres match IconRenderer.DMGBackground.
# The mounted volume wears the app's icon. The .dmg file itself keeps the system's disk-image icon:
# a custom file icon lives in a resource fork, which downloads strip.
import os

app = defines["app"]  # noqa: F821 (dmgbuild provides `defines`)
background = defines["background"]  # noqa: F821

format = "UDZO"
filesystem = "APFS"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(app, "Contents", "Resources", "AppIcon.icns")

default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
window_rect = ((200, 160), (660, 400))
icon_size = 128
text_size = 13
label_pos = "bottom"
icon_locations = {
    os.path.basename(app): (170, 176),
    "Applications": (490, 176),
}
