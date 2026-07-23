# 02 - Tunnel: the VPN authenticates headlessly and routes to the mail server,
# and the required openconnect-saml patch is baked into the image.
ensure_up >/dev/null 2>&1 || true

describe "tunnel: connectivity"

_tun0_addr() {
    local o; o=$(compose exec -T vpn sh -c 'ip -4 -o addr show tun0 2>/dev/null || true')
    assert_match "$o" '143\.50\.'
}
it "tun0 is up with a University of Graz (143.50.x) address" _tun0_addr

_reachable() {
    local o; o=$(probe reachability.py 2>&1); local rc=$?
    assert_ok "$rc"
    assert_match "$o" 'reachable through tunnel'
    note "$o"
}
it "the mail server is reachable through the tunnel" _reachable

describe "tunnel: required headless patch"

_csrf_patch() {
    local n
    n=$(compose exec -T vpn sh -c 'grep -c CSRFtoken /usr/local/lib/python3.12/site-packages/openconnect_saml/headless.py 2>/dev/null || echo 0')
    assert_ge "${n//[^0-9]/}" 1
    note "CSRFtoken references: ${n//[^0-9]/}"
}
it "openconnect-saml headless.py carries the CSRFtoken fix (else auth fails)" _csrf_patch

describe "tunnel: egress locked to mail only (not a backdoor)"

_egress_rules() {
    local o; o=$(compose exec -T vpn sh -c 'iptables -S OUTPUT 2>/dev/null || true')
    assert_match "$o" 'multiport --dports 993,587'
    assert_match "$o" 'tun0 -j DROP'
}
it "the tunnel egress firewall allows only the mail ports" _egress_rules

_egress_blocks_other() {
    # a non-mail port on the mail host must be unreachable over the tunnel
    local o; o=$(compose exec -T vpn python3 -c "
import socket
s = socket.socket(); s.settimeout(6)
try: s.connect(('email.uni-graz.at', 443)); print('reachable')
except Exception: print('blocked')
finally: s.close()")
    assert_match "$o" 'blocked'
}
it "a non-mail university port is blocked over the tunnel" _egress_blocks_other
