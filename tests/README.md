# EasyUniMailProxy test suite

Linux-native integration tests for the Docker stack. The structure mirrors the sibling EasyUniVPN suite (a runner, `helpers/`, numbered suites, a describe/it/assert harness, a colored summary, and teardown), but it is written in bash because this project runs on Linux, and it drives the real stack through `docker compose`.

Functional checks are small Python probes under `lib/`. The client-facing ones (IMAP, mail flow) are fed into the `mail` container (`mail_probe`), the one that serves clients in 2.0; the tunnel/auth ones are fed into the `vpn` container (`probe`). So the tests speak the same IMAP, SMTP, and TLS a real mail client does, against the same endpoints a client uses.

## Requirements

- Linux or WSL, with `docker` and `docker compose`, `bash`, `curl` (for the ntfy checks), and the usual `awk`, `grep`, and `timeout`.
- A filled-in `../.env` (the stack's own configuration): `VPN_USERNAME`, `VPN_PASSWORD`, `VPN_TOTP_SECRET`, and `NTFY_URL`. The suite reads the stack's `.env` directly; there is no separate test `.env`.

## Run

```bash
cd tests
./run-tests.sh                 # full suite (01 to 07): builds, brings the stack up, tears it down after
./run-tests.sh --keep-up       # leave the stack running afterwards
./run-tests.sh --only imap     # only suites whose filename contains "imap"
./run-tests.sh --skip-sendmail # do not send a test email (05)
./run-tests.sh --skip-ntfy     # do not send ntfy alerts (07)
./run-tests.sh --include-badauth   # also run 08 (submits a wrong password to the live SSO)
```

The suite restarts and tears down the stack (suite 06 restarts the VPN and does a cold start, and the runner runs `docker compose down` at the end unless `--keep-up`). Do not run it against an instance you need to stay up.

## Suites

| File | Covers |
|------|--------|
| `01-stack.sh`       | containers running and healthy; host ports 993 and 587 open |
| `02-tunnel.sh`      | tun0 has a campus address; mail server reachable; the required CSRFtoken patch is present |
| `03-owncert.sh`     | the box presents its OWN certificate (CN=MAIL_HOSTNAME, not the university's), and the mail store is ciphertext on disk |
| `04-imap.sh`        | login (enrolls on first use), folder discovery, special-use, IDLE, against the local mailbox |
| `05-mailflow.sh`    | real send via the box, arrival back in the INBOX, and cleanup (sends one email) |
| `06-reliability.sh` | failsafes: survives a vpn restart, a killed relay self-restarts, a clean cold start |
| `07-watchdog.sh`    | watchdog and ntfy: notify delivery, healthy ping, and an artificial-failure alert |
| `08-badauth.sh`     | bad-credential fast-fail (opt-in; hits the live SSO) |

## Notes on the functional suites (2.0)

In 2.0 the box serves a local, synced mailbox rather than passing traffic through. The first login enrolls the user (verified against the university), and the mailbox fills on the next sync, so `04` and `05` need a stack that has synced at least once; `05` also waits for a sync cycle for the sent message to return, which can take up to `SYNC_INTERVAL`. Use `--skip-sendmail` to skip the send.

## Notes on the ntfy tests (07)

They run the real watchdog code and send a few alerts to your configured `NTFY_URL`, then poll the topic to confirm delivery automatically. Watch your phone or ntfy app as well; seeing them arrive is the human-verified half the automated poll cannot do for you.
