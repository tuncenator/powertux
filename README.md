# powertux

Adaptive power-level knob for TUXEDO InfinityBook Pro 14 Gen10 AMD (Ryzen AI 9
HX 370 "Strix Point", `XxKK4NAx_XxSP4NAx`). Collapses `platform_profile`, EPP,
TCC ODM profile, and `cpufreq/boost` into 4 empirically-calibrated tiers
(silent / quiet / balanced / perf). A user-scope daemon picks the tier from AC
state, battery capacity, and 1-min load average. Manual override via waybar
clicks or `powertux-mode` keybind.

Why: the vendor's 2-profile auto-switch sits in one ~45-47W band and leaves
both the silent end (boost-off, ~19W) and the boost end (overboost ODM, ~64W)
unused. This project measures the chassis, picks 4 tiers across the full
range, and switches between them based on what you're actually doing.

## What you get

- **4 measured tiers**: `silent` (~19W) / `quiet` (~25W) / `balanced` (~41W) /
  `perf` (~64W). Numbers come from per-chassis calibration, not vendor guesswork.
- **Adaptive daemon** (`powertux-autod`) that picks a tier from AC plug,
  battery %, and 1-min load. Hysteresis on downgrades to avoid chatter.
- **Waybar widget** with per-segment colored Pango markup. Click to pin /
  raise / lower the tier. Suffix `a` marks auto mode.
- **CLI** (`powertux-mode`) for keybind-driven toggles, no GUI needed.
- **JSONL telemetry** (one row per 5s tick) plus `powertux-analyze`, an
  in-terminal report with residency / power-vs-vendor / per-display attribution
  / battery sessions / threshold sensitivity / tuning recommendations.
- **ETA backtest harness** (`powertux-eta-bench`) that replays closed
  discharge segments against a panel of ETA algorithms (naive / median / ewma
  / blended / regression / tier-conditional) and ranks them by composite UX score.
- **Calibration scripts** preserved for reproducibility; re-sweep after a
  firmware update or to retarget for a different chassis.

## Hardware support

Calibrated on **TUXEDO InfinityBook Pro 14 Gen10 AMD** (Ryzen AI 9 HX 370,
BIOS `N.1.20A13`, kernel 6.18, amd-pstate-epp, amd_pmf, tccd 3.0.3+). The
control flow (platform_profile + EPP + boost + TCC ODM) is portable to other
TUXEDO AMD laptops, but the power numbers in the tier table are this
chassis's. If you run on a different machine, re-run `powertux-calibrate` and
`powertux-calibrate-odm`, then edit the tier mapping in `bin/powertux-set` and
the TCC profile specs in `bin/powertux-install-profiles`.

Prereqs (required for the core knob):
- TUXEDO Control Center (`tccd`) running.
- `amd-pstate-epp` active (`scaling_driver` shows it).
- `busctl`, `python3`, `sudo`.
- waybar (for the bar widget; optional - the CLI works without it).

### Kernel/driver dependency (only matters for full battery analysis)

The **tier selection knob is self-contained**: it writes `platform_profile`,
EPP, `cpufreq/boost`, and talks to `tccd` over D-Bus. Stock kernel + stock
`tuxedo-drivers-dkms` is enough to make the daemon, waybar widget, manual
override, and tier switching all work end-to-end.

What **does** depend on a custom-patched `tuxedo-drivers` build:

- `/sys/class/power_supply/BAT0/charge_control_end_threshold` (active charge
  cap; the upstream `tuxedo-drivers` does not expose this on this board).
- `/sys/class/power_supply/BAT0/raw_xif1`, `raw_xif2`, `raw_cycle_count`
  (truthful design / last-full / cycle-count straight from the EC).

These power the battery sections of `powertux-analyze` (wear, cap-vs-cells
drift, accurate cycle count, charge sessions, ETA backtest dynamics). On
**this board** (`XxKK4NAx_XxSP4NAx`) the stock kernel ABI is broken: BAT0
reports `cycle_count=0` and `charge_full=charge_full_design` permanently, so
without the EC-direct `raw_*` paths the analyze report's wear math is
meaningless. Every patched-driver read in `powertux-autod` is wrapped in
`try/except` and yields `None` on failure: no crash, just sparser telemetry.

The patch (`charge_control_end_threshold` + the `raw_*` accessors) lives in
a private companion project; the relevant EC offset is `0x07B9` and the
implementation follows the standard kernel power-supply ABI. If you want
the full analyze experience and you have a comparable Uniwill-ODM TUXEDO
chassis, port the patch yourself - the devlog documents the full reverse
engineering trail.

## Quick install

```sh
git clone https://github.com/tuncenator/powertux.git ~/Programs/powertux
cd ~/Programs/powertux
./install.sh             # install everything
./install.sh --status    # see what's deployed
./install.sh --uninstall # remove everything (TCC backup + state preserved)
```

Idempotent. Run from any directory. The installer uses `$SUDO_USER` (or
`$USER`) to write the sudoers NOPASSWD rule for the right account; no need to
edit `sudoers/powertux` by hand.

Cloning elsewhere is fine - install paths resolve relative to the script.
The autod daemon writes telemetry to `~/Programs/powertux/log/` regardless of
clone location (override with `--log-dir`); creating a symlink or cloning to
that path is the easiest setup.

## What it installs

| Path | Purpose |
|---|---|
| `/usr/local/sbin/powertux-set` | apply a level 1-4 (root-only, real file) |
| `/usr/local/sbin/powertux-install-profiles` | inject 4 TCC profiles |
| `/usr/local/bin/powertux-current-level` | print current level (0-4) |
| `/usr/local/bin/powertux-autod` | adaptive daemon |
| `/usr/local/bin/powertux-mode` | get/set daemon mode (auto/pinned) |
| `/usr/local/bin/powertux-analyze` | terminal report from JSONL logs |
| `/usr/local/bin/powertux-eta-bench` | ETA prediction backtest + oracle |
| `/etc/sudoers.d/powertux` | NOPASSWD for powertux-set 1..4 |
| `/etc/tmpfiles.d/powertux.conf` | relax RAPL `energy_uj` perms to 0444 |
| `~/.config/systemd/user/powertux-autod.service` | user service unit |
| `~/.config/waybar/scripts/powertux*.sh` | waybar display + click handlers |
| `~/.config/powertux/state.json` | mode flag (auto/pinned) |

Plus 4 entries appended to `/etc/tcc/profiles`:
`powertux-silent`, `powertux-quiet`, `powertux-balanced`, `powertux-perf`.
Original profiles backed up to `/etc/tcc/profiles.bak-pre-powertux`.

Most user-scope files are symlinked; edits to the cloned repo take effect on
the next invocation (the daemon needs `systemctl --user restart
powertux-autod` to reload). The two `/usr/local/sbin` files are real copies
because the sudoers rule grants root via path - a symlink there would let
anyone with write access to the source bin/ replace the binary and gain
unrestricted root.

## The 4 tiers (measured on this chassis)

| Level | platform_profile | EPP | boost | ODM | load_W | MHz | temp |
|---|---|---|---|---|---:|---:|---:|
| L1 silent | low-power | power | 0 | none | ~19 | 1940 | 54 C |
| L2 quiet | performance | balance_performance | 1 | power_save | ~25 | 2616 | 58 C |
| L3 balanced | performance | balance_performance | 1 | enthusiast | ~41 | 3126 | 73 C |
| L4 perf | performance | performance | 1 | overboost | ~64 | 3573 | 86 C |

Methodology and raw sweep data live under `results/`; see `devlog.md` for
the full derivation including why boost=0 collapses all EPP/pp variants and
why ODM=power_save lands at ~25W.

## autod decision table

|                       | load1m < 2 | 2 <= load1m < 8 | load1m >= 8 |
|---                    |---         |---              |---          |
| **AC**                | L2         | L3              | L4          |
| **Battery >= 60%**    | L1         | L2              | L3          |
| **Battery 30-60%**    | L1         | L2              | L2          |
| **Battery < 30%**     | L1         | L1              | L2          |

- Upgrades apply on next 5s tick.
- Downgrades require 30s of sustained low load (load1m AND load5m).
- AC plug events cause re-evaluation on the next tick.
- Power cost of the daemon itself: ~0.001W (negligible).

## waybar integration

The install script copies the scripts. Config edits are NOT auto-applied
(munging `config.jsonc` is risky). Add manually if setting up a new bar:

`modules-right` entry:
```json
"custom/powertux",
```

Module config:
```json
"custom/powertux": {
    "exec": "~/.config/waybar/scripts/powertux.sh",
    "return-type": "json",
    "interval": 5,
    "format": "{}",
    "signal": 1,
    "on-click": "~/.config/waybar/scripts/powertux-up.sh",
    "on-click-right": "~/.config/waybar/scripts/powertux-down.sh",
    "on-click-middle": "~/.config/waybar/scripts/powertux-toggle.sh"
}
```

style.css:
```css
#custom-powertux { padding: 0 4px; font-family: monospace; }
```

The script emits Pango markup with per-segment colors (level, ODM, EPP, boost
each in a distinct color), so CSS only needs to handle padding.

Click semantics:
- Left: raise level (and pin to manual)
- Right: lower level (and pin to manual)
- Middle: toggle auto / pinned

In auto mode the level display gets an `a` suffix in yellow:
`L2a [pwr-B+-b1]`. In pinned mode no suffix.

No middle mouse button? Bind a keystroke to `powertux-mode`:

```sh
powertux-mode             # print current mode + pinned level
powertux-mode auto        # daemon picks the level
powertux-mode pinned      # pin at currently-applied level
powertux-mode pinned 3    # pin at L3 (applies it too)
powertux-mode toggle      # auto <-> pinned, same as middle-click
```

Example Hyprland keybind (`~/.config/hypr/hyprland.conf`):

```
bind = SUPER, F8, exec, powertux-mode toggle
```

## Analyzing logs

Autod writes one JSONL row per 5s tick to `~/Programs/powertux/log/<date>.jsonl`.
`powertux-analyze` reads them and prints a single terminal report:

```sh
powertux-analyze                       # full report, all logs
powertux-analyze --days 7              # last 7 days
powertux-analyze --from 2026-05-12     # since a date
powertux-analyze --section tldr,recs   # just headline + recommendations
powertux-analyze --ascii --no-color    # pipe-friendly
```

Report structure (each banner is a major group):

| Group | Sections |
|---|---|
| HEADER | hardware/kernel, range/coverage |
| HIGHLIGHTS | TL;DR, tuning recommendations |
| USAGE / TIER BEHAVIOR | residency, ribbon, daily timeline, hour-of-day, transitions, chatter, decision table, threshold sensitivity |
| LOAD / POWER | load distribution, power timeline, vs vendor baseline, per-display power attribution |
| BATTERY | sessions table, pending outcome, voltage/SoC, gauge/wear |
| PLATFORM | drift, thermal, calibration health, environment context |
| EVENTS | highlights reel (AC edges, biggest swings, longest session, etc.) |

The TL;DR + recommendations sections surface the load-bearing numbers and
actionable tuning hints (raise `UPGRADE_HOLD_SEC`, L1 reach, cap-vs-cells
drift, gap rate). The tier ribbon adapts to terminal width (7-21 min per
cell depending on cols). The per-display attribution section groups
battery `w_sys` by the EDID-identified `displays` set and reports the
median W cost per display (bus-powered USB-C portables surface naturally;
self-powered HDMI/DP ones net near zero).

Stdlib-only; unicode by default, `--ascii` for plain.

## ETA prediction backtesting

`powertux-eta-bench` replays every closed discharge segment against a
panel of ETA algorithms (naive / median / trimmed / ewma / blended /
voltage-only / tier-conditional / regression), then scores each on
accuracy, stability, and bias. The leaderboard ranks by a composite score
that matches the widget's UX goals (lower median error + smoother
predictions + smaller bias).

```sh
powertux-eta-bench                       # full backtest report
powertux-eta-bench --algorithms ewma-5,naive-15
powertux-eta-bench --segments-only       # list segments
powertux-eta-bench --show-predictions N  # tick-by-tick on segment N
powertux-eta-bench --oracle              # one-line JSON: best algorithm
```

The `--oracle` output is meant to be consumed by the waybar widget so the
"best algorithm in this house" recommendation is data-driven rather than
baked into the widget source. Expand the bench window (`--from` / `--to`)
once you have a few weeks of data to stop the recommendation from chasing
single-segment noise.

## Calibration

The calibration scripts are kept for reproducibility:

```sh
sudo ./bin/powertux-calibrate         # sweep platform_profile x EPP x boost
sudo ./bin/powertux-calibrate-odm     # sweep ODM profiles via tccd
sudo ./bin/powertux-probe             # per-level sustained-load probe (battery-sandbag check)
```

Each writes a timestamped JSON to `results/`. Useful if the tier numbers
drift after a firmware update or you want to re-derive the mapping for a
different chassis.

## Layout

```
bin/
  powertux-set                 apply level 1-4 (root, real file)
  powertux-install-profiles    inject 4 TCC profiles
  powertux-current-level       print current level
  powertux-autod               adaptive daemon
  powertux-mode                get/set mode (auto/pinned) from CLI
  powertux-analyze             terminal report from JSONL logs
  powertux-eta-bench           backtest ETA algorithms + oracle output
  powertux-calibrate           platform_profile / EPP / boost sweep
  powertux-calibrate-odm       ODM profile sweep
  powertux-probe               per-level sustained-load probe
sudoers/
  powertux                     NOPASSWD drop-in (user templated at install)
systemd/
  powertux-autod.service       user service unit
  powertux.tmpfiles.conf       relax RAPL energy_uj perms
waybar/
  powertux.sh                  display
  powertux-up.sh               left-click handler
  powertux-down.sh             right-click handler
  powertux-toggle.sh           middle-click handler
results/                       calibration data
install.sh                     installer
devlog.md                      append-only design log
METRICS.md                     per-field telemetry reference
```

## Troubleshooting

- Daemon log: `journalctl --user -u powertux-autod -f`
- Force-reset to auto mode: `powertux-mode auto` (or edit state.json directly)
- Bar shows `?? [tcc-default]`: tccd reverted to a non-powertux profile.
  Should self-heal within 5s; the daemon reasserts the pinned level on AC
  edges and on cold start. If it persists, `powertux-mode auto` or
  `powertux-mode pinned N` will force a re-apply.
- RAPL `energy_uj` missing or unreadable: the tmpfiles rule needs a reboot
  to take effect on first install. Until then `powertux-analyze` skips
  `w_pkg`-derived sections; everything else works.
- Reset everything: `./install.sh --uninstall`

## Project layout note

This repo focuses on the power-level knob. Charge-cap control (writing
`BAT0/charge_control_end_threshold`) lives in a separate, intentionally
decoupled project that ships the kernel-driver patch described above. The
two have orthogonal lifecycles: powertux's tier switching runs on a stock
kernel + stock `tuxedo-drivers-dkms`, while `powertux-analyze`'s full
battery sections only become accurate once the patched driver is in place.

## License

MIT. See [LICENSE](LICENSE).
