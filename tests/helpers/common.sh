#!/usr/bin/env bash
# Shared helpers + a tiny test harness for the EasyUniMailProxy suite.
#
# Structure mirrors EasyUniVPN's Pester helpers (describe/it/assert, isolated
# probes, colored summary), but Linux-native: the system under test is the
# Docker stack, and functional checks are Python probes (tests/lib/*.py) fed
# into the vpn container so the tests speak the same protocols a mail client does.

# Paths (this file is tests/helpers/common.sh).
HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(dirname "$HELPERS_DIR")"
PROJECT_ROOT="$(dirname "$TESTS_DIR")"
LIB_DIR="$TESTS_DIR/lib"

# Colors (only when stdout is a terminal).
if [ -t 1 ]; then
    C_RESET=$'\033[0m'; C_GRN=$'\033[32m'; C_RED=$'\033[31m'
    C_YEL=$'\033[33m'; C_CYN=$'\033[36m'; C_DIM=$'\033[2m'
else
    C_RESET=; C_GRN=; C_RED=; C_YEL=; C_CYN=; C_DIM=
fi

# Counters (accumulate across all sourced test files).
TEST_PASS=0; TEST_FAIL=0; TEST_SKIP=0
declare -a FAILED_NAMES=()

# ── test harness ─────────────────────────────────────────────────────────────
describe() { printf '\n%s%s%s\n' "$C_CYN" "$1" "$C_RESET"; }

# it <description> <function>
# Runs <function> in a subshell. Assertions that fail call `exit 1` (fails the
# test); any echoed text becomes the failure/detail note.
it() {
    local desc="$1" fn="$2" out
    if out=$("$fn" 2>&1); then
        printf '  %sPASS%s %s\n' "$C_GRN" "$C_RESET" "$desc"
        [ -n "$out" ] && printf '      %s%s%s\n' "$C_DIM" "$out" "$C_RESET"
        TEST_PASS=$((TEST_PASS + 1))
    else
        printf '  %sFAIL%s %s\n' "$C_RED" "$C_RESET" "$desc"
        [ -n "$out" ] && printf '      %s%s%s\n' "$C_RED" "$out" "$C_RESET"
        TEST_FAIL=$((TEST_FAIL + 1))
        FAILED_NAMES+=("$desc")
    fi
}

skip() {
    printf '  %s-%s %s %s(skipped%s)%s\n' \
        "$C_YEL" "$C_RESET" "$1" "$C_DIM" "${2:+: $2}" "$C_RESET"
    TEST_SKIP=$((TEST_SKIP + 1))
}

# Assertions - on failure print a message and exit the (subshell) test body.
assert_eq()      { [ "$1" = "$2" ]  || { echo "expected '$2', got '$1'"; exit 1; }; }
assert_ok()      { [ "$1" -eq 0 ]   || { echo "expected exit 0, got $1"; exit 1; }; }
assert_nonzero() { [ "$1" -ne 0 ]   || { echo "expected non-zero exit"; exit 1; }; }
assert_ge()      { [ "${1:-0}" -ge "$2" ] || { echo "expected >= $2, got '${1:-}'"; exit 1; }; }
assert_le()      { [ "${1:-0}" -le "$2" ] || { echo "expected <= $2, got '${1:-}'"; exit 1; }; }
assert_lt_f()    { awk "BEGIN{exit !($1 < $2)}" || { echo "expected < $2, got $1"; exit 1; }; }
assert_match()   { printf '%s' "$1" | grep -Eq "$2" || { echo "'$1' does not match /$2/"; exit 1; }; }
note()           { echo "$1"; }   # attach an info line to a passing test

# ── docker / stack ───────────────────────────────────────────────────────────
compose() { docker compose --project-directory "$PROJECT_ROOT" "$@"; }

# probe <file.py> [argv...] - run a probe in the vpn container; echo its output,
# return its exit code.
probe() {
    local f="$LIB_DIR/$1"; shift
    compose exec -T vpn python3 - "$@" < "$f"
}

container_field()    { docker inspect --format "$2" "$1" 2>/dev/null; }
container_status()   { container_field "$1" '{{.State.Status}}'; }
container_health()   { container_field "$1" '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}'; }
container_restarts() { container_field "$1" '{{.RestartCount}}'; }

wait_healthy() {  # [timeout_s]
    local end; end=$(( $(date +%s) + ${1:-180} ))
    while [ "$(date +%s)" -lt "$end" ]; do
        [ "$(container_health eump-vpn)" = "healthy" ] && return 0
        sleep 3
    done
    return 1
}

ensure_up() {  # [--build]
    [ "$(container_health eump-vpn)" = "healthy" ] && return 0
    if [ "${1:-}" = "--build" ]; then compose up -d --build >/dev/null 2>&1
    else compose up -d >/dev/null 2>&1; fi
    wait_healthy 180
}

port_open() {  # host_port [host]
    timeout 4 bash -c "exec 3<>/dev/tcp/${2:-127.0.0.1}/$1" 2>/dev/null
}

# Kill the socat listener for a port inside the vpn container, without needing
# procps (scan /proc/<pid>/cmdline). The self-restart loop should re-bind it.
kill_relay() {  # port
    compose exec -T -e KP="$1" vpn sh -c '
        for d in /proc/[0-9]*; do
            if tr "\0" " " < "$d/cmdline" 2>/dev/null | grep -q "TCP4-LISTEN:$KP"; then
                kill "$(basename "$d")" 2>/dev/null || true
            fi
        done' >/dev/null 2>&1
}

# ── ntfy ─────────────────────────────────────────────────────────────────────
unix_now() { date +%s; }

# ntfy_wait <topic_url> <regex> <since_unix> [timeout_s]
# Poll the topic's cached messages; echo + return 0 when a 'message' event whose
# JSON line matches <regex> appears. Needs curl on the host.
ntfy_wait() {
    local url="$1" re="$2" since="$3" end; end=$(( $(date +%s) + ${4:-30} ))
    while [ "$(date +%s)" -lt "$end" ]; do
        local hit
        hit=$(curl -s --max-time 15 "$url/json?poll=1&since=$since" 2>/dev/null \
              | grep '"event":"message"' | grep -E "$re" | head -1 || true)
        [ -n "$hit" ] && { echo "$hit"; return 0; }
        sleep 2
    done
    return 1
}

# watchdog_code <pycode> [ENV=VAL ...] - run the REAL watchdog image once with a
# one-off python command (so we exercise the actual notify/alert code).
watchdog_code() {
    local code="$1"; shift
    local envargs=()
    while [ $# -gt 0 ]; do envargs+=("-e" "$1"); shift; done
    compose run --rm "${envargs[@]}" --entrypoint python3 watchdog -c "$code"
}
