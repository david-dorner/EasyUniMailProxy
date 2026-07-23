# The tunnel container: openconnect + openconnect-saml, headless SAML auth,
# plus the raw-TCP passthrough relays (folded in so they share the VPN's
# lifecycle). See docs/DEVELOPMENT.md.
FROM python:3.12-slim

LABEL org.opencontainers.image.title="EasyUniMailProxy - vpn + relays" \
      org.opencontainers.image.description="University of Graz VPN tunnel with raw-TCP IMAP/SMTP passthrough relays" \
      org.opencontainers.image.licenses="GPL-3.0-or-later" \
      org.opencontainers.image.source="https://github.com/david-dorner/EasyUniMailProxy"

# openconnect - the VPN client (creates tun0, speaks the Cisco protocol)
# vpnc-scripts - the vpnc-script openconnect needs to configure routes/DNS
#                    (NOT pulled in by --no-install-recommends, so name it)
# iproute2 - `ip`, used by vpnc-script
# ca-certificates - validate the SSO / gateway TLS during headless auth
# bash - entrypoint + /dev/tcp healthcheck
# iptables - lock the tunnel egress to the mail ports only (see entrypoint.sh)
# tzdata - resolve named timezones (TZ) for the scheduled refresh times
RUN apt-get update && apt-get install -y --no-install-recommends \
        openconnect \
        vpnc-scripts \
        iproute2 \
        iputils-ping \
        ca-certificates \
        bash \
        socat \
        iptables \
        tzdata \
    && rm -rf /var/lib/apt/lists/*

# openconnect-saml - SAML/TOTP wrapper (headless backend = pure requests, no browser)
# keyrings.alt - PlaintextKeyring backend so keyring works with no Secret Service
# socat (above) - runs the raw-TCP passthrough relays inside the tunnel's own
#                    container, so they share the VPN's lifecycle (no fragile
#                    network_mode:service sidecar that fails to restart with it)
RUN pip install --no-cache-dir openconnect-saml keyrings.alt

# Patch the headless authenticator. The stock openconnect-saml CANNOT complete
# the University of Graz Cisco+Keycloak SAML flow: the ACS relay page sets a
# `CSRFtoken` cookie via JavaScript before auto-submitting, which a plain
# requests session never replicates. This patched copy (from EasyUniVPN,
# GPL-3.0) does. See docs/DEVELOPMENT.md / headless.py header.
COPY headless.py /usr/local/lib/python3.12/site-packages/openconnect_saml/headless.py

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
