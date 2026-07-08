#!/usr/bin/env python3
"""Unit tests for the low-battery alert logic in bin/powertux-autod.

The daemon is a plain script (no .py extension), so load it as a module via
importlib. Its top level is only constants + function defs (main() is guarded
by __name__ == "__main__"), so importing has no side effects.

Run: python3 -m unittest tests.test_alerts   (from the repo root)
     python3 tests/test_alerts.py
"""
import importlib.util
import unittest
from importlib.machinery import SourceFileLoader
from pathlib import Path

_AUTOD = Path(__file__).resolve().parent.parent / "bin" / "powertux-autod"
_loader = SourceFileLoader("powertux_autod", str(_AUTOD))
_spec = importlib.util.spec_from_loader(_loader.name, _loader)
autod = importlib.util.module_from_spec(_spec)
_loader.exec_module(autod)

alert_level = autod.alert_level
alert_rearm = autod.alert_rearm
DISCHG = "Discharging"


class AlertLevel(unittest.TestCase):
    def test_not_discharging_is_zero(self):
        for status in ("Charging", "Full", "Not charging", "Unknown", None):
            self.assertEqual(alert_level(3, 10, status), 0, status)

    def test_none_cap_is_zero(self):
        self.assertEqual(alert_level(None, 60, DISCHG), 0)

    def test_percent_rungs_at_boundaries(self):
        self.assertEqual(alert_level(21, None, DISCHG), 0)   # above warn
        self.assertEqual(alert_level(20, None, DISCHG), 1)   # warn edge
        self.assertEqual(alert_level(11, None, DISCHG), 1)
        self.assertEqual(alert_level(10, None, DISCHG), 2)   # crit edge
        self.assertEqual(alert_level(6, None, DISCHG), 2)
        self.assertEqual(alert_level(5, None, DISCHG), 3)    # emerg edge
        self.assertEqual(alert_level(1, None, DISCHG), 3)

    def test_eta_rungs(self):
        # high SoC, ETA alone drives the rung
        self.assertEqual(alert_level(80, 1801, DISCHG), 0)   # just above warn eta
        self.assertEqual(alert_level(80, 1800, DISCHG), 1)   # warn eta edge
        self.assertEqual(alert_level(80, 901, DISCHG), 1)
        self.assertEqual(alert_level(80, 900, DISCHG), 2)    # crit eta edge
        self.assertEqual(alert_level(80, 60, DISCHG), 2)     # no emerg eta rung

    def test_eta_none_is_percent_only(self):
        self.assertEqual(alert_level(50, None, DISCHG), 0)
        self.assertEqual(alert_level(8, None, DISCHG), 2)

    def test_max_of_both_dimensions(self):
        # 24% (pct rung 0) but ETA 10min (crit) -> crit
        self.assertEqual(alert_level(24, 600, DISCHG), 2)
        # 8% (crit) with a comfortable ETA (rung 0) -> still crit
        self.assertEqual(alert_level(8, 5000, DISCHG), 2)
        # 4% (emerg) beats any eta rung
        self.assertEqual(alert_level(4, 600, DISCHG), 3)


class AlertRearm(unittest.TestCase):
    def test_rearms_when_not_discharging(self):
        for status in ("Charging", "Full", "Not charging"):
            self.assertTrue(alert_rearm(0, 5, status), status)
            self.assertTrue(alert_rearm(3, 5, status), status)

    def test_no_rearm_while_active(self):
        # a live alert (level > 0) never re-arms, even above the margin
        self.assertFalse(alert_rearm(1, 24, DISCHG))
        self.assertFalse(alert_rearm(2, 90, DISCHG))

    def test_no_rearm_below_margin(self):
        # nothing tripping but still low: hold the latch (kills 20% flap)
        self.assertFalse(alert_rearm(0, 23, DISCHG))
        self.assertFalse(alert_rearm(0, 21, DISCHG))

    def test_rearms_above_margin_when_clear(self):
        self.assertTrue(alert_rearm(0, 24, DISCHG))
        self.assertTrue(alert_rearm(0, 90, DISCHG))


class Sessions(unittest.TestCase):
    """Drive the loop's latch semantics over a synthetic tick stream."""

    def _run(self, ticks):
        """ticks: list of (cap, eta, status). Returns (notifies, pins) where
        notifies is the list of rungs that fired a popup and pins counts emerg
        pins. Mirrors the main-loop block exactly."""
        last_level = 0
        emerg_pinned = False
        notifies, pins = [], 0
        for cap, eta, status in ticks:
            lvl = alert_level(cap, eta, status)
            if alert_rearm(lvl, cap, status):
                last_level = 0
                emerg_pinned = False
            if lvl > last_level:
                notifies.append(lvl)
                last_level = lvl
            if lvl >= 3 and not emerg_pinned:
                pins += 1
                emerg_pinned = True
        return notifies, pins

    def test_escalate_only_no_repeat(self):
        # slow drain through all three rungs, each fires once
        ticks = [(25, None, DISCHG), (20, None, DISCHG), (18, None, DISCHG),
                 (10, None, DISCHG), (7, None, DISCHG), (5, None, DISCHG),
                 (3, None, DISCHG)]
        notifies, pins = self._run(ticks)
        self.assertEqual(notifies, [1, 2, 3])
        self.assertEqual(pins, 1)

    def test_boundary_flap_does_not_respam(self):
        ticks = [(20, None, DISCHG), (21, None, DISCHG), (20, None, DISCHG),
                 (21, None, DISCHG), (19, None, DISCHG)]
        notifies, _ = self._run(ticks)
        self.assertEqual(notifies, [1])  # warn once despite 20/21 dithering

    def test_eta_alert_above_margin_no_spam(self):
        # 24% under heavy load, ETA pinned under 15min for many ticks: crit
        # fires ONCE, does not re-fire even though cap (24) > rearm margin (23).
        ticks = [(24, 600, DISCHG)] * 10
        notifies, _ = self._run(ticks)
        self.assertEqual(notifies, [2])

    def test_recovery_rearms_for_next_session(self):
        # drop to warn, plug in (recover), unplug and drop again -> warn twice
        ticks = [(19, None, DISCHG), (15, None, "Charging"),
                 (80, None, "Charging"), (19, None, DISCHG)]
        notifies, _ = self._run(ticks)
        self.assertEqual(notifies, [1, 1])

    def test_climb_above_margin_rearms(self):
        # eta transient trips warn at 30%, then eta recovers -> re-arm, then a
        # real percent warn later fires again
        ticks = [(30, 1700, DISCHG), (30, 5000, DISCHG), (20, None, DISCHG)]
        notifies, _ = self._run(ticks)
        self.assertEqual(notifies, [1, 1])

    def test_emerg_pins_once_per_session(self):
        ticks = [(5, None, DISCHG)] * 5
        _, pins = self._run(ticks)
        self.assertEqual(pins, 1)


if __name__ == "__main__":
    unittest.main()
