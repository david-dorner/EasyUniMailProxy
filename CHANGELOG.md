# Changelog

All notable changes to EasyUniMailProxy are documented here. The version number of the latest entry must match the `VERSION` file; the release workflow reads both to publish a GitHub release automatically.

## 2.0.2 - 2026-07-29

Near-instant mail, automatic folders, and native password-change handling. No configuration changes; upgrade with `git pull` then `docker compose up -d --build`.

- Near-instant new mail: the box now holds an IMAP IDLE connection to each user's university INBOX, so a new message is pulled into the local mailbox within a couple of seconds and pushed straight on to the client, instead of waiting for the poll. The periodic sync stays as a safety net and to keep other folders current. If a server does not support IDLE, it falls back to polling.
- Folders appear on their own: every synced folder is subscribed for the client, so all of a user's folders show up without subscribing by hand.
- Faster first mirror: the INBOX syncs first so it appears immediately, and because the box serves the local mailbox live, messages show up in the client as they download rather than only after the whole sync finishes.
- Password changes behave like a normal account: if a user changes their university password, the box notices the university rejecting the stored one, drops the stored credentials, and the client prompts for the new password - which re-verifies against the university and resumes. The cached mail is kept, and a false alarm is harmless (the client just re-authenticates with its still-valid password).
- Fixed a startup window where logins could fail for up to about 15 seconds after the mail container started: the login-socket permission fix from 2.0.1 now applies immediately instead of on the first periodic pass.
- Quieter logs: the harmless Python crypt deprecation warning is no longer logged as an auth error.

## 2.0.1 - 2026-07-29

Bug-fix release. No configuration changes; upgrade with `git pull` then `docker compose up -d --build`.

- Fixed IMAP and SMTP login failing on some hosts with "auth-client: connect(login) ... Permission denied" or "master(imap): net_connect_unix(imap) failed". Dovecot's unprivileged login process could not reach its auth socket, nor the backend-handoff socket after a successful password check, when the container's runtime directory carried a default POSIX ACL (or a restrictive umask) that stripped the "other" write bit from those root-owned sockets. The mail container now keeps the login-service sockets connectable regardless of the host's ACL or umask, so login works on every host. The login directory itself stays 0750, so only Dovecot's own processes can reach the sockets.
- Documented how to clear a stuck published port when upgrading, since the container that publishes the mail ports moved from the vpn container to the mail container (README troubleshooting).

## 2.0.0 - 2026-07-28

Major architecture change. EasyUniMailProxy is now a small self-hosted mail server (it terminates the client's TLS with its own certificate), rather than a transparent passthrough. This removes the certificate warning on every device - including Thunderbird for Android, which cannot accept the passthrough's hostname-mismatched certificate at all - and adds a local, offline-capable mailbox with prefetch and a durable send queue.

The trade-off is deliberate and was chosen explicitly: the box now decrypts and caches your mail, so it is no longer operator-blind. To keep that safe, every piece of persisted data is encrypted at rest.

- Own certificate: the box presents its own TLS certificate (Let's Encrypt via the Cloudflare DNS-01 challenge, HTTP-01, a certificate you supply, or a self-signed one for testing - `CERT_MODE`). Clients connect by a name you control, so there is no certificate warning anywhere.
- Local mailboxes with sync: each user's university mailbox is synced into a local mailbox with `mbsync` (UID-based, no duplicates) and served by Dovecot, so mail is instant and available offline; new mail is prefetched on an interval.
- Durable send queue: submitted mail is queued by Postfix and relayed to the university as the sender, retried until it lands, so sending survives a client disconnect or a brief tunnel outage.
- Enroll on first login: users still just configure their mail client with their university address (either the `bzedvz\` form or the plain address) and password. The first login is verified against the real university and enrolls the user; later logins are checked locally.
- Encryption at rest: the mail cache is stored on a gocryptfs filesystem and each user's university password is AES-encrypted, both keyed by a master key that is held only in memory at runtime and can be sealed to the machine's TPM (`KEY_MODE`: auto, tpm, autostart, or passphrase). A changed or lost key cannot read the old data and cannot corrupt it: the store re-initializes and re-syncs.
- The watchdog now monitors the client-facing mail server and separately flags when the university path (sync/send) is unreachable.

Upgrading from 1.x is not automatic: the deployment model and configuration have changed. See the README for the new setup. Because the container that publishes the mail ports changed (from `vpn` to `mail`), do a clean `docker compose down` before the first `docker compose up` on 2.0; if it reports `address already in use` on 993 or 587, clear the old stack and its network first (see the README Troubleshooting).

## 1.1.0 - 2026-07-27

Reliability and observability release. No configuration changes are required; existing `.env` files keep working.

- Faster, cheaper VPN recovery. The supervisor now separates the SAML login from the tunnel connection: it keeps the session token the login mints and brings the tunnel back from that token in about a second after a drop (measured ~1.5s from a hard kill), instead of repeating the full login every time. A fresh login happens only when the token is actually spent or near its 24-hour expiry.
- The tunnel is forced over TCP (openconnect `--no-dtls`). The previous UDP/DTLS transport was prone to silent NAT-timeout drops behind a home router, the main cause of the recurring short outages; TCP trades a little latency (irrelevant for mail) for a connection that stays up.
- The tunnel no longer rewrites the container's `/etc/resolv.conf`. It used to point DNS at the uni-internal resolvers, reachable only through the tunnel, so an unclean drop left DNS broken and blocked the next reconnect. The mail host resolves on public DNS to an in-tunnel address, so the uni resolvers are not needed; the gateway address is also pinned in `/etc/hosts` so a reconnect never depends on DNS.
- Drops are recovered without logging the session out (a hard stop sends no logout to the gateway, so the token stays valid). A clean logout is now sent only on a planned refresh or on shutdown, and the egress firewall matches any tunnel interface (`tun+`) rather than `tun0` by name.
- Watchdog statistics. The watchdog now keeps durable, size-bounded uptime and outage statistics in a persisted volume: 24h / 7d / 30d / all-time uptime from lossless per-day accounting, and one record per outage with its duration, cause, and probe-by-probe shape. Every failure streak is recorded (even brief blips that never cross the alert threshold), while alerts still fire only on sustained outages, so the data is rich without the notifications becoming noisy. During a failure it probes every few seconds to time the outage precisely. DOWN and recovery alerts now include the current uptime. The files are pruned to fixed bounds, so they never grow without limit.
- Documented an alternative single-machine setup: run the whole stack locally (WSL2 on Windows, natively on Linux, Docker Desktop on macOS) and point the mail client at `localhost`, for constant access on one computer without a separate server.
- New optional tuning knobs, all with safe defaults: `VPN_DPD`, `VPN_RECONNECT_TIMEOUT`, `VPN_TOKEN_MAX_AGE`, `VPN_RECONNECT_SETTLE`, `VPN_MINT_BACKOFF`, and the watchdog's `WATCHDOG_FAIL_INTERVAL`, `WATCHDOG_STATS_DIR`, `WATCHDOG_MAX_DAYS`, `WATCHDOG_MAX_OUTAGES`, `WATCHDOG_MAX_SAMPLES`, `WATCHDOG_LOG_SUMMARY_EVERY`, and `WATCHDOG_DAILY_SUMMARY`.

## 1.0.0 - 2026-07-23

First release.

- Self-hosted, always-on Docker stack that keeps a permanent University of Graz VPN connection and exposes the university mail server (`email.uni-graz.at`) as a normal IMAP/SMTP endpoint, so mail clients need no VPN on the user's own device
- Headless VPN sign-in reused from EasyUniVPN: an HTTP-only SAML flow submits the university credentials and a locally computed TOTP code, including the `headless.py` CSRFtoken patch that the Cisco plus Keycloak login requires
- End-to-end passthrough: the relay forwards raw TCP, so each client's TLS runs end to end to the real server and the host only ever sees ciphertext; the server operator cannot read users' mail or credentials
- The box firewalls its own VPN tunnel down to the mail ports only, so it cannot reach any other university service and cannot be used as a backdoor into the university network, even if the box itself were compromised
- Native experience: IMAP IDLE, folder and special-use discovery, server-side search, and SMTP submission all work because the client talks to the real server through the tunnel
- Multi-user with no per-user configuration: one carrier VPN account keeps the tunnel up, and every user authenticates their own mailbox with their own password
- Proactive VPN session refresh: the university expires the VPN session about every 24 hours, so the box re-authenticates itself at fixed local times (`VPN_REFRESH_TIMES`, default 03:00 and 04:00; timezone via `TZ`), quiet hours where the roughly 4-second reconnect is very unlikely to interrupt anyone, instead of waiting for an abrupt hard expiry
- Watchdog container that probes the whole mail path and sends ntfy alerts on failure and recovery, over the normal internet so alerts arrive even while the VPN is down
- Self-healing: a supervisor that re-authenticates the VPN on drop, the Docker restart policy, a DNS-wait on startup, and self-restarting relays folded into the VPN container
- Integration test suite (bash) covering functionality, reliability failsafes, and ntfy alert delivery
