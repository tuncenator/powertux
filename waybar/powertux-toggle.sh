#!/bin/sh
# Middle-click: toggle powertux mode between auto and pinned.
# Thin wrapper around the powertux-mode CLI so logic stays in one place.
exec /usr/local/bin/powertux-mode toggle
