# The mail container: the client-facing IMAP/SMTP server for EasyUniMailProxy 2.0.
# It terminates the client's TLS with our own certificate, serves local mailboxes
# (synced from the university), and (later phases) queues outbound mail. See
# docs/DEVELOPMENT.md.
FROM debian:12-slim

LABEL org.opencontainers.image.title="EasyUniMailProxy - mail server" \
      org.opencontainers.image.description="Client-facing IMAP/SMTP with local mailboxes, own TLS certificate, synced over the uni VPN" \
      org.opencontainers.image.licenses="GPL-3.0-or-later" \
      org.opencontainers.image.source="https://github.com/david-dorner/EasyUniMailProxy"

# dovecot-core / dovecot-imapd - the IMAP server clients connect to
# postfix        - the SMTP submission endpoint (587) and outbound queue/relay
# openssl        - self-signed certs (CERT_MODE=selfsigned) and key handling
# ca-certificates- validate Let's Encrypt / upstream TLS
# curl           - fetch the pinned lego release
# bash           - entrypoint + cert.sh
# The debconf preseed keeps the postfix install non-interactive and generates a
# base /etc/postfix/main.cf + master.cf (the mailname is a placeholder; the
# entrypoint overrides the real settings via postconf at runtime).
RUN echo "postfix postfix/main_mailer_type select Internet Site" | debconf-set-selections \
    && echo "postfix postfix/mailname string localhost" | debconf-set-selections \
    && apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        dovecot-core \
        dovecot-imapd \
        postfix \
        isync \
        openssl \
        ca-certificates \
        curl \
        bash \
        tpm2-tools \
        gocryptfs \
        fuse3 \
        python3 \
        python3-cryptography \
    && rm -rf /var/lib/apt/lists/*

# lego - the ACME client that obtains/renews the Let's Encrypt certificate. Pinned
# by version (integrity hardening tightens this to a digest check in a later phase).
ARG LEGO_VERSION=4.17.4
ARG LEGO_ARCH=amd64
RUN curl -fsSL "https://github.com/go-acme/lego/releases/download/v${LEGO_VERSION}/lego_v${LEGO_VERSION}_linux_${LEGO_ARCH}.tar.gz" \
        -o /tmp/lego.tgz \
    && tar -xzf /tmp/lego.tgz -C /usr/local/bin lego \
    && rm /tmp/lego.tgz \
    && lego --version

# Dedicated unprivileged user that owns all mail storage.
RUN groupadd -g 5000 vmail \
    && useradd -u 5000 -g vmail -d /mail -s /usr/sbin/nologin vmail \
    && mkdir -p /mail /certs \
    && chown vmail:vmail /mail

COPY dovecot/dovecot.conf /etc/dovecot/dovecot.conf
COPY cert.sh /usr/local/bin/cert.sh
COPY keys.sh /usr/local/bin/keys.sh
COPY authcheck.py /usr/local/bin/authcheck.py
COPY sync.py /usr/local/bin/sync.py
COPY idle.py /usr/local/bin/idle.py
COPY relaysend.py /usr/local/bin/relaysend.py
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /usr/local/bin/cert.sh /usr/local/bin/keys.sh /usr/local/bin/authcheck.py \
             /usr/local/bin/sync.py /usr/local/bin/idle.py /usr/local/bin/relaysend.py /entrypoint.sh

EXPOSE 993
ENTRYPOINT ["/entrypoint.sh"]
