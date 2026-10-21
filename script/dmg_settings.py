"""Finder layout for Calshot's drag-to-Applications disk image."""
from pathlib import Path

application = Path(defines["application"]).resolve()  # supplied by dmgbuild -D
format = "UDZO"
filesystem = "HFS+"
files = [(str(application), "Calshot.app")]
symlinks = {"Applications": "/Applications"}
background = "builtin-arrow"
window_rect = ((200, 200), (640, 280))
default_view = "icon-view"
icon_locations = {"Calshot.app": (140, 120), "Applications": (500, 120)}
icon_size = 96
text_size = 13
label_pos = "bottom"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
include_icon_view_settings = True
arrange_by = None
# Reuse the compiled app icon for the mounted volume, without modifying the app.
app_icon = application / "Contents" / "Resources" / "AppIcon.icns"
if app_icon.is_file():
    icon = str(app_icon)
