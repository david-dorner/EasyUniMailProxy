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
silent.

Config (environment):
  WATCHDOG_TARGET_HOST   host to probe (default "vpn" - the compose service)
  WATCHDOG_TARGET_PORT   IMAPS port (default 993)
  WATCHDOG_INTERVAL      seconds between checks (default 60)
  WATCHDOG_FAIL_THRESHOLD  consecutive failures before a DOWN alert (default 3)
  WATCHDOG_START_GRACE   seconds to reach first-healthy before warning (default 300)
  NTFY_URL               ntfy topic URL (required for alerts; else logs only)
  NTFY_TOKEN             optional bearer token for reserved/self-hosted topics
"""
from __future__ import annotations

import os
import socket
import ssl
import sys
import time
import urllib.request

TARGET_HOST = os.environ.get("WATCHDOG_TARGET_HOST", "vpn")
TARGET_PORT = int(os.environ.get("WATCHDOG_TARGET_PORT", "993"))
INTERVAL = int(os.environ.get("WATCHDOG_INTERVAL", "60"))
FAIL_THRESHOLD = int(os.environ.get("WATCHDOG_FAIL_THRESHOLD", "3"))
START_GRACE = int(os.environ.get("WATCHDOG_START_GRACE", "300"))
NTFY_URL = os.environ.get("NTFY_URL", "").strip()
NTFY_TOKEN = os.environ.get("NTFY_TOKEN", "").strip()

# The relay is a raw passthrough, so the cert on 993 is the university's - we
# only test reachability + the IMAP greeting, not identity, so verification off.
_TLS = ssl._create_unverified_context()


def log(msg: str):
    print(f"[watchdog] {time.strftime('%Y-%m-%d %H:%M:%S')} {msg}", flush=True)


def probe() -> tuple[bool, str]:
    """Return (healthy, detail). Healthy = IMAP greeting seen through the path."""
    try:
        with socket.create_connection((TARGET_HOST, TARGET_PORT), timeout=10) as raw:
            with _TLS.wrap_socket(raw, server_hostname="email.uni-graz.at") as s:
                s.settimeout(8)
                banner = s.recv(64)
        if banner.startswith(b"* OK"):
            return True, banner.decode(errors="replace").strip()
        return False, f"unexpected greeting: {banner!r}"
    except Exception as exc:  # noqa: BLE001 - any failure = path unhealthy
        return False, f"{type(exc).__name__}: {exc}"


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


def main():
    log(f"monitoring {TARGET_HOST}:{TARGET_PORT} every {INTERVAL}s "
        f"(alert after {FAIL_THRESHOLD} consecutive failures)")
    state = None          # None = not yet confirmed healthy; True/False afterwards
    fails = 0
    started = time.monotonic()
    warned_never_up = False

    while True:
        healthy, detail = probe()

        if healthy:
            if state is None:
                notify("EasyUniMailProxy online",
                       f"Mail path healthy: {detail}", "default", "white_check_mark")
                log(f"first healthy check: {detail}")
            elif state is False:
                notify("EasyUniMailProxy recovered",
                       "Mail path via the VPN is reachable again.", "default", "white_check_mark")
                log("recovered")
            state = True
            fails = 0
        else:
            fails += 1
            log(f"unhealthy ({fails}): {detail}")
            if state is True and fails >= FAIL_THRESHOLD:
                notify("EasyUniMailProxy DOWN",
                       f"Mail path unreachable for {fails} checks. The VPN or relay "
                       f"may be down.\nLast error: {detail}", "high", "rotating_light,warning")
                state = False
            elif state is None and not warned_never_up \
                    and time.monotonic() - started > START_GRACE:
                notify("EasyUniMailProxy never came up",
                       f"No healthy mail path since startup ({int(time.monotonic()-started)}s). "
                       f"Check config / VPN.\nLast error: {detail}", "high", "warning")
                warned_never_up = True

        time.sleep(INTERVAL)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
