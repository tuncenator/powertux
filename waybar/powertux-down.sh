#!/bin/sh
# Cycle powertux level down (towards silent). Stops at L1. Pins mode.
lvl=$(/usr/local/bin/powertux-current-level 2>/dev/null || echo 0)
case "$lvl" in
    0|4) new=3 ;;
    3)   new=2 ;;
    2)   new=1 ;;
    1)   new=1 ;;  # already at min; still re-pin to persist level in state
    *)   new=2 ;;
esac
sudo /usr/local/sbin/powertux-set "$new"
mkdir -p "$HOME/.config/powertux"
printf '{"mode":"pinned","level":%s}\n' "$new" > "$HOME/.config/powertux/state.json"
pkill -SIGRTMIN+1 waybar 2>/dev/null || true
