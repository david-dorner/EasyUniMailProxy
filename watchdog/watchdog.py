#!/usr/bin/env python3
"""EasyUniMailProxy watchdog.

Black-box health monitor for the whole mail path. Every INTERVAL seconds it
opens the IMAPS port on the mailproxy (which relays through the VPN tunnel to the
real Exchange server) and checks for the `* OK ...` IMAP greeting. That single
check exercises the entire chain - VPN tunnel, routing, the passthrough relay,
and upstream reachability - so any breakage trips it.

It runs in its OWN network namespace (not the vpn container's), so it stays alive
to alert even if the vpn container itself is down, and it reaches ntfy over the
normal internet (not the tunnel), so alerts arrive precisely when the VPN is
broken. State transitions (DOWN / RECOVERED) are pushed to ntfy; steady state is
silent (no "still fine" spam).

Statistics
----------
Alongside alerting, the watchdog keeps durable, space-bounded statistics so you
can answer "what is my real uptime, and what did each outage look like":

  * While healthy it probes every INTERVAL. The moment a probe fails it switches
    to FAIL_INTERVAL (a few seconds) so an outage's start, shape, and recovery
    are timed precisely - which is what makes a ~1s reconnect measurable - then
    returns to INTERVAL once healthy again.
  * EVERY failure streak is recorded as an outage record (even a single missed
    probe that never crossed the alert threshold), with its probe-by-probe trace
    and the error(s) seen. Alerts still only fire on a sustained streak, so the
    data captures blips without the notifications becoming noisy.
  * Uptime is accumulated losslessly as up/down seconds per calendar day, so
    24h / 7d / 30d / all-time percentages are exact without storing every probe.

Files under STATS_DIR (default /data), all bounded:
  state.json    current snapshot + lifetime counters (rewritten each probe)
  daily.json    one row per day (up/down/monitored seconds, counts); pruned to
                MAX_DAYS rows -> at most a few tens of KB
  outages.jsonl one line per finished outage (shape + cause); pruned to
                MAX_OUTAGES lines. Outages are rare, so this stays tiny.
Total footprint is well under a couple of MB even after years - it never grows
without bound.

Config (environment):
  WATCHDOG_TARGET_HOST     host to probe (default "vpn" - the compose service)
  WATCHDOG_TARGET_PORT     IMAPS port (default 993)
  WATCHDOG_INTERVAL        seconds between checks while healthy (default 60)
  WATCHDOG_FAIL_INTERVAL   seconds between checks during a failure (default 5)
  WATCHDOG_FAIL_THRESHOLD  consecutive failures before a DOWN alert (default 3)
  WATCHDOG_START_GRACE     seconds to reach first-healthy before warning (default 300)
  WATCHDOG_STATS_DIR       where to persist statistics (default /data)
  WATCHDOG_MAX_DAYS        daily rows to keep (default 400)
  WATCHDOG_MAX_OUTAGES     outage lines to keep (default 2000)
  WATCHDOG_MAX_SAMPLES     probe samples stored per outage's shape (default 600)
  WATCHDOG_LOG_SUMMARY_EVERY  log an uptime summary this often, seconds; 0 off (default 3600)
  WATCHDOG_DAILY_SUMMARY   1 = also push a once-a-day uptime digest to ntfy (default 0)
  NTFY_URL                 ntfy topic URL (required for alerts; else logs only)
  NTFY_TOKEN               optional bearer token for reserved/self-hosted topics
"""
from __future__ import annotations

import json
import os
import socket
import ssl
import sys
import time
import urllib.request
from datetime import datetime, timedelta, timezone

TARGET_HOST = os.environ.get("WATCHDOG_TARGET_HOST", "vpn")
TARGET_PORT = int(os.environ.get("WATCHDOG_TARGET_PORT", "993"))
INTERVAL = int(os.environ.get("WATCHDOG_INTERVAL", "60"))
FAIL_INTERVAL = int(os.environ.get("WATCHDOG_FAIL_INTERVAL", "5"))
FAIL_THRESHOLD = int(os.environ.get("WATCHDOG_FAIL_THRESHOLD", "3"))
START_GRACE = int(os.environ.get("WATCHDOG_START_GRACE", "300"))
STATS_DIR = os.environ.get("WATCHDOG_STATS_DIR", "/data")
MAX_DAYS = int(os.environ.get("WATCHDOG_MAX_DAYS", "400"))
MAX_OUTAGES = int(os.environ.get("WATCHDOG_MAX_OUTAGES", "2000"))
MAX_SAMPLES = int(os.environ.get("WATCHDOG_MAX_SAMPLES", "600"))
LOG_SUMMARY_EVERY = int(os.environ.get("WATCHDOG_LOG_SUMMARY_EVERY", "3600"))
DAILY_SUMMARY = os.environ.get("WATCHDOG_DAILY_SUMMARY", "0").strip() == "1"
NTFY_URL = os.environ.get("NTFY_URL", "").strip()
NTFY_TOKEN = os.environ.get("NTFY_TOKEN", "").strip()

STATE_FILE = os.path.join(STATS_DIR, "state.json")
DAILY_FILE = os.path.join(STATS_DIR, "daily.json")
OUTAGES_FILE = os.path.join(STATS_DIR, "outages.jsonl")

# The relay is a raw passthrough, so the cert on 993 is the university's - we
# only test reachability + the IMAP greeting, not identity, so verification off.
_TLS = ssl._create_unverified_context()


def log(msg: str):
    print(f"[watchdog] {time.strftime('%Y-%m-%d %H:%M:%S')} {msg}", flush=True)


def now() -> float:
    return time.time()


def day_key(ts: float) -> str:
    return datetime.fromtimestamp(ts, timezone.utc).strftime("%Y-%m-%d")


def iso(ts: float) -> str:
    return datetime.fromtimestamp(ts, timezone.utc).strftime("%Y-%m-%d %H:%M:%SZ")


def fmt_dur(seconds: float) -> str:
    """Human-compact duration: 45s, 3m12s, 1h04m."""
    s = int(round(seconds))
    if s < 60:
        return f"{s}s"
    if s < 3600:
        return f"{s // 60}m{s % 60:02d}s"
    return f"{s // 3600}h{(s % 3600) // 60:02d}m"


def probe() -> tuple[bool, str, float]:
    """Return (healthy, detail, latency_ms). Healthy = IMAP greeting through the path."""
    t0 = time.monotonic()
    try:
        with socket.create_connection((TARGET_HOST, TARGET_PORT), timeout=10) as raw:
            with _TLS.wrap_socket(raw, server_hostname="email.uni-graz.at") as s:
                s.settimeout(8)
                banner = s.recv(64)
        latency = (time.monotonic() - t0) * 1000.0
        if banner.startswith(b"* OK"):
            return True, banner.decode(errors="replace").strip(), latency
        return False, f"unexpected greeting: {banner!r}", latency
    except Exception as exc:  # noqa: BLE001 - any failure = path unhealthy
        latency = (time.monotonic() - t0) * 1000.0
        return False, f"{type(exc).__name__}: {exc}", latency


def notify(title: str, message: str, priority: str, tags: str):
    log(f"ALERT [{priority}] {title} - {message}")
    if not NTFY_URL:
        log("NTFY_URL not set; alert logged only.")
        return
    headers = {
        "Title": title.encode("utf-8"),
        "Priority": priority,
        "Tags": tags,
    }
    if NTFY_TOKEN:
        headers["Authorization"] = f"Bearer {NTFY_TOKEN}"
    try:
        req = urllib.request.Request(NTFY_URL, data=message.encode("utf-8"), headers=headers)
        with urllib.request.urlopen(req, timeout=15) as resp:
            resp.read()
    except Exception as exc:  # noqa: BLE001
        log(f"failed to send ntfy alert: {exc}")


def _write_atomic(path: str, text: str):
    """Write via a temp file + rename so a crash never leaves a half-written file."""
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.replace(tmp, path)


class Stats:
    """Durable, space-bounded uptime + outage statistics."""

    def __init__(self):
        # Interval attributed to a single probe is capped so a watchdog restart
        # (a long gap between the pre-restart probe and the first one after)
        # cannot dump a huge block of time into up/down. The excess is simply
        # left unmonitored rather than guessed.
        self.attribute_cap = max(2 * INTERVAL, 120)

        self.lifetime = {
            "first_seen": None, "monitored_s": 0.0, "up_s": 0.0, "down_s": 0.0,
            "probes_ok": 0, "probes_fail": 0, "outages": 0, "alerted_outages": 0,
        }
        self.daily: dict[str, dict] = {}
        self.boot_count = 0
        self.started_at = now()
        self.last_probe_at: float | None = None
        self.last_healthy: bool | None = None   # state DURING the interval that just ended
        self.current_outage: dict | None = None
        self.last_outage: dict | None = None

        self._load()
        self.boot_count += 1
        os.makedirs(STATS_DIR, exist_ok=True)

    # ---- persistence -------------------------------------------------------
    def _load(self):
        try:
            with open(STATE_FILE, encoding="utf-8") as fh:
                st = json.load(fh)
            self.lifetime.update(st.get("lifetime", {}))
            self.boot_count = st.get("boot_count", 0)
            self.last_probe_at = st.get("last_probe_at")
            self.last_healthy = st.get("healthy")
            self.current_outage = st.get("current_outage")
            self.last_outage = st.get("last_outage")
            log(f"loaded stats: {self._uptime_line()}")
        except FileNotFoundError:
            log("no prior stats; starting fresh.")
        except Exception as exc:  # noqa: BLE001 - never let bad state stop monitoring
            log(f"could not load stats ({exc}); starting fresh.")
        try:
            with open(DAILY_FILE, encoding="utf-8") as fh:
                self.daily = json.load(fh)
        except FileNotFoundError:
            self.daily = {}
        except Exception as exc:  # noqa: BLE001
            log(f"could not load daily stats ({exc}); starting fresh.")
            self.daily = {}

    def _day(self, ts: float) -> dict:
        k = day_key(ts)
        b = self.daily.get(k)
        if b is None:
            b = {"up_s": 0.0, "down_s": 0.0, "monitored_s": 0.0,
                 "ok": 0, "fail": 0, "outages": 0, "longest_outage_s": 0.0}
            self.daily[k] = b
            # Prune oldest days beyond the cap.
            if len(self.daily) > MAX_DAYS:
                for old in sorted(self.daily)[:-MAX_DAYS]:
                    del self.daily[old]
        return b

    def save(self, healthy, detail, latency):
        state = {
            "version": 1,
            "updated_at": iso(now()),
            "boot_count": self.boot_count,
            "started_at": iso(self.started_at),
            "last_probe_at": self.last_probe_at,
            "last_probe_iso": iso(self.last_probe_at) if self.last_probe_at else None,
            "healthy": healthy,
            "last_detail": detail,
            "last_latency_ms": round(latency, 1),
            "consecutive_fails": self.current_outage["down_probes"] if self.current_outage else 0,
            "lifetime": self.lifetime,
            "uptime": self.uptime_summary(),
            "current_outage": self.current_outage,
            "last_outage": self.last_outage,
        }
        try:
            _write_atomic(STATE_FILE, json.dumps(state, indent=2))
            _write_atomic(DAILY_FILE, json.dumps(self.daily))
        except Exception as exc:  # noqa: BLE001 - stats are best-effort
            log(f"could not persist stats: {exc}")

    def _append_outage(self, record: dict):
        try:
            with open(OUTAGES_FILE, "a", encoding="utf-8") as fh:
                fh.write(json.dumps(record) + "\n")
            # Prune to the last MAX_OUTAGES lines (cheap; the file is small).
            with open(OUTAGES_FILE, encoding="utf-8") as fh:
                lines = fh.readlines()
            if len(lines) > MAX_OUTAGES:
                _write_atomic(OUTAGES_FILE, "".join(lines[-MAX_OUTAGES:]))
        except Exception as exc:  # noqa: BLE001
            log(f"could not record outage: {exc}")

    # ---- accounting --------------------------------------------------------
    def account(self, ts: float):
        """Credit the interval that just ended to the state we were in during it."""
        if self.last_probe_at is None:
            return
        gap = ts - self.last_probe_at
        if gap <= 0:
            return
        gap = min(gap, self.attribute_cap)
        b = self._day(ts)
        self.lifetime["monitored_s"] += gap
        b["monitored_s"] += gap
        # last_healthy is the state during the interval. None (before the first
        # healthy check) counts as down: the service is not serving mail yet.
        if self.last_healthy:
            self.lifetime["up_s"] += gap
            b["up_s"] += gap
        else:
            self.lifetime["down_s"] += gap
            b["down_s"] += gap

    def record(self, ts: float, healthy: bool, detail: str, latency: float):
        """Fold one probe result into the statistics. Returns an event tag or None."""
        self.account(ts)
        if self.lifetime["first_seen"] is None:
            self.lifetime["first_seen"] = iso(ts)
        b = self._day(ts)
        event = None

        if healthy:
            self.lifetime["probes_ok"] += 1
            b["ok"] += 1
            if self.current_outage is not None:
                event = self._close_outage(ts)
        else:
            self.lifetime["probes_fail"] += 1
            b["fail"] += 1
            if self.current_outage is None:
                # Open an outage on the very first failed probe of a streak.
                self.current_outage = {
                    "start": ts, "start_iso": iso(ts), "down_probes": 0,
                    "errors": [], "samples": [], "alerted": False,
                    "boot": self.boot_count,
                }
            oc = self.current_outage
            oc["down_probes"] += 1
            # Keep a bounded, de-duplicated set of distinct error strings.
            if detail not in oc["errors"] and len(oc["errors"]) < 10:
                oc["errors"].append(detail)
            # Store the probe-by-probe shape, capped so one long outage can't bloat.
            if len(oc["samples"]) < MAX_SAMPLES:
                oc["samples"].append([round(ts - oc["start"], 1), round(latency, 1), detail[:80]])

        self.last_probe_at = ts
        self.last_healthy = healthy
        return event

    def mark_alerted(self):
        if self.current_outage is not None and not self.current_outage["alerted"]:
            self.current_outage["alerted"] = True
            self.lifetime["alerted_outages"] += 1

    def _close_outage(self, ts: float) -> str:
        oc = self.current_outage
        assert oc is not None
        duration = ts - oc["start"]
        record = {
            "start": oc["start_iso"],
            "end": iso(ts),
            "duration_s": round(duration, 1),
            "duration_h": fmt_dur(duration),
            "down_probes": oc["down_probes"],
            "alerted": oc["alerted"],
            "errors": oc["errors"],
            "samples": oc["samples"],
            "boot": oc["boot"],
        }
        self._append_outage(record)
        self.lifetime["outages"] += 1
        b = self._day(ts)
        b["outages"] += 1
        if duration > b["longest_outage_s"]:
            b["longest_outage_s"] = round(duration, 1)
        self.last_outage = {k: record[k] for k in
                            ("start", "end", "duration_s", "duration_h", "down_probes", "alerted", "errors")}
        self.current_outage = None
        return "recovered"

    # ---- reporting ---------------------------------------------------------
    def _window(self, days: int) -> tuple[float, float]:
        up = down = 0.0
        today = datetime.now(timezone.utc).date()
        for i in range(days):
            b = self.daily.get((today - timedelta(days=i)).isoformat())
            if b:
                up += b["up_s"]
                down += b["down_s"]
        return up, down

    @staticmethod
    def _pct(up: float, down: float) -> str:
        total = up + down
        if total <= 0:
            return "n/a"
        return f"{100.0 * up / total:.2f}%"

    def uptime_summary(self) -> dict:
        u24, d24 = self._window(1)
        u7, d7 = self._window(7)
        u30, d30 = self._window(30)
        lt = self.lifetime
        return {
            "last_24h": self._pct(u24, d24),
            "last_7d": self._pct(u7, d7),
            "last_30d": self._pct(u30, d30),
            "all_time": self._pct(lt["up_s"], lt["down_s"]),
            "since": lt["first_seen"],
            "outages_total": lt["outages"],
            "alerted_outages": lt["alerted_outages"],
        }

    def _uptime_line(self) -> str:
        s = self.uptime_summary()
        return (f"uptime 24h {s['last_24h']} | 7d {s['last_7d']} | 30d {s['last_30d']} | "
                f"all {s['all_time']} | outages {s['outages_total']} ({s['alerted_outages']} alerted)")

    def report_block(self) -> str:
        s = self.uptime_summary()
        lines = [
            f"Uptime: 24h {s['last_24h']}, 7d {s['last_7d']}, 30d {s['last_30d']}, all {s['all_time']}.",
            f"Outages recorded: {s['outages_total']} ({s['alerted_outages']} reached the alert threshold).",
        ]
        if self.last_outage:
            lo = self.last_outage
            lines.append(f"Last outage: {lo['duration_h']} ending {lo['end']} "
                         f"({lo['down_probes']} failed checks).")
        if s["since"]:
            lines.append(f"Measuring since {s['since']}.")
        return "\n".join(lines)


def main():
    log(f"monitoring {TARGET_HOST}:{TARGET_PORT}: {INTERVAL}s healthy / {FAIL_INTERVAL}s during a "
        f"failure, DOWN alert after {FAIL_THRESHOLD} consecutive failures. stats -> {STATS_DIR}")
    stats = Stats()

    state = None          # None = not yet confirmed healthy; True/False afterwards
    fails = 0
    started = time.monotonic()
    warned_never_up = False
    last_log_summary = time.monotonic()
    last_summary_day = day_key(now())

    # If we resume mid-outage (watchdog restarted while the path was down), carry
    # that forward so the outage is one continuous record, not two.
    if stats.current_outage is not None:
        state = False
        fails = stats.current_outage["down_probes"]
        log(f"resuming with an outage in progress ({fails} failed checks so far).")

    while True:
        ts = now()
        healthy, detail, latency = probe()
        event = stats.record(ts, healthy, detail, latency)

        if healthy:
            if state is None:
                notify("EasyUniMailProxy online",
                       "Mail path healthy.\n\n" + stats.report_block(),
                       "default", "white_check_mark")
                log(f"first healthy check ({latency:.0f}ms): {detail}")
            elif state is False:
                dur = stats.last_outage["duration_h"] if stats.last_outage else "?"
                notify("EasyUniMailProxy recovered",
                       f"Mail path reachable again after {dur} down.\n\n" + stats.report_block(),
                       "default", "white_check_mark")
                log(f"recovered after {dur}")
            state = True
            fails = 0
        else:
            fails += 1
            log(f"unhealthy ({fails}, {latency:.0f}ms): {detail}")
            if state is True and fails >= FAIL_THRESHOLD:
                stats.mark_alerted()
                notify("EasyUniMailProxy DOWN",
                       f"Mail path unreachable for {fails} checks. The VPN or relay "
                       f"may be down.\nLast error: {detail}", "high", "rotating_light,warning")
                state = False
            elif state is None and not warned_never_up \
                    and time.monotonic() - started > START_GRACE:
                stats.mark_alerted()
                notify("EasyUniMailProxy never came up",
                       f"No healthy mail path since startup ({int(time.monotonic()-started)}s). "
                       f"Check config / VPN.\nLast error: {detail}", "high", "warning")
                warned_never_up = True

        stats.save(healthy, detail, latency)

        # Periodic uptime line to the container log (no ntfy) for at-a-glance data.
        if LOG_SUMMARY_EVERY and time.monotonic() - last_log_summary >= LOG_SUMMARY_EVERY:
            log(stats._uptime_line())
            last_log_summary = time.monotonic()

        # Optional once-a-day ntfy digest (off by default to avoid noise).
        today = day_key(ts)
        if DAILY_SUMMARY and today != last_summary_day:
            notify("EasyUniMailProxy daily summary", stats.report_block(), "low", "bar_chart")
            last_summary_day = today

        # Probe fast while unhealthy so an outage's shape and recovery are timed
        # to the second; back to the relaxed interval once healthy.
        time.sleep(FAIL_INTERVAL if not healthy else INTERVAL)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
