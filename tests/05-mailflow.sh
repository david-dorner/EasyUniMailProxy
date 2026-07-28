# 05 - Mail flow: a real, uniquely-tagged message is submitted via 587, polled
# for in the INBOX via 993, timed, and then deleted (leaves no clutter).
# Sends one message to the carrier's own address. Skip with --skip-sendmail.
ensure_up >/dev/null 2>&1 || true

FLOW_OUT="$(mail_probe mailflow.py 2>&1)"; FLOW_RC=$?

describe "mail flow: end-to-end send + receive"

_delivered() { assert_ok "$FLOW_RC"; assert_match "$FLOW_OUT" 'arrived=yes'; note "$FLOW_OUT"; }
it "a submitted message is accepted and arrives in the INBOX" _delivered

_latency() {
    local l; l=$(printf '%s' "$FLOW_OUT" | grep -oE 'latency=[0-9.]+' | cut -d= -f2)
    [ -n "$l" ] || { echo "no latency measured (send may have failed)"; exit 1; }
    assert_lt_f "$l" 60
    note "latency=${l}s"
}
it "delivery latency is low (native-like, < 60s)" _latency

_cleaned() { assert_match "$FLOW_OUT" 'cleaned=yes'; }
it "the test message is deleted afterwards" _cleaned
