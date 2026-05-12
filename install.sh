#!/usr/bin/env bash
# powertux installer: deploys system commands, sudoers, TCC profiles,
# waybar scripts, and the autod user service.
#
# Usage:
#   ./install.sh              install everything (default)
#   ./install.sh --install    same
#   ./install.sh --uninstall  remove everything (preserves TCC backup + state.json)
#   ./install.sh --status     show what's installed
#
# Idempotent. Run from the repo root or anywhere; paths resolved relative to this file.

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ACTION="${1:---install}"

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
note()  { printf '  %s\n' "$*"; }
fail()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
ok()    { printf '  [ok]   %s\n' "$*"; }
miss()  { printf '  [miss] %s\n' "$*"; }

usage() {
    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

check_prereqs() {
    command -v python3 >/dev/null || fail "python3 not found"
    command -v busctl  >/dev/null || fail "busctl not found (systemd >=200 required)"
    command -v sudo    >/dev/null || fail "sudo not found"
    systemctl is-active --quiet tccd 2>/dev/null || fail "tccd service is not active; install tuxedo-control-center first"
    [ -f /etc/tcc/profiles ] || fail "/etc/tcc/profiles missing; is tccd installed?"
}

prime_sudo() {
    if ! sudo -n true 2>/dev/null; then
        bold "sudo cache cold; you may be prompted once"
    fi
    sudo true || fail "sudo failed"
}

wait_for_tccd() {
    # tccd accepts the systemctl restart synchronously but is not ready to
    # answer dbus calls until ~3-5s later. autod's first apply must wait or
    # the temp profile gets silently dropped (the active profile then stays
    # on whatever stateMap picked, which is TUXEDO Defaults on AC).
    local i
    for i in $(seq 1 20); do
        if busctl call com.tuxedocomputers.tccd /com/tuxedocomputers/tccd \
            com.tuxedocomputers.tccd GetActiveProfileJSON >/dev/null 2>&1; then
            note "tccd ready after ${i}*0.5s"
            return 0
        fi
        sleep 0.5
    done
    note "tccd did not become ready within 10s; continuing anyway"
}

do_install() {
    check_prereqs
    prime_sudo

    bold "[1/8] installing system commands"
    # The two /usr/local/sbin scripts are referenced by the sudoers
    # NOPASSWD drop-in. They MUST be real files (root-owned, 0755)
    # because a symlink would let anyone with write access to the
    # source bin/ replace the binary and gain unrestricted root via
    # `sudo powertux-set N`. Re-run install.sh when those two change.
    sudo install -m 0755 -o root -g root "$SCRIPT_DIR/bin/powertux-set"              /usr/local/sbin/
    sudo install -m 0755 -o root -g root "$SCRIPT_DIR/bin/powertux-install-profiles" /usr/local/sbin/
    # Everything else is symlinked: edits to bin/ take effect on the
    # next invocation (daemon needs a `systemctl --user restart
    # powertux-autod` to pick up code changes).
    sudo ln -sfn "$SCRIPT_DIR/bin/powertux-current-level" /usr/local/bin/powertux-current-level
    sudo ln -sfn "$SCRIPT_DIR/bin/powertux-autod"         /usr/local/bin/powertux-autod
    sudo ln -sfn "$SCRIPT_DIR/bin/powertux-mode"          /usr/local/bin/powertux-mode
    sudo ln -sfn "$SCRIPT_DIR/bin/powertux-analyze"       /usr/local/bin/powertux-analyze
    sudo ln -sfn "$SCRIPT_DIR/bin/powertux-eta-bench"     /usr/local/bin/powertux-eta-bench

    bold "[2/8] installing RAPL tmpfiles rule"
    sudo install -m 0644 -o root -g root "$SCRIPT_DIR/systemd/powertux.tmpfiles.conf" /etc/tmpfiles.d/powertux.conf
    sudo systemd-tmpfiles --create /etc/tmpfiles.d/powertux.conf || true
    note "energy_uj perms: $(stat -c '%a' /sys/class/powercap/intel-rapl:0/energy_uj 2>/dev/null || echo missing)"

    bold "[3/8] installing sudoers drop-in"
    # Template __POWERTUX_USER__ -> invoking user so the NOPASSWD rule grants
    # passwordless powertux-set to the right account. SUDO_USER is set by sudo
    # when install.sh is run via sudo wrappers; fall back to $USER otherwise.
    local target_user="${SUDO_USER:-$USER}"
    [ -n "$target_user" ] || fail "could not determine target user (set \$SUDO_USER or \$USER)"
    id -u "$target_user" >/dev/null 2>&1 || fail "user '$target_user' does not exist"
    local tmp_sudoers
    tmp_sudoers=$(mktemp)
    trap 'rm -f "$tmp_sudoers"' RETURN
    sed "s/__POWERTUX_USER__/$target_user/g" "$SCRIPT_DIR/sudoers/powertux" > "$tmp_sudoers"
    sudo install -m 0440 -o root -g root "$tmp_sudoers" /etc/sudoers.d/powertux
    if ! sudo visudo -c >/dev/null 2>&1; then
        sudo rm -f /etc/sudoers.d/powertux
        fail "sudoers validation failed; drop-in reverted"
    fi
    note "sudoers OK (user=$target_user)"

    bold "[4/8] granting fan-telemetry access (/dev/tuxedo_io)"
    # autod reads fan PWM duty and fan-sensor temps via ioctls on
    # /dev/tuxedo_io (default 0600 root). Create a dedicated `tuxedo-io`
    # group, add the user, install a udev rule that sets the device to
    # 0660 root:tuxedo-io, and apply the perms to the live node so the
    # daemon does not need to wait for next boot. Membership grants the
    # same write-ioctl capability as the kernel exposes; treat it as
    # equivalent trust to the existing powertux-set NOPASSWD rule.
    if ! getent group tuxedo-io >/dev/null 2>&1; then
        sudo groupadd -r tuxedo-io
        note "created group tuxedo-io"
    fi
    # systemd/powertux-autod.service wraps ExecStart with `sg tuxedo-io`,
    # which picks up the group from /etc/group at exec time. No relog is
    # needed: gpasswd -> daemon-reload -> restart is sufficient.
    if ! id -nG "$target_user" | tr ' ' '\n' | grep -qx tuxedo-io; then
        sudo gpasswd -a "$target_user" tuxedo-io >/dev/null
        note "added $target_user to tuxedo-io (no relog needed; sg wrap in unit)"
    fi
    sudo install -m 0644 -o root -g root "$SCRIPT_DIR/systemd/powertux-tuxedo-io.rules" \
        /etc/udev/rules.d/99-powertux-tuxedo-io.rules
    sudo udevadm control --reload-rules
    if [ -e /dev/tuxedo_io ]; then
        # Trigger pulls the new udev attrs onto the existing node so the
        # daemon can open it on the next restart without a reboot. We also
        # belt-and-suspenders chgrp/chmod in case the udev trigger races.
        sudo udevadm trigger --action=change /dev/tuxedo_io || true
        sudo chgrp tuxedo-io /dev/tuxedo_io
        sudo chmod 0660 /dev/tuxedo_io
        note "/dev/tuxedo_io perms: $(stat -c '%U:%G %a' /dev/tuxedo_io)"
    else
        note "/dev/tuxedo_io not present (non-TUXEDO chassis or tuxedo_io module not loaded); skipping"
    fi

    bold "[5/8] installing TCC profiles"
    sudo /usr/local/sbin/powertux-install-profiles
    wait_for_tccd

    bold "[6/8] installing waybar scripts"
    mkdir -p "$HOME/.config/waybar/scripts"
    # User-scope, so symlinks. Waybar re-execs the click handlers each
    # press, so edits in waybar/ take effect on next click.
    ln -sfn "$SCRIPT_DIR/waybar/powertux.sh"        "$HOME/.config/waybar/scripts/powertux.sh"
    ln -sfn "$SCRIPT_DIR/waybar/powertux-up.sh"     "$HOME/.config/waybar/scripts/powertux-up.sh"
    ln -sfn "$SCRIPT_DIR/waybar/powertux-down.sh"   "$HOME/.config/waybar/scripts/powertux-down.sh"
    ln -sfn "$SCRIPT_DIR/waybar/powertux-toggle.sh" "$HOME/.config/waybar/scripts/powertux-toggle.sh"

    bold "[7/8] initializing state file"
    mkdir -p "$HOME/.config/powertux"
    if [ ! -f "$HOME/.config/powertux/state.json" ]; then
        printf '{"mode":"auto"}\n' > "$HOME/.config/powertux/state.json"
        note "state.json -> {\"mode\":\"auto\"}"
    else
        note "state.json exists; left untouched"
    fi

    bold "[8/8] enabling autod user service"
    mkdir -p "$HOME/.config/systemd/user"
    # Symlinked. systemd reads symlinked units fine; edits to
    # systemd/powertux-autod.service take effect on next daemon-reload.
    ln -sfn "$SCRIPT_DIR/systemd/powertux-autod.service" \
        "$HOME/.config/systemd/user/powertux-autod.service"
    systemctl --user daemon-reload
    systemctl --user enable powertux-autod.service
    # restart picks up the new binary if the daemon was already running;
    # starts it from cold otherwise.
    systemctl --user restart powertux-autod.service
    note "autod active: $(systemctl --user is-active powertux-autod.service)"

    echo
    bold "install complete"
    echo
    echo "Live-edit setup:"
    echo "  CLI scripts (powertux-analyze, -eta-bench, -mode, -current-level)"
    echo "  and the waybar scripts are SYMLINKED to bin/ and waybar/, so edits"
    echo "  there take effect immediately. The autod daemon also runs from a"
    echo "  symlink; after editing bin/powertux-autod, restart it:"
    echo "    systemctl --user restart powertux-autod.service"
    echo
    echo "  Re-running ./install.sh is only needed when:"
    echo "  - powertux-set or powertux-install-profiles changes (root-owned copy)"
    echo "  - sudoers / tmpfiles / tcc profiles / unit file structure changes"
    echo "  - first install on a fresh machine"
    echo
    echo "Waybar config edits are NOT auto-applied. If this is a fresh setup, add:"
    echo "  - \"custom/powertux\" to your modules-right list in config.jsonc"
    echo "  - module config block (see README.md for the snippet)"
    echo "  - #custom-powertux style in style.css"
    echo "Then SIGUSR2 waybar to reload."
    echo
    echo "Watch the daemon:"
    echo "  journalctl --user -u powertux-autod -f"
}

do_uninstall() {
    prime_sudo

    bold "[1/8] stopping + disabling autod"
    systemctl --user disable --now powertux-autod.service 2>/dev/null || true
    rm -f "$HOME/.config/systemd/user/powertux-autod.service"
    systemctl --user daemon-reload

    bold "[2/8] removing RAPL tmpfiles rule (does not revert energy_uj perms until reboot)"
    sudo rm -f /etc/tmpfiles.d/powertux.conf

    bold "[3/8] removing TCC profiles (preserving /etc/tcc/profiles.bak-pre-powertux)"
    if [ -x /usr/local/sbin/powertux-install-profiles ]; then
        sudo /usr/local/sbin/powertux-install-profiles --remove
    else
        note "powertux-install-profiles missing; skipping TCC profile cleanup"
        note "manual: edit /etc/tcc/profiles and remove powertux-* entries, then restart tccd"
    fi

    bold "[4/8] removing sudoers drop-in"
    sudo rm -f /etc/sudoers.d/powertux

    bold "[4b/8] removing /dev/tuxedo_io udev rule (keeping tuxedo-io group)"
    # We don't drop the group or remove the user from it: the group may
    # be in use by other tools, and removing membership requires a relog
    # to take effect anyway. Removing the rule + reverting the live
    # device perms is enough to revoke autod's read path.
    sudo rm -f /etc/udev/rules.d/99-powertux-tuxedo-io.rules
    sudo udevadm control --reload-rules
    if [ -e /dev/tuxedo_io ]; then
        sudo chgrp root /dev/tuxedo_io 2>/dev/null || true
        sudo chmod 0600 /dev/tuxedo_io 2>/dev/null || true
        note "/dev/tuxedo_io reverted to root:root 0600"
    fi

    bold "[5/8] removing system commands"
    sudo rm -f /usr/local/sbin/powertux-set
    sudo rm -f /usr/local/sbin/powertux-install-profiles
    sudo rm -f /usr/local/bin/powertux-current-level
    sudo rm -f /usr/local/bin/powertux-autod
    sudo rm -f /usr/local/bin/powertux-mode
    sudo rm -f /usr/local/bin/powertux-analyze
    sudo rm -f /usr/local/bin/powertux-eta-bench

    bold "[6/8] removing waybar scripts"
    rm -f "$HOME/.config/waybar/scripts/powertux.sh"
    rm -f "$HOME/.config/waybar/scripts/powertux-up.sh"
    rm -f "$HOME/.config/waybar/scripts/powertux-down.sh"
    rm -f "$HOME/.config/waybar/scripts/powertux-toggle.sh"

    bold "[7/8] keeping user state"
    note "kept: ~/.config/powertux/state.json"
    note "kept: /etc/tcc/profiles.bak-pre-powertux (original TCC profiles backup)"

    echo
    bold "uninstall complete"
    echo
    echo "Waybar config.jsonc + style.css still reference custom/powertux."
    echo "Remove those entries manually or waybar will log 'module not found'."
}

do_status() {
    bold "files:"
    for f in \
        /usr/local/sbin/powertux-set \
        /usr/local/sbin/powertux-install-profiles \
        /usr/local/bin/powertux-current-level \
        /usr/local/bin/powertux-autod \
        /usr/local/bin/powertux-mode \
        /usr/local/bin/powertux-analyze \
        /usr/local/bin/powertux-eta-bench \
        "$HOME/.config/systemd/user/powertux-autod.service" \
        "$HOME/.config/waybar/scripts/powertux.sh" \
        "$HOME/.config/waybar/scripts/powertux-up.sh" \
        "$HOME/.config/waybar/scripts/powertux-down.sh" \
        "$HOME/.config/waybar/scripts/powertux-toggle.sh" \
        "$HOME/.config/powertux/state.json"
    do
        if [ -L "$f" ]; then
            tgt=$(readlink "$f")
            # confirm the symlink target resolves to something live
            if [ -e "$f" ]; then
                ok "$f -> $tgt"
            else
                miss "$f -> $tgt (DANGLING)"
            fi
        elif [ -e "$f" ]; then
            ok "$f (copy)"
        else
            miss "$f"
        fi
    done

    bold "sudoers:"
    # /etc/sudoers.d is usually 0750 so we can't stat by path; probe via sudo -n -l instead.
    if sudo -n -l /usr/local/sbin/powertux-set 1 >/dev/null 2>&1; then
        ok "NOPASSWD: /usr/local/sbin/powertux-set"
    else
        miss "NOPASSWD: /usr/local/sbin/powertux-set (clicks will prompt for password)"
    fi

    bold "tuxedo_io access:"
    if [ ! -e /dev/tuxedo_io ]; then
        miss "/dev/tuxedo_io not present (non-TUXEDO chassis or module not loaded)"
    else
        local tio_mode tio_group
        tio_mode=$(stat -c '%a' /dev/tuxedo_io 2>/dev/null)
        tio_group=$(stat -c '%G' /dev/tuxedo_io 2>/dev/null)
        if [ -f /etc/udev/rules.d/99-powertux-tuxedo-io.rules ]; then ok "/etc/udev/rules.d/99-powertux-tuxedo-io.rules"; else miss "/etc/udev/rules.d/99-powertux-tuxedo-io.rules"; fi
        if [ "$tio_group" = "tuxedo-io" ] && [ "$tio_mode" = "660" ]; then
            ok "/dev/tuxedo_io perms: $tio_group $tio_mode"
        else
            miss "/dev/tuxedo_io perms: $tio_group $tio_mode (expected tuxedo-io 660)"
        fi
        if id -nG "$USER" | tr ' ' '\n' | grep -qx tuxedo-io; then
            ok "user '$USER' is in tuxedo-io group"
        else
            miss "user '$USER' is NOT in tuxedo-io group (relog after install)"
        fi
    fi

    bold "RAPL access:"
    local rapl_mode
    rapl_mode=$(stat -c '%a' /sys/class/powercap/intel-rapl:0/energy_uj 2>/dev/null || echo "")
    if [ -f /etc/tmpfiles.d/powertux.conf ]; then ok "/etc/tmpfiles.d/powertux.conf"; else miss "/etc/tmpfiles.d/powertux.conf"; fi
    if [ "$rapl_mode" = "444" ]; then ok "energy_uj readable (mode 444)"; else miss "energy_uj mode=${rapl_mode:-missing} (autod will skip w_pkg)"; fi

    bold "TCC profiles:"
    if [ -r /etc/tcc/profiles ]; then
        local ids
        ids=$(grep -o '"powertux-[a-z]*"' /etc/tcc/profiles 2>/dev/null | sort -u | tr '\n' ' ')
        if [ -n "$ids" ]; then ok "$ids"; else miss "no powertux- profiles found"; fi
    else
        miss "/etc/tcc/profiles not readable"
    fi

    bold "daemon:"
    note "active:  $(systemctl --user is-active powertux-autod.service 2>&1 || true)"
    note "enabled: $(systemctl --user is-enabled powertux-autod.service 2>&1 || true)"

    bold "current state:"
    if command -v /usr/local/bin/powertux-current-level >/dev/null; then
        note "level: L$(/usr/local/bin/powertux-current-level)"
    fi
    if [ -f "$HOME/.config/powertux/state.json" ]; then
        note "state: $(python3 -c "
import json
d=json.load(open('$HOME/.config/powertux/state.json'))
m=d.get('mode','?')
l=d.get('level')
print(f'mode={m}'+(f' level={l}' if m=='pinned' and l else ''))
" 2>/dev/null || echo "?")"
    fi
}

case "$ACTION" in
    -h|--help)      usage ;;
    --install|install)     do_install ;;
    --uninstall|uninstall) do_uninstall ;;
    --status|status)       do_status ;;
    *)
        echo "unknown action: $ACTION" >&2
        echo "try --help" >&2
        exit 2
        ;;
esac
