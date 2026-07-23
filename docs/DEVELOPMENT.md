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
│   ├── entrypoint.sh           keyring/profile, DNS wait, relays, connect
│   └── headless.py             Patched openconnect-saml headless authenticator
├── watchdog/
│   ├── Dockerfile
│   └── watchdog.py             Mail-path probe and ntfy alerts
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

## 6. Reliability and self-healing

- **Brief network blips** are handled inside the tunnel by openconnect itself
  (its own reconnect), with no re-auth and no new one-time code.
- **A full tunnel drop** is handled by the supervisor loop in the entrypoint. It
  runs one `openconnect-saml connect` at a time (not openconnect-saml's own
  `--reconnect`, so the timing is ours), and when that returns it re-runs the
  headless SAML flow with a short backoff (`VPN_RECONNECT_BACKOFF`, default 35
  seconds, deliberately above the 30-second one-time-code window so Keycloak
  never sees a replayed code).
- **The roughly 24-hour session expiry** is handled proactively. The university
  expires the VPN session about 24 hours after sign-in (openconnect logs the
  exact time as "Session authentication will expire at ..."). Rather than wait
  for that hard expiry, where openconnect can retry a dead session for minutes,
  the supervisor re-authenticates at fixed local times (`VPN_REFRESH_TIMES`,
  default `03:00,04:00`, read in `TZ`). Two times a day keep the largest gap
  under 24 hours with no drift, so a refresh always lands before the session can
  expire; the entrypoint warns if the configured times leave a gap of 24 hours
  or more. A planned refresh reconnects immediately (no anti-replay wait, since
  the session is at least an hour old), so the gap is about four seconds, at a
  quiet hour by default; an unexpected drop keeps the longer 35-second backoff.
- **A process crash or container exit** is handled by
  `restart: unless-stopped`. Because the relays are folded into the vpn
  container, they restart with the tunnel.
- **A cold-start DNS race** is handled by a wait loop in the entrypoint: Docker's
  embedded resolver can lag for a second or two at container start, which would
  otherwise fail the first connect with "Failed to resolve univpn.uni-graz.at"
  and force a restart.
- **A relay crash** is handled by a per-relay restart loop in the entrypoint
  (`while true; do socat ...; done`).
- **Anything the above misses** (a silently dead tunnel, an unreachable upstream,
  a stopped relay, or the vpn container itself down) is caught by the watchdog,
  which alerts.

The client-visible effect of a reconnect is that the client's connection drops
and the mail app reconnects automatically, the same as a laptop briefly losing
Wi-Fi.

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
itself carries no emoji. There is no `docker.sock`-based auto-restarter:
recovery is handled by `--reconnect` and the Docker restart policy, and the
watchdog reports anything that slips through.

---

## 8. DNS and routing

DNS and routing to the mail server work without extra configuration on the
network tested. openconnect's `vpnc-script` rewrites `/etc/resolv.conf` with the
university resolvers, `email.uni-graz.at` resolves to an address inside the
split-tunnel route pushed by the VPN, and ports 993 and 587 are reachable
through the tunnel.

If a future network change breaks this, the knobs are still present:

- Some Docker setups mount `/etc/resolv.conf` read-only, which stops
  `vpnc-script` from installing the VPN's DNS. Set `dns:` in `docker-compose.yml`
  to the university resolver (reachable once the tunnel is up), or pin the
  server address with `extra_hosts`.
- On a split tunnel where the mail server's subnet is not pushed, add a route by
  passing `--route <CIDR>` through an extra openconnect-saml argument.

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
