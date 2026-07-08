# Battery threshold notifications — design

Date: 2026-07-08
Status: approved (pending spec review)
Component: `bin/powertux-autod`

## Goal

Desktop notifications when the battery is running low, triggered by **either**
battery percentage or estimated time-to-empty crossing a threshold. Three
escalating rungs. At the lowest rung, additionally pin the machine to the
silent power tier (L1) to stretch remaining runtime.

## Approach

**A. Inline in `powertux-autod`.** The daemon's 5s poll loop already reads
`cap` (capacity %) and `bat["status"]`, and computes the EWMA-smoothed
discharge ETA `eta_empty_s`, all in scope by the time `log_tick(...)` runs
(main loop, `bin/powertux-autod:1176-1222`). A small edge-triggered alert
check is added immediately after that call. No new process, no new
dependency, no install/systemd/sudoers change. Deploy = restart the user
service.

Rejected: a separate alert daemon (extra service + duplicated battery reads
for no gain) and generic tools like `batsignal`/upower low-battery (cannot
express the ETA trigger or the "pin to L1" action).

## Trigger

Evaluated every tick, but only when `bat["status"] == "Discharging"`.
Severity is the **max** of a percent rung and a time rung:

| Rung | ordinal | Percent (`cap`) | Time (`eta_empty_s`) | Urgency |
|------|---------|-----------------|----------------------|---------|
| warn  | 1 | `<= 20`  | `<= 1800` (30 min) | normal |
| crit  | 2 | `<= 10`  | `<= 900` (15 min)  | normal, `expire=0` (stays until dismissed) |
| emerg | 3 | `<= 5`   | (percent only)     | critical (bypasses do-not-disturb) |

- The time dimension contributes only when `eta_empty_s is not None`. It is
  `None` during discharge warmup and across suspend/wake gaps (existing EWMA
  reset logic), so those ticks fall back to percent-only. Percent is always
  available (`read_int(CAP_FILE, 100)`).
- All six thresholds plus the urgencies and the emergency pin level are
  top-of-file constants (see Config), retunable without touching logic.

## Edge-triggering and re-arm

Two pieces of per-run loop state, initialized alongside `last_ac` /
`last_applied` in `main()` (`bin/powertux-autod:1052-1063`):

- `last_alert_level` (int, starts 0)
- `emerg_pinned` (bool, starts False)

Rules each tick:

1. `level = alert_level(cap, eta_empty_s, status)`.
2. **Re-arm** first: if `alert_rearm(level, cap, status)` is true, set
   `last_alert_level = 0` and `emerg_pinned = False`. Re-arm condition:
   `status != "Discharging"` **or** (`level == 0` **and** `cap >
   ALERT_REARM_PCT`), where `ALERT_REARM_PCT = 23` (warn 20 + 3 margin).
3. **Notify** only on escalation: if `level > last_alert_level`, send the
   notification for `level`, then set `last_alert_level = level`.
4. **Emergency pin**: if `level == 3` and not `emerg_pinned`, run the pin
   action, then set `emerg_pinned = True`.

The `level == 0` guard on the re-arm is load-bearing: the percent margin
alone is wrong because the ETA dimension can trigger *above* 23% (e.g. 24%
under heavy load with ETA < 30 min). Re-arming purely on `cap > 23` there
would reset the latch every tick and re-fire the warn every 5s. Requiring
`level == 0` means re-arm happens only when nothing is currently tripping,
so an active ETA alert at 24% latches and stays silent after its one popup;
it re-arms once the (heavily smoothed, ~3 min time constant) ETA recovers.

Result: at most one notification per rung per discharge session. Because
notifications fire only on *increase* and re-arm needs both `level == 0` and
`cap > 23` while discharging (or any non-discharging status), a value
oscillating on the 20% boundary does not re-fire. A fast multi-rung drop in
one tick (e.g. across a suspend gap) fires a single popup at the current
severity rather than one per skipped rung.

## Emergency pin action

On first entry to rung 3 (chosen behavior: "notify + pin to low, so we can
unpin should we want to, letting auto mode drive it"):

1. `apply_level(ALERT_EMERG_PIN_LEVEL)` (= L1). This runs
   `sudo powertux-set 1` and signals waybar, exactly as the daemon's own tier
   applies do.
2. Write `{"mode":"pinned","level":1}\n` to `STATE_FILE` atomically
   (temp file + `os.replace`), matching `powertux-mode`'s `write_pinned`.
3. Set `last_applied = 1` so the next tick's pinned-mode-change handler
   (`bin/powertux-autod:1080-1086`, which assumes the setter already applied
   the level) stays consistent and does not phantom-reapply.

Why both apply **and** write state: the pinned-mode branch in the loop
assumes whoever set the pin already called `powertux-set` (that is what
`powertux-mode` does). Writing `state.json` alone would flip the widget to
"pinned L1" without changing hardware. So the action mirrors `powertux-mode
pinned 1`: apply, then persist.

The pin is deliberately sticky: after replug the daemon stays pinned at L1
until the user unpins (`powertux-mode auto`, waybar middle-click). Firing
once per session (`emerg_pinned`) means a manual unpin at 4% is respected and
not re-forced on the next tick.

## Notification delivery

`notify-send` (libnotify 0.8.8, installed at `/usr/sbin/notify-send`) to the
running swaync daemon over `org.freedesktop.Notifications`.

- App name `powertux` (`-a powertux`).
- Replace tag: `-h string:x-canonical-private-synchronous:powertux-battery`
  so each new rung replaces the previous popup in place (swaync + dunst both
  honor this) instead of stacking stale battery notifications.
- Urgency per the table (`-u normal` / `-u critical`); crit and emerg use
  `-t 0` (no expire).
- Summary/body scale to what is known:
  - both known: `Battery critical` / `10% - about 14 min left`
  - percent only: `Battery critical` / `10% remaining`
- Icon: `battery-caution-symbolic` (warn/crit), `battery-empty-symbolic`
  (emerg). Icon names depend on the theme; a missing icon degrades silently.
- Delivery is `subprocess.run(cmd, timeout=5, check=False, ...)` wrapped in
  `try/except Exception` so a notify failure logs and is swallowed, never
  breaking the poll loop (matches the daemon's defensive `try/except` style).

**Environment fix (integration risk).** A `systemd --user` service may lack
`DBUS_SESSION_BUS_ADDRESS` in its environment, which `notify-send` needs to
reach the session bus. `send_battery_alert` passes an env copy; if that
variable is absent it is set to `unix:path=${XDG_RUNTIME_DIR}/bus` (falling
back to `/run/user/<uid>/bus`). This is the one thing verified live before
the feature is called done.

## Code shape

Isolated, testable units:

- `alert_level(cap, eta_empty_s, status) -> int` (0..3) — **pure**. Returns 0
  unless `status == "Discharging"`; else `max(pct_rung, eta_rung)` where
  `eta_rung` is 0 when `eta_empty_s is None`.
- `alert_rearm(level, cap, status) -> bool` — **pure**. True when
  `status != "Discharging"` or (`level == 0` and `cap > ALERT_REARM_PCT`).
- `send_battery_alert(level, cap, eta_empty_s)` — builds the `notify-send`
  argv and shells out (side-effecting, thin).
- `pin_emergency_level()` — apply L1 + atomic `state.json` write (side-effecting, thin).

The two pure functions carry all the branching logic and are unit-tested.

## Telemetry

Add `"alert_level": last_alert_level` to each JSONL tick record
(`bin/powertux-autod:1176-1222`), written after the tick's alert evaluation so
the logged value reflects the current rung. Additive; existing readers
(`powertux-analyze`, `powertux-eta-*`) key on specific fields and ignore
extras. `METRICS.md` gets a one-line entry for the new field.

## Config (new constants, top of `bin/powertux-autod`)

```python
# Low-battery alerts (desktop notifications via notify-send -> swaync).
ALERT_PCT_WARN   = 20     # rung 1
ALERT_PCT_CRIT   = 10     # rung 2
ALERT_PCT_EMERG  = 5      # rung 3
ALERT_ETA_WARN_S = 1800   # 30 min -> rung 1
ALERT_ETA_CRIT_S = 900    # 15 min -> rung 2  (no ETA rung for emerg)
ALERT_REARM_PCT  = 23     # re-arm once cap climbs back above this
ALERT_EMERG_PIN_LEVEL = 1 # tier to pin at emerg (L1 silent, ~19W)
ALERT_APP_NAME   = "powertux"
ALERT_TAG        = "powertux-battery"
```

## Testing

- New `tests/test_alerts.py`, stdlib `unittest`. Loads `bin/powertux-autod`
  via `importlib` + `SourceFileLoader` (the file has no `.py` extension;
  module top level is constants + defs only, `main()` is under
  `if __name__ == "__main__"`, so import has no side effects). Run:
  `python3 -m unittest tests/test_alerts.py`.
- Cases: percent rungs at boundaries; ETA rungs; both-dim max wins; not
  discharging -> 0; `eta_empty_s is None` -> percent-only; escalate-only (no
  re-notify at same level); re-arm on charge; re-arm on climb above 23%;
  **ETA alert above 23% does not re-arm / does not spam** (the bug the
  `level == 0` guard fixes); emerg fires the pin exactly once per session.
- Live verification: temporarily raise `ALERT_PCT_WARN` above the current SoC,
  restart the service, confirm the swaync popup appears and the journal logs
  the alert, then revert. Confirms the notify-send path and the service's
  D-Bus environment end to end.

## Deploy

`systemctl --user restart powertux-autod`. Nothing else: the daemon runs from
a symlink to the repo, `notify-send` is already installed, and no
install.sh / systemd unit / sudoers change is required.

## Out of scope

- Charge-side notifications (full / charge-cap reached) — discharge only per request.
- Waybar widget colour changes on low battery.
- Sound on critical.
- A config file for the thresholds (they stay source constants, matching the
  existing `ETA_*` / tier tunables).
