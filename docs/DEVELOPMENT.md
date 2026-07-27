# EasyUniMailProxy - Developer Documentation

Technical reference for working on EasyUniMailProxy: how the containers fit
together, why the design is what it is, and how to build, test, and release. For
user-facing information (deployment, client setup, security summary) see the
[README](../README.md).

---

## 1. Overview

EasyUniMailProxy is a self-hosted Docker stack that keeps a permanent connection
to the University of Graz VPN (`univpn.uni-graz.at`, Cisco ASA with SAML single
sign-on via Keycloak "uniLOGIN") and re-exposes the university mail server
(`email.uni-graz.at`, Microsoft Exchange) as an ordinary IMAP/SMTP endpoint.
Mail clients connect to the box instead of the university server and never touch
the VPN themselves.

Two decisions define the system:

1. **Transparent proxy, not a local mirror.** Instead of synchronising mailboxes
   into local storage (mbsync, Dovecot, Postfix), the box relays the client's
   own IMAP/SMTP session to the real server. Every feature is therefore native
   by construction (IDLE, folder and special-use discovery, server-side search),
   and no mailbox data is stored on the box. Multi-user comes for free.

2. **End-to-end passthrough, not TLS termination.** The relay is a raw TCP
   forwarder. It does not terminate TLS, so each client's TLS (IMAPS 993) or
   STARTTLS (submission 587) session is negotiated end to end with the real
   server. The box, and anyone with access to it, only ever sees ciphertext.
   This is what lets the stack be shared safely: users do not have to trust the
   operator with their plaintext mail or credentials.

The VPN sign-in is completely headless: an HTTP-only SAML flow submits the
university credentials and a locally computed TOTP code, so no browser ever
opens. This reuses EasyUniVPN's approach and its patched `headless.py` (see
section 4).

---

## 2. Repository layout

```
EasyUniMailProxy/
├── README.md                   User-facing: deploy, client setup, security
├── docs/DEVELOPMENT.md         This file
├── CHANGELOG.md                Version history (top entry must match VERSION)
├── VERSION                     Single source of truth for the version
├── LICENSE                     GPL-3.0-or-later
├── THIRD-PARTY-NOTICES.md      Component attributions
├── docker-compose.yml          Two services: vpn (tunnel + relays) and watchdog
├── .env.example                Configuration template
├── vpn/
│   ├── Dockerfile              openconnect + socat + openconnect-saml + patch
│   ├── entrypoint.sh           keyring/profile, DNS wait, relays, token supervisor
│   ├── vpnc-noresolv           vpnc-script wrapper: install routes, never touch DNS
│   └── headless.py             Patched openconnect-saml headless authenticator
├── watchdog/
│   ├── Dockerfile
│   └── watchdog.py             Mail-path probe, ntfy alerts, uptime/outage stats
└── tests/                      Integration suite (see section 10)
    ├── run-tests.sh
    ├── helpers/common.sh
    ├── lib/*.py
    └── 01..08-*.sh
```

---

## 3. Container topology

```
   Mail clients (no VPN)
        |   IMAPS 993, SMTP submission 587 (STARTTLS)
        |   TLS is end to end to Exchange; the box sees ciphertext
        v
+---------------------------------------------------------------+
|  Docker host                        [ firewall: 993 / 587 ]   |
|                                                               |
|  vpn container                                                |
|    openconnect-saml (headless SAML) + openconnect  tun0       |
|    + socat raw-TCP relays  :993  :587  ---> published to host |
|                                                               |
|  watchdog container (own namespace)                           |
|    probes the mail path; ntfy alerts over the normal internet |
+-------------------------------+-------------------------------+
                                |  VPN tunnel (univpn.uni-graz.at)
                                v
        University network ---> email.uni-graz.at (Exchange)
```

### Why the relays live in the vpn container

The passthrough relays are two `socat` processes, and they must run inside the
tunnel's network namespace. They could be a separate container using
`network_mode: "service:vpn"`, but Docker does not reliably restart such a
container when the vpn container restarts: it is left in the `Created` state,
which silently breaks the mail path after any VPN reconnect. Folding the relays
into the vpn container ties them to the tunnel's exact lifecycle, so they always
restart together. This also removes an entire container and its failure mode.

### Multi-user

The VPN only provides network reachability to the mail server. Mailbox
authentication is a separate step the client performs directly against Exchange,
inside the end-to-end TLS. So one carrier account (in `.env`) keeps the tunnel
up, and any number of users authenticate their own mailboxes through it with
their own passwords. The stack is stateless with respect to users and stores no
per-user secrets. The one-time code is only ever needed for the VPN handshake.

---

## 4. The headless SAML patch

Stock `openconnect-saml` cannot complete the Graz Cisco ASA plus Keycloak SAML
flow headlessly. The Cisco ACS relay page sets a `CSRFtoken` cookie with a
JavaScript `document.cookie` assignment before auto-submitting the SAML form,
and a plain `requests` session never runs that JavaScript, so the gateway
rejects the SAML POST.

`vpn/headless.py` is a modified copy of openconnect-saml's
`openconnect_saml/headless.py` (GPL-3.0-or-later; see the file header), taken
from EasyUniVPN. Its `_fill_form` detects SAML relay forms (those carrying a
`SAMLResponse`/`SAMLRequest` hidden field), submits them without injecting
credentials, and replicates the `CSRFtoken` cookie assignment on the requests
session. It also generates TOTP codes from the server's clock (measured from the
HTTP `Date` header of each response), so a wrong container clock cannot push the
code outside the window Keycloak accepts.

The `vpn/Dockerfile` copies this file over the package installed from PyPI:

```
COPY headless.py /usr/local/lib/python3.12/site-packages/openconnect_saml/headless.py
```

The file's Windows-specific pieces (an `%APPDATA%` TOTP cooldown) are inert on
Linux, so it is used verbatim.

---

## 5. Passthrough and the security model

The relays are raw Layer-4 forwarders:

```
socat TCP4-LISTEN:993,reuseaddr,fork  TCP4:email.uni-graz.at:993
socat TCP4-LISTEN:587,reuseaddr,fork  TCP4:email.uni-graz.at:587
```

They forward bytes only. The client's TLS (implicit on 993) or STARTTLS
(negotiated in-band on 587) runs end to end with Exchange, so the relay sees
ciphertext. Because it forwards raw IMAP/SMTP, the client authenticates and
interacts directly with the real server, which is why IDLE, folder discovery,
special-use, search, and submission are all native.

**Trust boundary.** The box holds the carrier VPN account (the operator's own,
in `.env`) and forwards ciphertext. It holds no end-user mail password and
cannot read any user's mail.

**What the operator or a root intruder can see.** Connection metadata only:
addresses, timing, byte counts, and which ports. Not message content and not
credentials, both of which are inside the end-to-end TLS.

**Why passthrough matters against an active operator.** An operator could
replace the relay with a TLS-terminating one to attempt a man in the middle, but
that would present a different certificate than the university's, which clients
that accepted the real `email.uni-graz.at` certificate will flag. Passthrough
therefore keeps the operator honest: they cannot silently start reading.

**The tunnel carries only mail (not a backdoor into the university).** Two
things confine what can be reached through this box. First, the relays have a
fixed destination (the mail server on 993 and 587), so a client can never pick
an arbitrary host or port, and the mail server itself requires valid credentials,
so an unauthenticated client gets nothing. Second, the entrypoint installs an
iptables egress firewall on the tunnel interface (`tun0`) that permits only the
mail ports (993, 587) and DNS and drops everything else, and blocks new inbound
connections from the university side. So even a compromise of this container
cannot reach any other university host, port, or service over the VPN. The VPN
transport itself, on the physical interface, is unaffected, and this is best
effort: if iptables is unavailable the proxy still only relays mail, but the
extra firewall is not active (a warning is logged).

**The trade-off.** Because the relay never terminates TLS, the certificate a
client validates is the university's own (`email.uni-graz.at`), not the box's
hostname. Clients accept it once (a trust-on-first-use of the genuine
certificate). A clean certificate for the box's own hostname would require TLS
termination, which is exactly what would let the operator read everything.

**Firewalling.** Ports 993 and 587 are an authentication surface that someone
could try to brute-force through the proxy. Only let trusted clients reach them:
put the box on a private overlay (WireGuard, Tailscale) or restrict the ports to
known addresses. Use `BIND_ADDR` in `.env` to bind them to a private interface
instead of `0.0.0.0`. A minimal host rule set:

```
# ufw: allow only a trusted subnet or overlay CIDR to the mail ports
ufw default deny incoming
ufw allow from 100.64.0.0/10 to any port 993 proto tcp   # e.g. Tailscale
ufw allow from 100.64.0.0/10 to any port 587 proto tcp
ufw allow OpenSSH
ufw enable
```

Rate-limiting repeated connection attempts (for example with an nftables
connection limit or fail2ban) blunts brute force; Exchange's own lockout policy
is the backstop.

**Hardening the carrier secret.** The `.env` file and the in-container plaintext
keyring hold the operator's VPN credentials. If that matters on a given host,
use Docker or compose secrets instead of `.env`, or a `keyrings.cryptfile`
backend with a runtime passphrase. Losing this secret exposes the VPN account,
not any user's mailbox.

---

## 6. VPN reliability: session model, transport, and self-healing

### The session model (measured, not assumed)

The reconnect strategy is built on how the Graz gateway actually treats a
session, established by probing the live gateway:

- **A login mints a bearer token.** The SAML plus TOTP login returns a Cisco
  AnyConnect session cookie (shaped `sessionID@...@...@hash`). openconnect needs
  only that cookie to raise the tunnel, and does so in about a second, with no
  second login.
- **The token is reusable and survives a drop.** The same cookie brings the
  tunnel back up repeatedly. An *unclean* loss of the tunnel (the process is
  hard-killed, or the network dies) leaves the session valid server-side, so a
  reconnect from the cookie succeeds.
- **A clean logout is what ends the session.** openconnect, on `SIGTERM`, sends
  the gateway a disconnect and the cookie is then rejected (HTTP 401). Whether
  the token survives therefore depends entirely on how openconnect stops: a hard
  `SIGKILL` (no disconnect sent) preserves it; a `SIGTERM` retires it.
- **One token can carry several tunnels at once.** A second openconnect started
  from the same cookie raises a second tunnel that also carries traffic. This is
  what would make a zero-gap make-before-break refresh possible if the data ever
  shows it is needed (see below).
- **The session hard-expires after about 24 hours**, independent of activity
  (openconnect logs "Session authentication will expire at ...").

### The supervisor

`vpn/entrypoint.sh` is built directly on those facts, and separates the two
things a sign-in does:

- `mint_token` runs the login **once** (`openconnect-saml ... --authenticate
  shell`) and captures the cookie, the server-certificate pin, and the gateway
  URL. `run_tunnel` then hands that cookie to a plain `openconnect` call. The
  token is held in memory only, never written to disk.
- On a drop the loop **reconnects from the held token** (about one second) and
  logs in again only when the token is actually spent (the gateway rejects it,
  matched from openconnect's output) or is near its 24-hour age
  (`VPN_TOKEN_MAX_AGE`, default 20 hours). This replaces the previous behaviour
  of repeating the full SAML login on every reconnect.
- It stops openconnect with **`SIGKILL` for an unplanned drop** (preserving the
  token so it can be reused) and with **`SIGTERM` only when deliberately retiring
  a session** (a planned refresh, or container shutdown via the entrypoint's
  `trap`), so the gateway is not left with dangling sessions when it can be
  avoided.
- Two safeguards bound the login rate: `mint_token` never begins a login within
  `MIN_MINT_SPACING` (32 s) of the previous one, so a burst can never replay a
  one-time code; and three consecutive immediate exits force a fresh login rather
  than a hot reconnect loop on a token that has gone bad in a way the output
  patterns did not catch.

Measured recovery from a hard tunnel kill, reconnecting from the token, is about
1.5 seconds, versus the multi-second full re-login it replaces.

### Transport: forced TCP

The tunnel is forced over TCP (`openconnect --no-dtls`). The default UDP/DTLS
transport is prone to silent NAT-timeout drops behind a home router, where the
datagram flow simply stops and the client only notices at the next dead-peer
check; those were the main source of the recurring short outages. TCP costs a
little latency, irrelevant for mail, for a connection that stays up. `VPN_DPD`
(default 5 s) bounds how fast a genuinely dead peer is noticed;
`VPN_RECONNECT_TIMEOUT` (default 25 s) caps how long openconnect retries in place
before it exits and the supervisor takes over.

### DNS: never break resolv.conf

openconnect's stock `vpnc-script` rewrites `/etc/resolv.conf` to the uni-internal
resolvers, which are reachable only through the tunnel. On an unclean drop its
teardown never runs, so `/etc/resolv.conf` is left pointing at now-unreachable
servers, and the next reconnect cannot even resolve the gateway hostname; a
one-second blip becomes a long outage. `vpn/vpnc-noresolv` wraps `vpnc-script`
and clears `INTERNAL_IP4_DNS`, so the routes are still installed but DNS is left
untouched (`vpnc-script` only edits `resolv.conf` when that variable is set).
This is safe because `email.uni-graz.at` resolves on **public** DNS to an address
inside the tunnel's route range, so the uni resolvers are never needed. As a
further guard the gateway's address is pinned in `/etc/hosts` at startup, so a
reconnect never depends on DNS at all.

### The rest of the safety net

- **The ~24-hour session expiry** is handled proactively. Rather than wait for
  the hard expiry, where openconnect can retry a dead session for minutes, the
  supervisor cycles to a fresh token at fixed local times (`VPN_REFRESH_TIMES`,
  default `03:00,04:00`, read in `TZ`). Two times a day keep the largest gap
  under 24 hours with no drift; the entrypoint warns if the configured times
  leave a gap of 24 hours or more.
- **A process crash or container exit** is handled by `restart: unless-stopped`.
  Because the relays are folded into the vpn container, they restart with it.
- **A cold-start DNS race** is handled by a wait loop in the entrypoint: Docker's
  embedded resolver can lag for a second or two at container start, which would
  otherwise fail the first connect and force a restart.
- **A relay crash** is handled by a per-relay restart loop
  (`while true; do socat ...; done`).
- **Anything the above misses** (a silently dead tunnel, an unreachable upstream,
  a stopped relay, or the vpn container itself down) is caught by the watchdog,
  which alerts and records it.

The client-visible effect of a reconnect is that the client's connection drops
and the mail app reconnects automatically, the same as a laptop briefly losing
Wi-Fi.

### If sub-second failover is ever needed

The measured ~1.5 s reconnect closes most of the gap, and forcing TCP should make
unplanned drops rare in the first place. If the watchdog statistics later show
that residual drops still hurt, the session model already permits a zero-gap
make-before-break refresh: a second tunnel can be raised on the same token (or a
freshly minted one) and traffic switched to it before the first is torn down, so
there is no interruption at all. The egress firewall already matches any tunnel
interface (`tun+`) to allow for a transient second tunnel. This is deliberately
left unimplemented until the data justifies the added complexity.

---

## 7. The watchdog

`watchdog/watchdog.py` is a black-box monitor. Every `WATCHDOG_INTERVAL` seconds
it opens the relay's IMAPS port and reads the `* OK` IMAP greeting. That single
probe exercises the whole chain: tunnel, routing, relay, and upstream
reachability.

It runs in its **own** network namespace, not the vpn container's, for two
reasons: it stays alive to alert even when the vpn container is down, and it
reaches ntfy over the normal internet rather than the tunnel, so alerts arrive
precisely when the VPN is broken.

State transitions are pushed to ntfy: a one-time "online" ping on the first
healthy check (which also confirms the alert path works), a DOWN alert after
`WATCHDOG_FAIL_THRESHOLD` consecutive failures, and a RECOVERED alert when the
path returns. Steady state is silent. The alert emoji seen on the phone comes
from ntfy's `Tags` field (for example `rotating_light`, `warning`,
`white_check_mark`), which is the idiomatic ntfy way to render icons; the code
itself carries no emoji. There is no `docker.sock`-based auto-restarter: recovery
is handled by the supervisor and the Docker restart policy, and the watchdog
reports anything that slips through.

### Statistics

The watchdog also keeps durable, size-bounded uptime and outage statistics under
`WATCHDOG_STATS_DIR` (default `/data`, a persisted volume), so you can answer
"what is my real uptime, and what did each outage look like":

- **Adaptive probing.** While healthy it probes every `WATCHDOG_INTERVAL`. The
  moment a probe fails it switches to `WATCHDOG_FAIL_INTERVAL` (default 5 s) so
  an outage's start, shape, and recovery are timed to the second, then returns to
  the relaxed interval once healthy. This is what makes a ~1 s reconnect
  measurable.
- **Every failure streak is recorded** as one outage record, including a brief
  blip that never crossed the alert threshold (the record's `alerted` flag says
  whether it did). Alerts still fire only on a sustained streak, so the data is
  rich without the notifications becoming noisy.
- **Uptime is lossless.** Up and down seconds are accumulated per calendar day,
  so 24h / 7d / 30d / all-time percentages are exact without storing every probe.
  Time is credited to the state the path was in during each interval; a gap
  larger than twice the interval (a watchdog restart) is capped so it cannot dump
  a false block of downtime.

Three files, each bounded so they never grow without limit:

| File | Contents | Bound |
|---|---|---|
| `state.json` | Current snapshot: health, consecutive fails, lifetime counters, the uptime summary, the current and last outage. Rewritten each probe. | Fixed size |
| `daily.json` | One row per day: up / down / monitored seconds, probe counts, outage count, longest outage. | `WATCHDOG_MAX_DAYS` rows (default 400) |
| `outages.jsonl` | One line per finished outage: start, end, duration, failed-check count, `alerted`, the distinct error strings (the cause), and a capped probe-by-probe trace (the shape: offset, latency, error per sample). | `WATCHDOG_MAX_OUTAGES` lines (default 2000), `WATCHDOG_MAX_SAMPLES` samples per outage (default 600) |

Even after years this stays well under a couple of megabytes. If the watchdog
restarts mid-outage it resumes the in-progress outage as one continuous record
rather than splitting it. DOWN and recovery alerts carry the current uptime
figures; `WATCHDOG_LOG_SUMMARY_EVERY` (default hourly) also prints an uptime line
to the container log, and `WATCHDOG_DAILY_SUMMARY=1` optionally pushes a once-a-day
digest to ntfy (off by default, to keep alerts quiet). Read the current numbers
with, for example:

```
docker compose exec watchdog cat /data/state.json
docker compose exec watchdog cat /data/outages.jsonl
```

---

## 8. DNS and routing

The box keeps the container's normal (public) DNS and deliberately does **not**
adopt the university resolvers; see section 6 ("DNS: never break resolv.conf")
for why. This works because `email.uni-graz.at` resolves on public DNS to an
address that falls inside the split-tunnel route the VPN pushes
(`143.50.0.0/16`), so the relay reaches it over the tunnel regardless of which
resolver named it. Ports 993 and 587 are reachable through the tunnel, and the
gateway's own address is pinned in `/etc/hosts` at startup so a reconnect never
depends on a resolver.

If a future network change breaks this, the knobs are still present:

- If `email.uni-graz.at` ever stops resolving publicly, add it to `extra_hosts`
  in `docker-compose.yml` pointing at its in-tunnel address, or drop the
  `--script vpnc-noresolv` override so the tunnel installs the university
  resolvers again (accepting the reconnect fragility that override exists to
  avoid).
- On a split tunnel where the mail server's subnet is not pushed, add a route by
  passing `--route <CIDR>` as an extra openconnect argument in `run_tunnel`.

Note that the university's port 465 is open at the TCP level but does not speak
implicit TLS; submission is 587 with STARTTLS, which is what the relay forwards.

---

## 9. Configuration

All configuration is in `.env` (copied from `.env.example`):

| Variable | Purpose |
|---|---|
| `VPN_USERNAME` | The carrier account's email (plain, no `bzedvz\` prefix) |
| `VPN_PASSWORD` | The carrier account's uniLOGIN password |
| `VPN_TOTP_SECRET` | The carrier account's base32 TOTP secret |
| `NTFY_URL` | The ntfy topic the watchdog posts alerts to |
| `NTFY_TOKEN` | Optional bearer token for a reserved or self-hosted ntfy topic |
| `BIND_ADDR` | Host interface the mail ports bind to (keep firewalled) |
| `VPN_REFRESH_TIMES` | Local times to proactively re-authenticate the VPN (default `03:00,04:00`; two a day keep the gap under the ~24h expiry with no drift) |
| `TZ` | Timezone the refresh times and log timestamps use (default `Europe/Berlin`) |

The VPN server (`univpn.uni-graz.at`), the mail server (`email.uni-graz.at`),
and the profile name are constants baked into the images, because this project
targets one university.

### Advanced tuning (optional, safe defaults)

These rarely need changing; they exist so behaviour can be tuned without editing
code. Set them in the service `environment:` (watchdog) or via `.env` (vpn).

| Variable | Default | Purpose |
|---|---|---|
| `VPN_DPD` | `5` | Dead-peer-detection interval (s): how fast a silent drop is noticed |
| `VPN_RECONNECT_TIMEOUT` | `25` | How long openconnect retries its transport in place before it exits to the supervisor (s) |
| `VPN_TOKEN_MAX_AGE` | `72000` | Re-authenticate a session token once it reaches this age (s); default 20h, under the ~24h expiry |
| `VPN_RECONNECT_SETTLE` | `1` | Settle pause before reconnecting from an existing token after a drop (s) |
| `VPN_MINT_BACKOFF` | `35` | Pause after a failed login before retrying (s); above the one-time-code window |
| `WATCHDOG_INTERVAL` | `60` | Probe interval while healthy (s) |
| `WATCHDOG_FAIL_INTERVAL` | `5` | Probe interval during a failure (s), to time an outage precisely |
| `WATCHDOG_FAIL_THRESHOLD` | `3` | Consecutive failures before a DOWN alert |
| `WATCHDOG_STATS_DIR` | `/data` | Where uptime/outage statistics are persisted |
| `WATCHDOG_MAX_DAYS` | `400` | Daily rows kept in `daily.json` |
| `WATCHDOG_MAX_OUTAGES` | `2000` | Outage lines kept in `outages.jsonl` |
| `WATCHDOG_MAX_SAMPLES` | `600` | Probe samples stored per outage's shape |
| `WATCHDOG_LOG_SUMMARY_EVERY` | `3600` | Log an uptime line this often (s); `0` disables |
| `WATCHDOG_DAILY_SUMMARY` | `0` | `1` also pushes a once-a-day uptime digest to ntfy |

`AUTH_ONLY=1`, passed to the vpn container, validates the carrier credentials and
exits without opening the tunnel. It needs no `NET_ADMIN` or `/dev/net/tun`,
which makes it a fast way to check credentials:
`docker compose run --rm -e AUTH_ONLY=1 vpn`.

---

## 10. Building, versioning, and testing

### Building and running

There is no separate build step. `docker compose up -d` builds the two images
locally on the host and starts the stack; `docker compose up -d --build` forces
a rebuild after a change. The images are not published to any registry; every
deployment builds them from this repository.

### Versioning

The `VERSION` file at the repository root is the single source of truth, and the
top section of `CHANGELOG.md` must carry the same version. Versioning exists only
to track changes and to let users see when a newer release is available; nothing
is stamped into the images. Release checklist:

1. Bump `VERSION`.
2. Add a `## x.y.z - date` section at the top of `CHANGELOG.md`.
3. Push to `main`. The release workflow (section 11) tags and publishes a GitHub
   release automatically when it sees a `VERSION` value with no matching git tag.

### Testing

`tests/run-tests.sh` is the integration suite (bash), structured like
EasyUniVPN's Pester suite (a runner, `helpers/common.sh` with a
`describe`/`it`/assert harness, numbered suites, a colored summary, and
teardown). Functional checks are Python probes in `tests/lib/` fed into the vpn
container so the tests speak the same protocols a mail client does. The suites
cover the stack, the tunnel and the required patch, passthrough, the native IMAP
experience, a real send and receive, reliability failsafes (surviving a restart,
relay self-restart, a clean cold start), and the watchdog with real ntfy
delivery. The suite restarts and tears down the stack, so it is not meant to run
against an instance that must stay up.

See [../tests/README.md](../tests/README.md) for the runner options.

---

## 11. Release automation

The stack is deployed with `docker compose`, not from a registry, so the release
workflow does not build or publish any images. `.github/workflows/release.yml`
runs on every push to `main` and only does version tracking:

1. Reads `VERSION`. If tag `v{VERSION}` already exists, the workflow stops, so
   pushing ordinary commits never re-releases.
2. Extracts the matching `## {VERSION}` section from `CHANGELOG.md` as the
   release notes.
3. Creates git tag `v{VERSION}` and a GitHub release, which is how users see that
   a newer version is available. The source is attached automatically by GitHub.

So publishing a release is exactly: bump `VERSION`, write the changelog entry,
push to `main`.

---

## 12. Licensing constraints

The project is **GPL-3.0-or-later**, and this is not freely changeable:
`vpn/headless.py` is a derivative of openconnect-saml (GPL-3.0-or-later), and the
vpn image installs the openconnect-saml package. Any distribution of these must
remain GPL-compatible. The full component inventory is in
[../THIRD-PARTY-NOTICES.md](../THIRD-PARTY-NOTICES.md).

When adding a dependency, check its license first: MIT, BSD, Apache-2.0, and
LGPL are fine to include; GPL is fine (the project is GPL); proprietary or
source-unavailable components are not.
