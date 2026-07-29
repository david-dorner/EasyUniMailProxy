#!/usr/bin/env python3
"""Dovecot checkpassword auth backend: enroll-on-first-login + local verify.

Dovecot runs this for every IMAP/SMTP login. The credentials arrive on file
descriptor 3 as "username\\0password\\0..."; on success we set USER/HOME and exec
the reply program Dovecot passed as argv[1]; on failure we exit non-zero.

Logic:
  * Normalize the username: the user may type either "bzedvz\\name@edu.uni-graz.at"
    or the plain "name@edu.uni-graz.at". We canonicalize to the lower-case plain
    address for the local identity, and add the "bzedvz\\" form only when talking
    to the university.
  * If the user is already enrolled, verify the password against the stored hash
    (fast, offline, no university contact).
  * If not enrolled (or the stored hash no longer matches, e.g. the university
    password was changed), verify the password against the real university IMAP
    through the tunnel. On success, (re)enroll: store a password hash for future
    local checks and the university password encrypted under the master key, so
    the sync engine can act for the user later. A short per-user cooldown keeps a
    wrong-password flood from hammering the university.

Storage, under /mail/.creds/<email>/ (same volume as the cache, so a master-key
change discards it together with the mail):
    passhash    crypt(SHA-512) of the password, for local verification
    upass.enc   the university password, encrypted (Fernet/AES) under the master key
    last_uni    epoch of the last university verification attempt (cooldown)
"""
import base64
import warnings
with warnings.catch_warnings():
    # crypt is deprecated in 3.13 but present and fine on the image's Python 3.11;
    # silence the noisy warning so Dovecot does not log it as an auth error.
    warnings.simplefilter("ignore", DeprecationWarning)
    import crypt
import hashlib
import hmac
import imaplib
import os
import ssl
import sys
import time

MASTER_KEY_FILE = "/run/mail/master.key"
CREDS_ROOT = "/mail/.creds"
MAIL_SERVER = os.environ.get("UPSTREAM_IMAP_HOST", "email.uni-graz.at")
MAIL_PORT = int(os.environ.get("UPSTREAM_IMAP_PORT", "993"))
UNI_COOLDOWN = int(os.environ.get("ENROLL_COOLDOWN", "5"))  # seconds between uni checks


def log(msg: str):
    print(f"[auth] {msg}", file=sys.stderr, flush=True)


# ── Username handling ────────────────────────────────────────────────────────
def normalize(username: str) -> str:
    """Canonical local identity: strip any 'DOMAIN\\' prefix, lower-case."""
    u = username.strip()
    if "\\" in u:
        u = u.split("\\", 1)[1]
    return u.lower()


def upstream_user(email: str) -> str:
    """The form the university expects for mail login."""
    return "bzedvz\\" + email


# ── Encryption (uni password at rest) ────────────────────────────────────────
def _fernet():
    from cryptography.fernet import Fernet
    with open(MASTER_KEY_FILE, "rb") as fh:
        material = fh.read()
    key = base64.urlsafe_b64encode(hashlib.sha256(material).digest())
    return Fernet(key)


def encrypt_secret(secret: str) -> bytes:
    return _fernet().encrypt(secret.encode("utf-8"))


def decrypt_secret(token: bytes) -> str:
    return _fernet().decrypt(token).decode("utf-8")


# ── Credential store ─────────────────────────────────────────────────────────
def creds_dir(email: str) -> str:
    return os.path.join(CREDS_ROOT, email)


def is_enrolled(email: str) -> bool:
    return os.path.isfile(os.path.join(creds_dir(email), "passhash"))


def verify_local(email: str, password: str) -> bool:
    try:
        with open(os.path.join(creds_dir(email), "passhash")) as fh:
            stored = fh.read().strip()
    except OSError:
        return False
    return hmac.compare_digest(crypt.crypt(password, stored), stored)


VMAIL_UID = int(os.environ.get("VMAIL_UID", "5000"))
VMAIL_GID = int(os.environ.get("VMAIL_GID", "5000"))


def _own_by_mail(path: str):
    """Hand a path to the mail user, so the imap/sync processes (which run as
    vmail) can use it even though enrollment may run as root."""
    try:
        os.chown(path, VMAIL_UID, VMAIL_GID)
    except (PermissionError, FileNotFoundError, OSError):
        pass


def enroll(email: str, password: str):
    d = creds_dir(email)
    os.makedirs(d, mode=0o700, exist_ok=True)
    passhash = crypt.crypt(password, crypt.mksalt(crypt.METHOD_SHA512))
    _write(os.path.join(d, "passhash"), passhash.encode())
    _write(os.path.join(d, "upass.enc"), encrypt_secret(password))
    mbox = f"/mail/{email}"
    os.makedirs(mbox, mode=0o700, exist_ok=True)
    for path in [d, mbox] + [os.path.join(d, f) for f in os.listdir(d)]:
        _own_by_mail(path)
    log(f"enrolled {email}")


def deauth(email: str):
    """Drop a user's stored credentials after the university rejects them (the
    user changed their university password). The stale password then stops passing
    the fast local check, so the client's old password fails, the client prompts
    for the new one, and entering it re-verifies against the university and
    re-enrolls - the same experience as a normal account whose password changed.
    The cached mail is left untouched. Safe if it fires on a false alarm: the
    client simply re-authenticates with its still-valid password and re-enrolls."""
    d = creds_dir(email)
    for name in ("passhash", "upass.enc", "last_uni"):
        try:
            os.remove(os.path.join(d, name))
        except OSError:
            pass
    log(f"de-enrolled {email}: university rejected the stored password; the client must re-enter it")


def _write(path: str, data: bytes):
    tmp = path + ".tmp"
    with open(tmp, "wb") as fh:
        fh.write(data)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def cooldown_ok(email: str) -> bool:
    """True if we may contact the university for this user right now."""
    d = creds_dir(email)
    os.makedirs(d, mode=0o700, exist_ok=True)
    marker = os.path.join(d, "last_uni")
    now = time.time()
    try:
        last = float(open(marker).read().strip())
    except (OSError, ValueError):
        last = 0.0
    if now - last < UNI_COOLDOWN:
        return False
    _write(marker, str(now).encode())
    return True


# ── University verification ──────────────────────────────────────────────────
def verify_uni(email: str, password: str) -> bool:
    """Log in to the real university IMAP (through the tunnel) to check the password."""
    ctx = ssl.create_default_context()  # validates the genuine email.uni-graz.at cert
    try:
        conn = imaplib.IMAP4_SSL(MAIL_SERVER, MAIL_PORT, ssl_context=ctx, timeout=20)
    except Exception as exc:  # noqa: BLE001 - network/tunnel down = temporary failure
        log(f"cannot reach university IMAP ({exc}); temporary failure")
        sys.exit(111)  # tell Dovecot this is temporary, not a wrong password
    try:
        conn.login(upstream_user(email), password)
        conn.logout()
        return True
    except imaplib.IMAP4.error:
        return False
    finally:
        try:
            conn.shutdown()
        except Exception:  # noqa: BLE001
            pass


# ── Main auth decision ───────────────────────────────────────────────────────
def authenticate(email: str, password: str) -> bool:
    if is_enrolled(email):
        if verify_local(email, password):
            return True
        # Stored hash did not match: the university password may have changed.
        if cooldown_ok(email) and verify_uni(email, password):
            enroll(email, password)  # refresh the stored hash + encrypted password
            return True
        return False
    # First time we see this user: only the university can vouch for them.
    if cooldown_ok(email) and verify_uni(email, password):
        enroll(email, password)
        return True
    return False


def main():
    try:
        raw = os.read(3, 4096)
    except OSError:
        sys.exit(2)  # not called by Dovecot (no fd 3) = misuse
    parts = raw.split(b"\0")
    username = parts[0].decode("utf-8", "replace") if parts else ""
    password = parts[1].decode("utf-8", "replace") if len(parts) > 1 else ""
    email = normalize(username)
    if not password or "@" not in email:
        sys.exit(1)

    if not authenticate(email, password):
        sys.exit(1)

    os.environ["USER"] = email
    os.environ["HOME"] = f"/mail/{email}"
    reply = sys.argv[1] if len(sys.argv) > 1 else None
    if not reply:
        sys.exit(0)  # allow standalone testing without a reply program
    os.execv(reply, [reply])


if __name__ == "__main__":
    main()
