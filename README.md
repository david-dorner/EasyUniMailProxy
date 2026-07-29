# EasyUniMailProxy

**Use your University of Graz email on any device, without ever putting the VPN on that device, and with no certificate warnings anywhere.**

EasyUniMailProxy is a small self-hosted mail server that runs on an always-on Linux box (a home server, a VPS, a Raspberry Pi). It keeps one permanent connection to the University of Graz VPN, syncs your university mailbox into a local mailbox, and serves it as an ordinary IMAP/SMTP endpoint behind its **own trusted certificate**. You point Thunderbird, or any mail app on any device, at your box and log in with your normal university credentials.

It is a sister project to [EasyUniVPN](https://github.com/david-dorner/EasyUniVPN) and reuses its headless VPN sign-in (SAML plus password plus one-time code, no browser).

> **Unofficial software.** EasyUniMailProxy is an independent project. It is **not affiliated with, endorsed by, or supported by the University of Graz**. If it breaks, ask here (GitHub issues), not the university's IT support. You are responsible for using it in line with your university's acceptable-use policy. Use at your own risk.

---

## How it works

- One **carrier** university account (in `.env`) keeps the VPN tunnel up.
- Each user's university mailbox is **synced into a local mailbox** and served by Dovecot, so reading is instant and works offline. New mail arrives within a couple of seconds (the box holds an IMAP IDLE connection to the university and syncs the moment mail lands, with a periodic sync as a safety net), and all of your folders are subscribed automatically.
- Outgoing mail is **queued and relayed** to the university as the sender, and retried until it lands, so sending survives a disconnect or a brief outage.

For the full design, see [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

---

## The security model

The box **terminates your TLS** with its own certificate. That means the box does handle your mail and your password - **it is not "operator-blind" like the old 1.x passthrough was.** Whoever runs the box is technically capable of accessing the mail and passwords it holds.

What the design does to make that as hard as practical:

- **Passwords are never stored in plaintext.** Your university password is used to log in, then encrypted (AES) at rest and only decrypted, into memory, for the moment it is needed to sync or send.
- **Cached mail is encrypted at rest.** All mailboxes live on an encrypted (gocryptfs) filesystem, so the disk/volume holds only ciphertext.
- **The key can be bound to the machine.** Both of the above are keyed by a master key that exists only in memory at runtime and can be sealed to the machine's TPM, so it is not sitting on the disk in the clear.

The boundary: a determined operator, or an attacker who gains root, could still read live traffic from memory or run a modified container. This is not mathematically impossible - it is made **hard, not impossible**. Nothing sensitive is plaintext on disk, the password's plaintext lifetime is minimal, and the key can be TPM-bound. **Share the box only with people who accept that you, as the operator, are technically capable of accessing their mail** - even though the design works hard to prevent it.

(If you need a design where the operator genuinely *cannot* read anything, that is the 1.x passthrough - but it comes with the certificate warning, which does not work on all mobile clients.)

---

## Requirements

- A Linux host with **Docker** and **Docker Compose**, with `/dev/net/tun` (for the VPN) and `/dev/fuse` (for the encrypted mail store) available. Both are standard on a normal Linux host. WSL2 should also work on Windows.
- One university account whose credentials and TOTP secret go in `.env` (the carrier). Getting the TOTP secret is a one-time step, described in the EasyUniVPN README under "Getting your TOTP secret".
- A **hostname you control** that points at the box, for the certificate (for example a subdomain on a domain you own).
- An [ntfy](https://ntfy.sh) topic for watchdog alerts (free, no account).

---

## Setup

```bash
git clone https://github.com/david-dorner/EasyUniMailProxy.git
cd EasyUniMailProxy
cp .env.example .env
# edit .env (see below), then:
docker compose up -d
docker compose logs -f mail
```

In `.env` you set:

- **The carrier VPN account** - `VPN_USERNAME`, `VPN_PASSWORD`, `VPN_TOTP_SECRET`.
- **The certificate** - `MAIL_HOSTNAME` (the name your clients connect to) and `CERT_MODE`:
  - `cloudflare-dns` (recommended): Let's Encrypt via the Cloudflare DNS-01 challenge. Free, auto-renewing, trusted everywhere, works behind NAT. Needs a scoped `CF_DNS_API_TOKEN` and `ACME_EMAIL`.
  - `http-01`: Let's Encrypt via HTTP-01 (needs inbound port 80).
  - `manual`: supply your own certificate (`CERT_FILE`, `CERT_KEY`).
  - `selfsigned`: for LAN/testing only (clients will warn).
- **The at-rest key** - `KEY_MODE` (default `auto`: use the TPM if the machine has one, otherwise generate and store a strong key).
- **The ntfy topic** - `NTFY_URL` (and optional `NTFY_TOKEN`).

**DNS:** point `MAIL_HOSTNAME` at your box. A simple way is a CNAME to a name that already tracks your IP (for example a dynamic-DNS record). If you use Cloudflare, keep the record **"DNS only" (grey cloud)** - the proxy only handles web traffic and would break IMAP/SMTP.

---

## Mail client settings

Use your normal university settings, and change only the **server** to your box. There is **no certificate warning to accept** - the box presents a real, trusted certificate for `MAIL_HOSTNAME`.

**Incoming (IMAP)**

| Field | Value |
|---|---|
| Server | your `MAIL_HOSTNAME` (e.g. `mail.example.com`) |
| Port | `993` |
| Security | SSL/TLS |
| Username | `bzedvz\your.name@edu.uni-graz.at` *or* the plain `your.name@edu.uni-graz.at` |
| Password | your university password |

**Outgoing (SMTP)**

| Field | Value |
|---|---|
| Server | your `MAIL_HOSTNAME` |
| Port | `587` |
| Security | STARTTLS |
| Username | same as incoming |
| Password | your university password |

The **first time** you log in, the box verifies your credentials against the real university and enrolls you; your mailbox then starts syncing (it may take a moment to fill on the first sync). After that, logins are checked locally and mail is instant.

---

## Reaching the box from your devices

The box needs to be reachable from your devices, and the mail ports should be open only to people you trust:

- **Same network (LAN):** point your mail client at the box's local address.
- **Private overlay VPN (WireGuard, Tailscale):** put the box and your devices on a mesh network and use the overlay address. This is a different VPN from the university one; it only connects your own devices to your own box.
- **Port forwarding plus a hostname:** forward external 993 and 587 to the box and use `MAIL_HOSTNAME`. Firewall the ports to the sources you expect. Set `BIND_ADDR` in `.env` accordingly.

You can also **run it on your own machine** (WSL2 on Windows, natively on Linux, Docker Desktop on macOS) with `BIND_ADDR=127.0.0.1`, and point your mail client at `localhost` - for constant access on one computer with no separate server.

---

## Security notes

- **Everything persisted is encrypted at rest** (mail store via gocryptfs, passwords via AES), keyed by a master key that is held only in memory and can be sealed to the TPM.
- **The box cannot be used as a backdoor into the university.** Over the VPN it can reach only the mail server's ports; the tunnel egress is firewalled to the mail ports and DNS, so even a compromise of the box cannot reach other university services.
- **Firewall the mail ports (993, 587).** They are an authentication surface; only let trusted clients reach them (private overlay, or restrict to known addresses). Set `BIND_ADDR` to a private interface. Full guidance in [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).
- **Watchdog alerts.** A monitor probes the client-facing mail server every minute and alerts (via ntfy, over the normal internet) on an outage or recovery, with your uptime figures. It separately flags when the university path (sync/send) is unreachable.

---

## Troubleshooting

Check `docker compose logs -f mail`, `docker compose logs -f vpn`, and `docker compose logs -f watchdog`.

- **`docker compose up` fails with "address already in use" on 993 or 587.** A container left in a partially-created state can keep the published port reserved even though nothing is actually listening on it (check with `sudo ss -ltnp | grep -E ':(993|587)'` - if that is empty, this is what happened). It shows up most often right after an upgrade, when the container that publishes the mail ports changes (in 2.0 it moved from `vpn` to `mail`), or after a repeated or interrupted `up`. A plain `docker compose down` does not always release it; force-remove the stack and its network, then bring it up again: `docker rm -f eump-mail eump-vpn eump-watchdog 2>/dev/null; docker network rm easyunimailproxy_eump 2>/dev/null; docker compose up -d`.
- **The VPN will not authenticate.** Check the carrier `VPN_USERNAME` (plain email), `VPN_PASSWORD`, and `VPN_TOTP_SECRET`. Confirm them without opening the tunnel: `docker compose run --rm -e AUTH_ONLY=1 vpn`.
- **The certificate does not issue.** For `cloudflare-dns`, check the API token has DNS edit permission on your zone and that `MAIL_HOSTNAME` / `ACME_EMAIL` are set. You can dry-run against Let's Encrypt staging with `ACME_STAGING=1`.
- **A mailbox is empty at first.** The first sync can take a moment to fill; watch `docker compose logs -f mail` for the sync lines.
- **Checking uptime or outages.** The watchdog keeps statistics in its volume: `docker compose exec watchdog cat /data/state.json`.

---

## Versioning and updating

`docker compose up -d` builds the images locally; there is nothing separate to publish. The `VERSION` file and the top of [CHANGELOG.md](CHANGELOG.md) carry the current version, and a GitHub release is published for each version. To update a deployment: `git pull` then `docker compose up -d --build`. When upgrading across the major version (1.x to 2.0), run a clean `docker compose down` first, because the container that publishes the mail ports changed; if `up` then reports `address already in use` on 993 or 587, see Troubleshooting.

## License

EasyUniMailProxy is free software, licensed under the [GNU General Public License v3.0 or later](LICENSE). `vpn/headless.py` is a modified copy of a file from [openconnect-saml](https://github.com/mschabhuettl/openconnect-saml) (GPL-3.0-or-later). It builds on [OpenConnect](https://www.infradead.org/openconnect/), [Dovecot](https://www.dovecot.org/), [Postfix](http://www.postfix.org/), [isync/mbsync](https://isync.sourceforge.io/), [gocryptfs](https://nuetzlich.net/gocryptfs/), and [lego](https://go-acme.github.io/lego/). See [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) for all attributions.

*"University of Graz", "uniLOGIN", and "Microsoft Exchange" are trademarks of their respective owners and are used here only to describe compatibility.*
