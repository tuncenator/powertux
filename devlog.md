# devlog

Append-only design log. Newest entries at the bottom. Pair project to a
separate `tuxedo-charge-cap-re` repo (charge-cap is intentionally decoupled
from the power-level knob).

## 2026-05-11 - Problem statement

TUXEDO InfinityBook Pro 14 Gen10 AMD (`XxKK4NAx_XxSP4NAx`, BIOS `N.1.20A13`).
Ryzen AI 9 HX 370 (Strix Point), kernel 6.18.26-1-MANJARO, amd-pstate-epp
active, amd_pmf as the platform_profile provider. tccd 3.0.3-2 running with
"TUXEDO Defaults" / "Battery Efficient" auto-switching on AC/battery edges.

Goal: collapse the platform_profile / EPP / TCC ODM / cpufreq-boost tangle
into a single user-facing knob with 4 discrete tiers, picked from empirical
calibration rather than vendor assumptions. The vendor's 2-profile auto-switch
sat in one TDP band (~45-47W under load) and left the silent end (boost-off,
~19W) and the boost end (overboost ODM, ~64W) unused.

## 2026-05-11 - Calibration sweeps

Four calibration runs in `~/Programs/powertux/results/`:

| File | Sweep | Notes |
|---|---|---|
| `2026-05-11-224101-calibration.json` | platform_profile x EPP, 6 candidates | v1: contaminated by syncthing |
| `2026-05-11-232510-calibration.json` | same matrix + boost axis | v2: with quieter desktop |
| `2026-05-11-235041-calibration.json` | targeted boost=0 + EPP=performance | v3: hypothesis disproved (boost=0 collapses EPP) |
| `2026-05-12-000931-odm-calibration.json` | TCC ODM profile sweep | v4: power_save / enthusiast / overboost via SetTempProfileById |

Methodology: each candidate gets 10-15s idle sample + 40s under `7z b 2`
load, sampling RAPL package energy (`/sys/class/powercap/intel-rapl:0/energy_uj`),
all-core MHz mean (`/sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq`),
k10temp Tctl, BAT0 power_now when on battery. Stops tccd during pp/EPP/boost
sweeps to prevent EPP reassignment; uses tccd profiles for ODM sweeps.

Findings:

1. **platform_profile alone is nearly a no-op.** lp-bp = 45.0W vs bal-bp =
   45.3W vs perf-BP = 47.4W under same EPP. Only EPP=performance under
   platform_profile=performance unlocks the +33% PPT jump from ~48W to ~64W.

2. **boost=0 collapses all EPP/pp variants** to ~19W / 1940 MHz / 76k 7z. EPP
   is a no-op when cpufreq/boost=0 because scaling_max_freq clamps to base.
   This is documented amd-pstate-epp behavior since the CPB-boost patch
   series (mainlined post-6.9).

3. **ODM=power_save lands at ~25W** as predicted by community ref (XMG
   Fusion-class chassis ~25W). Provides the missing middle tier between
   Silent (~19W) and Balanced (~41-48W).

4. **ODM=enthusiast (41W) is cooler than no-ODM (47W)** with identical 7z
   score (~112k). Enthusiast = "thermal/acoustic-friendly perf" preset.

5. **ODM=overboost did NOT push past 64W** on this 14" chassis. Same as no-ODM
   + EPP=performance. Tuxedo apparently caps PL1 at 65W regardless of ODM on
   IBP14; the IBP15 reaches 90W in overboost per public spec.

## 2026-05-11 - 4-tier design (final)

| Level | platform_profile | EPP | boost | ODM | Measured load_W | MHz | Tctl_max | 7z Tot |
|---|---|---|---|---|---:|---:|---:|---:|
| L1 silent | low-power | power | 0 | (any) | 19 | 1940 | 54 | 76k |
| L2 quiet | performance | balance_performance | 1 | power_save | 25 | 2616 | 58 | 93k |
| L3 balanced | performance | balance_performance | 1 | enthusiast | 41 | 3126 | 73 | 111k |
| L4 perf | performance | performance | 1 | overboost | 64 | 3573 | 86 | 121k |

Gap sequence: +6W / +16W / +23W. Each step unambiguously distinct in fan,
temp, score, and battery drain. Charge cap intentionally NOT bundled (lives
in the sibling charge-cap project; orthogonal axis: stationary-vs-mobile, not
silent-vs-loud).

## 2026-05-11 - tccd interface

`com.tuxedocomputers.tccd` on the system bus. Default policy
(`/usr/share/dbus-1/system.d/com.tuxedocomputers.tccd.conf`) allows any user
to send. No sudo needed for tccd calls.

Key methods:
- `GetActiveProfileJSON` -> returns full active profile JSON (id, cpu, fan, odm)
- `SetTempProfileById(s)` -> applies a profile transiently; reverted on
  next AC/battery edge (`stateMap` re-applies)
- `ODMProfilesAvailable` -> `[power_save, enthusiast, overboost]` on this board
- `GetChargeEndThreshold` -> reads our patched 0x07B9 sysfs

ODM profile schema in `/etc/tcc/profiles`: `{"name": "<one-of>"}` or `{}` =
firmware factory default (which on this board behaves close to enthusiast,
slightly less capped).

## 2026-05-11 - powertux design

Workspace `~/Programs/powertux/` (NOT in Sync; this is host-specific
calibration data).

Components:

```
bin/
  powertux-set                 # apply level 1-4 (root): writes platform_profile +
                               # busctl SetTempProfileById to powertux-<tier>
  powertux-install-profiles    # append 4 TCC profiles to /etc/tcc/profiles
                               # (idempotent, --remove for reversal)
  powertux-current-level       # print 1-4 or 0 (active TCC profile -> level)
  powertux-autod               # adaptive daemon (load + AC + cap -> level)
  powertux-calibrate           # pp x EPP x boost sweep
  powertux-calibrate-odm       # ODM profile sweep
sudoers/powertux               # NOPASSWD: /usr/local/sbin/powertux-set [1-4]
systemd/powertux-autod.service # user service unit
waybar/powertux*.sh            # display + click handlers (Pango per-segment color)
install.sh                     # one-shot installer (install/uninstall/status)
results/*.json                 # raw calibration data
log/YYYY-MM-DD.jsonl           # autod tick log (added later, see entries below)
```

Profiles inject as code (Python dict in `powertux-install-profiles` SPECS list)
into `/etc/tcc/profiles`. Cloned from first existing profile as template
(inherits display/webcam/fan fields). Original profiles backed up to
`/etc/tcc/profiles.bak-pre-powertux` on first install. State-map in
`/etc/tcc/settings` untouched -> on AC/battery edges tccd auto-reverts to
"TUXEDO Defaults" / "Battery Efficient"; autod re-applies within ~5s.

Auth: clicks invoke `sudo /usr/local/sbin/powertux-set N` through a sudoers
drop-in restricting NOPASSWD to N in {1,2,3,4}.

Waybar text format (V1 design): `L<N> [<odm>-<epp>-b<boost>]` with Pango
per-segment colors. In auto mode appends a yellow `a` after the digit:
`L2a [pwr-B+-b1]`. Left-click cycles up (and pins), right cycles down (pins),
middle toggles auto<->pinned.

## 2026-05-12 - autod decision table (v1)

5s poll. Initial table:

|   | load1m < 2 | 2-8 | >8 |
|---|---|---|---|
| AC | L2 | L3 | L4 |
| BAT >=60% | L1 | L2 | L3 |
| BAT 30-60% | L1 | L2 | L2 |
| BAT <30% | L1 | L1 | L2 |

Hysteresis (v1): upgrades immediate, downgrades require 30s of sustained
low load (load1m AND load5m below thresholds).

Power cost of daemon itself: ~0.002% CPU duty, negligible at RAPL grain.
Subprocess only on level changes (~100ms each, typically 0-5/hr).

## 2026-05-12 - 9 transitions / 10 min observation

Live log over 10 min showed L1<->L2 oscillation at load1m boundary of 2.
Load typically hovered 1.3-3.5 in normal use (claude agents, firefox,
background syncs). Threshold=2 was inside the noise band.

Cause: upgrades had no hysteresis, so single-poll noise spikes (one 5s
window above threshold) triggered transitions.

Fix: added `UPGRADE_HOLD_SEC = 5` (require 1 confirming poll before upgrade
applies). Decision: kept threshold=2; preferred filtering noise via dwell
over raising threshold (cleaner separation of "noise" vs "real").

## 2026-05-12 - L1 floor problem and v2 policy

Realization: load1m is a 1-min EWMA. A 5s burst of 4 cores contributes only
~0.33 to load1m (5/60 x 4). Interactive bursts (typing, mouse, click
handlers) never push load1m above threshold even when they're producing
audible stutter. L1 has `boost=0` and `EPP=power` -> every IRQ runs at
~2 GHz base clock. Result: same UX problem the user had on Battery Efficient
(stuttering mouse, slowed typing), but worse.

Fix: L1 only fires on truly-sustained-idle (load1m, load5m AND load15m all
< 1) OR low-battery deep-idle. New table:

|   | sustained idle (all 3 < 1) | load1m < 2 | 2-8 | >8 |
|---|---|---|---|---|
| AC | L2 | L2 | L3 | L4 |
| BAT >=60% | L1 | L2 | L2 | L3 |
| BAT 30-60% | L1 | L2 | L2 | L2 |
| BAT <30% | L1 | L1 | L2 | L2 |

L1 reserved for "I'm not using this laptop right now" (screen idle, media
playback, charger waiting). Normal interactive usage stays at L2 with boost
available, race-to-idle preserved for snappy feel.

## 2026-05-12 - JSONL logging

Autod now appends one JSONL line per 5s tick to
`~/Programs/powertux/log/<YYYY-MM-DD>.jsonl`. Fields: `t, mode, load1m,
load5m, load15m, ac, cap, tte_s, current, target, pending`.

Daily rotation; cleanup of files older than 30 days runs once per day at
midnight rollover. ~800 KB/day raw, planned for offline analysis to tune
thresholds against real usage patterns.

Planned: `bin/powertux-analyze` script (not yet written) reading the JSONL
files for time-at-level histograms, per-capacity load distributions,
transition-per-hour timeline. Decision: run for 2-4 weeks of data, then
tune thresholds from observed behavior.

## Open items

- ~~Analysis script for the JSONL logs.~~ Resolved 2026-05-12: see the
  powertux-analyze entry below.
- ~~AC/battery transition while pinned: tccd auto-switches to TUXEDO
  Defaults / Battery Efficient, autod stays out of it because mode=pinned.~~
  Resolved 2026-05-12: daemon re-asserts the pinned level on AC edges and
  on cold start. See the 2026-05-12 pinned-persistence entry below.
- AC/battery transition while in auto: up to 5s gap during which tccd's
  profile is applied (Battery Efficient = EPP=power = stutter-y) before
  autod's next tick re-asserts the right powertux level. Decision:
  acceptable as-is. Cheap fix if ever annoying: AC state sub-poll at 1s in
  autod, immediate tick on edge.
- Fan curves: all 4 powertux profiles inherit "Balanced" from the cloned
  template. Could differentiate per tier (L1/L2 -> "Quiet"; L4 -> custom
  aggressive curve) but marginal gain since temperature drives fan more
  than preset choice. Revisit if L4 ever throttles or L1/L2 are audible
  at idle.
- charge cap is wired separately in the tuxedo-charge-cap-re project.
  Both projects share the laptop but don't share files.
- `time_to_empty_now` (BAT0) currently logged but not used in the decision
  table. Capacity is more stable; revisit if capacity proves too coarse.

## Reference: install paths

- `/usr/local/sbin/powertux-set` (0755 root, NOPASSWD allowed)
- `/usr/local/sbin/powertux-install-profiles` (0755 root)
- `/usr/local/bin/powertux-current-level` (0755 root, user-callable)
- `/usr/local/bin/powertux-autod` (0755 root)
- `/usr/local/bin/powertux-mode` (0755 root, user-callable)
- `/etc/sudoers.d/powertux` (0440 root)
- `~/.config/systemd/user/powertux-autod.service`
- `~/.config/waybar/scripts/powertux{,-up,-down,-toggle}.sh`
- `~/.config/powertux/state.json`
- `/etc/tcc/profiles` (appended) + `/etc/tcc/profiles.bak-pre-powertux` (backup)

## Reference: key reads while debugging

```
~/Programs/powertux/install.sh --status     # full deployment status
journalctl --user -u powertux-autod -f      # live daemon log
busctl call com.tuxedocomputers.tccd /com/tuxedocomputers/tccd \
    com.tuxedocomputers.tccd GetActiveProfileJSON   # confirm active TCC profile
cat /sys/class/powercap/intel-rapl:0/name   # confirms package-0 RAPL counter
cat /sys/firmware/acpi/platform_profile     # current amd_pmf level
cat /sys/devices/system/cpu/cpufreq/boost   # 1 or 0
cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference
```

## 2026-05-12 - Pinned level persistence + AC-edge re-assert

Boot symptom: after reboot, bar showed `?? [tcc-default]`. Root cause: tccd
starts on its default profile; daemon read `{"mode":"pinned"}` and respected
the pin by sleeping. But the pinned level was never persisted -- state only
recorded the mode bit -- so the daemon couldn't have re-applied it even if
it wanted to.

Same shape as the AC/battery-while-pinned open item: an external party
(systemd boot, or tccd's AC-edge profile switch) clobbers the TCC profile,
the daemon stays out because mode=pinned, user sees the default profile
until they middle-click.

Resolution:

1. state schema extended: `{"mode":"pinned","level":1..4}`. Old form
   `{"mode":"pinned"}` still parses; daemon falls back to the auto-computed
   target as a one-time bootstrap on cold start (logged distinctly).
2. Waybar up/down scripts now write the new level into state alongside the
   mode bit.
3. Daemon re-applies the pinned level when `last_applied is None` (cold
   start) and on AC/battery edges. AC edge is detected by comparing the
   current AC reading to the prior tick; first tick after start sees
   `last_ac is None` and is skipped (already covered by the cold-start
   branch). Cost: zero new subprocess calls on steady-state ticks.
4. New `powertux-mode` CLI (`/usr/local/bin/powertux-mode`) exposes
   `auto | pinned [N] | toggle | show`. Waybar `powertux-toggle.sh` is now
   a thin `exec` to it. Use case: laptops without a middle-click button;
   bind a keystroke in the WM instead.
5. install.sh now `restart`s the user service instead of `--now`-enabling
   (the latter is a no-op when the unit is already running, so re-runs of
   the installer wouldn't pick up daemon changes).

Closes the open item about AC/battery-while-pinned. Boot recovery and
transition recovery are the same mechanism.

## 2026-05-12 - powertux-analyze

Single Python file, stdlib-only, ~430 lines. Reads
`~/Programs/powertux/log/*.jsonl` (or `--log-dir DIR`) and prints one
continuous report. Range filters: `--days N`, `--from ISO`, `--to ISO`.
Unicode block chars by default; `--ascii` falls back to `#:.=+*`. Color
auto-disabled when stdout is not a tty; `--no-color` forces it off.

Sections:

- Range: from/to, span, samples + coverage, gaps, AC vs battery split,
  mode split (auto vs pinned), AC plug-in / unplug edge counts.
- Tier residency: stacked bars for overall + AC + battery, with absolute
  durations and percentages.
- Daily timeline: one row per day, 24 cells (one per hour). Cell height
  = avg load1m clamped at 8, cell color = dominant `current` tier in
  that hour.
- Hour-of-day pattern: aggregated tier share per hour-of-day. Skipped
  when only one day of data is available.
- Transitions per hour: only hours with activity. Bar split into an
  upgrade segment (red) and a downgrade segment (green).
- load1m distribution: log-ish buckets (<0.5, 0.5-1, 1-2, 2-4, 4-8, 8-16,
  >=16) with p50/p95/p99/max.
- Battery: session count, total time, drained capacity, drain rate over
  net-drain sessions, capacity sparkline.
- Pending-tier outcome: counts pending sequences that ended applied vs
  reverted (hold-timer suppressed a transient). Both are healthy.
- Decision-table validation: 4x3 grid (AC, B+, B=, B- x load <2 / 2-8 /
  >=8). Each cell prints the observed dominant tier + share + total time
  in that cell, with `*` flagging divergence from README policy.

First-run findings on 10h of mixed data:

- Tier residency: 0% L1 across the entire window. Suggests either L1 is
  too aggressive (drops below useful for actual workloads) or the load
  threshold for L1 is unreachable in practice once a browser/terminal
  are open.
- Decision-table: two `*` cells, both on battery with low load. Auto
  mode observed L2/L3 instead of policy L1. Explained by the 30s
  downgrade hold: load briefly dips below 2, hold runs, load returns
  before the timer fires. Working as designed; the `*` is a useful flag
  of "policy says X but reality is Y because of smoothing", not a bug.
- Pending applied/reverted ratio: 73/27. The hold timer is suppressing
  about a quarter of would-be transitions. Good sign for the
  downgrade-hold value, though the up-hold (5s = 1 extra tick) does
  less work.
- Battery drain rate: 11 %/hr aggregate over net-drain sessions.

Wired into install.sh (install/uninstall/status all touch the new
binary). README gains an "Analyzing logs" section and a row in the
install table.

## 2026-05-12 - Power telemetry + counterfactual

Added two telemetry fields to autod's JSONL output and two new sections
to powertux-analyze that turn the data into a "what did auto actually
save you" answer and a calibration health report.

Telemetry (per tick):

- `w_pkg` -- CPU package W from RAPL energy_uj delta over the tick.
  Requires `/sys/class/powercap/intel-rapl:0/energy_uj` to be readable
  by the user-scope daemon (default Manjaro perms are 0400 root). Fix
  in install.sh: ship `/etc/tmpfiles.d/powertux.conf` setting mode 0444,
  applied at install time via `systemd-tmpfiles --create` and persisted
  across reboots by systemd-tmpfiles-setup. RAPL side-channel concern
  acknowledged in the conf file; 5s sampling is far below attack-grade
  resolution and many distros already ship 0444 by default.
- `w_sys` -- full-system W from BAT0 `voltage_now * current_now`. Only
  set when status == "Discharging" (i.e., on battery + actually drawing).
  No perms gymnastics required; sysfs is 0444 already.

Both reads are ~10-30 microseconds, well below the 5s tick interval.
Daemon falls back to null silently if either path is unreadable.

powertux-analyze additions:

- `vs baseline` section:
    - Computes observed package Wh per tick: prefers `w_pkg` if present,
      else falls back to estimation via `w_at(idle_W, load_W, load1m)`
      using the calibration table.
    - Counterfactual: at each tick, assume the system was running the
      vendor default that powertux replaced -- TUXEDO Defaults
      (ODM-none, perf pp, balance_performance EPP) on AC, Battery
      Efficient (low-power pp, power EPP) on battery -- with W
      interpolated by the same load1m. Calibration constants in
      `TIER_W`, `BASELINE_AC`, `BASELINE_BAT` lifted from
      `results/2026-05-12-000931-odm-calibration.json` and
      `results/2026-05-11-232510-calibration.json`.
    - Reports saved Wh and percent for AC, battery, and total. Also
      surfaces the measured-vs-estimated ratio per row so the reader can
      weight the number.
- `calibration health` section:
    - **Chatter**: count of transitions reversed within 5 min. First
      run on 3h35m of auto data showed 22 of 34 transitions (64.7%)
      chattered -- big enough to flag as a real tuning issue, not noise.
    - **Upgrade / downgrade latency**: time from `target != current` to
      convergence. Discontinuity reset on mode change or sample gap
      > 2 ticks so a divergence bracketed by a pinned-mode interval
      doesn't get counted as multi-hour latency. First run: upgrade
      p50/p95/max all 10-12s (hold=5s + 1 tick), downgrade all 35-36s
      (hold=30s + 1 tick). Algorithm timing exactly matches config.
    - **Pending duration histograms** (applied vs reverted): for the
      same window, applied avg 17s p50 7s, reverted avg 10s p50 10s.
      Reverts happen fast, which is the point of the hold -- catches
      transient spikes inside the first couple of ticks.
    - **Pin override events**: counts of auto -> pinned transitions
      grouped by direction (up = "auto under-provisioned", down = "auto
      over-provisioned", same = "user just locked in current pick").
      Per-pair breakdown for the up/down ones.

First-run interpretation, 10h37m window with 33.7% in auto:

- Estimated savings vs vendor defaults: 32 Wh on AC (26%), 10 Wh on
  battery (7%), total 42 Wh (16%). Caveat: 0% measured -- this is the
  estimation path. Will re-evaluate once enough w_pkg data accumulates.
- Battery-side savings are smaller because the user spent most of the
  battery window pinned at L3, which sits very close to Battery
  Efficient's measured load_W (40.82 vs 44.07). The savings argument
  for auto on battery is mostly about hitting L1 during true idle,
  which is the policy cell with 0% residency so far.
- 64.7% chatter is the strongest tuning signal. Load1m distribution
  has 41% of mass in [1, 2) -- right against the L2/L3 threshold. The
  upgrade hold (5s = 1 confirming tick) is too short to filter slow
  oscillation in this band. Options for v3: widen UPGRADE_HOLD_SEC,
  add a hysteresis band (different thresholds for up vs down), or
  switch to a longer-window load metric (load5m) for the AC tier
  decision. Defer until 1-2 weeks of auto-dominant data.

Permissions footprint added by this change: 1 file, `/etc/tmpfiles.d/
powertux.conf`. Removed cleanly by `install.sh --uninstall` (perms
revert to 0400 on next reboot).

## 2026-05-12 - tccd post-restart state drift

Bug seen right after `./install.sh`: bar showed `?? [tcc-default]` even
though `journalctl --user -u powertux-autod` showed a clean `init L2`
ten seconds prior. Manual `busctl call ... GetActiveProfileJSON`
returned `TUXEDO Defaults`. The daemon's JSONL log kept emitting
`"current":2` though, oblivious.

Sequence of events (timestamps from the journal):

```
13:36:01  install.sh step 4 -> powertux-install-profiles -> systemctl restart tccd
13:36:01  install.sh step 7 -> systemctl restart powertux-autod
13:36:01  autod: init L2  (calls sudo powertux-set 2)
13:36:01  powertux-set: busctl call SetTempProfileById s "powertux-quiet"
13:36:03  tccd: Daemon started  (ODM profile 'overboost' default-applied)
13:36:??  tccd settles, stateMap pulls TUXEDO Defaults (AC)
13:36:53  my manual probe: SetTempProfileById -> Temp profile selected
```

Three things conspired:

1. `powertux-install-profiles` unconditionally `systemctl restart tccd`
   even when the profile file hash didn't change. install.sh continued
   to step 5/6/7 immediately. tccd took ~3-5s to come up.
2. `powertux-set` issued busctl SetTempProfileById while tccd was still
   booting. dbus accepted the call (the busctl exit code was 0) but
   tccd silently dropped it during init. powertux-set had no
   verification step, so it reported success.
3. autod's `apply_level` uses `subprocess.run(..., check=False)`, so it
   wouldn't have noticed even if powertux-set had failed. last_applied
   was set to 2 regardless. In auto mode the daemon only re-applies on
   target-change, so it sat staring at the wrong tccd state forever.

Fix, three layers (belt + braces; chose this over single-point fix because
the race-after-tccd-restart will recur whenever tccd restarts for any
reason, not just at install time):

A. **install.sh: wait_for_tccd helper**. After step 4, polls
   `busctl GetActiveProfileJSON` every 500ms up to 10s. Lets step 7's
   autod restart fire only when tccd can actually accept calls.

B. **powertux-set: retry + verify**. Up to 3 attempts at busctl
   SetTempProfileById with 1s backoff. After each attempt, re-reads
   GetActiveProfileJSON and confirms `"id"` matches the requested
   profile. Exits non-zero only after all 3 fail, which `apply_level`
   still won't see (check=False) but at least is no longer silently
   dropping the failure.

C. **autod: drift detection each tick**. New `read_tccd_active_id()`
   parses GetActiveProfileJSON (the busctl payload uses `\"` escapes, so
   the marker is the literal `\"id\":\"`, not `"id":"` -- caught this
   in a test pass). Each tick, if `last_applied` is set, compare the
   tccd active id to `TIER_TCCD_ID[last_applied]`. On mismatch, log and
   re-apply. Cost: one `busctl call` per tick (~20ms wall), ~0.4% of
   the 5s interval. Catches: post-restart races (belt for A), any
   future tccd self-restart, anything else that drives a
   SetTempProfileById from outside (rare but cheap to defend).

The autod no longer has to trust that the apply landed -- it verifies
every tick. That makes A and B nice-to-haves rather than load-bearing,
which is the right balance for a state-sync layer like this.

## 2026-05-12 - Battery telemetry expansion + cap-vs-cells discovery

Findings today exposed two things the kernel ABI hid from `powertux` and
from any user trusting the standard battery widget:

1. **`charge_control_end_threshold` does not actually keep cells off the
   high-voltage plateau on this EC.** Cap=80 was set for ~78 minutes
   while plugged in. Kernel `capacity` reported `80` the whole time and
   `current_now = 0` (per the patch verification on 2026-05-11). When
   the cap was lifted, `capacity` rose from 80% to ~96% over ~2 minutes
   with `current_now` still reading 0 and `status` = `Not charging`. Math
   says that's ~240 W of charging if real -- physically impossible at
   ~80 W charger / 86 Wh pack. The coulomb counter (`charge_now`) had
   been pinned during the hold; lifting the cap let the EC re-anchor it
   to the OCV-implied SoC. `voltage_now` showed 16.631 V (4.158 V/cell
   on 4S) at that moment, which is ~95-100% Li-ion SoC. The cells were
   physically at ~95% SoC the entire time the cap was advertising 80%.

   Implication: the cap stops the *visible* charging current, but the
   EC continues a sub-`current_now`-floor maintenance/equalization that
   the kernel cannot see. Over hours the cells creep to full-plateau
   voltage. The longevity benefit of `charge_control_end_threshold=80`
   is much smaller than advertised on this board.

2. **The EC physically disconnects BAT0 at SoC=100 on AC.** Right after
   the cap-removal experiment, `/sys/class/power_supply/BAT0/` vanished
   entirely. `PNP0C0A:00` still showed in ACPI (`_STA` = 31), but the
   battery driver had no power_supply child. Kernel journal had no
   `BAT_INSERT/REMOVE` events. This is a TUXEDO firmware behavior:
   once charging hits 100%, the EC takes the cells off the bus and
   powers the system directly from AC. Side effect for userspace:
   `charge_control_end_threshold` becomes unwritable (the sysfs file is
   gone), capacity reporting goes dark, voltage reads zero, every
   battery field returns None.

   Recovery: unplug AC for a moment. The system switches to battery
   draw, EC re-enables BAT0, sysfs node reappears. The
   `charge_control_end_threshold` register is volatile across the
   re-engage (as already documented for reboot in the systemd-persist
   entry above), so the systemd service has to re-apply on every
   re-attach. Plus AC-online and post-resume hooks are the only ones
   firing today; a battery-attach udev rule would close that gap.

### What this means for the upstream PRs

The patch (`tuxedo-drivers#4`, `Wer-Wolf/uniwill-laptop#16`) implements
the standard kernel ABI correctly: write 80 to EC[0x07B9], EC stops
`Charging` immediately, `current_now -> 0`, `status -> Not charging`.
That contract is honored. What the kernel ABI doesn't promise (and
the EC firmware doesn't deliver) is that the *cells* stay at the
percentage advertised.

This isn't a regression caused by the patch. The same behavior would
appear if the cap were exposed by Tuxedo's stock driver -- the EC is
what holds (or doesn't hold) the cells. The patch is just what makes
the cap *reachable* from userspace on this board at all; the
plateau-creep is below it.

Worth posting back to TCC #268 once verified with a clean v_bat
session: the patch is the right fix for the ABI gap, but users
expecting 80%-cap to deliver Li-ion-longevity-grade SoC limiting will
be disappointed on Gen10. Setting a lower cap (60-65) may be the
practical workaround if voltage measurements confirm cells track the
cap there.

### Telemetry expansion (autod)

Reaction to "we missed this for a day because we weren't logging
voltage": expand the JSONL schema to capture every battery signal we
could conceivably want, so the next anomaly is in the data the first
time it happens.

Added fields per tick, on top of the existing ones from earlier today:

```
v_bat        pack voltage in V (always honest; the one signal that
             didn't lie today)
i_bat        current_now in A (signed per ACPI; on this board the
             ACPI rate is "disabled" so it pins to 0 even during
             discharge, but log it raw)
cap_th       charge_control_end_threshold int (active cap)
status       Charging | Discharging | Not charging | Full | Unknown
charge_now   coulomb counter in uAh (snaps without current flow when
             EC re-anchors; today's 80% -> 96% jump was this field
             moving)
charge_full  coulomb-counter "full" reference in uAh (tracks wear
             plus any EC re-anchoring of the reference)
cycle_count  integer wear indicator
```

`v_bat` is the load-bearing signal: when the kernel coulomb counter
lies (today) or the cell stops responding (BAT0 detached state),
`voltage_now` is still readable as long as BAT0 exists, and the OCV
curve gives an honest SoC estimate. The widget `~/.config/waybar/
scripts/battery-soc` displays this delta live; the analyze script
backfills it for any window.

### Analyze additions

New section "Battery voltage / SoC" surfaces:

- Per-cell voltage and OCV-derived SoC (min / p50 / max)
- Status time distribution (% of window in each ACPI status)
- BAT0 detach events with timestamps and durations (so the "where did
  the battery go" question is answered automatically)
- **OCV-SoC exceeded cap_th**: the headline number for the upstream
  conversation. Time above cap, max drift, the timestamp at which it
  peaked
- Kernel cap% vs OCV-SoC% delta distribution (sag vs drift)
- Voltage sparkline
- cap_th change events with kernel cap and OCV-SoC at the moment of
  each change (so a flip from 100 -> 80 followed by drift becomes a
  one-line story in the report)
- charge_full change events (wear or EC re-anchor)
- cycle_count delta across the window

### Custom waybar widget

`~/.config/waybar/scripts/battery-soc` (Python, no extension):

- Displays kernel SoC% with bracketed delta of OCV-derived SoC.
- Variant A from the design pass: `++` prefix when charging, no
  symbol when discharging, `--` (dim red) replaces SoC when BAT0
  is detached.
- Color gradient on the delta bracket: deep blue (<2) -> dim blue
  (2-5) -> gray (5-10) -> orange (10-15) -> red (>=15). Sag (negative
  delta during discharge) is always dim gray since it's just IR drop.
- Pango markup, JSON return for waybar; class is `normal` /
  `caution` / `warn` / `detached` for optional background tinting.
- Pairs with the existing `battery-cap.sh` widget which renders the
  clickable `/<cap_th>%` suffix; the bar reads e.g. `80% [+1] /80%`.

Wired into `~/.config/waybar/config.jsonc` (`modules-right` and the
`custom/battery-soc` config block) and `~/.config/waybar/style.css`
(background tints for `caution`/`warn`/`detached`).

### What's still untrustworthy

- `current_now` on this board: pinned at 0 most of the time; the user
  noted "battery rate information disabled btw from acpi". We log
  `i_bat` raw anyway in case it ever comes back, but don't depend on
  it for energy accounting. `w_sys` derived from V*I will be null
  most of the time as a consequence.
- `capacity` (kernel %): trusted only at the moments where it tracks
  voltage. The drift section in analyze flags when it doesn't.
- `charge_now` (coulomb counter): subject to non-physical snaps when
  the EC re-anchors. Useful as a logged-over-time signal, not as an
  instantaneous SoC.
- `voltage_now`: the one signal that's worked correctly all day. The
  widget and analyze section both lean on it as the reference.

## 2026-05-15 - autod / analyze tuning pass (post-3d data)

3d16h of accumulated data drove four daemon changes and three analyze
ones. Replay simulator (`whatif` section) projects chatter 68% -> 34%
and trans/hr 8.1 -> 2.5 on the same window.

autod:
- L2/L3 hysteresis 1.5 / 2.5 (was symmetric 2.0 inside the noise band).
- `UPGRADE_HOLD_SEC` 5 -> 20, `DOWNGRADE_HOLD_SEC` 30 -> 20.
- L1 trigger now lid-closed-no-externals or backlight=0 (was load-only
  "all 3 windows < 1", 0.3% residency).

analyze:
- New `whatif` section replays through arbitrary thresholds.
- `hour-of-day` load metric mean -> median (a runaway-process spike on
  2026-05-14 pushed load1m to 9k for ~6 min and skewed every mean).
- Dropped `ribbon` (duplicated `timeline` at coarser resolution).
- `EXPECTED` policy table, documented-policy print, threshold-sensitivity
  band labels, and README decision table all updated to match.

## 2026-05-21 - ETA accuracy audit: log upower silently, build comparator

Complaint: widget ETA "looks like garbage". Pulled data; built a tool
that detects charge/discharge cycles and scores each logged ETA
predictor against the actual time-to-end of the cycle.

Two diagnoses came out of the audit before the new comparator could
even produce numbers:

1. `tte_s` (`/sys/class/power_supply/BAT0/time_to_empty_now`) is
   literally always 0 in the log. The file doesn't exist on this BAT0
   (charge-based sysfs interface, no energy/time fields exposed);
   `read_int(TTE_FILE, 0)` returned the default for 15,384/15,384
   discharge ticks. Schema artifact, not a kernel reading. Dropped
   from log_tick. Removed TTE_FILE.

2. `eta_empty_s` was null on ALL 1551 ticks of 2026-05-21's main 2h09m
   discharge segment (12:21-14:30). `compute_eta_empty_s` bails when
   `raw_xif2_mah` is null, but the sibling widget code path falls back
   to `charge_full_design` in the same case. So during that segment
   autod logged nothing while the widget displayed a (fallback-pack-Wh)
   ETA. Asymmetry between predictor in autod and predictor in widget.
   Not yet fixed; surfaced for triage.

Schema changes:

- Added `read_upower()`: org.freedesktop.UPower.Device GetAll via gdbus,
  one subprocess per tick (~4ms). Parses State, EnergyRate, TimeToEmpty,
  TimeToFull with two regexes. Silently null on subprocess failure or
  property absence.
- New JSONL fields per tick: `upower_w` (EnergyRate W), 
  `upower_eta_empty_s` (TimeToEmpty s; only when State=Discharging and
  > 0), `upower_eta_full_s` (TimeToFull s; only when State=Charging and
  > 0). Logged silently for accuracy comparison; NOT shown in any widget.
  upower's "0 means not applicable" treated as null to match our
  None-when-undefined convention.

`bin/powertux-eta-compare`: focused report. Walks `log/*.jsonl{,.gz}`,
finds segments of contiguous `Discharging` and `Charging` (same gap +
MIN_SEGMENT_TICKS rules as eta-bench), drops open ones, and for each
closed segment computes the actual time-to-end at every tick and
compares the LOGGED `eta_empty_s`/`eta_full_s` (ours) and
`upower_eta_empty_s`/`upower_eta_full_s` (upower) against it. Per-
segment median-absolute-error table, aggregate stats with head-to-head
win count, and horizon breakdown. Stdlib only.

Differs from `powertux-eta-bench`: bench replays candidate algorithms
fresh from raw inputs to explore the design space; compare reads the
field that was ACTUALLY emitted at the time, so what it scores is what
the daemon actually told the world. Independent purposes, both kept.

First-run findings on 9 days of data (no upower overlap yet -- the new
schema started writing today at 16:32):

Discharge (25 closed segments, ours-only baseline):
- per-segment med abs error ranges 5-30 min on "good" segments
  (60min+ duration, stable load)
- balloons to 1-3h on short segments (<20min), where the 15-min
  rolling mean hadn't converged before the segment ended
- segment 11 (5.2min): med err 2h14m -- 25x the segment duration

Charge (46 closed segments, ours-only baseline):
- `eta_full_s` = `(charge_full - charge_now) / current_now`
- significantly worse than discharge: many segments show >1h median
  error against <1h actual durations
- root cause already known (devlog 2026-05-12 cap-vs-cells): EC re-
  anchors charge_now non-physically and suppresses current_now during
  trickle, so both the numerator and denominator are dirty

The upower/ours head-to-head will populate after enough closed
discharge and charge cycles land with the new schema. Re-run
`powertux-eta-compare` to refresh.

## 2026-05-21 - charge ETA: V*I rolling mean replaces kernel ABI

Built `bin/powertux-eta-backtest` to simulate two candidate fixes
against history before shipping anything:

- discharge `coldsupp-d`: suppress ETA for first 180s of segment.
  Result: med abs 33m10s -> 32m39s aggregate (1.5%), 100% ties on
  ticks where both predict. Not worth shipping.
- charge `rolling-c`: avg(v_bat * i_bat) over 15-min window of
  Charging ticks, divided by `full_wh * (100 - kernel_cap) / 100`.
  Result: med abs 36m52s -> 26m54s (27% better), p90 1h45m -> 1h14m,
  max 82h58m -> 2h53m (kills the outlier), mean signed +47m -> +24m,
  wins 75.9% head-to-head. Ship it.

Wired `rolling-c` into autod's `compute_eta_full_s` and the widget's
`charge_eta_seconds`. The two paths now mirror each other (autod
maintains a tick-by-tick `recent_w_chg` list; widget reads the log
tail). Kernel `cap` is used as SoC source during charge, not OCV
(cells run above OCV under charge current, OCV-derived SoC would
over-report by 5-10pp).

`compute_eta_full_s` signature changed: now takes
`(recent_w_chg, bat, cap, now)` instead of `(bat)`. Callers in
autod's main loop updated.

Re-run `powertux-eta-backtest` after the next few charge cycles to
confirm the deployed code reproduces the simulated numbers.

## 2026-05-21 - discharge ETA: tier-conditional baseline replaces rolling mean

Followup: extended `powertux-eta-backtest` with two more candidates,
backtested all four on the same 26 closed discharge segments.

| algo | med abs | p90 | max | vs baseline |
|---|---:|---:|---:|---:|
| baseline-d (rolling w_sys 15-min) | 33m10s | 3h28m | 6h52m | (current) |
| coldsupp-d (suppress first 180s) | 32m39s | 3h30m | 5h35m | +1.5% |
| **tier-d** (`rem_wh / TIER_W[tier]`) | **22m08s** | **1h36m** | **2h32m** | **+33%** |
| reg-d (numpy OLS, LOO-CV) | 24m57s | 1h50m | 3h36m | +25% |

Head-to-head: tier-d wins 66.9% of same-tick ticks against baseline-d;
reg-d 66.7%. tier-d also beats reg-d on every aggregate metric AND has
no training step / no numpy dep.

Rationale: within a tier the per-tick load swings (Claude agent runs,
build bursts, video playback) average out over the multi-hour discharge
timescale, so the 15-min rolling mean catches noise rather than signal.
The tier identity itself is the more stable predictor; updates only on
auto-shift or pin, which are the events that actually change the
forward-projection.

Wired tier-d into autod's `compute_eta_empty_s` (signature changed:
takes `(bat, current_tier)` instead of `(recent_w_sys, bat, now)`) and
into widget's `discharge_eta_seconds` (reads `current` from latest log
tick). `recent_w_sys` removed from autod main loop (unused after the
swap; still logged per tick as `w_sys` for future bench experiments).
Added a `charge_full` fallback for `raw_xif2_mah` so the 2026-05-21
"null full segment" failure mode can't recur silently.

TIER_W constants `{1:19, 2:25, 3:41, 4:64}` in both autod and widget;
documented as "update both at once after a recalibration run". From
`results/2026-05-12-000931-odm-calibration.json` and
`results/2026-05-11-232510-calibration.json`.

Open: rerun `powertux-eta-backtest` after another N closed segments to
verify the deployed code matches simulated numbers, and check whether
upower's predictor (now also being logged) beats or loses to tier-d.
If upower wins clearly, switch the widget to upower as the source and
retire `compute_eta_empty_s`; if tier-d wins, keep it as a clean local
predictor that's independent of the upower daemon.

## 2026-07-01 - 6-week data pass: chatter re-tune, ETA verdicts, savings now measured

50d01h wall-clock since the last tuning pass; 12d21h of actual autod ticks
(223k samples, 25.8% coverage -- the rest is laptop off/suspended, 82% on
AC). Enough closed cycles and auto-mode time to settle every "re-run after
N cycles" item left open on 2026-05-21.

### ETA: both open items closed, local predictors kept

Ran `powertux-eta-compare` (logged field vs actual) and re-ran
`powertux-eta-backtest` (candidate replay) over the full window.

- Deployed algos reproduce the simulated numbers. Discharge `tier-d`:
  26m31s median abs err over 58 closed segments vs baseline-d 43m45s
  (+39%, matches the +33% seen on the original 26-segment sample), wins
  71.2% head-to-head. Charge `rolling-c`: 25m55s vs baseline-c 34m33s
  (+25%), wins 72.0%. Both hold.
- ours vs upower (the "switch the widget to upower if it wins" question):
  ours wins both. Discharge is a blowout -- ours 30m52s vs upower 2h59m,
  96.4% head-to-head; upower's discharge predictor is unusable on this
  board (med rel 453%). Charge is a moderate win -- ours 24m51s vs 30m47s,
  68.5%; upower only edges ahead in the 30-60min horizon. Decision: keep
  tier-d and rolling-c as the local predictors, do NOT switch the widget to
  upower. Both open items closed.

### Chatter regressed to 47.9%; widened the L2/L3 band

The one real problem. Observed chatter climbed back to 47.9% (350/731
transitions reversed within 5min, 2.5/hr) vs the <25% target. Essentially
all of it is L2<->L3 (181 L3<->L3 + 159 L2<->L2 of 350). Root cause is
geometric: load1m spends 30.6% of the window inside [1.5, 2.5] -- exactly
the old hysteresis band -- so the deadband filtered nothing.

Backtested the fix options on the real auto dataset (reused `_simulate`
from powertux-analyze):

| variant                        | trans/hr | chatter (sim) |
|---|---:|---:|
| prev (1.5/2.5, hold 20/20)     | 1.47     | 33.5%         |
| up-hold 20 -> 40               | 1.20     | 28.5%         |
| widen band 1.2/3.0             | 0.88     | 23.2%         |
| **widen 1.2/3.0 + up-hold 30** | **0.80** | **23.2%**     |
| load5m decision + widen        | 0.54     | 26.6%         |

Widening the deadband beats raising the hold, residency essentially
unchanged (L2 66 / L3 32). Caveat: the simulator reports 33.5% where the
daemon logs 47.9% (it omits the AC-edge reasserts and the load5m<8
downgrade guard), so it under-reads absolute chatter -- treat as
directional. Real post-fix chatter is likely ~33-37%, still the largest
single-lever drop available.

Shipped: `L2_TO_L3 2.5 -> 3.0`, `L3_TO_L2 1.5 -> 1.2`, `UPGRADE_HOLD_SEC
20 -> 30` in autod (`DOWNGRADE_HOLD_SEC` stays 20). Daemon restarted via
the symlink deploy (`systemctl --user restart`; no reinstall, no tccd
restart). Updated to stay honest: analyze whatif `current` variant (plus a
`prev` variant for the 1.5/2.5 policy), the threshold-sensitivity band, the
near-boundary literals, the recommendations engine (now points at load5m
as the next lever since band + hold are already widened), and the README
decision table. load5m for the L2/L3 decision is the reserved next move if
another 1-2 weeks still show chatter above target.

### Savings now measured, not estimated

`vs baseline` is 72.5% below the vendor counterfactual (obs 3113 Wh vs
11335 Wh), and it's now 97% measured w_pkg -- back in May this path was 0%
measured and read 16%. The observed side is honest RAPL; the baseline is
still an interpolated vendor-default counterfactual, so the magnitude leans
on that model, but the direction is solid. Per-tier measured package draw
(L1 4.5W / L2 7.3W / L3 14.1W / L4 15.5W mean) sits far below the
calibration ceilings {19,25,41,64} because those were 7z-load-saturated;
real usage (load1m p50 1.69) rarely saturates a tier.

### Battery: EC truth vs kernel ABI, cap-vs-cells reconfirmed

- EC-believed full 4400 mAh vs the kernel's 5200; 15.4% apparent wear; real
  cycle_count 11 -> 39 (+28 in window) while the kernel ABI still reports 0.
  The raw_xif1/2/raw_cycles telemetry added 2026-05-12 is doing its job.
  raw_xif2 (learned-full) wandered 4900 -> 3800 -> back to 4400 over the
  window (gauge re-learning).
- cap-vs-cells drift reconfirmed: +20.0% OCV-SoC over cap_th. But cap_th has
  been unused (null) since 2026-05-21 -- charging is now driven by the
  sibling charge-cap project's `charging_profile` abstraction (stationary
  97% / balanced 2% / high_capacity 1% of the window).

### Two minor drifts noted, not fixed

- L1 residency 0.6%: the machine suspends rather than idling into L1, so L1
  barely fires even with the lid-closed / backlight-0 trigger. Expected.
- `powertux-set` never writes `cpufreq/boost`, so L1's calibrated boost=0 is
  not applied; the drift detector flags boost=1 on 100% of L1 ticks (1389
  ticks). Benign -- platform_profile=low-power clamps frequency anyway (L1
  draws ~2-5W, MHz ~1150), so L1 is still a low-power state, just not via the
  boost knob. Fix later: either write boost=0 in the L1 branch of
  powertux-set, or relax the L1 drift expectation. Low priority at 0.6%.

### Note

Analyze has grown to 26 sections since this log last covered it (per-display
power attribution, per-tier thermal + fan PWM, EC wear gauge, environment
context). Those landed in git (fan PWM/temp telemetry, the `fans` /
`thermal` / `displays` / `environment` sections, the drift-detector pinned
fix) without their own devlog entries; this pass is the catch-up.

## 2026-07-01 - ETA v2: 3-way study, EWMA discharge + SoC-curve charge

Complaint was "discharge time isn't accurate." Built `bin/powertux-eta-3way`
(stdlib) to compare three predictors on the real logs across several slices:
default (waybar `{time}` = charge/current, instantaneous kernel ABI), current
(the widget's tier-W discharge + 15-min v*i rolling-mean charge), and a v2.
57 closed discharge segments, 138 charge segments.

### The visible defect was jitter, not bias

Discharge, Metric A (full ETA vs time-to-segment-end):

| predictor | med err | p90 err | med jit/5s | p90 jit/5s |
|---|---:|---:|---:|---:|
| default   | 126m | 359m | 19.7m | 127.4m |
| current   |  27m |  82m |  1.2m |   7.9m |
| v2 (current+EWMA) | 27m | 81m | 0.1m | 0.7m |

The number lurching ~8min between two 5s ticks (p90 jitter 7.9m) is what read
as "inaccurate." An EWMA (alpha 0.1, ~50s tc) on the emitted ETA crushes it
(p90 7.9m -> 0.7m) at zero accuracy cost. In the honest region (segments that
actually drained <=20%, ticks below 40% SoC) both current and v2 are 6m -- the
widget is accurate when it matters; the far-horizon 27m median is dominated by
the plug-in-truncation artifact (sessions end at plug-in, not empty).

Two v2 ideas were tested and REJECTED by the data:
- Sag-correcting voltage (v + iR, R fit 0.32 ohm) + a measured per-tier system
  divisor (L2=20W vs TIER_W 25W): made accuracy worse (61m; honest region 37m
  vs 6m). Metric B (divisor-only) showed the per-tier median draw predicts
  drain time worse than TIER_W, because the median is dragged down by long
  idle-at-L2 stretches that never drain; the sessions that reach empty are the
  high-load ones. Correct-looking physics, wrong constant for the job.

### Charge is the mirror image: model it, don't smooth it

Charge power is a repeatable, SoC-dependent CC-CV curve set by the EC (median
v*i by decile: ~32W to 79%, then 17W @80s, 11W @90s), not exogenous user load.
So the SoC-conditioned curve wins where the flat rolling mean fails -- near
full, where the mean keeps applying CC-stage watts after the current tapered:

- taper region (cap>=70%, segments reaching full): v2 curve 4m vs current 10m
- p90 tail 121m -> 85m; 1h+ horizon 28m -> 17m
- slightly worse overall median (24 -> 29m) on short top-ups that get unplugged
  before full -- cases nobody watches.

EWMA buys nothing on charge (rolling-c is already smooth). A charger-adaptive
hybrid (scale the curve by recent actual v*i) was tested and REJECTED (41m,
p90 235m -- the global scale amplifies noise). The static curve is robust
anyway: the stationary profile (97% of charging) rate-limits at the EC, so
charge power is charger-independent. Re-derive the curve if a faster default
profile is adopted.

The asymmetry is the whole point: discharge power is exogenous (your load) so
you can only smooth it; charge power is endogenous (the charger's CC-CV
program) so you can model it.

### Deployed

autod is now the single ETA predictor; the widget just displays its logged
value (`eta_empty_s` / `eta_full_s`) with an unsmoothed local fallback if autod
is stale/down. Removes the duplicated predictor the two had been maintaining in
parallel.

- autod: `compute_eta_empty_s` unchanged (raw tier-W) but the main loop now
  EWMA-smooths it (`ETA_EMPTY_EWMA_ALPHA=0.1`, reset between sessions and across
  >3-tick gaps so it never smooths over a suspend). `compute_eta_full_s`
  rewritten to integrate remaining Wh over `CHG_W_CURVE` (drops the
  `recent_w_chg` rolling window). Logged `eta_empty_s`/`eta_full_s` are now the
  smoothed/curve values (what the widget shows).
- widget `battery-soc`: `read_logged_eta()` reads autod's latest fresh tick;
  local `discharge_eta_seconds`/`charge_eta_seconds` kept only as fallback.
- waybar: discovered the stock `battery` module (the "default", crude
  `{time}`) was defined but placed in no bar -- the custom `battery-soc` was
  already the only battery display. Removed the dead stock block.
- New tool `bin/powertux-eta-3way` (referenced above); reproduces the numbers.

Open: verify live once on battery -- the widget rendered correctly at Full
(`--`), and the predictors unit-tested sane, but a real discharge/charge cycle
under the new autod hasn't been observed yet. Re-run `powertux-eta-3way` after
a few cycles to confirm deployed output matches the backtest.
