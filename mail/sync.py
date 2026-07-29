#!/usr/bin/env python3
"""Sync each enrolled user's local Maildir with their university mailbox.

Runs as the mail user (vmail). For every enrolled user it decrypts the stored
university password (under the master key), writes a temporary mbsync config, and
runs mbsync to reconcile the local Maildir with the university IMAP mailbox over
the tunnel. mbsync is UID-based, so it never duplicates or loses messages, and it
keeps a per-folder SyncState alongside the mail, so a wiped cache re-pulls cleanly
rather than pushing spurious deletions upstream.

Env knobs (all optional):
  UPSTREAM_IMAP_HOST  university IMAP host (default email.uni-graz.at)
  SYNC_MODE           mbsync Sync mode: Pull | Push | All (default All = two-way)
  SYNC_PATTERNS       folder patterns (default "*"); e.g. "INBOX" to limit
  SYNC_MAXMSG         cap messages kept locally per folder (0 = unlimited)
"""
import glob
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, "/usr/local/bin")
import authcheck as a  # reuse decrypt_secret + the credential layout

MAIL_SERVER = os.environ.get("UPSTREAM_IMAP_HOST", "email.uni-graz.at")
SYNC_MODE = os.environ.get("SYNC_MODE", "All")
SYNC_PATTERNS = os.environ.get("SYNC_PATTERNS", "*")
SYNC_MAXMSG = os.environ.get("SYNC_MAXMSG", "0")


def log(msg: str):
    print(f"[sync] {msg}", flush=True)


def enrolled_users():
    return [
        os.path.basename(d.rstrip("/"))
        for d in glob.glob("/mail/.creds/*/")
        if os.path.isfile(os.path.join(d, "upass.enc"))
    ]


def mbsyncrc(email: str, maildir: str) -> str:
    # A MaxMessages cap keeps the local cache bounded; ExpireUnread no makes sure
    # it only ever drops old READ mail, never anything unread.
    maxmsg = (f"MaxMessages {SYNC_MAXMSG}\nExpireUnread no\n"
              if SYNC_MAXMSG not in ("", "0") else "")
    # The university login is "bzedvz\\<email>". mbsync sends it in the plain IMAP
    # LOGIN command (the image ships no SASL plugins, so no AUTHENTICATE is used -
    # Exchange rejects SASL PLAIN/NTLM here anyway), and it does NOT escape the
    # backslash itself. So we DOUBLE the backslash in the config: mbsync passes it
    # through verbatim, and the server unescapes "\\\\" back to one "\\". (Verified
    # against the live server; a single backslash mangles the username -> NO LOGIN.)
    # PassCmd reads the password from the environment we hand mbsync, so it never
    # lands in the config file and any characters in it are safe.
    return f"""
IMAPAccount uni
Host {MAIL_SERVER}
Port 993
User bzedvz\\\\{email}
PassCmd "printenv UNI_PW"
SSLType IMAPS
SystemCertificates yes
AuthMechs LOGIN

IMAPStore uni-remote
Account uni

MaildirStore uni-local
Inbox {maildir}/
SubFolders Maildir++

Channel uni
Far :uni-remote:
Near :uni-local:
Patterns {SYNC_PATTERNS}
Create Both
Expunge Both
{maxmsg}Sync {SYNC_MODE}
SyncState *
"""


def sync_user(email: str, boxes=None):
    """Reconcile the user's local Maildir with the university. `boxes` limits the
    run to specific mailboxes (e.g. "INBOX") for a fast push; None syncs all."""
    try:
        with open(f"/mail/.creds/{email}/upass.enc", "rb") as fh:
            pw = a.decrypt_secret(fh.read())
    except Exception as exc:  # noqa: BLE001
        log(f"{email}: cannot read stored credentials ({exc})")
        return
    maildir = f"/mail/{email}/Maildir"
    os.makedirs(maildir, exist_ok=True)

    with tempfile.NamedTemporaryFile("w", suffix=".mbsyncrc", delete=False) as fh:
        fh.write(mbsyncrc(email, maildir))
        cfg = fh.name
    os.chmod(cfg, 0o600)
    channel = "uni" if not boxes else f"uni:{boxes}"
    label = boxes or "all folders"
    env = {**os.environ, "UNI_PW": pw}
    try:
        r = subprocess.run(["mbsync", "-c", cfg, channel],
                           env=env, capture_output=True, text=True, timeout=1800)
        if r.returncode == 0:
            log(f"{email}: sync OK ({label})")
        else:
            err = (r.stderr or r.stdout).strip()
            log(f"{email}: mbsync rc={r.returncode} ({label}): {err[:400]}")
            # If the university rejected the login (not a network hiccup), the user
            # changed their password: drop the stored credentials so the client is
            # prompted to re-enter it (see authcheck.deauth).
            low = err.lower()
            if ("authenticationfailed" in low or "authentication failed" in low
                    or "login failed" in low):
                a.deauth(email)
    except subprocess.TimeoutExpired:
        log(f"{email}: sync timed out ({label})")
    finally:
        os.unlink(cfg)


def main():
    users = enrolled_users()
    if not users:
        return
    for email in users:
        sync_user(email)


if __name__ == "__main__":
    main()
