# 07 - Watchdog + ntfy notifications. Runs the REAL watchdog code and verifies
# alerts actually reach your ntfy topic (also check your phone - that's the
# human-verified part). Sends a few test alerts to your configured NTFY_URL.
ensure_up >/dev/null 2>&1 || true

if [ -z "${NTFY_URL:-}" ]; then skip "watchdog / ntfy suite" "NTFY_URL not set in .env"; return 0; fi
if ! command -v curl >/dev/null; then skip "watchdog / ntfy suite" "curl not installed on host"; return 0; fi

MARK="suitetest-$(date +%s)-$RANDOM"

describe "watchdog: ntfy delivery"

_notify_delivers() {
    local since; since=$(unix_now)
    local o; o=$(watchdog_code "import watchdog; watchdog.notify('EUMP suite $MARK','watchdog notify test','default','test_tube')" 2>&1)
    assert_ok "$?"
    ntfy_wait "$NTFY_URL" "$MARK" "$((since - 2))" 30 >/dev/null \
        || { echo "notify() ran but the alert never appeared on the ntfy topic"; exit 1; }
    note "delivered to $NTFY_URL - you should see it on your phone"
}
it "notify() delivers an alert to your ntfy topic (check your phone!)" _notify_delivers

describe "watchdog: healthy-path ping"

_online_ping() {
    local since; since=$(unix_now)
    watchdog_code "import threading,os,watchdog; threading.Timer(9, lambda: os._exit(0)).start(); watchdog.main()" \
        WATCHDOG_INTERVAL=1 WATCHDOG_FAIL_THRESHOLD=2 >/dev/null 2>&1
    ntfy_wait "$NTFY_URL" "online|healthy" "$((since - 2))" 25 >/dev/null \
        || { echo "watchdog did not send an 'online' ping for the healthy path"; exit 1; }
}
it "sends an 'online' ping when the mail path is healthy" _online_ping

describe "watchdog: failure alert (artificial)"

_alerts_on_failure() {
    local since; since=$(unix_now)
    # Point the real watchdog loop at a dead port; after the short grace it must
    # detect the unreachable path and fire an alert.
    local o; o=$(watchdog_code "import threading,os,watchdog; threading.Timer(12, lambda: os._exit(0)).start(); watchdog.main()" \
        WATCHDOG_TARGET_PORT=1 WATCHDOG_INTERVAL=1 WATCHDOG_FAIL_THRESHOLD=2 WATCHDOG_START_GRACE=3 2>&1)
    assert_match "$o" '(unhealthy|never came up|DOWN)'
    ntfy_wait "$NTFY_URL" "never came up|DOWN|unreachable" "$((since - 2))" 25 >/dev/null \
        || { echo "watchdog detected the failure but no alert reached ntfy"; exit 1; }
    note "failure detected and alerted"
}
it "detects an unreachable mail path and alerts via ntfy" _alerts_on_failure
