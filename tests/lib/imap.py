"""Probe: native IMAP experience through the proxy.

Logs in with the carrier account (from the container's env), lists folders, and
reports special-use + IDLE capability. Prints one `key=value` line; exits 0/1.
"""
import os
import socket
import ssl
import sys


def q(x):
    return '"' + x.replace("\\", "\\\\").replace('"', '\\"') + '"'


def read_until(sock, tag, limit=80000):
    buf = b""
    sock.settimeout(10)
    while len(buf) < limit:
        chunk = sock.recv(8000)
        if not chunk:
            break
        buf += chunk
        for line in buf.split(b"\r\n"):
            if (line.startswith(tag + b" OK")
                    or line.startswith(tag + b" NO")
                    or line.startswith(tag + b" BAD")):
                return buf.decode(errors="replace")
    return buf.decode(errors="replace")


user = "bzedvz\\" + os.environ["VPN_USERNAME"]
pw = os.environ["VPN_PASSWORD"]

try:
    ctx = ssl.create_default_context()
    with socket.create_connection(("127.0.0.1", 993), timeout=10) as raw:
        with ctx.wrap_socket(raw, server_hostname="email.uni-graz.at") as s:
            s.settimeout(10)
            s.recv(200)  # greeting
            s.sendall(b"c1 CAPABILITY\r\n")
            cap = read_until(s, b"c1")
            idle = "IDLE" in cap.upper()
            s.sendall(("a1 LOGIN " + q(user) + " " + q(pw) + "\r\n").encode())
            if "a1 OK" not in read_until(s, b"a1"):
                print("FAIL login rejected by server")
                sys.exit(1)
            s.sendall(b'a2 LIST "" "*"\r\n')
            r = read_until(s, b"a2")
            folders = [ln for ln in r.split("\r\n") if ln.startswith("* LIST")]
            special = [k for k in ("\\Trash", "\\Sent", "\\Junk", "\\Drafts")
                       if any(k in ln for ln in folders)]
            s.sendall(b"a3 LOGOUT\r\n")
    if not folders:
        print("FAIL login OK but no folders returned")
        sys.exit(1)
    print(f"OK login=yes folders={len(folders)} special={len(special)} "
          f"special_list={','.join(special)} idle={'yes' if idle else 'no'}")
    sys.exit(0)
except Exception as e:  # noqa: BLE001
    print(f"FAIL {type(e).__name__}: {e}")
    sys.exit(1)
