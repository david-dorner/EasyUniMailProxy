# Changelog

All notable changes to EasyUniMailProxy are documented here. The version number
of the latest entry must match the `VERSION` file; the release workflow reads
both to publish a GitHub release automatically.

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
