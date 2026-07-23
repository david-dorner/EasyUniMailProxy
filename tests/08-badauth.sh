# 08 - Credential failsafe (OPT-IN: --include-badauth).
# Submits a WRONG password to the live university SSO and asserts the patched
# headless auth fast-fails instead of hanging. This is one failed login on your
# real account, so it's excluded from the default run.
describe "auth: bad-credential fast-fail (hits the live SSO)"

_wrong_password_fast_fail() {
    local start end rc o
    start=$(date +%s)
    o=$(compose run --rm -e AUTH_ONLY=1 -e VPN_PASSWORD=definitely-not-the-password vpn 2>&1); rc=$?
    end=$(date +%s)
    assert_nonzero "$rc"
    assert_le "$((end - start))" 60
    note "rejected in $((end - start))s (exit $rc) - headless.py fast-fails bad credentials"
}
it "AUTH_ONLY with a wrong password fails fast (non-zero, < 60s)" _wrong_password_fast_fail
