#!/usr/bin/env bash
# Bring up the University of Graz VPN headlessly and keep it up.
#
# openconnect-saml sources the password + TOTP secret from `keyring`. In a
# container there is no Secret Service, so we use the PlaintextKeyring backend
# and pre-load the two secrets from the environment. The container filesystem
# is already the trust boundary (see docs/DEVELOPMENT.md, Security section).
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
    if python3 -c "import socket,sys; socket.gethostbyname('${VPN_SERVER}')" 2>/dev/null; then
        break
    fi
    echo "[vpn] waiting for DNS to resolve ${VPN_SERVER}..."
    sleep 2
done

# ── Lock the tunnel egress to the mail service only ──
# Over the VPN, this container may reach ONLY the mail ports (IMAPS 993 and
# submission 587) and DNS. Every other university host, port, and service is
# unreachable through the tunnel, so even a compromise of this box cannot be
# turned into a backdoor into the wider university network. The VPN transport
# itself (on eth0) and this container's own return traffic are unaffected. The
# rules reference tun0 by name, so they can be installed before the interface
# exists; they take effect once the tunnel comes up. Best effort: if iptables is
# unavailable the proxy still only relays mail, but this extra firewall is off.
apply_egress_lock() {
    iptables -A OUTPUT -o lo -j ACCEPT &&
    iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT &&
    iptables -A OUTPUT ! -o tun0 -j ACCEPT &&
    iptables -A OUTPUT -o tun0 -p tcp -m multiport --dports 993,587 -j ACCEPT &&
    iptables -A OUTPUT -o tun0 -p udp --dport 53 -j ACCEPT &&
    iptables -A OUTPUT -o tun0 -p tcp --dport 53 -j ACCEPT &&
    iptables -A OUTPUT -o tun0 -j DROP &&
    iptables -A INPUT -i tun0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT &&
    iptables -A INPUT -i tun0 -j DROP
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

# ── Keep the VPN up, and refresh the session on a schedule ──
# The university expires the VPN session about 24 hours after sign-in
# (openconnect logs the exact time: "Session authentication will expire at ...").
# Waiting for that hard expiry is rough: openconnect can keep retrying a dead
# session for minutes before giving up. Instead we re-authenticate ourselves at
# fixed local times (VPN_REFRESH_TIMES, default 03:00 and 04:00), quiet hours
# where a ~4-second reconnect is very unlikely to disturb anyone. Using two times
# a day (not one) keeps the largest gap under 24h with no drift, so a refresh
# always lands before the session can hard-expire. Times are read in TZ (default
# Europe/Berlin); set TZ to your server's zone if different. Brief network blips
# are still absorbed by openconnect itself, with no re-auth. We run one connect
# per loop (not openconnect-saml's own --reconnect) so we control the timing.
# VPN_REFRESH_SECONDS is a test-only fixed-interval override.
export TZ="${TZ:-Europe/Berlin}"
VPN_REFRESH_TIMES="${VPN_REFRESH_TIMES:-03:00,04:00}"
VPN_RECONNECT_BACKOFF="${VPN_RECONNECT_BACKOFF:-35}"
VPN_PROACTIVE_BACKOFF="${VPN_PROACTIVE_BACKOFF:-2}"

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

# Kill the openconnect binary (comm is exactly "openconnect"), without procps.
kill_openconnect() {
    local d
    for d in /proc/[0-9]*; do
        [ "$(cat "$d/comm" 2>/dev/null || true)" = "openconnect" ] \
            && kill "$(basename "$d")" 2>/dev/null || true
    done
    return 0
}

# Clean shutdown on docker stop: drop the tunnel and exit.
trap 'kill_openconnect; exit 0' TERM INT

warn_if_schedule_unsafe
echo "[vpn] connecting to ${VPN_SERVER} (headless SAML + TOTP); proactive refresh at ${VPN_REFRESH_TIMES} ${TZ}."
while true; do
    rm -f /tmp/proactive_refresh
    # --no-sudo: we are already root; openconnect creates tun0 directly
    # (needs NET_ADMIN + /dev/net/tun).
    openconnect-saml connect "${PROFILE_NAME}" --browser headless --no-sudo &
    oc_saml=$!

    # When to refresh: the next scheduled time, or a fixed interval in tests.
    refresh_in="${VPN_REFRESH_SECONDS:-$(seconds_until_next_refresh)}"
    echo "[vpn] next proactive refresh: $(date -d "@$(( $(date +%s) + refresh_in ))" '+%Y-%m-%d %H:%M:%S %Z') (in ${refresh_in}s)"

    # Refresh timer: at the scheduled time, end the current session so the loop
    # re-authenticates before the server-side expiry. The flag marks it planned.
    ( sleep "${refresh_in}"
      touch /tmp/proactive_refresh
      echo "[vpn] proactive refresh: re-authenticating before the session expires"
      kill "${oc_saml}" 2>/dev/null || true
      kill_openconnect ) &
    refresh_timer=$!

    wait "${oc_saml}" 2>/dev/null || true   # blocks until it exits (drop or timer)
    kill "${refresh_timer}" 2>/dev/null || true
    kill_openconnect                        # make sure the tunnel is down

    if [ -f /tmp/proactive_refresh ]; then
        # Planned refresh: the session was at least an hour old (refreshes are
        # spaced apart), so there is no one-time-code anti-replay risk. Reconnect
        # right away to keep the gap tiny (about 4 seconds total).
        backoff="${VPN_PROACTIVE_BACKOFF}"
        echo "[vpn] reconnecting now (planned refresh, ${backoff}s settle)..."
    else
        # Unexpected drop, which could have happened seconds after a login. Keep
        # the backoff above the 30-second code window so no code is reused.
        backoff="${VPN_RECONNECT_BACKOFF}"
        echo "[vpn] VPN session ended unexpectedly; re-authenticating in ${backoff}s..."
    fi
    sleep "${backoff}"
done
