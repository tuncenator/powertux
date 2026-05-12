#!/bin/sh
# waybar custom module: powertux unified indicator with per-segment colors.
# Reads current TCC level + auto/pinned mode. Renders "L2a [pwr-B+-b1]" with
# 'a' suffix in distinct color when mode=auto.
lvl=$(/usr/local/bin/powertux-current-level 2>/dev/null || echo 0)
mode=$(python3 -c "import json
try: print(json.load(open('$HOME/.config/powertux/state.json')).get('mode','auto'))
except: print('auto')" 2>/dev/null || echo auto)

C_L1="#97FFFF"
C_L2="#42c8ed"
C_L3="#f3f4f5"
C_L4="#ff66ff"
C_SIL="#97FFFF"
C_PWR="#42ED7B"
C_ENT="#ffa500"
C_OVR="#ff66ff"
C_NA="#888888"
C_BP="#ffa500"
C_PF="#ff66ff"
C_B0="#888888"
C_B1="#42ED7B"
C_BRK="#777777"
C_AUTO="#ffcc00"

mk() { printf "<span color='%s'>%s</span>" "$1" "$2"; }

[ "$mode" = "auto" ] && auto_sfx="$(mk $C_AUTO a)" || auto_sfx=""

case "$lvl" in
    1) cls=silent;   name=silent;      odm=none;        epp=na;                  b=0; pred=19
       seg="$(mk $C_L1 L1)${auto_sfx} $(mk $C_BRK '[')$(mk $C_SIL sil)$(mk $C_BRK '-')$(mk $C_NA na)$(mk $C_BRK '-')$(mk $C_B0 b0)$(mk $C_BRK ']')" ;;
    2) cls=quiet;    name=quiet;       odm=power_save;  epp=balance_performance; b=1; pred=25
       seg="$(mk $C_L2 L2)${auto_sfx} $(mk $C_BRK '[')$(mk $C_PWR pwr)$(mk $C_BRK '-')$(mk $C_BP 'B+')$(mk $C_BRK '-')$(mk $C_B1 b1)$(mk $C_BRK ']')" ;;
    3) cls=balanced; name=balanced;    odm=enthusiast;  epp=balance_performance; b=1; pred=41
       seg="$(mk $C_L3 L3)${auto_sfx} $(mk $C_BRK '[')$(mk $C_ENT ent)$(mk $C_BRK '-')$(mk $C_BP 'B+')$(mk $C_BRK '-')$(mk $C_B1 b1)$(mk $C_BRK ']')" ;;
    4) cls=perf;     name=performance; odm=overboost;   epp=performance;         b=1; pred=64
       seg="$(mk $C_L4 L4)${auto_sfx} $(mk $C_BRK '[')$(mk $C_OVR ovr)$(mk $C_BRK '-')$(mk $C_PF Pf)$(mk $C_BRK '-')$(mk $C_B1 b1)$(mk $C_BRK ']')" ;;
    *)
        pp=$(cat /sys/firmware/acpi/platform_profile 2>/dev/null || echo "?")
        epp=$(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null || echo "?")
        boost=$(cat /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || echo "?")
        printf '{"text":"<span color=\\"%s\\">?? [tcc-default]</span>","class":"unknown","tooltip":"No powertux level active.\\npp=%s EPP=%s boost=%s\\nLeft-click: + perf  |  Right: - perf  |  Middle: auto/pinned"}\n' \
            "$C_BRK" "$pp" "$epp" "$boost"
        exit 0
        ;;
esac

printf '{"text":"%s","class":"%s","tooltip":"powertux %s [mode=%s]\\nODM=%s EPP=%s boost=%s\\n~%sW under sustained load\\nLeft: + perf  |  Right: - perf  |  Middle: auto/pinned"}\n' \
    "$seg" "$cls" "$name" "$mode" "$odm" "$epp" "$b" "$pred"
