# EasyUniMailProxy

**Use your University of Graz email on any device, without ever putting the VPN
on that device.**

EasyUniMailProxy is a small self-hosted service that runs on an always-on Linux
box (a home server, a VPS, a Raspberry Pi). It keeps one permanent connection to
the University of Graz VPN and exposes the university mail server as an ordinary
IMAP/SMTP endpoint. You point Thunderbird, or any mail app on any device, at
your box and log in with your normal university credentials. Everything you get
natively over the VPN (instant push, Trash/Sent/Junk discovery, server-side
search) you get here too, because your client is talking to the real server
through the tunnel.

Crucially, the box **cannot read your mail or your password**: your client's TLS
runs end to end to the real server, and the service only forwards ciphertext.
That is what makes it safe to share with a few other people.

It is a sister project to
[EasyUniVPN](https://github.com/david-dorner/EasyUniVPN) and reuses its headless
VPN sign-in (SAML plus password plus one-time code, no browser).

> **Unofficial software.** EasyUniMailProxy is an independent project. It is
> **not affiliated with, endorsed by, or supported by the University of Graz**.
> If it breaks, ask here (GitHub issues), not the university's IT support. You
> are responsible for using it in line with your university's acceptable-use
> policy. Use at your own risk.

---

## How it works

```
Your phone / laptop   ---- IMAPS 993, SMTP 587 (TLS end to end) ---->   [ your box ]   ---->   real Exchange
     (no VPN)                                                          VPN tunnel + relay      (email.uni-graz.at)
```

- One **carrier** university account (in `.env`) keeps the VPN tunnel up.
- Every user logs into **their own** mailbox through it, with their own password.
- No mail and no user passwords are stored on the box; it only forwards bytes.

For the full design, see [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

---

## Requirements

- A Linux host (or WSL) with **Docker** and **Docker Compose**, and
  `/dev/net/tun` available (standard on any normal Linux host).
- One university account whose credentials and TOTP secret go in `.env` (the
  carrier). Getting the TOTP secret is a one-time step, described in the
  EasyUniVPN README under "Getting your TOTP secret"; it is the `secret=` value
  inside your authenticator's QR code.
- An [ntfy](https://ntfy.sh) topic for watchdog alerts (free, no account).

---

## Setup

```bash
git clone https://github.com/david-dorner/EasyUniMailProxy.git
cd EasyUniMailProxy
cp .env.example .env
# edit .env: the carrier VPN account, and a long secret ntfy topic
docker compose up -d
docker compose logs -f vpn        # watch the tunnel authenticate and come up
```

When `docker compose ps` shows the `vpn` container healthy, the proxy is ready.
Subscribe to your `NTFY_URL` topic in the ntfy app; you will get an "online"
ping, and later any DOWN or RECOVERED alerts.

To verify everything end to end, run the test suite in [tests/](tests/):

```bash
cd tests && ./run-tests.sh
```

---

## Example deployment

The box needs to be reachable from your devices, and the mail ports should be
open only to people you trust. There are a few options for this:

- **Same network only.** If your devices and the server are on the same home
  or office network (LAN), point your mail client at the server's local address
  (for example `192.168.1.10`). Nothing is exposed to the internet. This is the
  simplest and safest option.
- **Private overlay VPN.** Put the server and your
  devices on a mesh VPN such as Tailscale or WireGuard, and point your mail
  client at the server's overlay address. The mail ports never touch the public
  internet, and only devices on your overlay can reach them. This is a different
  VPN from the university one; it only connects your own devices to your own
  server, so your devices still need no university VPN.
- **Port forwarding plus a hostname.** On your router, forward external ports
  993 and 587 to the server. If your home IP address changes over time, give the
  server a stable name with a dynamic-DNS provider (DDNS) and point your mail
  client at that hostname. If you expose the ports this way, firewall them to the
  source addresses you expect so they are not open to the whole internet (see
  Security below).

Whichever you choose:

1. Set `BIND_ADDR` in `.env` to the interface the ports should listen on (for
   example the overlay or LAN address, or `0.0.0.0` when it sits behind a
   firewall).
2. Make sure the server itself can always reach the internet, for the VPN.
3. Point every mail client at that address, using the settings in the next
   section.

---

## Mail client settings

Use your normal university settings, and change only the **server** to your box.

**Incoming (IMAP)**

| Field | Value |
|---|---|
| Server | your box's hostname or IP |
| Port | `993` |
| Security | SSL/TLS |
| Username | `bzedvz\your.name@edu.uni-graz.at` |
| Password | your university password |

**Outgoing (SMTP)**

| Field | Value |
|---|---|
| Server | your box's hostname or IP |
| Port | `587` |
| Security | STARTTLS |
| Username | `bzedvz\your.name@edu.uni-graz.at` |
| Password | your university password |

**The certificate prompt is expected and correct.** Because the box never
decrypts your traffic, your client is shown the **university's own certificate**
(`email.uni-graz.at`) rather than one for your box's hostname. On the first
connection your client asks you to confirm it; accept it once. You are
confirming the genuine university certificate, and this is exactly what
guarantees that even the server's owner cannot silently read your mail.

---

## Adding more users

There is nothing to configure. Anyone with a university mailbox uses the
settings above with their own username and password. The carrier account only
provides the network path; each mailbox is authenticated directly against the
real server, end to end, so the operator never sees another user's password or
mail.

---

## Security

- **The operator cannot read users' mail or credentials.** TLS is end to end to
  the real server; the box forwards ciphertext only. The most anyone with access
  to the box can see is connection metadata (which addresses connect, when, and
  how many bytes).
- **The box cannot be used as a backdoor into the university.** Through the proxy
  a client can only ever reach the mail server's IMAP/SMTP ports, and the mail
  server requires valid credentials, so no one without a mail account can do
  anything. On top of that, the box firewalls its own VPN tunnel down to the
  mail ports only, so even if the box itself were compromised it still could not
  reach any other university host, port, or service.
- **Firewall the mail ports.** Ports `993` and `587` are an authentication
  surface. Only let trusted clients reach them: put the box on a private overlay
  network (WireGuard, Tailscale) or restrict the ports to known addresses, and
  do not expose them to the open internet. Set `BIND_ADDR` in `.env` to bind to
  a private interface. Full guidance is in
  [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).
- **Watchdog alerts.** A monitor probes the whole mail path every minute and
  sends an ntfy alert if the VPN or relay goes down, and again when it recovers.
  Alerts travel over the normal internet, so they reach you even while the VPN
  is broken.
- The carrier VPN password lives in `.env`, which is the operator's own
  credential, not any user's. Keep the host secured accordingly.

---

## Troubleshooting

Check `docker compose logs -f vpn` and `docker compose logs -f watchdog`, or run
the test suite in [tests/](tests/).

- **The VPN will not authenticate.** Check `VPN_USERNAME` (the plain email, with
  no `bzedvz\` prefix), `VPN_PASSWORD`, and `VPN_TOTP_SECRET` (the bare base32
  secret). Confirm the credentials without opening the tunnel with
  `docker compose run --rm -e AUTH_ONLY=1 vpn`.
- **The tunnel is up but mail will not connect.** Check
  `docker compose logs watchdog`; the whole path is probed there.
- **A certificate warning appears in the client.** This is expected; accept the
  `email.uni-graz.at` certificate once (see above).

---

## Versioning

There is nothing separate to build: `docker compose up -d` builds the images
locally on the host. Versioning exists only to track changes and to let you see
when a newer release is available. The `VERSION` file and the top entry of
[CHANGELOG.md](CHANGELOG.md) carry the current version, and a GitHub release is
published for each version (bump `VERSION`, add a `## x.y.z` section to the
changelog, and push to `main`). To update an existing deployment, pull the
latest and run `docker compose up -d --build`.

## Testing

The integration suite (functionality, reliability failsafes, and ntfy alert
delivery) lives in [tests/](tests/):

```bash
cd tests && ./run-tests.sh
```

## Privacy and security

- User mail and passwords are never decrypted or stored on the box; the service
  forwards ciphertext only.
- The only secret the box holds is the carrier VPN account, which is the
  operator's own.
- There is no analytics, telemetry, or phone-home of any kind. The watchdog
  contacts only the ntfy topic you configure.

## License

EasyUniMailProxy is free software, licensed under the
[GNU General Public License v3.0 or later](LICENSE). `vpn/headless.py` is a
modified copy of a file from
[openconnect-saml](https://github.com/mschabhuettl/openconnect-saml)
(GPL-3.0-or-later). It builds on
[OpenConnect](https://www.infradead.org/openconnect/) and
[socat](http://www.dest-unreach.org/socat/). See
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) for all attributions.

*"University of Graz", "uniLOGIN", and "Microsoft Exchange" are trademarks of
their respective owners and are used here only to describe compatibility.*
