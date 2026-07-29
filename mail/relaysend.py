#!/usr/bin/env python3
"""Postfix pipe transport: relay a submitted message to the university.

Postfix accepts the user's submission on 587, queues it durably, and hands each
queued message to this script. We authenticate to the university's submission
server as the sender (with their stored, decrypted university password) and send.

Using a pipe + Python smtplib (rather than Postfix's own SASL) means:
  * no SASL plugins in the image, so mbsync keeps using the plain IMAP LOGIN it
    needs (the university rejects SASL PLAIN/NTLM here);
  * smtplib base64-encodes the "bzedvz\\<email>" username, so the backslash is
    not mangled;
  * Postfix still owns the queue and retries: we exit EX_TEMPFAIL on a transient
    failure (tunnel down, upstream busy) and Postfix tries again later, which is
    what makes "send while away" work.

argv: <sender> <recipient> [<recipient> ...]   (message body on stdin)
"""
import ssl
import sys

sys.path.insert(0, "/usr/local/bin")
import authcheck as a

EX_OK, EX_UNAVAILABLE, EX_NOPERM, EX_TEMPFAIL = 0, 69, 77, 75
UNI_HOST = "email.uni-graz.at"
UNI_PORT = 587


def main() -> int:
    import smtplib
    if len(sys.argv) < 3:
        sys.stderr.write("relaysend: usage: relaysend <sender> <recipient>...\n")
        return EX_TEMPFAIL
    sender = sys.argv[1]
    recipients = sys.argv[2:]
    message = sys.stdin.buffer.read()

    email = a.normalize(sender)
    try:
        with open(f"/mail/.creds/{email}/upass.enc", "rb") as fh:
            password = a.decrypt_secret(fh.read())
    except Exception:  # noqa: BLE001 - sender has no stored credentials
        sys.stderr.write(f"relaysend: sender {email} is not enrolled; cannot relay\n")
        return EX_NOPERM

    try:
        server = smtplib.SMTP(UNI_HOST, UNI_PORT, timeout=60)
        server.ehlo()
        server.starttls(context=ssl.create_default_context())
        server.ehlo()
        server.login("bzedvz\\" + email, password)
        server.sendmail(sender, recipients, message)
        server.quit()
        return EX_OK
    except smtplib.SMTPAuthenticationError:
        # The stored password no longer works (the user changed their university
        # password). Drop the credentials so the client is prompted to re-enter it,
        # and defer this message so Postfix retries once the user has re-enrolled.
        sys.stderr.write("relaysend: university rejected the sender's credentials; de-enrolling\n")
        a.deauth(email)
        return EX_TEMPFAIL
    except smtplib.SMTPRecipientsRefused as exc:
        sys.stderr.write(f"relaysend: recipients refused: {exc.recipients}\n")
        return EX_UNAVAILABLE
    except (smtplib.SMTPException, OSError) as exc:
        # Transient: tunnel down, upstream busy, TLS hiccup. Postfix will retry.
        sys.stderr.write(f"relaysend: transient failure, will retry: {exc}\n")
        return EX_TEMPFAIL


if __name__ == "__main__":
    sys.exit(main())
