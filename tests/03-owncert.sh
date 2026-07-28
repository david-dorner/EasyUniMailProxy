# 03 - Own certificate + encryption at rest (2.0). The box TERMINATES the
# client's TLS with ITS OWN certificate (not the university's), and the cached
# mail is ciphertext on disk. This is the inverse of the 1.x operator-blind
# passthrough: here, the box legitimately holds the plaintext, so what matters is
# that it presents its own certificate and encrypts what it stores.
ensure_up >/dev/null 2>&1 || true

describe "own certificate (2.0): the box presents its own cert, not the university's"

_imaps_owncert() {
    local want; want=$(compose exec -T mail printenv MAIL_HOSTNAME 2>/dev/null | tr -d '\r')
    local subj
    subj=$(compose exec -T mail sh -c 'echo | openssl s_client -connect localhost:993 2>/dev/null | openssl x509 -noout -subject 2>/dev/null' | tr -d '\r')
    note "certificate on 993: ${subj}  (expected CN=${want})"
    assert_match "$subj" "CN *= *${want}"
    if echo "$subj" | grep -q 'email\.uni-graz\.at'; then
        echo "the box is presenting the UNIVERSITY certificate - it is not terminating with its own"
        exit 1
    fi
}
it "IMAPS 993 presents the box's own certificate (CN=MAIL_HOSTNAME)" _imaps_owncert

describe "encryption at rest (2.0): the on-disk mail store holds only ciphertext"

_encrypted_at_rest() {
    local marker="EUMP-ENCTEST-$$-$(date +%s)"
    # Write a known marker through the plaintext mount, then look for it on the
    # on-disk (gocryptfs) volume - it must not be there in the clear.
    compose exec -T mail sh -c "printf '%s' '$marker' > /mail/.enctest" >/dev/null 2>&1
    local hits
    hits=$(compose exec -T mail sh -c "grep -ral '$marker' /mnt/cipher 2>/dev/null | wc -l" | tr -d '[:space:]')
    compose exec -T mail sh -c "rm -f /mail/.enctest" >/dev/null 2>&1
    note "marker written via the mount; plaintext occurrences on the on-disk volume: ${hits} (want 0)"
    assert_eq "$hits" "0"
}
it "a marker written through the mount does not appear as plaintext on disk" _encrypted_at_rest
