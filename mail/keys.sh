#!/usr/bin/env bash
# Resolve the master key that encrypts stored credentials and cached mail, and
# guard the cache against a changed key.
#
# KEY_MODE:
#   auto       use the TPM if this machine has one, else autostart. Default.
#   tpm        seal/unseal the key to the TPM (key never stored on disk in clear).
#   autostart  use MASTER_KEY if set; else use a stored auto-generated key; else
#              generate a strong random key and store it, so the stack always
#              starts and stays consistent across restarts (weaker: key on the box).
#   passphrase derive the key from MAIL_PASSPHRASE supplied at start (not stored).
#
# The live key is written to a tmpfs file the other components read. Persistent
# key artifacts live in /keys. A fingerprint of the key that encrypted the
# current cache lives with the data (/mail/.keyid); if the key ever changes, the
# old cache can no longer be decrypted, so we discard it and re-sync rather than
# fail.
set -euo pipefail

KEY_MODE="${KEY_MODE:-auto}"
KEYS_DIR=/keys                       # persistent: stored key / TPM sealed blob
RUN_DIR=/run/mail                    # tmpfs: the live key
KEYFILE="${RUN_DIR}/master.key"

mkdir -p "$KEYS_DIR" "$RUN_DIR"
chmod 700 "$RUN_DIR" "$KEYS_DIR"
log() { echo "[keys] $*"; }

gen_key()      { openssl rand -base64 32; }                         # 32 random bytes, base64
derive_key()   { printf '%s' "$1" | openssl dgst -sha256 -binary | openssl base64; }
fingerprint()  { printf '%s' "$1" | openssl dgst -sha256 | awk '{print $NF}' | cut -c1-16; }
tpm_available(){ [ -e /dev/tpmrm0 ] && command -v tpm2_createprimary >/dev/null 2>&1; }

# Seal stdin's secret to the TPM. The primary key is re-derivable (deterministic
# template), so we only persist the sealed object (seal.pub/seal.priv), which is
# useless without this exact TPM.
tpm_seal() {
    local t; t=$(mktemp -d)
    tpm2_createprimary -Q -C o -g sha256 -G ecc -c "$t/primary.ctx"
    tpm2_create -Q -C "$t/primary.ctx" -i - -u "$KEYS_DIR/seal.pub" -r "$KEYS_DIR/seal.priv"
    rm -rf "$t"
}
tpm_unseal() {
    local t; t=$(mktemp -d)
    tpm2_createprimary -Q -C o -g sha256 -G ecc -c "$t/primary.ctx"
    tpm2_load -Q -C "$t/primary.ctx" -u "$KEYS_DIR/seal.pub" -r "$KEYS_DIR/seal.priv" -c "$t/seal.ctx"
    tpm2_unseal -Q -c "$t/seal.ctx"
    rm -rf "$t"
}

resolve_key() {
    local mode="$KEY_MODE"
    if [ "$mode" = auto ]; then
        if tpm_available; then mode=tpm; else mode=autostart; fi
        log "auto: no explicit choice; selected '${mode}'."
    fi
    case "$mode" in
        tpm)
            if ! tpm_available; then
                log "ERROR: KEY_MODE=tpm but no usable TPM (need /dev/tpmrm0 + tpm2-tools). Refusing to downgrade silently."
                exit 1
            fi
            if [ -f "$KEYS_DIR/seal.priv" ]; then
                KEY=$(tpm_unseal)
                log "master key unsealed from the TPM."
            else
                KEY=$(gen_key)
                printf '%s' "$KEY" | tpm_seal
                log "generated a new master key and sealed it to the TPM."
            fi
            ;;
        autostart)
            if [ -n "${MASTER_KEY:-}" ]; then
                KEY=$(derive_key "$MASTER_KEY")
                log "using the operator-supplied MASTER_KEY."
            elif [ -f "$KEYS_DIR/master.key" ]; then
                KEY=$(cat "$KEYS_DIR/master.key")
                log "using the stored auto-generated master key."
            else
                KEY=$(gen_key)
                printf '%s' "$KEY" > "$KEYS_DIR/master.key"
                chmod 600 "$KEYS_DIR/master.key"
                log "no TPM and no MASTER_KEY: generated a strong random master key and stored it in the keys volume so the stack starts and stays consistent."
                log "NOTE: that key sits on the box (weaker at rest). Use KEY_MODE=tpm or set MASTER_KEY for stronger protection."
            fi
            ;;
        passphrase)
            : "${MAIL_PASSPHRASE:?KEY_MODE=passphrase needs MAIL_PASSPHRASE supplied at start}"
            KEY=$(derive_key "$MAIL_PASSPHRASE")
            log "derived the master key from the supplied passphrase (not stored)."
            ;;
        *)
            log "ERROR: unknown KEY_MODE '${KEY_MODE}'."; exit 1 ;;
    esac
    printf '%s' "$KEY" > "$KEYFILE"
    chmod 600 "$KEYFILE"
}

resolve_key
log "master key ready (mode ${KEY_MODE}, fingerprint $(fingerprint "$(cat "$KEYFILE")"))."
# A changed key is detected downstream: the encrypted mail store (gocryptfs, see
# the entrypoint) fails to open with a different key, and is re-initialized then,
# so the cache re-syncs cleanly instead of breaking.
