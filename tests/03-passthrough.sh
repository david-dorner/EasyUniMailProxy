# 03 - Passthrough (operator-blind): the relay presents the university's OWN
# certificate, strictly validated. A TLS-terminating proxy with its own cert
# would fail this - so passing proves the box can't read the traffic.
ensure_up >/dev/null 2>&1 || true

describe "passthrough: operator-blind (real university certificate)"

_imaps_cert() {
    local o; o=$(probe passthrough.py imaps 2>&1); local rc=$?
    assert_ok "$rc"
    assert_match "$o" 'cert_cn=email\.uni-graz\.at'
    assert_match "$o" 'validation=strict-ca'
    note "$o"
}
it "IMAPS 993 presents the real email.uni-graz.at cert (strict-validated)" _imaps_cert

_smtp_cert() {
    local o; o=$(probe passthrough.py smtp 2>&1); local rc=$?
    assert_ok "$rc"
    assert_match "$o" 'cert_cn=email\.uni-graz\.at'
    assert_match "$o" 'auth_advertised=yes'
    note "$o"
}
it "SMTP 587 STARTTLS upgrades to the real uni cert and advertises AUTH" _smtp_cert
