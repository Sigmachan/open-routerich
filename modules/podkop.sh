#!/bin/sh
# open-routerich :: modules/podkop.sh
# Universal podkop (domain routing via VLESS/Shadowsocks/AmneziaWG) using the
# OFFICIAL itdoginfo installer (not routerich's pinned 0.2.5 ipk), then applies
# the routerich-tuned routing config (youtube/rutracker/instagram/discord +
# a "second" http-proxy profile for chatgpt/tiktok/etc).
#
# Requirements: OpenWrt >= 24.10, kmod-nft-tproxy (tproxy). Will NOT work on
# vendor immutable routers without nft_tproxy (e.g. Xiaomi IPQ stock) — use the
# DNS-redirect + youtubeUnblock path there instead.
#
# Usage: sh modules/podkop.sh [--iface awg10] [--profile main|second|youtube]
set -eu

ZU_BASE_URL="${ZU_BASE_URL:-https://raw.githubusercontent.com/Sigmachan/open-routerich/main}"
_self="$(cd "$(dirname -- "$0" 2>/dev/null)/.." 2>/dev/null && pwd || true)"
if [ -n "$_self" ] && [ -f "$_self/lib/common.sh" ]; then
    . "$_self/lib/common.sh"
elif [ -n "$ZU_BASE_URL" ]; then
    eval "$(wget -qO- --no-check-certificate "$ZU_BASE_URL/lib/common.sh" 2>/dev/null \
            || uclient-fetch -qO- "$ZU_BASE_URL/lib/common.sh")"
else
    echo "lib/common.sh not found. Run from a clone, or set ZU_BASE_URL." >&2; exit 1
fi

IFACE="awg10"; PROFILE="main"
while [ $# -gt 0 ]; do
    case "$1" in
        --iface)   IFACE="$2"; shift ;;
        --profile) PROFILE="$2"; shift ;;
        *) warn "unknown option: $1" ;;
    esac; shift
done

# --- preflight: tproxy + version --------------------------------------------
if detect_immutable; then
    die "Immutable/vendor root detected — podkop needs to install into / and needs nft_tproxy. Not supported here; use install.sh (DNS+QUIC) + youtubeUnblock via Entware."
fi
MINOR="$(detect_minor)"
[ -z "$MINOR" ] || branch_ge "$MINOR" "24.10" \
    || warn "podkop officially targets OpenWrt >= 24.10 (you have $MINOR) — may not work."

pm_update || warn "pkg update failed"
ensure_pkg kmod-nft-tproxy 0
ensure_pkg jq 1; ensure_pkg curl 1

# --- install podkop via the official installer ------------------------------
if pm_installed podkop; then
    log "podkop already installed"
else
    log "Installing podkop via official itdoginfo installer..."
    _inst="$(fetch_stdout https://raw.githubusercontent.com/itdoginfo/podkop/main/install.sh 2>/dev/null)"
    if [ -n "$_inst" ]; then
        printf '%s\n' "$_inst" | sh 2>&1 | tail -20 || warn "official installer returned non-zero"
    else
        warn "could not fetch official installer; trying feed..."
        ensure_pkg podkop 0
    fi
fi
pm_installed podkop || die "podkop install failed. See https://github.com/itdoginfo/podkop"

# --- apply routerich-tuned routing config -----------------------------------
backup() { [ -f /etc/config/podkop ] && cp -f /etc/config/podkop "/root/podkop.bak.$$" || true; }
apply_tpl() { # apply_tpl <template-name>
    _n="$1"
    if [ -n "$_self" ] && [ -f "$_self/config_files/$_n" ]; then cp -f "$_self/config_files/$_n" /etc/config/podkop
    else fetch_to "$ZU_BASE_URL/config_files/$_n" /etc/config/podkop || die "cannot fetch config_files/$_n"; fi
}
backup
case "$PROFILE" in
    main)    apply_tpl podkop ;;
    second)  apply_tpl podkopSecond ;;
    youtube) apply_tpl podkopSecondYoutube ;;
    *) die "unknown profile: $PROFILE (main|second|youtube)" ;;
esac

# retarget the routing interface (template defaults to awg10)
if [ "$IFACE" != "awg10" ]; then
    sed -i "s/'awg10'/'$IFACE'/g" /etc/config/podkop
    log "podkop interface set to $IFACE"
fi
uci commit podkop 2>/dev/null || true

manage_service podkop enable restart
log "podkop configured (profile=$PROFILE, iface=$IFACE)."
log "Tune lists in LuCI -> Services -> Podkop, or /etc/config/podkop."
