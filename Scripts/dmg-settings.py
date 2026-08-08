# dmgbuild settings for Cheerio's download disk image.
#
# This is the whole layout: two icons over a generated background, an arrow
# between them, and nothing else in the window. dmgbuild writes the .DS_Store
# that carries the icon positions and the background reference using the
# ds_store and mac_alias modules — no AppleScript, no Finder, no GUI session.
# See Scripts/make-dmg.sh for why that matters and how this file is invoked.
#
# Not run directly: `dmgbuild -s Scripts/dmg-settings.py` execs it with a
# `defines` dict holding the three paths make-dmg.sh passes with -D.
#
# The icon coordinates and window size below come from Scripts/dmg-geometry.json,
# the same file Scripts/render-dmg-background.swift reads to draw the wells and
# the arrow at those coordinates — one file, not two copies to keep matched.

import json
import os.path

app = defines["app"]  # noqa: F821 — dmgbuild injects `defines`
background_image = defines["background"]  # noqa: F821
geometry_path = defines["geometry"]  # noqa: F821

with open(geometry_path, encoding="utf-8") as _geometry_file:
    geometry = json.load(_geometry_file)

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
# image and the arrow stops lining up with the icons. Both numbers come from
# dmg-geometry.json. (x, y) is just the window's on-screen position and has no
# counterpart in the art, so it stays a plain literal here.
window_rect = ((200, 180), (geometry["width"], geometry["height"]))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
background = background_image

# ---- Icon view ---------------------------------------------------------
icon_size = geometry["icon_size"]
text_size = 12
label_pos = "bottom"
include_icon_view_settings = True
include_list_view_settings = False

# Finder coordinates: origin top-left, y downward, and these are icon
# *centres*. Read from dmg-geometry.json, the same file
# render-dmg-background.swift reads for its well centres.
icon_locations = {
    app_name: tuple(geometry["left_icon_center"]),
    "Applications": tuple(geometry["right_icon_center"]),
}
