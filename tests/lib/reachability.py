"""Probe: is the university mail server reachable through the VPN tunnel?

Run inside the vpn container (which owns tun0). Prints one machine-readable line
and exits 0 on success, 1 on failure.
"""
import socket
import sys

try:
    ip = socket.gethostbyname("email.uni-graz.at")
    socket.create_connection((ip, 993), timeout=8).close()
    print(f"OK email.uni-graz.at -> {ip}:993 reachable through tunnel")
    sys.exit(0)
except Exception as e:  # noqa: BLE001
    print(f"FAIL {type(e).__name__}: {e}")
    sys.exit(1)
