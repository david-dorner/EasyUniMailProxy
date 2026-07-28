#!/usr/bin/env bash
# Obtain (or renew) the TLS certificate the mail server presents to clients.
#
# One knob, CERT_MODE, selects how the certificate is acquired. The result is
# always written to a fixed place that Dovecot and Postfix read:
#     /certs/fullchain.pem   certificate + chain
#     /certs/key.pem         private key
#
# Modes:
#   cloudflare-dns  Let's Encrypt via the Cloudflare DNS-01 challenge. Free,
#                   auto-renewing, trusted everywhere, works behind NAT with no
#                   inbound ports. Needs CF_DNS_API_TOKEN (a scoped Cloudflare
#                   token) and ACME_EMAIL.
#   http-01         Let's Encrypt via the HTTP-01 challenge. Also free, but needs
#                   inbound port 80 reachable from the internet. Needs ACME_EMAIL.
#   manual          Use a certificate you supply yourself (any CA, or a Cloudflare
#                   Origin cert). Point CERT_FILE and CERT_KEY at the files.
#   selfsigned      Generate a self-signed certificate. For LAN / testing only;
#                   clients will warn, exactly like the old passthrough did.
#
# lego drives the ACME modes and supports ~150 DNS providers, so adding another
# provider later is only a couple of env vars.
set -euo pipefail

CERT_MODE="${CERT_MODE:-selfsigned}"
: "${MAIL_HOSTNAME:?set MAIL_HOSTNAME}"
CERT_DIR=/certs
LEGO_DIR="${CERT_DIR}/lego"
ACTION="${1:-run}"   # "run" (obtain if missing) or "renew"
mkdir -p "$CERT_DIR"

log() { echo "[cert] $*"; }

# Optional dry-run against Let's Encrypt staging: validates the token and the
# DNS-01 flow with no rate limits, but the resulting certificate is NOT trusted.
# Set ACME_STAGING=1 to use it. Uses --server=URL (one token) so it stays a
# single argument when unset expands to nothing.
STAGING_ARGS=""
if [ "${ACME_STAGING:-0}" = "1" ]; then
    STAGING_ARGS="--server=https://acme-staging-v02.api.letsencrypt.org/directory"
    log "ACME_STAGING=1: using Let's Encrypt STAGING (the certificate will NOT be trusted)."
fi

# Copy whatever lego produced into the fixed fullchain.pem / key.pem paths.
install_lego_result() {
    cp "${LEGO_DIR}/certificates/${MAIL_HOSTNAME}.crt" "${CERT_DIR}/fullchain.pem"
    cp "${LEGO_DIR}/certificates/${MAIL_HOSTNAME}.key" "${CERT_DIR}/key.pem"
}

case "$CERT_MODE" in
    selfsigned)
        if [ "$ACTION" = renew ]; then exit 0; fi   # nothing to renew
        log "generating a self-signed certificate for ${MAIL_HOSTNAME} (LAN/testing; clients will warn)."
        openssl req -x509 -newkey rsa:2048 -nodes \
            -keyout "${CERT_DIR}/key.pem" -out "${CERT_DIR}/fullchain.pem" \
            -days 3650 -subj "/CN=${MAIL_HOSTNAME}" \
            -addext "subjectAltName=DNS:${MAIL_HOSTNAME}" 2>/dev/null
        ;;

    manual)
        : "${CERT_FILE:?set CERT_FILE for CERT_MODE=manual}"
        : "${CERT_KEY:?set CERT_KEY for CERT_MODE=manual}"
        log "using the supplied certificate ${CERT_FILE}."
        cp "$CERT_FILE" "${CERT_DIR}/fullchain.pem"
        cp "$CERT_KEY"  "${CERT_DIR}/key.pem"
        ;;

    cloudflare-dns)
        : "${CF_DNS_API_TOKEN:?set CF_DNS_API_TOKEN for CERT_MODE=cloudflare-dns}"
        : "${ACME_EMAIL:?set ACME_EMAIL for CERT_MODE=cloudflare-dns}"
        export CLOUDFLARE_DNS_API_TOKEN="$CF_DNS_API_TOKEN"
        local_action="$ACTION"
        # If we have never obtained a cert, "run"; otherwise "renew".
        if [ -f "${LEGO_DIR}/certificates/${MAIL_HOSTNAME}.crt" ]; then local_action=renew; else local_action=run; fi
        log "Let's Encrypt (Cloudflare DNS-01) ${local_action} for ${MAIL_HOSTNAME}."
        lego $STAGING_ARGS --accept-tos --email "$ACME_EMAIL" --dns cloudflare \
             --domains "$MAIL_HOSTNAME" --path "$LEGO_DIR" "$local_action" \
             $( [ "$local_action" = renew ] && echo --days 30 )
        install_lego_result
        ;;

    http-01)
        : "${ACME_EMAIL:?set ACME_EMAIL for CERT_MODE=http-01}"
        local_action="$ACTION"
        if [ -f "${LEGO_DIR}/certificates/${MAIL_HOSTNAME}.crt" ]; then local_action=renew; else local_action=run; fi
        log "Let's Encrypt (HTTP-01) ${local_action} for ${MAIL_HOSTNAME} (needs inbound port 80)."
        lego $STAGING_ARGS --accept-tos --email "$ACME_EMAIL" --http --http.port ":80" \
             --domains "$MAIL_HOSTNAME" --path "$LEGO_DIR" "$local_action" \
             $( [ "$local_action" = renew ] && echo --days 30 )
        install_lego_result
        ;;

    *)
        echo "[cert] ERROR: unknown CERT_MODE '${CERT_MODE}'." >&2
        echo "[cert]        Use cloudflare-dns, http-01, manual, or selfsigned." >&2
        exit 1
        ;;
esac

chmod 600 "${CERT_DIR}/key.pem"
log "certificate ready at ${CERT_DIR}/fullchain.pem"
