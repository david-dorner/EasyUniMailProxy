#!/usr/bin/env bash
# Bring up the University of Graz VPN headlessly and keep it up.
#
# openconnect-saml sources the password + TOTP secret from `keyring`. In a
# container there is no Secret Service, so we use the PlaintextKeyring backend
# and pre-load the two secrets from the environment. The container filesystem
# is already the trust boundary (see docs/DEVELOPMENT.md, Security section).
#
# The supervisor splits the two things a VPN sign-in actually does:
#   1. AUTHENTICATE  - the SAML + TOTP login. Slow (a few seconds), consumes a
#      one-time code, and mints a session token that stays valid for ~24h.
#   2. CONNECT       - hand that token to openconnect to raise the tunnel. Fast
#      (~1s) and can be repeated: the same token brings the tunnel back up
#      without a fresh login, and even survives an unclean drop.
# openconnect-saml normally fuses the two, re-running the whole login on every
# reconnect. We keep the token and reconnect from it, so a dropped tunnel comes
# back in about a second instead of a full re-auth. We only log in again when the
# token is actually spent (rejected by the gateway, or near its 24h expiry).
# These behaviours were established empirically against the live gateway; see
# docs/DEVELOPMENT.md (VPN session model) for the findings behind each choice.
set -euo pipefail

: "${VPN_USERNAME:?set VPN_USERNAME in .env}"
: "${VPN_PASSWORD:?set VPN_PASSWORD in .env}"
: "${VPN_TOTP_SECRET:?set VPN_TOTP_SECRET in .env}"

# University of Graz constants (this project targets one university only).
export VPN_SERVER="univpn.uni-graz.at"
export PROFILE_NAME="UniVPN"

export PYTHON_KEYRING_BACKEND="keyrings.alt.file.PlaintextKeyring"
export OPENCONNECT_SAML_CONFIG="/config/openconnect-saml/config.toml"
mkdir -p /config/openconnect-saml

# openconnect identity + wiring. The user-agent matches what openconnect-saml
# sends so the gateway treats our direct openconnect calls identically. The
# script wrapper installs the tunnel routes but never rewrites resolv.conf
# (see vpnc-noresolv for why). One named interface keeps the egress rules simple.
OC_USERAGENT="AnyConnect Linux_64 4.7.00136"
OC_SCRIPT="/usr/local/bin/vpnc-noresolv"
TUN_IFACE="tun0"

# ── Load secrets into the keyring + write the openconnect-saml profile ──
# Mirrors EasyUniVPN's save_profile(): username + totp_source=local in the
# profile; password + TOTP secret in the keyring; headless browser backend.
python3 - <<'PY'
import os
import keyring
from openconnect_saml import config as c

user = os.environ["VPN_USERNAME"]
profile_name = os.environ["PROFILE_NAME"]

# openconnect-saml reads these keys (APP_NAME = "openconnect-saml").
keyring.set_password("openconnect-saml", user, os.environ["VPN_PASSWORD"])
keyring.set_password("openconnect-saml", "totp/" + user, os.environ["VPN_TOTP_SECRET"])

cfg = c.load()
creds = c.Credentials(username=user, totp_source="local")
profile = c.ProfileConfig(
    server=os.environ["VPN_SERVER"],
    user_group="",
    name=profile_name,
    credentials=creds.as_dict(),
    browser="headless",
)
cfg.add_profile(profile_name, profile)
cfg.active_profile = profile_name
cfg.default_profile = profile.to_host_profile()
c.save(cfg)
print(f"[vpn] profile '{profile_name}' written for {user}")
PY

# ── AUTH_ONLY=1: validate SAML + password + TOTP and exit (no tunnel). ──
# Needs no NET_ADMIN / /dev/net/tun - useful to confirm credentials and the
# headless CSRFtoken patch work before bringing up the real tunnel.
if [[ "${AUTH_ONLY:-0}" == "1" ]]; then
    echo "[vpn] AUTH_ONLY: verifying credentials against ${VPN_SERVER} (no tunnel)..."
    exec openconnect-saml connect "${PROFILE_NAME}" --browser headless --authenticate shell
fi

# Wait for DNS to resolve the gateway. Docker's embedded resolver can lag for a
# second or two at container startup; without this the very first connect can die
# with "Failed to resolve univpn.uni-graz.at" and force a restart.
for _ in $(seq 1 30); do
    if python3 -c "import socket; socket.gethostbyname('${VPN_SERVER}')" 2>/dev/null; then
        break
    fi
    echo "[vpn] waiting for DNS to resolve ${VPN_SERVER}..."
    sleep 2
done

# Pin the gateway's address in /etc/hosts. We no longer let the tunnel rewrite
# resolv.conf, so this is belt-and-suspenders: even if DNS breaks for any other
# reason, reconnecting to the gateway never depends on a working resolver.
gw_ip=$(python3 -c "import socket; print(socket.gethostbyname('${VPN_SERVER}'))" 2>/dev/null || true)
if [ -n "${gw_ip}" ] && ! grep -q "[[:space:]]${VPN_SERVER}\$" /etc/hosts 2>/dev/null; then
    echo "${gw_ip} ${VPN_SERVER}" >> /etc/hosts
    echo "[vpn] pinned ${VPN_SERVER} -> ${gw_ip} in /etc/hosts."
fi

# ── Lock the tunnel egress to the mail service only ──
# Over the VPN, this container may reach ONLY the mail ports (IMAPS 993 and
# submission 587) and DNS. Every other university host, port, and service is
# unreachable through the tunnel, so even a compromise of this box cannot be
# turned into a backdoor into the wider university network. The VPN transport
# itself (on eth0) and this container's own return traffic are unaffected. The
# rules match tun+ (any tunnel interface) so they cover the active tunnel and any
# transient second tunnel a future make-before-break refresh might raise; they
# can be installed before the interface exists and take effect once it appears.
# Best effort: if iptables is unavailable the proxy still only relays mail, but
# this extra firewall is off.
apply_egress_lock() {
    iptables -A OUTPUT -o lo -j ACCEPT &&
    iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT &&
    iptables -A OUTPUT ! -o tun+ -j ACCEPT &&
    iptables -A OUTPUT -o tun+ -p tcp -m multiport --dports 993,587 -j ACCEPT &&
    iptables -A OUTPUT -o tun+ -p udp --dport 53 -j ACCEPT &&
    iptables -A OUTPUT -o tun+ -p tcp --dport 53 -j ACCEPT &&
    iptables -A OUTPUT -o tun+ -j DROP &&
    iptables -A INPUT -i tun+ -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT &&
    iptables -A INPUT -i tun+ -j DROP
}
if apply_egress_lock 2>/tmp/egress.err; then
    echo "[vpn] tunnel egress locked: only mail (993/587) and DNS are allowed over the VPN."
else
    echo "[vpn] WARNING: could not apply the tunnel egress lock (iptables): $(cat /tmp/egress.err 2>/dev/null)"
    echo "[vpn]          The proxy still relays only mail, but the extra egress firewall is inactive."
fi

# ── Passthrough relays (raw TCP), inside THIS container's tunnel namespace ──
# We do NOT terminate TLS: each client's TLS/STARTTLS runs end-to-end to Exchange,
# so this box only ever sees ciphertext. Each relay self-restarts if it exits.
# They listen immediately; connections just fail until the tunnel is up.
MAIL_SERVER="email.uni-graz.at"
start_relay() {  # port
    local port="$1"
    while true; do
        socat "TCP4-LISTEN:${port},reuseaddr,fork" "TCP4:${MAIL_SERVER}:${port}" || true
        echo "[vpn] relay :${port} exited; restarting in 2s"
        sleep 2
    done
}
start_relay 993 &   # IMAPS (implicit TLS, end-to-end)
start_relay 587 &   # SMTP submission (STARTTLS, end-to-end)
echo "[vpn] passthrough relays up on 993/587 (operator-blind - ciphertext only)."

# ── Tuning knobs (env-overridable) ──
export TZ="${TZ:-Europe/Berlin}"
# Quiet-hour times at which to cycle to a fresh session token before the ~24h
# server-side expiry. Two times a day keep the largest gap under 24h with no
# drift. VPN_REFRESH_SECONDS is a test-only fixed-interval override.
VPN_REFRESH_TIMES="${VPN_REFRESH_TIMES:-03:00,04:00}"
# Dead Peer Detection interval (seconds): how often openconnect checks the peer
# is alive, so it bounds how fast a drop is noticed. Lower is snappier but a
# little chattier and slightly more prone to reacting to a brief latency spike.
VPN_DPD="${VPN_DPD:-5}"
# How long openconnect keeps trying to restore its transport in place (reusing
# the current token) after a drop before it gives up and exits so our loop takes
# over. openconnect's default is 300s, which stretches a blip into minutes.
VPN_RECONNECT_TIMEOUT="${VPN_RECONNECT_TIMEOUT:-25}"
# Re-authenticate a token before it can hard-expire. The gateway grants ~24h;
# 20h leaves generous margin while keeping logins rare (roughly one a day beyond
# the scheduled refreshes).
VPN_TOKEN_MAX_AGE="${VPN_TOKEN_MAX_AGE:-72000}"
# Settle pause before reconnecting from an existing token after a drop. This is
# NOT a re-auth (no one-time code involved), so it can be short.
VPN_RECONNECT_SETTLE="${VPN_RECONNECT_SETTLE:-1}"
# Pause after a FAILED login before retrying. Kept above the 30s one-time-code
# window so a retry never reuses a code the gateway just saw, and it doubles as
# gentle rate-limiting against the login endpoint.
VPN_MINT_BACKOFF="${VPN_MINT_BACKOFF:-35}"

# Session-token state (held in memory only, never written to disk).
VPN_COOKIE=""
VPN_FP=""
VPN_HOST=""
TOKEN_MINTED=0
# The gateway's TOTP codes are valid for 30s and are single-use, so two logins
# closer than this can present the same code and be rejected. We never let a
# re-auth start sooner than this after the previous login attempt.
MIN_MINT_SPACING=32
LAST_MINT=0

# Seconds from now until the soonest scheduled refresh time.
seconds_until_next_refresh() {
    local now next best="" t
    now=$(date +%s)
    for t in ${VPN_REFRESH_TIMES//,/ }; do
        next=$(date -d "today $t" +%s 2>/dev/null) || continue
        if [ "$next" -le "$now" ]; then next=$(date -d "tomorrow $t" +%s); fi
        if [ -z "$best" ] || [ "$next" -lt "$best" ]; then best="$next"; fi
    done
    if [ -z "$best" ]; then best=$(( now + 82800 )); fi   # 23h fallback
    echo "$(( best - now ))"
}

# Warn if the schedule cannot preempt a ~24h session (largest gap 24h or more).
warn_if_schedule_unsafe() {
    local prev="" first="" maxgap=0 g m mins="" h mm t
    for t in ${VPN_REFRESH_TIMES//,/ }; do
        h="${t%%:*}"; mm="${t##*:}"
        case "$h$mm" in *[!0-9]*|"") continue;; esac
        mins="$mins $(( 10#$h * 60 + 10#$mm ))"
    done
    mins=$(printf '%s\n' $mins | sort -n)
    for m in $mins; do
        if [ -z "$first" ]; then first="$m"; fi
        if [ -n "$prev" ]; then g=$(( m - prev )); if [ "$g" -gt "$maxgap" ]; then maxgap="$g"; fi; fi
        prev="$m"
    done
    if [ -n "$first" ]; then g=$(( first + 1440 - prev )); if [ "$g" -gt "$maxgap" ]; then maxgap="$g"; fi; fi
    if [ -z "$first" ] || [ "$maxgap" -ge 1440 ]; then
        echo "[vpn] WARNING: VPN_REFRESH_TIMES ('${VPN_REFRESH_TIMES}') has a gap of 24h"
        echo "[vpn]          or more; the session may hard-expire before a refresh. Use"
        echo "[vpn]          at least two times less than 24h apart (default 03:00,04:00)."
    fi
    return 0
}

# Signal every running openconnect (comm is exactly "openconnect"), without
# procps. Default SIGKILL (9): a hard stop sends NO logout to the gateway, so the
# session token stays valid and we can reconnect from it. Pass 15 (SIGTERM) only
# when we WANT openconnect to log the session out cleanly (planned refresh or
# shutdown), i.e. when we are deliberately discarding the token.
kill_openconnect() {
    local sig="${1:-9}" d
    for d in /proc/[0-9]*; do
        [ "$(cat "$d/comm" 2>/dev/null || true)" = "openconnect" ] \
            && kill "-${sig}" "$(basename "$d")" 2>/dev/null || true
    done
    return 0
}

# Log in once and capture the session token (COOKIE), the server-cert pin
# (FINGERPRINT), and the gateway URL (HOST). Returns non-zero on failure.
mint_token() {
    local out wait_s
    # Never present a one-time code twice: keep logins at least one code-window
    # apart, even when a safety re-auth wants to fire right after the last one.
    wait_s=$(( LAST_MINT + MIN_MINT_SPACING - $(date +%s) ))
    if [ "$wait_s" -gt 0 ]; then
        echo "[vpn] waiting ${wait_s}s before logging in again so the one-time code rolls over..."
        sleep "$wait_s"
    fi
    LAST_MINT=$(date +%s)
    echo "[vpn] authenticating (headless SAML + TOTP) to mint a ~24h session token..."
    if ! out=$(openconnect-saml connect "${PROFILE_NAME}" --browser headless \
                   --authenticate shell 2>/tmp/auth.err); then
        echo "[vpn] login failed: $(tail -n1 /tmp/auth.err 2>/dev/null || true)"
        return 1
    fi
    VPN_COOKIE=$(printf '%s\n' "$out" | sed -n 's/^COOKIE=//p'      | tr -d "'\"")
    VPN_FP=$(printf     '%s\n' "$out" | sed -n 's/^FINGERPRINT=//p' | tr -d "'\"")
    VPN_HOST=$(printf   '%s\n' "$out" | sed -n 's/^HOST=//p'        | tr -d "'\"")
    if [ -z "$VPN_COOKIE" ] || [ -z "$VPN_FP" ] || [ -z "$VPN_HOST" ]; then
        echo "[vpn] login produced no usable token; retrying shortly."
        VPN_COOKIE=""
        return 1
    fi
    TOKEN_MINTED=$(date +%s)
    echo "[vpn] token minted; connecting."
    return 0
}

# Raise the tunnel from the current token (no re-auth). Backgrounds openconnect
# and sets oc_pid. --no-dtls forces the tunnel over TCP: DTLS/UDP is prone to
# silent NAT-timeout drops behind a home router, which were the main source of
# the recurring outages; TCP trades a little latency (irrelevant for mail) for a
# connection that stays up. --cookie-on-stdin keeps the token off the argv/env.
run_tunnel() {
    printf '%s' "$VPN_COOKIE" | openconnect \
        --cookie-on-stdin --servercert "$VPN_FP" --useragent "$OC_USERAGENT" \
        --no-dtls --interface "$TUN_IFACE" --script "$OC_SCRIPT" \
        --force-dpd "$VPN_DPD" --reconnect-timeout "$VPN_RECONNECT_TIMEOUT" \
        "$VPN_HOST" >/tmp/oc.log 2>&1 &
    oc_pid=$!
}

# Clean shutdown on docker stop: log the session out (SIGTERM) and exit.
trap 'echo "[vpn] shutting down; logging the VPN session out."; kill_openconnect 15; exit 0' TERM INT

warn_if_schedule_unsafe
echo "[vpn] starting; TCP tunnel, ~1s token reconnects, proactive refresh at ${VPN_REFRESH_TIMES} ${TZ}."
short_exits=0   # consecutive connects that died almost immediately (safety net)
while true; do
    # 1. Make sure we hold a fresh-enough token. Re-auth only when we have none
    #    or the current one is near its 24h expiry.
    now=$(date +%s)
    if [ -z "$VPN_COOKIE" ] || [ $(( now - TOKEN_MINTED )) -ge "$VPN_TOKEN_MAX_AGE" ]; then
        if ! mint_token; then sleep "$VPN_MINT_BACKOFF"; continue; fi
    fi

    # 2. Raise the tunnel from the token.
    rm -f /tmp/proactive_refresh
    conn_start=$(date +%s)
    run_tunnel

    # 3. Proactive refresh timer: at the scheduled quiet-hour time, cleanly end
    #    the session (SIGTERM logs it out) so the loop mints a fresh token before
    #    the server-side hard expiry can bite during the day.
    refresh_in="${VPN_REFRESH_SECONDS:-$(seconds_until_next_refresh)}"
    echo "[vpn] tunnel up on ${TUN_IFACE}; next proactive refresh $(date -d "@$(( $(date +%s) + refresh_in ))" '+%Y-%m-%d %H:%M:%S %Z') (in ${refresh_in}s)."
    ( sleep "$refresh_in"
      touch /tmp/proactive_refresh
      echo "[vpn] proactive refresh: cycling to a fresh session at the scheduled time."
      kill_openconnect 15 ) &
    refresh_timer=$!

    # 4. Block until the tunnel exits: a drop, the refresh timer, or a dead token.
    wait "$oc_pid" 2>/dev/null || true
    kill "$refresh_timer" 2>/dev/null || true
    kill_openconnect 9   # ensure it is fully down (hard, so an unplanned drop keeps the token)

    # 5. Decide how to come back.
    held=$(( $(date +%s) - conn_start ))
    if [ -f /tmp/proactive_refresh ]; then
        # Planned refresh: deliberately discard the token and log in fresh.
        VPN_COOKIE=""
        short_exits=0
        echo "[vpn] planned refresh complete; re-authenticating."
        sleep 1
    elif grep -qiE 'cookie was rejected|http/[0-9.]+ 401|authentication failure|session (authentication )?(has )?expired|token (is )?invalid|permission denied' /tmp/oc.log; then
        # The gateway refused the token (spent or hard-expired): must re-auth.
        VPN_COOKIE=""
        short_exits=0
        echo "[vpn] session token no longer accepted; re-authenticating. (last: $(grep -iE 'cookie was rejected|401|expired|invalid' /tmp/oc.log | tail -n1))"
        sleep 2
    elif [ "$held" -lt 5 ]; then
        # The tunnel died almost at once. Likely a transient gateway/transport
        # issue rather than a normal drop; reconnect from the token but back off
        # so we never hot-loop. If it keeps happening the token is probably bad
        # in a way our patterns missed, so force a fresh login as a safety net.
        short_exits=$(( short_exits + 1 ))
        if [ "$short_exits" -ge 3 ]; then
            VPN_COOKIE=""
            short_exits=0
            echo "[vpn] repeated immediate exits; re-authenticating to be safe."
        else
            echo "[vpn] tunnel exited after ${held}s (${short_exits}/3); retrying from token in 5s..."
        fi
        sleep 5
    else
        # An unclean transport drop after a healthy run. The token is still
        # valid, so reconnect from it immediately - about a one-second recovery,
        # no login.
        short_exits=0
        echo "[vpn] tunnel dropped after ${held}s; reconnecting from the existing token..."
        sleep "$VPN_RECONNECT_SETTLE"
    fi
done
