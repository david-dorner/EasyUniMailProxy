#!/usr/bin/env python3
"""Near-instant upstream sync: IMAP IDLE push plus a periodic safety-net sync.

Runs as the mail user (vmail). For every enrolled user it:
  * Holds a persistent IMAP connection to the university INBOX and issues IDLE
    (RFC 2177), so the moment the university signals new mail it triggers an
    immediate mbsync of the INBOX. Dovecot then pushes it to the client over its
    own IMAP IDLE, so a new mail reaches the phone/laptop within a couple of
    seconds instead of waiting for the poll.
  * Runs the periodic full sync (every SYNC_INTERVAL) as a safety net and to keep
    folders other than the INBOX in step.
  * Syncs the INBOX first on (re)connect so the most important folder mirrors
    immediately, then the rest. Because Dovecot serves the local Maildir live,
    the client sees messages appear as they download, rather than waiting for the
    whole sync to finish.
  * Subscribes the client to every synced folder (through the local Dovecot), so
    all of the user's folders show up without them subscribing by hand.

It degrades gracefully: if a server does not offer IDLE, or the tunnel is down,
it falls back to the periodic sync and keeps retrying.

Env knobs (optional): everything sync.py reads, plus
  SYNC_INTERVAL   periodic full-sync interval, seconds (default 60)
  IDLE_REFRESH    re-issue IDLE at least this often, seconds (default 1500)
  IDLE_RESCAN     how often to pick up newly enrolled users, seconds (default 30)
"""
import imaplib
import os
import re
import socket
import ssl
import sys
import threading
import time

sys.path.insert(0, "/usr/local/bin")
import authcheck as a  # decrypt_secret + upstream_user + the credential layout
import sync            # enrolled_users + sync_user (mbsync)

HOST = sync.MAIL_SERVER
PORT = int(os.environ.get("UPSTREAM_IMAP_PORT", "993"))
SYNC_INTERVAL = int(os.environ.get("SYNC_INTERVAL", "60"))
IDLE_REFRESH = int(os.environ.get("IDLE_REFRESH", "1500"))
IDLE_RESCAN = int(os.environ.get("IDLE_RESCAN", "30"))
LOCAL_IMAP = ("127.0.0.1", 993)

_locks = {}
_locks_guard = threading.Lock()


def log(msg: str):
    print(f"[idle] {msg}", flush=True)


def _user_lock(email):
    """One mbsync at a time per user, so a push and the periodic run never overlap."""
    with _locks_guard:
        return _locks.setdefault(email, threading.Lock())


def _password(email):
    with open(f"/mail/.creds/{email}/upass.enc", "rb") as fh:
        return a.decrypt_secret(fh.read())


# -- Sync helpers -------------------------------------------------------------
def sync_all_folders(email):
    """INBOX first (so it mirrors immediately), then every folder."""
    with _user_lock(email):
        sync.sync_user(email, boxes="INBOX")
        sync.sync_user(email)


def sync_inbox(email):
    with _user_lock(email):
        sync.sync_user(email, boxes="INBOX")


# -- Folder subscriptions: make every synced folder visible to the client -----
_LIST_RE = re.compile(rb'^\([^)]*\)\s+(?:"[^"]*"|NIL)\s+(?P<name>.+)$')


def _names(lines):
    out = []
    for raw in lines or []:
        if not raw:
            continue
        m = _LIST_RE.match(raw.strip())
        if not m:
            continue
        name = m.group("name").strip()
        if name.startswith(b'"') and name.endswith(b'"'):
            name = name[1:-1]
        out.append(name.decode("ascii", "replace"))
    return out


def subscribe_all(email, password):
    """Subscribe the client to every folder, through the local Dovecot, so the
    user sees all their mail without subscribing by hand. Uses Dovecot's own
    SUBSCRIBE (so the on-disk format is always right) and only adds folders that
    are not subscribed yet."""
    m = None
    try:
        ctx = ssl._create_unverified_context()  # local self-connection to our own IMAP
        m = imaplib.IMAP4_SSL(*LOCAL_IMAP, ssl_context=ctx, timeout=30)
        m.login(email, password)
        have = set(_names(m.lsub()[1]))
        added = 0
        for name in _names(m.list()[1]):
            if name.upper() == "INBOX" or name in have:
                continue
            try:
                if m.subscribe('"%s"' % name)[0] == "OK":
                    added += 1
            except Exception:  # noqa: BLE001
                pass
        if added:
            log(f"{email}: subscribed {added} new folder(s)")
    except Exception as exc:  # noqa: BLE001
        log(f"{email}: subscribe skipped ({exc})")
    finally:
        if m is not None:
            try:
                m.logout()
            except Exception:  # noqa: BLE001
                pass


# -- IMAP IDLE ----------------------------------------------------------------
def _idle_wait(conn, timeout):
    """Issue IDLE, wait up to `timeout`s for a mailbox change, then end IDLE.
    Returns True if the server signalled new/changed mail."""
    tag = conn._new_tag()
    conn.send(tag + b" IDLE\r\n")
    while True:  # the server answers with a "+" continuation once it is idling
        resp = conn.readline()
        if not resp:
            raise imaplib.IMAP4.abort("connection closed starting IDLE")
        if resp.startswith(b"+"):
            break
        if resp.startswith(tag):  # a tagged reply instead = IDLE not accepted
            raise imaplib.IMAP4.abort(f"IDLE not accepted: {resp!r}")
    changed = False
    conn.sock.settimeout(timeout)
    try:
        while True:
            line = conn.readline()
            if not line:
                raise imaplib.IMAP4.abort("connection closed during IDLE")
            up = line.upper()
            if b"EXISTS" in up or b"RECENT" in up:
                changed = True
                break
    except socket.timeout:
        pass
    finally:
        conn.sock.settimeout(None)
    conn.send(b"DONE\r\n")
    while True:  # drain until the IDLE command's tagged completion
        line = conn.readline()
        if not line or line.startswith(tag):
            break
        up = line.upper()
        if b"EXISTS" in up or b"RECENT" in up:
            changed = True
    return changed


def watch_user(email):
    ctx = ssl.create_default_context()  # validates the genuine uni certificate
    backoff = 5
    while True:
        conn = None
        try:
            pw = _password(email)
            conn = imaplib.IMAP4_SSL(HOST, PORT, ssl_context=ctx, timeout=30)
            try:
                conn.login(a.upstream_user(email), pw)
            except imaplib.IMAP4.abort:
                raise  # connection lost mid-login: a transient issue, retry below
            except imaplib.IMAP4.error as exc:
                # The university rejected our stored password: it was changed. Drop
                # the credentials so the client is prompted for the new one, and
                # stop watching until the user re-enrolls by re-entering it.
                log(f"{email}: university rejected the stored password ({exc}); de-enrolling")
                a.deauth(email)
                return
            if "IDLE" not in conn.capabilities:
                log(f"{email}: server does not offer IDLE; relying on periodic sync")
                conn.logout()
                while True:  # stay alive so the manager does not respawn us
                    time.sleep(3600)
            conn.select("INBOX", readonly=True)  # read-only: never touch flags
            log(f"{email}: watching INBOX for new mail")
            sync_all_folders(email)   # catch up on anything missed while away
            subscribe_all(email, pw)  # make every folder visible
            backoff = 5
            while True:
                if _idle_wait(conn, IDLE_REFRESH):
                    log(f"{email}: new mail signalled; syncing INBOX")
                    sync_inbox(email)
        except Exception as exc:  # noqa: BLE001
            log(f"{email}: watch ended ({exc.__class__.__name__}: {exc}); retrying in {backoff}s")
        finally:
            if conn is not None:
                try:
                    conn.logout()
                except Exception:  # noqa: BLE001
                    pass
        time.sleep(backoff)
        backoff = min(backoff * 2, 120)


def periodic():
    """Full sync of every user on an interval: the safety net, and it keeps
    folders other than the INBOX current even without an IDLE signal for them."""
    while True:
        for email in sync.enrolled_users():
            try:
                sync_all_folders(email)
            except Exception as exc:  # noqa: BLE001
                log(f"{email}: periodic sync error ({exc})")
        time.sleep(SYNC_INTERVAL)


def main():
    threading.Thread(target=periodic, daemon=True).start()
    watchers = {}
    while True:
        for email in sync.enrolled_users():
            t = watchers.get(email)
            if t is None or not t.is_alive():
                t = threading.Thread(target=watch_user, args=(email,), daemon=True)
                t.start()
                watchers[email] = t
        time.sleep(IDLE_RESCAN)


if __name__ == "__main__":
    main()
