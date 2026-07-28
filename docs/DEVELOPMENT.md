# EasyUniMailProxy - Developer Documentation

Technical reference for working on EasyUniMailProxy 2.0: how the containers fit together, why the design is what it is, and how to build, test, and release. For user-facing information (deployment, client setup, security summary) see the [README](../README.md).

> **2.0 is a major change from 1.x.** 1.x was a transparent, operator-blind passthrough. 2.0 is a small self-hosted mail server that terminates the client's TLS with its own certificate. See section 1 for why, and section 5 for the security model that replaces operator-blindness.

---

## 1. Overview

EasyUniMailProxy keeps a permanent connection to the University of Graz VPN (`univpn.uni-graz.at`, Cisco ASA with SAML single sign-on via Keycloak "uniLOGIN") and re-exposes the university mail server (`email.uni-graz.at`, Microsoft Exchange) to mail clients that never touch the VPN themselves.

Two decisions define 2.0:

1. **Terminating mail server, not a passthrough.** The box presents its **own** TLS certificate, terminates the client's connection, serves each user's mailbox from a **local synced copy** (Dovecot + mbsync), and **relays** their outgoing mail to the university (Postfix). This is what removes the certificate warning on every device.

   The 1.x passthrough forwarded raw TCP, so clients were shown the university's certificate for `email.uni-graz.at` under a hostname they had not dialed. Every client warned about that, and Thunderbird for Android cannot accept it at all (it has no working override for a trusted-but-hostname-mismatched certificate). Terminating with a certificate for a name the client *does* dial is the only fix that works everywhere.

2. **Encrypted at rest, because it is no longer operator-blind.** Terminating TLS means the box handles plaintext mail and passwords. To keep that safe, the mail cache is stored on an encrypted filesystem and passwords are encrypted, both keyed by a master key that lives only in memory and can be sealed to the TPM. See section 5.

The VPN sign-in is unchanged from 1.x: a headless HTTP-only SAML flow with a locally computed TOTP code and the patched `headless.py` (section 4).

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
├── docker-compose.yml          Three services: vpn, mail, watchdog
├── .env.example                Configuration template
├── vpn/                        The tunnel + internal relay to the university
│   ├── Dockerfile              openconnect + socat + openconnect-saml + patch
│   ├── entrypoint.sh           tunnel supervisor (session-token reuse), relays
│   ├── vpnc-noresolv           vpnc-script wrapper: routes only, never touch DNS
│   └── headless.py             Patched openconnect-saml headless authenticator
├── mail/                       The client-facing mail server (2.0 core)
│   ├── Dockerfile              Dovecot + Postfix + isync + gocryptfs + lego + python
│   ├── entrypoint.sh           key + encrypted store + cert + services + sync loop
│   ├── keys.sh                 master key resolution (KEY_MODE)
│   ├── cert.sh                 certificate acquisition (CERT_MODE, lego)
│   ├── authcheck.py            Dovecot checkpassword: enroll + verify
│   ├── sync.py                 per-user mbsync (local Maildir <-> university)
│   ├── relaysend.py            Postfix pipe transport: relay a message to the uni
│   └── dovecot/dovecot.conf    Dovecot config (IMAPS, checkpassword, Maildir)
├── watchdog/
│   ├── Dockerfile
│   └── watchdog.py             Mail-path probe, ntfy alerts, uptime/outage stats
└── tests/                      Integration suite
```

---

## 3. Container topology

```
   Mail clients (no VPN)
        |  IMAPS 993, SMTP submission 587 - the box's own certificate
        v
+-----------------------------------------------------------------------+
|  Docker host                         [ firewall: 993 / 587 ]          |
|                                                                       |
|  mail container (client-facing)                                       |
|    Dovecot (IMAPS 993)  +  Postfix (submission 587, queue)            |
|    local per-user mailboxes on an ENCRYPTED (gocryptfs) store         |
|      |  mbsync sync (read)            |  pipe relay (send)            |
|      +--------------- vpn:993 --------+------- vpn:587 ---------+      |
|                                                                |      |
|  vpn container (internal, static 172.28.0.2)                   |      |
|    openconnect tunnel + raw-TCP relays (email.uni-graz.at)     |      |
|                                                                |      |
|  watchdog container: probes mail:993 + vpn:993; ntfy alerts    |      |
+--------------------------------+--------------------------------------+
                                 |  VPN tunnel (univpn.uni-graz.at)
                                 v
             University network -> email.uni-graz.at (Exchange)
```

- The **vpn** container is unchanged from 1.1.0 (tunnel + raw relays), but is now internal only: it exposes the university mail server to the other containers as `vpn:993` / `vpn:587` on the compose network, with a **static IP 172.28.0.2**.
- The **mail** container is the 2.0 core (below). It reaches the university through the vpn relay under the university's real name (section 11), so the university's certificate validates on the sync/send leg while the box presents its own certificate to clients.
- The **watchdog** monitors the client-facing server and the upstream path.

---

## 4. The headless SAML patch

Unchanged from 1.x. Stock `openconnect-saml` cannot complete the Graz Cisco ASA plus Keycloak SAML flow headlessly: the ACS relay page sets a `CSRFtoken` cookie via JavaScript before auto-submitting, which a plain `requests` session never replicates. `vpn/headless.py` (a modified copy from EasyUniVPN, GPL-3.0-or-later) replicates that cookie and generates TOTP codes from the server clock. The `vpn/Dockerfile` copies it over the PyPI package.

---

## 5. Security model (2.0)

**Not operator-blind.** The box terminates the client's TLS with its own certificate, so it handles plaintext mail and passwords. Whoever runs the box is technically capable of accessing the mail and passwords it holds. This is the deliberate cost of removing the certificate warning on every device. (If you need a design where the operator genuinely cannot read anything, that is the 1.x passthrough, which comes with the warning that mobile clients cannot accept.)

**What limits exposure - encryption at rest.**

- **Passwords** (`mail/authcheck.py`): each user's university password is stored AES-encrypted (a Fernet token) under the master key, and decrypted only into memory for the moment it is needed to sync or send. It is never written to disk in plaintext. A separate crypt(SHA-512) hash is kept for fast local login checks; that hash is not reversible.
- **Cached mail** (`mail/entrypoint.sh` + gocryptfs): all mailboxes and the credential store live under a gocryptfs mount, so the `mail-data` volume holds only ciphertext (encrypted filenames and contents). The plaintext view exists only inside the FUSE mount at `/mail`.
- **The master key** (`mail/keys.sh`): held only in a tmpfs file at runtime, and can be sealed to the machine's TPM so it is never on disk in the clear (section 7).

**The honest boundary.** A root operator or an attacker who gains root can still read live traffic from process memory or run a modified container image. This is made **hard, not impossible**: nothing sensitive is plaintext on disk, the password's plaintext lifetime is minimal, and the key can be TPM-bound. Anyone sharing the box must accept that the operator is technically capable of accessing their mail, even though the design works against it.

**Still confined: no backdoor into the university.** The vpn container's egress firewall (unchanged from 1.x) permits only the mail ports and DNS over the tunnel, so even a compromise of the box cannot reach other university services.

**Current hardening gap (tracked).** Dovecot runs the enrollment `checkpassword` backend in its main auth process, which is set to run as root so it can read the key and write the encrypted store (section 6). A future change should move the privileged enrollment step into a small least-privilege helper. The FUSE mount also requires `SYS_ADMIN` on the mail container, which limits how far the container can otherwise be locked down.

---

## 6. The mail server: enrollment, sync, send

### Enrollment and authentication (`authcheck.py`)

Dovecot uses `authcheck.py` as a `checkpassword` passdb, so it runs for every IMAP and SMTP login:

- **Username normalization.** The user may type `bzedvz\name@edu.uni-graz.at` or the plain `name@edu.uni-graz.at`. The backend strips any `DOMAIN\` prefix and lower-cases it to a canonical local identity, and adds the `bzedvz\` form only when talking to the university. Dovecot's `auth_username_chars` is empty so the backslash reaches the backend, which rewrites `USER` to the canonical address.
- **Enroll on first login.** If the user is not yet enrolled, the backend logs in to the real university IMAP (through the tunnel) to verify the password. On success it enrolls them: a crypt(SHA-512) hash for fast local checks, plus the university password AES-encrypted under the master key for the sync/send engine.
- **Later logins** are checked against the local hash (offline, no university contact). A changed university password is picked up via a rate-limited re-check against the university.
- **Privileges.** The auth process runs as root (`service auth { user = root }`) so the backend can read the master key and write the encrypted store and mailboxes; enrollment then hands ownership of the mailbox and credential files to the mail user (`vmail`). See the hardening note in section 5.

### Sync / read (`sync.py` + mbsync)

For each enrolled user, `sync.py` decrypts the stored university password and runs `mbsync` to reconcile the local Maildir with the university mailbox. It runs as `vmail` on an interval (`SYNC_INTERVAL`), which is the prefetch. mbsync is UID-based, so it never duplicates or loses messages, and its per-folder SyncState lives with the mail (inside the encrypted store), so a wiped cache re-pulls cleanly instead of pushing spurious deletions upstream.

University-specific details, established against the live server:

- The university **rejects SASL PLAIN/NTLM** here, so mbsync uses the plain IMAP `LOGIN` over TLS (`AuthMechs LOGIN`, and the image ships no SASL plugins).
- mbsync does not escape the backslash in the `bzedvz\` username when it builds the `LOGIN` command, so the config **doubles the backslash** (`User bzedvz\\...`) and the server unescapes it back to one. A single backslash mangles the username and the login fails.
- `ExpireUnread no` is set when a `MaxMessages` cap is used, so the cache only ever drops old *read* mail.

### Send (`relaysend.py` + Postfix)

Postfix accepts the user's submission on 587 (SASL authenticated against Dovecot, STARTTLS with the box's certificate) and queues it durably. `default_transport` routes every queued message to a **pipe transport** that runs `relaysend.py` as `vmail`. That script decrypts the sender's university password and relays the message to the university submission server with Python `smtplib` (AUTH over STARTTLS), then reports success.

A pipe + smtplib is used instead of Postfix's own SASL because: the university rejects Postfix's SASL here too; adding the SASL plugins Postfix would need would break mbsync (it would try SASL); and smtplib base64-encodes the `bzedvz\` username so the backslash is not mangled. Transient failures return `EX_TEMPFAIL`, so Postfix keeps the message queued and retries - which is what makes "send while away" work.

---

## 7. Encryption at rest and key management

### The master key (`keys.sh`, `KEY_MODE`)

`keys.sh` resolves the master key before anything encrypted is touched, and writes it to a tmpfs file (`/run/mail/master.key`) the other components read.

- `auto` (default): use the TPM if the machine has one (`/dev/tpmrm0` + tpm2-tools), otherwise fall back to autostart.
- `tpm`: seal/unseal the key to the TPM. Only the sealed blob is persisted (useless without that TPM); the key never touches the disk in the clear.
- `autostart`: use `MASTER_KEY` if set; else a stored auto-generated key; else generate a strong random key and store it in the keys volume, so the stack always starts and stays consistent. (Weaker: that key is on the box.)
- `passphrase`: derive the key from `MAIL_PASSPHRASE` supplied at start (not stored). Strongest against disk theft, but manual after a reboot.

### The encrypted store (gocryptfs)

The `mail-data` volume is mounted at `/mnt/cipher` (the ciphertext directory). The entrypoint initializes gocryptfs there on first run (keyed by the master key) and mounts it at `/mail` (the plaintext view, `-allow_other` so Dovecot, mbsync, and the relay can use it). Everything the mail server writes goes through gocryptfs and lands as ciphertext on the volume.

**Key change is safe.** The gocryptfs config is protected by the master key, so a different master key cannot open the store. The entrypoint detects the failed open, re-initializes an empty store, and the mailboxes re-sync from the university - it never breaks or corrupts. (This replaces the 1.x fingerprint wipe.)

**Requirements.** Mounting the FUSE store needs `/dev/fuse`, `cap_add: SYS_ADMIN`, and `security_opt: apparmor:unconfined` on the mail container (all in `docker-compose.yml`). This is the cost of encrypting the cache inside the container rather than relying on host disk encryption. The store is unmounted on shutdown (`fusermount3 -u /mail`).

---

## 8. Certificates (`cert.sh`, `CERT_MODE`)

`cert.sh` acquires the certificate the box presents, driven by `CERT_MODE`, and writes it to `/certs/fullchain.pem` + `/certs/key.pem` for Dovecot and Postfix.

- `cloudflare-dns`: Let's Encrypt via the Cloudflare DNS-01 challenge (lego), using a scoped `CF_DNS_API_TOKEN`. Free, auto-renewing, trusted everywhere, works behind NAT with no inbound ports. Recommended.
- `http-01`: Let's Encrypt via HTTP-01 (needs inbound port 80).
- `manual`: use a supplied `CERT_FILE` / `CERT_KEY`.
- `selfsigned`: for LAN/testing (clients warn).

lego drives the ACME modes and supports ~150 DNS providers, so adding another is a couple of env vars. `ACME_STAGING=1` runs against Let's Encrypt staging (no rate limits) to validate the token and DNS-01 flow. On restart with an existing certificate the entrypoint renews (a no-op until ~30 days before expiry) rather than re-issuing, so a restart never burns the weekly rate limit. A daily background loop renews.

---

## 9. VPN reliability (the vpn container)

The vpn container is the 1.1.0 tunnel, unchanged. Summary:

- **Session-token reuse.** The supervisor separates the SAML login (which mints a ~24h session token) from the tunnel connection (which reuses that token). A drop reconnects from the cached token in about a second; a full re-login happens only when the token is spent or near expiry. Drops are dropped with `SIGKILL` (which preserves the token); a clean logout (`SIGTERM`) is sent only on a planned refresh or shutdown.
- **Forced TCP** (`--no-dtls`) avoids the silent UDP NAT-timeout drops that were the main source of recurring outages.
- **DNS is never rewritten.** `vpnc-noresolv` installs the tunnel routes but not the university resolvers (which are only reachable through the tunnel and would block a reconnect if left behind); the mail host resolves on public DNS to an in-tunnel address, and the gateway is pinned in `/etc/hosts`.
- **Egress lock** (iptables on `tun+`) permits only the mail ports and DNS over the tunnel.
- **Proactive refresh** at quiet-hour local times cycles the token before the ~24h server expiry.

Tuning knobs (`VPN_DPD`, `VPN_RECONNECT_TIMEOUT`, `VPN_TOKEN_MAX_AGE`, `VPN_REFRESH_TIMES`, `TZ`, ...) are documented in `.env.example`.

---

## 10. The watchdog

`watchdog/watchdog.py` runs in its own namespace and reaches ntfy over the normal internet, so alerts arrive even when the VPN is down. In 2.0 it probes two things:

- **Primary: the client-facing mail server** (`mail:993`). Its `* OK` greeting is the health signal for the uptime statistics and the DOWN / recovered alerts. If it is down, clients cannot connect.
- **Upstream: the tunnel/relay** (`vpn:993`). If the upstream is down while the mail server is up, cached mail still opens but syncing and sending are paused; this is flagged with a lower-priority alert.

It keeps durable, size-bounded uptime and per-outage statistics (24h / 7d / 30d / all-time, plus each outage's duration, cause, and probe-by-probe shape) under `WATCHDOG_STATS_DIR`, probing fast during a failure to time it precisely. Steady state is silent; alert icons come from ntfy's `Tags` field.

---

## 11. DNS and routing

Two different name resolutions matter:

- **The box's own name** (`MAIL_HOSTNAME`) resolves publicly to the box, so clients reach it and its Let's Encrypt certificate matches.
- **The university's name on the sync/send leg.** The mail container must reach `email.uni-graz.at` through the vpn relay *under the university's real name* so the university certificate validates. This is done with a **static vpn IP** (`172.28.0.2`) plus `extra_hosts: email.uni-graz.at:172.28.0.2` on the mail container. Only the mail container gets this mapping; the vpn container resolves the university normally, so its relay does not loop back on itself. (A compose network alias was avoided precisely because it would poison the vpn container's own resolution and loop.)

Port 465 at the university is TCP-open but not implicit TLS; submission is 587 with STARTTLS, which is what the relay uses.

---

## 12. Configuration

All configuration is in `.env` (copied from `.env.example`). The main variables:

| Variable | Purpose |
|---|---|
| `VPN_USERNAME` / `VPN_PASSWORD` / `VPN_TOTP_SECRET` | The carrier VPN account |
| `MAIL_HOSTNAME` | The name clients connect to and the certificate name |
| `CERT_MODE` | `cloudflare-dns` \| `http-01` \| `manual` \| `selfsigned` |
| `CF_DNS_API_TOKEN` / `ACME_EMAIL` | For the Let's Encrypt modes |
| `KEY_MODE` | `auto` \| `tpm` \| `autostart` \| `passphrase` (at-rest key) |
| `MASTER_KEY` / `MAIL_PASSPHRASE` | For the autostart / passphrase key modes |
| `NTFY_URL` / `NTFY_TOKEN` | Watchdog alerts |
| `BIND_ADDR` | Host interface the mail ports bind to (keep firewalled) |
| `SYNC_MODE` / `SYNC_INTERVAL` | mbsync direction (default `All`) and prefetch interval |

Advanced sync/VPN knobs (`SYNC_PATTERNS`, `SYNC_MAXMSG`, `VPN_DPD`, ...) have safe defaults; see `.env.example` and the scripts. `AUTH_ONLY=1` on the vpn container validates the carrier credentials without opening the tunnel.

---

## 13. Building, versioning, and testing

There is no separate build step: `docker compose up -d` builds the three images locally, and `--build` forces a rebuild. The images are not published to a registry.

`VERSION` is the single source of truth and must match the top section of `CHANGELOG.md`. Release checklist: bump `VERSION`, add a `## x.y.z - date` section to the changelog, push to `main`; the release workflow tags and publishes a GitHub release when it sees a `VERSION` with no matching tag.

`tests/run-tests.sh` is the integration suite (bash). Because 2.0 exercises real university mailboxes (enrollment, sync, a real send), the functional suites need a carrier account and touch the live university, so they are opt-in; the structural checks (stack comes up, certificate present, services listening) run without it.

---

## 14. Release automation

`.github/workflows/release.yml` runs on every push to `main` and only does version tracking: it reads `VERSION`, stops if tag `v{VERSION}` already exists (so ordinary commits never re-release), extracts the matching `## {VERSION}` changelog section, and creates the tag + GitHub release. No images are built or published.

---

## 15. Licensing constraints

The project is **GPL-3.0-or-later**, and this is not freely changeable: `vpn/headless.py` is a derivative of openconnect-saml (GPL-3.0-or-later), and the vpn image installs the openconnect-saml package. The full component inventory is in [../THIRD-PARTY-NOTICES.md](../THIRD-PARTY-NOTICES.md). When adding a dependency, check its license: MIT, BSD, Apache-2.0, LGPL, and GPL are fine; proprietary or source-unavailable components are not.
