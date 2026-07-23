#!/usr/bin/env bash
# EasyUniMailProxy integration test runner (Linux / WSL).
#
# Mirrors EasyUniVPN's Run-Tests.ps1: check prerequisites, bring the Docker
# stack up, run the numbered suites, print a colored summary, tear down, and
# exit 0/1. The suite drives the real stack (it restarts / tears it down), so
# don't run it against an instance you need to stay up - or pass --keep-up.
#
# Usage:
#   ./run-tests.sh [options]
#     --build            docker compose build before running
#     --only <substr>    run only suites whose filename contains <substr>
#     --skip-sendmail    skip the send/receive suite (05)
#     --skip-ntfy        skip the watchdog/ntfy suite (07)
#     --include-badauth  also run the bad-credential suite (08) - hits the live SSO
#     --keep-up          leave the stack running after the tests
#     -h | --help        this help
set -uo pipefail
cd "$(dirname "$0")"
source helpers/common.sh

ONLY=""; SKIP_SENDMAIL=0; SKIP_NTFY=0; INCLUDE_BADAUTH=0; KEEP_UP=0; DO_BUILD=0
while [ $# -gt 0 ]; do
    case "$1" in
        --build)           DO_BUILD=1; shift ;;
        --only)            ONLY="${2:-}"; shift 2 ;;
        --skip-sendmail)   SKIP_SENDMAIL=1; shift ;;
        --skip-ntfy)       SKIP_NTFY=1; shift ;;
        --include-badauth) INCLUDE_BADAUTH=1; shift ;;
        --keep-up)         KEEP_UP=1; shift ;;
        -h|--help)         sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $1 (try --help)"; exit 1 ;;
    esac
done

# ── prerequisites ─────────────────────────────────────────────────────────────
command -v docker >/dev/null    || { echo "${C_RED}docker not found on PATH${C_RESET}"; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "${C_RED}docker compose not available${C_RESET}"; exit 1; }
command -v curl >/dev/null      || echo "${C_YEL}warning: curl not found - ntfy checks will be skipped${C_RESET}"

ENV_FILE="$PROJECT_ROOT/.env"
[ -f "$ENV_FILE" ] || { echo "${C_RED}.env not found at $ENV_FILE - copy .env.example to .env and fill it in${C_RESET}"; exit 1; }
for k in VPN_USERNAME VPN_PASSWORD VPN_TOTP_SECRET; do
    grep -qE "^$k=." "$ENV_FILE" || { echo "${C_RED}.env is missing $k${C_RESET}"; exit 1; }
done
NTFY_URL="$(grep -E '^NTFY_URL=' "$ENV_FILE" | cut -d= -f2- | tr -d '[:space:]')"
export NTFY_URL

# ── banner ────────────────────────────────────────────────────────────────────
echo
echo "${C_CYN}============================================================${C_RESET}"
echo "${C_CYN}  EasyUniMailProxy Integration Tests${C_RESET}"
echo "${C_CYN}============================================================${C_RESET}"

# ── bring the stack up ────────────────────────────────────────────────────────
echo "Bringing the stack up${DO_BUILD:+ (build)}..."
[ $DO_BUILD -eq 1 ] && compose build >/dev/null 2>&1
if ! ensure_up --build; then
    echo "${C_RED}stack did not become healthy - see: docker compose logs vpn${C_RESET}"
    [ $KEEP_UP -eq 0 ] && compose down >/dev/null 2>&1
    exit 1
fi
echo "${C_GRN}stack healthy.${C_RESET}"

# ── select + run suites ───────────────────────────────────────────────────────
for f in [0-9][0-9]-*.sh; do
    [ -e "$f" ] || continue
    [ -n "$ONLY" ] && [[ "$f" != *"$ONLY"* ]] && continue
    case "$f" in
        05-*) [ $SKIP_SENDMAIL -eq 1 ] && { skip "$f" "--skip-sendmail"; continue; } ;;
        07-*) [ $SKIP_NTFY     -eq 1 ] && { skip "$f" "--skip-ntfy";     continue; } ;;
        08-*) [ $INCLUDE_BADAUTH -eq 0 ] && { skip "$f" "opt-in: --include-badauth"; continue; } ;;
    esac
    printf '\n%s── %s ──%s\n' "$C_CYN" "$f" "$C_RESET"
    # shellcheck disable=SC1090
    source "./$f"
done

# ── teardown ──────────────────────────────────────────────────────────────────
echo
if [ $KEEP_UP -eq 0 ]; then
    echo "${C_YEL}Tearing down the stack...${C_RESET}"
    compose down >/dev/null 2>&1
else
    echo "${C_YEL}Leaving the stack running (--keep-up).${C_RESET}"
fi

# ── summary ───────────────────────────────────────────────────────────────────
echo
echo "${C_CYN}============================================================${C_RESET}"
if [ "$TEST_FAIL" -eq 0 ]; then
    echo "  ${C_GRN}PASSED${C_RESET}  ${TEST_PASS} passed, ${TEST_SKIP} skipped"
    exit 0
else
    echo "  ${C_RED}FAILED${C_RESET}  ${TEST_FAIL} failed, ${TEST_PASS} passed, ${TEST_SKIP} skipped"
    for n in "${FAILED_NAMES[@]}"; do echo "    ${C_RED}- ${n}${C_RESET}"; done
    exit 1
fi
