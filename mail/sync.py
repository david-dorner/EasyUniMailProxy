#!/usr/bin/env python3
"""Sync each enrolled user's local Maildir with their university mailbox.

Runs as the mail user (vmail). For every enrolled user it decrypts the stored
university password (under the master key), writes a temporary mbsync config, and
runs mbsync to reconcile the local Maildir with the university IMAP mailbox over
the tunnel. mbsync is UID-based, so it never duplicates or loses messages, and it
keeps a per-folder SyncState alongside the mail, so a wiped cache re-pulls cleanly
rather than pushing spurious deletions upstream.

A folder mbsync once mirrored locally can stop existing on the far side (the
university renames or reorganizes its special folders - e.g. it used to expose
plain "Sent"/"Drafts"/"Spam" and later switched to its Exchange locale's own
names, "Gesendete Elemente"/"Entwuerfe"/"Junk-E-Mail"). mbsync's Maildir driver
treats "far side box cannot be opened" as fatal to the WHOLE channel, so one
orphaned local folder silently blocks sync for every folder, including INBOX,
until someone notices mail stopped arriving. quarantine_stale_folders() runs a
live far-side LIST before every full sync and moves any local folder that is no
longer present over there out of mbsync's way (see its docstring), so this
degrades to "that one old folder stops updating" instead of "nothing syncs".

Env knobs (all optional):
  UPSTREAM_IMAP_HOST  university IMAP host (default email.uni-graz.at)
  SYNC_MODE           mbsync Sync mode: Pull | Push | All (default All = two-way)
  SYNC_PATTERNS       folder patterns (default "*"); e.g. "INBOX" to limit
  SYNC_MAXMSG         cap messages kept locally per folder (0 = unlimited)
"""
import glob
import imaplib
import os
import shutil
import ssl
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, "/usr/local/bin")
import authcheck as a  # reuse decrypt_secret + the credential layout
from imap_list import imap_utf7_decode, parse_list  # shared LIST parsing + UTF-7 decode

MAIL_SERVER = os.environ.get("UPSTREAM_IMAP_HOST", "email.uni-graz.at")
UPSTREAM_IMAP_PORT = int(os.environ.get("UPSTREAM_IMAP_PORT", "993"))
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
Create Near
Expunge Both
{maxmsg}Sync {SYNC_MODE}
SyncState *
"""
# Create Near (not Both): folders are only ever created LOCALLY to mirror the
# university - we never create a folder on the university side. This keeps the
# box a faithful mirror of exactly the folders the university exposes and stops a
# client's own folders (e.g. Thunderbird's English "Sent"/"Drafts") from being
# pushed up and polluting the real mailbox. Messages and flags still sync both
# ways for folders that exist on both sides.


def far_side_folders(email: str, pw: str) -> set[str]:
    """The live set of folder names the university exposes right now, via a
    direct IMAP LIST (not mbsync's own idea of them, which only updates as it
    syncs). Raises on a network/login failure; the caller decides how to treat
    "couldn't check" vs. "checked, and it's really gone".

    The university reports its own IMAP hierarchy separator per folder (e.g. a
    child folder comes back as "Sync Issues/Conflicts" with sep "/"), but
    mbsync's MaildirStore uses the Maildir++ on-disk convention, which is always
    "." regardless of the IMAP separator - so names here are translated to "."
    (whatever separator the server actually reports, not assumed) to compare
    like-for-like with _local_subfolders()'s decoded names."""
    m = imaplib.IMAP4_SSL(MAIL_SERVER, UPSTREAM_IMAP_PORT,
                           ssl_context=ssl.create_default_context(), timeout=30)
    try:
        m.login(a.upstream_user(email), pw)
        names = set()
        for name, _flags, sep in parse_list(m.list()[1]):
            names.add(name.replace(sep, ".") if sep else name)
    finally:
        try:
            m.logout()
        except Exception:  # noqa: BLE001
            pass
    return names


# Local Maildir++ subfolders are directories named ".<folder>" (dots in the
# folder name itself are escaped elsewhere, e.g. "Sync Issues.Conflicts" is
# ".Sync Issues.Conflicts"), and mbsync stores the folder name on disk in raw
# IMAP modified UTF-7 (e.g. ".Entw&APw-rfe"), the same form the far side sends
# it in - so it must be UTF-7-decoded the same way before comparing against the
# (already-decoded) far-side names, or a live, correctly-named folder with any
# non-ASCII character in it looks "stale" purely because of the encoding.
def _local_subfolders(maildir: str) -> list[tuple[str, str]]:
    """Returns [(decoded_name, raw_dir_name), ...]."""
    out = []
    for raw in os.listdir(maildir):
        if raw.startswith(".") and os.path.isdir(os.path.join(maildir, raw)):
            out.append((imap_utf7_decode(raw[1:]), raw[1:]))
    return out


def quarantine_stale_folders(email: str, maildir: str, far_names: set[str]):
    """Move any local folder that mbsync once mirrored but the university no
    longer exposes OUT of the Maildir root entirely (into a "stale-folders"
    directory that is a SIBLING of Maildir, not inside it - a dot-directory
    placed inside the Maildir root is itself a Maildir++ folder as far as
    Dovecot/mbsync are concerned, and would immediately get indexed and shown
    to the client as an empty mailbox, which defeats the point), so:
      * mbsync's `Patterns *` never sees it again (its "far side box cannot be
        opened" error is fatal to the whole sync channel - see the module
        docstring), so this one dead folder can no longer block INBOX or any
        other folder from syncing;
      * Dovecot stops listing/advertising it, so Thunderbird (and any other
        client) drops it from the folder pane on its next refresh instead of
        showing a dead duplicate next to the real, correctly-named folder.
    The mail itself is kept (moved, not deleted) under stale-folders/<folder>-
    <ts>/ in case anything in it was never actually mirrored into its live
    replacement.
    """
    try:
        far_names = far_names | {"INBOX"}  # never touch the inbox itself
        local = _local_subfolders(maildir)
    except FileNotFoundError:
        return
    stale = [(decoded, raw) for decoded, raw in local if decoded not in far_names]
    if not stale:
        return
    # maildir is ".../<email>/Maildir"; the quarantine dir is its sibling, so it
    # sits under the user's own area but outside anything Dovecot/mbsync walk.
    quarantine = os.path.join(os.path.dirname(maildir), "stale-folders")
    os.makedirs(quarantine, exist_ok=True)
    ts = int(time.time())
    for decoded, raw in stale:
        src = os.path.join(maildir, f".{raw}")
        dst = os.path.join(quarantine, f"{decoded}-{ts}")
        try:
            shutil.move(src, dst)
            log(f"{email}: '{decoded}' no longer exists on the university server; "
                f"moved local copy to stale-folders/{decoded}-{ts} so sync is not blocked")
        except OSError as exc:
            log(f"{email}: could not quarantine stale folder '{decoded}' ({exc})")


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

    # Only check on a full run (not the fast per-box INBOX push from IDLE): it's
    # one extra IMAP round-trip, cheap but pointless to pay on every push. A
    # failure here (network hiccup) just skips this pass's check - mbsync still
    # runs against whatever is on disk, same as before this existed.
    if boxes is None:
        try:
            far_names = far_side_folders(email, pw)
            quarantine_stale_folders(email, maildir, far_names)
        except Exception as exc:  # noqa: BLE001
            log(f"{email}: could not check far-side folder list ({exc.__class__.__name__}: {exc}); "
                f"skipping stale-folder check this round")

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
