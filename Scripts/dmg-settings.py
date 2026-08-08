# dmgbuild settings for Cheerio's download disk image.
#
# This is the whole layout: two icons over a generated background, an arrow
# between them, and nothing else in the window. dmgbuild writes the .DS_Store
# that carries the icon positions and the background reference using the
# ds_store and mac_alias modules — no AppleScript, no Finder, no GUI session.
# See Scripts/make-dmg.sh for why that matters and how this file is invoked.
#
# Not run directly: `dmgbuild -s Scripts/dmg-settings.py` execs it with a
# `defines` dict holding the two paths make-dmg.sh passes with -D.
#
# The geometry here has to agree with Scripts/render-dmg-background.swift,
# which draws the wells and the arrow at these same coordinates. make-dmg.sh
# runs both, so they change together; if you move an icon, move the well.

import os.path

app = defines["app"]  # noqa: F821 — dmgbuild injects `defines`
background_image = defines["background"]  # noqa: F821

app_name = os.path.basename(app)

# ---- Disk image ---------------------------------------------------------
# UDZO: zlib-compressed, read-only. The format every Mac has mounted since
# forever, and the one `hdiutil convert` produces smallest for a bundle.
format = "UDZO"
compression_level = 9
# size is deliberately unset: dmgbuild measures the payload and adds slack.

# ---- Contents ----------------------------------------------------------
files = [app]
symlinks = {"Applications": "/Applications"}
# The extension is noise in a window whose only job is "drag this there".
hide_extensions = [app_name]

# ---- Window ------------------------------------------------------------
# (w, h) must match the background PNG's 1x pixel size, or Finder scales the
# image and the arrow stops lining up with the icons.
window_rect = ((200, 180), (640, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
background = background_image

# ---- Icon view ---------------------------------------------------------
icon_size = 128
text_size = 12
label_pos = "bottom"
include_icon_view_settings = True
include_list_view_settings = False

# Finder coordinates: origin top-left, y downward, and these are icon
# *centres*. Kept in sync with render-dmg-background.swift's well centres.
icon_locations = {
    app_name: (168, 172),
    "Applications": (472, 172),
}
