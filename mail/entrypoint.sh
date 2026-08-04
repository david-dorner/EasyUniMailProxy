#!/usr/bin/env bash
# The mail container: a real IMAP server that clients connect to, presenting our
# own certificate (so there is no hostname-mismatch warning on any device). This
# phase stands up the client-facing IMAP endpoint with local authentication;
# filling each mailbox from the university and outbound submission come next.
set -euo pipefail

: "${MAIL_HOSTNAME:?set MAIL_HOSTNAME in .env (the name clients connect to)}"

# 0. Resolve the at-rest master key (KEY_MODE) before anything stores or reads
#    encrypted data. Writes the live key to /run/mail/master.key (tmpfs).
/usr/local/bin/keys.sh
# Let the mail user (which runs the auth-worker and the mail processes) read the
# live master key and own the credential store.
chgrp vmail /run/mail /run/mail/master.key 2>/dev/null || true
chmod 0750 /run/mail 2>/dev/null || true
chmod 0640 /run/mail/master.key 2>/dev/null || true

# 0b. Mount the encrypted mail store. Everything under /mail (mailboxes and the
#     credential store) is written through gocryptfs, so the mail-data volume
#     holds only ciphertext; the plaintext view exists only inside this mount.
#     The encryption key derives from the master key, so a changed master key
#     cannot open the store - we then re-initialize it and the mail re-syncs.
CIPHER_DIR=/mnt/cipher
mkdir -p "$CIPHER_DIR" /mail
grep -q '^user_allow_other' /etc/fuse.conf 2>/dev/null || echo 'user_allow_other' >> /etc/fuse.conf
mount_store() { gocryptfs -q -nosyslog -passfile /run/mail/master.key -allow_other "$CIPHER_DIR" /mail; }
if [ ! -f "$CIPHER_DIR/gocryptfs.conf" ]; then
    echo "[mail] initializing the encrypted mail store."
    gocryptfs -q -nosyslog -init -passfile /run/mail/master.key "$CIPHER_DIR"
fi
if ! mount_store; then
    echo "[mail] WARNING: the encrypted mail store will not open with the current key (master key"
    echo "[mail]          changed?). Discarding it and re-initializing so the mailboxes re-sync."
    find "$CIPHER_DIR" -mindepth 1 -delete 2>/dev/null || true
    gocryptfs -q -nosyslog -init -passfile /run/mail/master.key "$CIPHER_DIR"
    mount_store
fi
echo "[mail] encrypted mail store mounted at /mail."

# 1. Obtain (or reuse) the TLS certificate per CERT_MODE.
/usr/local/bin/cert.sh run

# 2. Users enroll themselves on first login (see authcheck.py): there is no
#    static user file. Just make sure the encrypted credential store exists,
#    owned by the mail user so the auth-worker can write to it.
install -d -m 0770 -o vmail -g vmail /mail/.creds

# 3. Renew the certificate in the background (a no-op for selfsigned/manual).
( while true; do
      sleep 86400
      if /usr/local/bin/cert.sh renew; then
          doveadm reload 2>/dev/null || true
          echo "[mail] certificate renew check done."
      fi
  done ) &

# 3b. Background mail sync + push. idle.py (as the mail user, so it can read the
#     master key and write the mailboxes) holds an IMAP IDLE connection to each
#     enrolled user's university INBOX, so new mail is pulled in within a couple
#     of seconds; it also runs the periodic full sync (every SYNC_INTERVAL) as a
#     safety net and for other folders, syncs the INBOX first so it mirrors
#     immediately, and subscribes the client to every synced folder. Supervised
#     so a crash restarts it.
( while true; do
      runuser -u vmail -- python3 /usr/local/bin/idle.py 2>&1 || true
      echo "[mail] sync/idle daemon exited; restarting in 5s."
      sleep 5
  done ) &
echo "[mail] mail sync + IDLE push started."

# 3c. Tag the university's special folders (Sent/Drafts/Trash/Junk/Archive) with
#     their roles so every mail client auto-recognizes the localized folder names
#     and does not create its own duplicates. special_use.py (as root: it writes
#     Dovecot config) logs in to the university as an enrolled user, reads the
#     university's OWN special-use flags - no folder names are hardcoded - and
#     writes /etc/dovecot/special-use.conf; we reload Dovecot when it changes.
#     Polls until it can discover (a user is enrolled and the tunnel is up), then
#     relaxes to an hourly refresh in case the folders change.
( interval="${SPECIALUSE_POLL:-30}"
  while true; do
      /usr/local/bin/special_use.py; rc=$?
      case "$rc" in
          10) doveadm reload 2>/dev/null || true; echo "[mail] special-use folder tags applied."; interval=3600 ;;
          0)  interval=3600 ;;
          *)  interval="${SPECIALUSE_POLL:-30}" ;;
      esac
      sleep "$interval"
  done ) &

# 4. Configure and start Postfix: the SMTP submission endpoint on 587, using the
#    same certificate and Dovecot for SASL, so IMAP and SMTP share one login.
#    Outbound relay to the university is added in a later phase; for now it only
#    accepts authenticated submissions from our own users.
postconf -e "myhostname=${MAIL_HOSTNAME}" \
            "smtpd_banner=\$myhostname ESMTP" \
            "compatibility_level=3.6" \
            "maillog_file=/var/log/mail.log" \
            "inet_protocols=ipv4" \
            "mydestination=" \
            "local_recipient_maps=" \
            "smtpd_tls_cert_file=/certs/fullchain.pem" \
            "smtpd_tls_key_file=/certs/key.pem" \
            "smtpd_tls_security_level=may" \
            "smtpd_sasl_type=dovecot" \
            "smtpd_sasl_path=private/auth" \
            "smtpd_sasl_auth_enable=yes" \
            "smtpd_sasl_security_options=noanonymous" \
            "smtpd_relay_restrictions=permit_sasl_authenticated,reject" \
            "smtpd_recipient_restrictions=permit_sasl_authenticated,reject"
# No public SMTP on 25; the only listener is submission (587), TLS + auth required.
postconf -MX 'smtp/inet' 2>/dev/null || true
postconf -M 'submission/inet=submission inet n - n - - smtpd'
postconf -P 'submission/inet/syslog_name=postfix/submission' \
            'submission/inet/smtpd_tls_security_level=encrypt' \
            'submission/inet/smtpd_sasl_auth_enable=yes' \
            'submission/inet/smtpd_relay_restrictions=permit_sasl_authenticated,reject'
# Route all outbound mail through our pipe transport, which relays each message
# to the university as the sender (see relaysend.py). Postfix keeps the durable
# queue and retries, so a message survives a client disconnect or a tunnel blip.
postconf -e "default_transport=unisend"
if ! grep -q '^unisend' /etc/postfix/master.cf; then
    cat >> /etc/postfix/master.cf <<'MCF'
unisend   unix  -       n       n       -       -       pipe
  flags=q user=vmail argv=/usr/local/bin/relaysend.py ${sender} ${recipient}
MCF
fi
# Postfix daemonizes and would lose /dev/stdout, so it logs to a file and we
# relay that file to the container's stdout (this survives the exec below).
: > /var/log/mail.log
tail -n0 -F /var/log/mail.log 2>/dev/null &
newaliases 2>/dev/null || true
postfix start
echo "[mail] Postfix submission (587) up."

# 5. Clean shutdown on docker stop: stop both services.
trap 'echo "[mail] shutting down."; postfix stop 2>/dev/null || true; doveadm stop 2>/dev/null || true; fusermount3 -u /mail 2>/dev/null || true; exit 0' TERM INT

# 5b. Keep Dovecot's login-service sockets connectable by the unprivileged login
#     user. Dovecot's imap-login runs as "dovenull", which is neither the owner
#     nor in the group of the root-owned sockets under /run/dovecot/login/ (the
#     "login" auth socket and the "imap" backend-handoff socket), so it relies on
#     their "other" write bit. On hosts whose container runtime directory carries
#     a default ACL or a restrictive umask, that bit is stripped (sockets come up
#     0664 instead of 0666); login then fails - either "auth-client: connect(login)
#     ... Permission denied" (can't reach auth) or "master(imap): net_connect_unix
#     (imap) failed" (can't hand off after auth) - and clients just see a
#     connection error. Dovecot recreates these at startup (and could on a reload),
#     so we re-assert the mode on every socket in that directory for the life of
#     the container. Backgrounded because Dovecot is exec'd as PID 1 below. The
#     login/ directory itself stays 0750 (root:dovenull), so only Dovecot's own
#     processes can reach these sockets regardless of the 0666 bits.
( applied=0
  while true; do
      if [ -S /run/dovecot/login/login ]; then
          chmod g+x /run/dovecot/login 2>/dev/null || true
          for s in /run/dovecot/login/*; do
              [ -S "$s" ] && chmod 0666 "$s" 2>/dev/null || true
          done
          applied=1
      fi
      # Poll fast until the sockets exist and are fixed (Dovecot creates them a
      # moment after this starts), so there is no startup window where logins
      # fail; then relax to a periodic re-assert in case they are recreated.
      if [ "$applied" = 1 ]; then sleep 15; else sleep 0.2; fi
  done ) &

echo "[mail] starting Dovecot IMAPS on 993 for ${MAIL_HOSTNAME} (CERT_MODE=${CERT_MODE:-selfsigned})."
# 6. Run Dovecot in the foreground so it is the container's main process.
exec dovecot -F
