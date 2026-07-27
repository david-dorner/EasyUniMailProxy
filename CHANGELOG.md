# Changelog

All notable changes to EasyUniMailProxy are documented here. The version number
of the latest entry must match the `VERSION` file; the release workflow reads
both to publish a GitHub release automatically.

## 1.1.0 - 2026-07-27

Reliability and observability release. No configuration changes are required;
existing `.env` files keep working.

- Faster, cheaper VPN recovery. The supervisor now separates the SAML login from
  the tunnel connection: it keeps the session token the login mints and brings
  the tunnel back from that token in about a second after a drop (measured ~1.5s
  from a hard kill), instead of repeating the full login every time. A fresh
  login happens only when the token is actually spent or near its 24-hour expiry.
- The tunnel is forced over TCP (openconnect `--no-dtls`). The previous UDP/DTLS
  transport was prone to silent NAT-timeout drops behind a home router, the main
  cause of the recurring short outages; TCP trades a little latency (irrelevant
  for mail) for a connection that stays up.
- The tunnel no longer rewrites the container's `/etc/resolv.conf`. It used to
  point DNS at the uni-internal resolvers, reachable only through the tunnel, so
  an unclean drop left DNS broken and blocked the next reconnect. The mail host
  resolves on public DNS to an in-tunnel address, so the uni resolvers are not
  needed; the gateway address is also pinned in `/etc/hosts` so a reconnect never
  depends on DNS.
- Drops are recovered without logging the session out (a hard stop sends no
  logout to the gateway, so the token stays valid). A clean logout is now sent
  only on a planned refresh or on shutdown, and the egress firewall matches any
  tunnel interface (`tun+`) rather than `tun0` by name.
- Watchdog statistics. The watchdog now keeps durable, size-bounded uptime and
  outage statistics in a persisted volume: 24h / 7d / 30d / all-time uptime from
  lossless per-day accounting, and one record per outage with its duration,
  cause, and probe-by-probe shape. Every failure streak is recorded (even brief
  blips that never cross the alert threshold), while alerts still fire only on
  sustained outages, so the data is rich without the notifications becoming
  noisy. During a failure it probes every few seconds to time the outage
  precisely. DOWN and recovery alerts now include the current uptime. The files
  are pruned to fixed bounds, so they never grow without limit.
- Documented an alternative single-machine setup: run the whole stack locally
  (WSL2 on Windows, natively on Linux, Docker Desktop on macOS) and point the
  mail client at `localhost`, for constant access on one computer without a
  separate server.
- New optional tuning knobs, all with safe defaults: `VPN_DPD`,
  `VPN_RECONNECT_TIMEOUT`, `VPN_TOKEN_MAX_AGE`, `VPN_RECONNECT_SETTLE`,
  `VPN_MINT_BACKOFF`, and the watchdog's `WATCHDOG_FAIL_INTERVAL`,
  `WATCHDOG_STATS_DIR`, `WATCHDOG_MAX_DAYS`, `WATCHDOG_MAX_OUTAGES`,
  `WATCHDOG_MAX_SAMPLES`, `WATCHDOG_LOG_SUMMARY_EVERY`, and
  `WATCHDOG_DAILY_SUMMARY`.

## 1.0.0 - 2026-07-23

First release.

- Self-hosted, always-on Docker stack that keeps a permanent University of Graz
  VPN connection and exposes the university mail server (`email.uni-graz.at`) as
  a normal IMAP/SMTP endpoint, so mail clients need no VPN on the user's own
  device
- Headless VPN sign-in reused from EasyUniVPN: an HTTP-only SAML flow submits
  the university credentials and a locally computed TOTP code, including the
  `headless.py` CSRFtoken patch that the Cisco plus Keycloak login requires
- End-to-end passthrough: the relay forwards raw TCP, so each client's TLS runs
  end to end to the real server and the host only ever sees ciphertext; the
  server operator cannot read users' mail or credentials
- The box firewalls its own VPN tunnel down to the mail ports only, so it cannot
  reach any other university service and cannot be used as a backdoor into the
  university network, even if the box itself were compromised
- Native experience: IMAP IDLE, folder and special-use discovery, server-side
  search, and SMTP submission all work because the client talks to the real
  server through the tunnel
- Multi-user with no per-user configuration: one carrier VPN account keeps the
  tunnel up, and every user authenticates their own mailbox with their own
  password
- Proactive VPN session refresh: the university expires the VPN session about
  every 24 hours, so the box re-authenticates itself at fixed local times
  (`VPN_REFRESH_TIMES`, default 03:00 and 04:00; timezone via `TZ`), quiet hours
  where the roughly 4-second reconnect is very unlikely to interrupt anyone,
  instead of waiting for an abrupt hard expiry
- Watchdog container that probes the whole mail path and sends ntfy alerts on
  failure and recovery, over the normal internet so alerts arrive even while the
  VPN is down
- Self-healing: a supervisor that re-authenticates the VPN on drop, the Docker
  restart policy, a DNS-wait on startup, and self-restarting relays folded into
  the VPN container
- Integration test suite (bash) covering functionality, reliability failsafes,
  and ntfy alert delivery
