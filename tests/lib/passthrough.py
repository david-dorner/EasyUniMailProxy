"""Probe: prove the relay is end-to-end passthrough (operator-blind).

The relay must present the *university's own* certificate, validating strictly
against the public CA set + hostname `email.uni-graz.at`. If the relay were
terminating TLS with its own cert, strict validation would fail. That is the
cryptographic proof the box cannot read the traffic.

    passthrough.py imaps   -> validate the 993 implicit-TLS cert
    passthrough.py smtp    -> EHLO/STARTTLS on 587, then validate the upgraded cert

Prints `key=value` diagnostics; exits 0 on success, 1 on failure.
"""
import socket
import ssl
import sys

mode = sys.argv[1] if len(sys.argv) > 1 else "imaps"


def _cert_ids(cert):
    subj = dict(x[0] for x in cert["subject"]).get("commonName")
    issuer = dict(x[0] for x in cert["issuer"]).get("organizationName")
    return subj, issuer


def _smtp_resp(sock):
    sock.settimeout(8)
    data = b""
    while True:
        chunk = sock.recv(4096)
        if not chunk:
            break
        data += chunk
        lines = [x for x in data.split(b"\r\n") if x]
        if lines and len(lines[-1]) >= 4 and lines[-1][3:4] == b" ":
            break
    return data.decode(errors="replace")


def check_imaps():
    ctx = ssl.create_default_context()
    with socket.create_connection(("127.0.0.1", 993), timeout=10) as raw:
        with ctx.wrap_socket(raw, server_hostname="email.uni-graz.at") as s:
            cn, issuer = _cert_ids(s.getpeercert())
    assert cn == "email.uni-graz.at", f"unexpected cert CN {cn!r} (relay is terminating TLS?)"
    print(f"OK mode=imaps cert_cn={cn} issuer={issuer!r} validation=strict-ca+hostname")


def check_smtp():
    raw = socket.create_connection(("127.0.0.1", 587), timeout=10)
    _smtp_resp(raw)
    raw.sendall(b"EHLO probe\r\n")
    _smtp_resp(raw)
    raw.sendall(b"STARTTLS\r\n")
    if not _smtp_resp(raw).startswith("220"):
        raise AssertionError("server did not accept STARTTLS")
    ctx = ssl.create_default_context()
    tls = ctx.wrap_socket(raw, server_hostname="email.uni-graz.at")  # strict validation
    cn, issuer = _cert_ids(tls.getpeercert())
    tls.sendall(b"EHLO probe\r\n")
    ehlo = _smtp_resp(tls)
    tls.sendall(b"QUIT\r\n")
    tls.close()
    assert cn == "email.uni-graz.at", f"unexpected cert CN {cn!r} (relay is terminating TLS?)"
    auth = any("AUTH" in l for l in ehlo.splitlines())
    assert auth, "no AUTH advertised after STARTTLS"
    print(f"OK mode=smtp cert_cn={cn} issuer={issuer!r} auth_advertised=yes")


try:
    if mode == "imaps":
        check_imaps()
    elif mode == "smtp":
        check_smtp()
    else:
        print(f"FAIL unknown mode {mode!r}")
        sys.exit(2)
    sys.exit(0)
except Exception as e:  # noqa: BLE001
    print(f"FAIL {type(e).__name__}: {e}")
    sys.exit(1)
