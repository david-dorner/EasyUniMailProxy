# 01 - Stack: the containers are running and healthy, and the mail ports are
# accepting connections on the host.
ensure_up >/dev/null 2>&1 || true

describe "stack: containers"

_vpn_healthy() {
    assert_eq "$(container_status eump-vpn)" "running"
    assert_eq "$(container_health eump-vpn)" "healthy"
}
it "the vpn container is running and healthy" _vpn_healthy

_watchdog_running() { assert_eq "$(container_status eump-watchdog)" "running"; }
it "the watchdog container is running" _watchdog_running

describe "stack: published ports"

_port_993() { port_open 993 || { echo "993 not accepting connections"; exit 1; }; }
it "host port 993 (IMAPS) is accepting connections" _port_993

_port_587() { port_open 587 || { echo "587 not accepting connections"; exit 1; }; }
it "host port 587 (SMTP submission) is accepting connections" _port_587
