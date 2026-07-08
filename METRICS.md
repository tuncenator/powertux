# powertux metrics guide

Every field that `powertux-autod` writes to `~/Programs/powertux/log/<date>.jsonl`,
what it measures, and whether it can be trusted on this board (TUXEDO
InfinityBook Pro 14 Gen10 AMD, `XxKK4NAx_XxSP4NAx`, BIOS `N.1.20A13`,
kernel 6.18 series, patched tuxedo-drivers with charge-cap fix).

Two record types share the daily JSONL:

- **Startup record** (one per daemon start, marker `"meta": true`) -- static
  hardware/kernel/board identity.
- **Tick record** (one per 5s, no `meta` key) -- the live telemetry.

`powertux-analyze` filters between the two and surfaces each in its own
section.

---

## Startup record fields

| field | source | unit | what it is | trust |
|---|---|---|---|---|
| `t` | system clock | ISO datetime | record timestamp | OK |
| `meta` | (constant `true`) | bool | marks the record as metadata, not a tick | OK |
| `host` | `platform.node()` | str | hostname | OK |
| `kernel` | `platform.release()` | str | running kernel version | OK |
| `cpu_model` | `/proc/cpuinfo` `model name` | str | CPU model string | OK |
| `dmi_product_name` | `/sys/devices/virtual/dmi/id/product_name` | str | chassis name from DMI | OK |
| `dmi_board_name` | `/sys/devices/virtual/dmi/id/board_name` | str | motherboard ID from DMI | OK |
| `dmi_sys_vendor` | `/sys/devices/virtual/dmi/id/sys_vendor` | str | vendor from DMI | OK |
| `dmi_bios_version` | `/sys/devices/virtual/dmi/id/bios_version` | str | BIOS version from DMI | OK |
| `charge_full_design` | `BAT0/charge_full_design` | µAh | factory design capacity | OK (matches `raw_xif1_mah * 1000`) |
| `voltage_min_design` | `BAT0/voltage_min_design` | µV | design empty-cutoff voltage | OK |
| `battery_model` | `BAT0/model_name` | str | battery part identifier | OK |

These let cross-machine analysis correlate anomalies with hardware
identity, and detect when something changed across boots (BIOS update,
kernel upgrade, battery replacement).

---

## Tick record fields

### Time and daemon mode

| field | source | unit | what it is | trust |
|---|---|---|---|---|
| `t` | system clock | ISO datetime | tick timestamp | OK |
| `mode` | `~/.config/powertux/state.json` | "auto" / "pinned" | daemon's current operating mode | OK |

### CPU load

| field | source | unit | what it is | trust |
|---|---|---|---|---|
| `load1m` | `/proc/loadavg`[0] | runnable-tasks-EWMA | 1-minute load average | OK |
| `load5m` | `/proc/loadavg`[1] | runnable-tasks-EWMA | 5-minute load average | OK |
| `load15m` | `/proc/loadavg`[2] | runnable-tasks-EWMA | 15-minute load average | OK |

Used by `compute_target()` to pick a tier. EWMA smoothing means brief
spikes (a few hundred ms of activity) move `load1m` by ~0.05-0.2; only
sustained activity crosses thresholds.

### Power source state

| field | source | unit | what it is | trust |
|---|---|---|---|---|
| `ac` | `AC0/online` | 0 or 1 | 1 = AC adapter connected | OK |

### Battery state from kernel ABI (some fields LIE on this board)

| field | source | unit | what it is | trust on this board |
|---|---|---|---|---|
| `cap` | `BAT0/capacity` | % (0-100) | kernel's coulomb-counter percentage | **PARTIAL** -- gets pinned during cap-hold (counter doesn't increment while `current_now=0`) and stays at last-known when BAT0 detaches |
| `cap_th` | `BAT0/charge_control_end_threshold` | % (0-100) | active charge limit; charging stops when capacity reaches this | OK (when BAT0 is attached; null when detached, EC retains value internally only across detach) |
| `tte_s` | `BAT0/time_to_empty_now` | seconds | kernel-estimated time to empty | unreliable since it depends on `current_now` |
| `status` | `BAT0/status` | str | one of Charging / Discharging / Not charging / Full / Unknown | OK (this one is honest) |
| `charge_now` | `BAT0/charge_now` | µAh | coulomb counter; what the kernel believes is currently in the pack | partial: snaps without current flow when EC re-anchors (e.g. 2026-05-12: 80% -> 96% jump on cap removal) |
| `charge_full` | `BAT0/charge_full` | µAh | kernel's "full" reference | **LIES** -- always equals `charge_full_design` on this board; use `raw_xif2_mah` for truth |
| `cycle_count` | `BAT0/cycle_count` | int | kernel's cycle count | **LIES** -- always 0 on this board; use `raw_cycles` for truth |
| `i_bat` | `BAT0/current_now` | A | instantaneous battery current; sign per ACPI | **PARTIAL** -- ACPI rate reporting was disabled at firmware level; reads 0 when not actively discharging, even during trickle-charge maintenance |
| `v_bat` | `BAT0/voltage_now` | V | pack terminal voltage | **OK** -- the load-bearing honest signal on this board; OCV-curve gives true SoC at rest |
| `w_sys` | computed `v_bat * i_bat` | W | full-system instantaneous draw | inherits `i_bat`'s problems: only non-null during measurable discharge |

### Battery state from raw_* paths (EC truth)

These come from sysfs entries exposed by the patched `tuxedo-drivers`
module (`raw_cycle_count_show`, `raw_xif1_show`, `raw_xif2_show` in
`uniwill_keyboard.h`). They read EC RAM directly at offsets
`0x0400-0x0405` and bypass the broken kernel ABI translation.

| field | source | unit | what it is | trust |
|---|---|---|---|---|
| `raw_cycles` | `BAT0/raw_cycle_count` | int | EC's actual cycle counter | **OK** -- the truth on this board |
| `raw_xif1_mah` | `BAT0/raw_xif1` | mAh | reads EC RAM at offset 0x0402; matches design capacity (5200 mAh on this board) and matches both kernel `charge_full_design` and ACPI `_BIF.DesignCapacity`. | OK |
| `raw_xif2_mah` | `BAT0/raw_xif2` | mAh | reads EC RAM at offset 0x0405. Originally interpreted as `_BIF.LastFullChargeCapacity` per DSDT analysis; that interpretation is now in doubt. | **DO NOT USE FOR WEAR ESTIMATION**, see below. |

`raw_xif2` cross-check (2026-05-12): ACPI's own `_BIF` (via `acpi -i`)
returns `last_full_capacity = 5200 mAh = design` (no wear). The kernel
ABI `charge_full` returns the same. But `raw_xif2` reads 4600 mAh after
a fresh discharge-to-balanced-full cycle, having dropped from a prior
4900 mAh reading. Three observations conflict with treating `raw_xif2`
as "EC's learned full capacity":

1. ACPI's `_BIF` and the patched driver's `raw_xif2` disagree by 600 mAh,
   even though `raw_xif1` (also from the same EC region) matches ACPI.
2. `raw_xif2` went *down* (4900 -> 4600) after a fresh full-charge cycle.
   A gauge that had been underestimating should go *up* after a clean
   full anchor, not down.
3. The "5.8% wear" claim we made on 2026-05-12 morning, and amplified to
   "11.5% wear" after this evening's cycle, contradicts every other tool
   on the system reporting zero wear.

Likely explanation: `raw_xif2` reads something other than `_BIF[2]` on
this board (an EC working estimate, a stationary-profile-specific
anchor, or an encoded value we haven't decoded). The DSDT-to-EC-RAM
mapping for this field needs to be re-verified before relying on it.

For now: **use `charge_full` or ACPI `_BIF` for wear estimation**, both
of which are conservative on this board (always equal to design) but at
least agree with standard tooling. If you need a real wear measurement,
the only honest path is a real capacity test: full discharge under
known load, integrate w_sys over time, divide by nominal voltage,
compare against design.

### Power consumed

| field | source | unit | what it is | trust |
|---|---|---|---|---|
| `w_pkg` | RAPL `intel-rapl:0/energy_uj` delta | W | CPU package average power over the tick interval | OK (null on first tick; needs prev reading for Δ). Available because install.sh ships an `/etc/tmpfiles.d/powertux.conf` setting `energy_uj` to mode 0444. |

### Tier decision (autod state)

| field | source | unit | what it is | trust |
|---|---|---|---|---|
| `current` | autod internal | 1..4 / null | the tier autod last successfully applied | OK (kept consistent with tccd via verify-each-tick; null until first apply) |
| `target` | `compute_target()` | 1..4 | the tier the decision table picks for this tick's inputs | OK |
| `pending` | autod internal | 1..4 / null | the tier queued behind a hold timer (upgrade 5s or downgrade 30s); null when not pending | OK |

### Platform writers (sanity check for competing power managers)

| field | source | unit | what it is | trust |
|---|---|---|---|---|
| `pp` | `/sys/firmware/acpi/platform_profile` | str | current platform_profile (e.g. "low-power", "performance") | OK; compare to what powertux-set wrote |
| `epp` | `cpu0/cpufreq/energy_performance_preference` | str | current EPP (e.g. "power", "balance_performance", "performance") | OK |
| `boost` | `/sys/devices/system/cpu/cpufreq/boost` | 0 or 1 | cpufreq boost enable | OK |
| `tccd_id` | busctl `GetActiveProfileJSON` -> id | str | tccd's active profile id (e.g. "powertux-quiet") | OK |
| `charging_profile` | `/sys/devices/platform/tuxedo_keyboard/charging_profile/charging_profile` | str | one of `stationary` / `balanced` / `high_capacity`; controls CV plateau height, charging current rate, and auto-detach trigger on this board. Independent of `tccd_id` (which is the powertux performance tier). | OK |
| `fan1_pwm_pct` | ioctl `R_UW_FANSPEED` on `/dev/tuxedo_io` -> EC[0x1804] | float 0-100 | CPU-fan PWM duty cycle (NOT RPM; the EC does not expose tach on this board family). Raw EC byte scaled by `NB02_FAN_SPEED_MAX=200`. | OK; null when daemon couldn't open `/dev/tuxedo_io` (group `tuxedo-io` not granted, non-TUXEDO chassis, or `tuxedo_io` module not loaded) |
| `fan2_pwm_pct` | ioctl `R_UW_FANSPEED2` -> EC[0x1809] | float 0-100 | GPU-fan PWM duty (or mirror of fan1 on single-fan chassis). | OK |
| `fan1_temp_c` | ioctl `R_UW_FAN_TEMP` -> EC[0x043e] | int C | EC fan-sensor temp 1; tracks CPU heatsink region. Tends to track k10temp within a few degrees. | OK; null when sensor returns 0 (no sensor on this channel) or device unreadable |
| `fan2_temp_c` | ioctl `R_UW_FAN_TEMP2` -> EC[0x044f] | int C | EC fan-sensor temp 2; populated on dGPU chassis, returns 0 (-> null) on iGPU-only chassis. | OK |

`analyze` cross-checks each of these against the expected value for
`current`:

| tier | pp | epp | boost | tccd_id |
|---|---|---|---|---|
| L1 silent | `low-power` | `power` | 0 | `powertux-silent` |
| L2 quiet | `performance` | `balance_performance` | 1 | `powertux-quiet` |
| L3 balanced | `performance` | `balance_performance` | 1 | `powertux-balanced` |
| L4 perf | `performance` | `performance` | 1 | `powertux-perf` |

Any drift means another process is writing the same knobs (tlp, GNOME
power profiles, manual user edit) or tccd reverted its state.

### Performance

| field | source | unit | what it is | trust |
|---|---|---|---|---|
| `cpu_mhz` | mean of `cpu*/cpufreq/scaling_cur_freq` | MHz | average current frequency across all logical CPUs | OK (rounded to int) |

Expected mean MHz per tier from calibration:
- L1 silent: ~1940 (boost off, base-clamped)
- L2 quiet: ~2616 (ODM power_save, balance_perf EPP)
- L3 balanced: ~3126 (ODM enthusiast)
- L4 perf: ~3573 (ODM overboost)

These are *under load*; idle values are far lower (typically 1100-1500 MHz
on Strix Point regardless of tier).

### Thermal

| field | source | unit | what it is | trust |
|---|---|---|---|---|
| `cpu_temp_c` | k10temp hwmon, `temp1_input` | °C | Tctl (k10temp control-loop temperature) | OK |
| `gpu_temp_c` | amdgpu hwmon, `temp1_input` (edge) | °C | iGPU edge temperature | OK |

### Environment

| field | source | unit | what it is | trust |
|---|---|---|---|---|
| `brightness_pct` | `/sys/class/backlight/*/brightness` | % | panel backlight relative to its max | OK |
| `kbd_backlight_pct` | `/sys/class/leds/*kbd_backlight*/brightness` | % | keyboard backlight relative to its max | OK |
| `displays_ext` | `/sys/class/drm/card*-*/status` | int | count of connected non-internal, non-Writeback connectors | OK |
| `displays` | EDID parse of each connected non-internal connector | list[str] | sorted IDs like `"DP-2:GWD-1161-ARZOPA"` (connector, PNP vendor, product code, monitor name). Stable across attach/detach so analyze can attribute power per display. EDID parses are cached, refreshed only when the connector set changes. | OK |
| `pd_partner_max_w` | `/sys/class/typec/portN-partner/usb_power_delivery/sink-capabilities/*` | W | sum of nameplate sink-capability max W across every USB-PD partner that is currently sinking from the laptop. This is the *ceiling* of what bus-powered devices may draw; live draw is in `w_sys`. Null when no PD partner is sinking. | OK as ceiling |
| `lid` | `/proc/acpi/button/lid/*/state` | "open"/"closed" | ACPI lid switch state | OK |
| `charging_profile` | `/sys/devices/platform/tuxedo_keyboard/charging_profile/charging_profile` | str | one of `stationary` / `balanced` / `high_capacity` | OK |

### Fan telemetry

| field | source | unit | what it is | trust |
|---|---|---|---|---|
| `fan1_pwm_pct` | ioctl `R_UW_FANSPEED` on `/dev/tuxedo_io` -> EC[0x1804], scaled by `NB02_FAN_SPEED_MAX=200` | % 0-100 | CPU fan PWM duty. NOT RPM; the EC does not expose tach on this board family (Uniwill universal-EC-fan-control). | OK |
| `fan2_pwm_pct` | EC[0x1809] | % 0-100 | GPU fan PWM duty (dGPU models); mirrors fan1 or stays at 0 on single-fan chassis. | OK |
| `fan1_temp_c` | EC[0x043e] | int C | Fan-sensor temp near CPU heatsink. Tracks k10temp within a few degrees. | OK |
| `fan2_temp_c` | EC[0x044f] | int C | Fan-sensor temp near GPU heatsink. 0 -> null on iGPU-only chassis. | OK |

All four are null when the daemon could not open `/dev/tuxedo_io` (user
not yet in the `tuxedo-io` group, non-TUXEDO chassis, or kernel module
not loaded). Install.sh handles the group + udev rule; a relog is
required after first install for the systemd --user manager to pick up
the new group membership.

Per-display attribution: ticks are grouped by their `displays` set; the
mean `w_sys` of each group minus the no-external baseline gives an
empirical W cost per display set. Subtracting set-of-N vs set-of-N-1
isolates each display's contribution. Bus-powered displays (Arzopa
class) surface as the highest delta; self-powered ones (DELL, LG, etc.)
generally net near zero because their power comes from the wall, not
the laptop USB rail.

### ETA predictions

These are autod's per-tick estimates of remaining time. Logged so
`powertux-eta-bench` can compare predicted-at-time-T against actual
time-to-end and tune the algorithm from data.

| field | source | unit | what it is | trust |
|---|---|---|---|---|
| `eta_empty_s` | computed | seconds | predicted time until discharge ends, only set when `status == "Discharging"`. Rolling-mean `w_sys` over the last 900 s divided into OCV-derived remaining Wh (mAh from `raw_xif2_mah`, voltage from `v_bat`). Null if fewer than 6 discharge samples in the window, or inputs missing. | OK for the algorithm as written; calibration via `powertux-eta-bench` |
| `eta_full_s` | computed | seconds | predicted time until charge ends, only set when `status == "Charging"`. `(charge_full - charge_now) / current_now`. | partial: `current_now` is suppressed during the trickle tail on this board, so the late-charge prediction blows up. CC-stage prediction is reasonable. |
| `alert_level` | computed | 0..3 | low-battery notification rung at this tick: 0 none / 1 warn / 2 crit / 3 emerg. Max of a percent rung (`ALERT_PCT_*`) and a time rung (`ALERT_ETA_*` on `eta_empty_s`); 0 unless `status == "Discharging"`. Edge-triggered notify + emerg L1 pin are driven off this. | OK |

---

## Quick reference: "what should I trust right now?"

| question | answer field | not this |
|---|---|---|
| true state of charge | OCV-derived from `v_bat` | `cap` (lies during cap-hold) |
| battery wear | (no honest signal on this board; see above) | not `raw_xif2`, not `charge_full`. Both disagree with reality in different ways. |
| cycle count | `raw_cycles` | `cycle_count` (lies, always 0) |
| is the cap actually capping cells | `v_bat` per-cell vs Li-ion OCV curve | `cap` reading capped is necessary but not sufficient |
| how much power am I drawing | `w_pkg` for CPU, `w_sys` for full system (battery only) | calibrated `load_W` per tier (estimate, not measured) |
| am I actively charging | `status == "Charging"` and `i_bat > 0` | `current_now > 0` alone (it's suppressed below threshold) |

---

## Known limitations of this board

The findings below are observations on `XxKK4NAx_XxSP4NAx` with BIOS
`N.1.20A13`. Sister boards may share or differ; `_BIF` and EC offsets
should match across the Gen10 AMD lineup that ships
`tux_featureset_3_descriptor` per Wer-Wolf's uniwill-laptop.

1. **`current_now` is suppressed by firmware.** Reads 0 in most states
   even when current is flowing (especially during trickle/maintenance
   charge). Reads honestly during measurable discharge.
2. **`cycle_count` always returns 0 via standard ABI.** Use `raw_cycles`.
3. **`charge_full` always equals `charge_full_design`.** Use `raw_xif2_mah`.
4. **`charge_control_end_threshold` is volatile across reboot and AC
   re-engage.** Userspace must re-apply (handled by
   `tuxedo-charge-cap-re/`'s systemd services + sleep hook).
5. **The EC auto-detaches BAT0 at SoC=100 on AC.** All BAT0 sysfs paths
   vanish, kernel reports defaults. Recovery: unplug AC briefly.
6. **`charge_control_end_threshold` stops the charge controller but
   does not keep cells off the high-voltage plateau.** Sub-sensor-floor
   maintenance current lifts the cells to ~4.16 V/cell over hours even
   with cap=80 set. The actual SoC limit is much higher than the cap
   value suggests. Use `v_bat` to see the truth.

These limitations motivated the expanded telemetry surface here. Every
known kernel-ABI lie has a `raw_*` or `v_bat` counterpart logged
alongside, so post-hoc analysis can recover the truth.
