#!/bin/sh
# Cycle powertux level up (towards performance). Stops at L4. Pins mode.
lvl=$(/usr/local/bin/powertux-current-level 2>/dev/null || echo 0)
case "$lvl" in
    0|1) new=2 ;;
    2)   new=3 ;;
    3)   new=4 ;;
    4)   new=4 ;;  # already at max; still re-pin to persist level in state
    *)   new=2 ;;
esac
sudo /usr/local/sbin/powertux-set "$new"
mkdir -p "$HOME/.config/powertux"
printf '{"mode":"pinned","level":%s}\n' "$new" > "$HOME/.config/powertux/state.json"
pkill -SIGRTMIN+1 waybar 2>/dev/null || true
