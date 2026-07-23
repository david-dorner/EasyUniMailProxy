# 06 - Reliability / failsafes (disruptive; runs after the functional suites).
# Verifies the fixes that make this deployable: relays recover with the tunnel,
# a killed relay self-restarts, and a cold start doesn't crash-loop.
ensure_up >/dev/null 2>&1 || true

describe "reliability: failsafes"

_survives_restart() {
    compose restart vpn >/dev/null 2>&1
    wait_healthy 180 || { echo "vpn did not return to healthy after restart"; exit 1; }
    local o; o=$(probe passthrough.py imaps 2>&1); local rc=$?
    assert_ok "$rc"
    note "mail path recovered after restart"
}
it "the mail path survives a full vpn restart (folded-in relays)" _survives_restart

_relay_self_restart() {
    kill_relay 993
    sleep 6
    local o; o=$(probe passthrough.py imaps 2>&1); local rc=$?
    assert_ok "$rc"
    note "socat 993 was re-bound by its restart loop"
}
it "a killed relay is automatically restarted" _relay_self_restart

describe "reliability: clean cold start"

_cold_start() {
    compose down >/dev/null 2>&1
    ensure_up >/dev/null 2>&1 || { echo "cold start failed to become healthy"; exit 1; }
    local r; r=$(container_restarts eump-vpn)
    assert_le "$r" 1
    note "RestartCount=$r (the DNS-wait failsafe avoids boot-time resolve failures)"
}
it "a fresh 'up' comes healthy without crash-looping" _cold_start
