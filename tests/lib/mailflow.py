"""Probe: full outgoing + incoming round trip.

Submits a uniquely-tagged message through 587 (STARTTLS), polls the INBOX via
993 until it arrives, measures latency, then DELETES the test message (so the
suite leaves no clutter). Sends to the carrier's own address unless an address
is given as argv[1]. Prints one `key=value` line; exits 0/1.
"""
import os
import ssl
import sys
import time
import uuid
import imaplib
import smtplib
from email.message import EmailMessage

sender = os.environ["VPN_USERNAME"]
to = sys.argv[1] if len(sys.argv) > 1 else sender
login = "bzedvz\\" + sender
pw = os.environ["VPN_PASSWORD"]

marker = uuid.uuid4().hex[:12]
subject = f"EUMP-suite-selftest {marker}"

msg = EmailMessage()
msg["From"] = sender
msg["To"] = to
msg["Subject"] = subject
msg.set_content(
    "Automated EasyUniMailProxy test message. Safe to ignore - the test suite "
    "deletes it automatically after confirming delivery.\n")

# Talking to 127.0.0.1, but the cert behind the passthrough is the uni's, so we
# can't verify hostname here; reachability + protocol is what this probe checks.
ctx = ssl._create_unverified_context()

try:
    t0 = time.time()
    s = smtplib.SMTP("127.0.0.1", 587, timeout=30)
    s.ehlo("suite")
    s.starttls(context=ctx)
    s.ehlo("suite")
    s.login(login, pw)
    s.send_message(msg)
    s.quit()
    submit_s = round(time.time() - t0, 1)

    for _ in range(20):  # up to ~40s
        time.sleep(2)
        M = imaplib.IMAP4_SSL("127.0.0.1", 993, ssl_context=ctx)
        try:
            M.login(login, pw)
            M.select("INBOX")
            typ, data = M.uid("search", None, f'(HEADER Subject "{marker}")')
            ids = data[0].split()
            if ids:
                latency = round(time.time() - t0, 1)
                M.uid("store", ids[-1], "+FLAGS", "(\\Deleted)")
                M.expunge()
                M.logout()
                print(f"OK submit={submit_s}s arrived=yes latency={latency}s "
                      f"cleaned=yes subject={subject!r}")
                sys.exit(0)
        finally:
            try:
                M.logout()
            except Exception:  # noqa: BLE001
                pass

    print(f"FAIL submit={submit_s}s but message not received within timeout "
          f"subject={subject!r}")
    sys.exit(1)
except Exception as e:  # noqa: BLE001
    print(f"FAIL {type(e).__name__}: {e}")
    sys.exit(1)
