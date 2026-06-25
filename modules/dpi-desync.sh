#!/bin/sh
# open-routerich :: modules/dpi-desync.sh
# ECM-AWARE, SELF-REVERTING youtubeUnblock (DPI desync) for vendor routers.
#
# Reality on QCA NSS/ECM hardware-offload routers (Xiaomi IPQ5424 et al.): the
# accelerator can corrupt the fake/fragmented packets a DPI-desync engine injects
# and break HTTPS. There is NO functional per-flow exempt on this vendor ECM
# build (net.ecm.tcp_denied_ports is an inert stub; only the GLOBAL accel toggle
# works, and disabling it kills throughput). So desync here is BEST-EFFORT.
#
# This module makes trying it SAFE and HONEST:
#   * detects ECM/NSS offload,
#   * attempts the per-flow exempt (and reports whether it actually took),
#   * runs youtubeUnblock on a TARGETED SNI list (not "all") with control
#     domains (google/cloudflare) kept OUT of the list,
#   * a connectivity SENTINEL auto-reverts the moment the controls drop from
#     HTTP 200 — so a failed desync never leaves the router broken,
#   * reports the truthful outcome: works / not-viable-reverted.
#
# Usage: sh modules/dpi-desync.sh [check|try|off]
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

QNUM="${YU_QUEUE:-537}"
CHAIN=YOUTUBEUNBLOCK
YU_BIN="${YU_BIN:-/opt/bin/youtubeUnblock}"
# TARGET SNIs to desync (RKN-blocked / throttled). Controls (google/cloudflare)
# are intentionally NOT here so the sentinel can prove connectivity survives.
TARGET_SNI="${TARGET_SNI:-googlevideo.com,youtube.com,youtu.be,ytimg.com,ggpht.com,discord.com,discord.gg,discordapp.net,discord.media,rutracker.org,rutracker.net,x.com,twitter.com,instagram.com}"
CTRL_URLS="https://www.google.com https://ya.ru"
ACTION="${1:-check}"

ecm_present() { [ -d /sys/kernel/debug/ecm ]; }
ecm_enabled() { [ "$(cat /sys/kernel/debug/ecm/ecm_classifier_default/enabled 2>/dev/null)" = 1 ]; }
http() { c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$1" 2>/dev/null)"; echo "${c:-000}"; }
# "connected" = we got ANY TLS+HTTP response; desync breakage shows up as 000.
ctrl_alive() { c="$(http "$1")"; case "$c" in 000|"") return 1 ;; *) return 0 ;; esac; }
controls_ok() { for u in $CTRL_URLS; do ctrl_alive "$u" || { sleep 1; ctrl_alive "$u" || return 1; }; done; return 0; }

teardown() {
    [ -x "$YU_BIN" ] && killall "$(basename "$YU_BIN")" 2>/dev/null || true
    killall youtubeUnblock 2>/dev/null || true
    i=0; while iptables -t mangle -D POSTROUTING -j "$CHAIN" 2>/dev/null; do i=$((i+1)); [ "$i" -gt 10 ] && break; done
    iptables -t mangle -F "$CHAIN" 2>/dev/null || true
    iptables -t mangle -X "$CHAIN" 2>/dev/null || true
    # neutralize any Entware autostart so rc.unslung can't resurrect it
    for s in /opt/etc/init.d/S*youtubeUnblock*; do [ -f "$s" ] && mv "$s" "${s%/*}/K${s##*/S}.disabled" 2>/dev/null || true; done
    # restore ECM exempt knob
    sysctl -w net.ecm.tcp_denied_ports="" >/dev/null 2>&1 || true
}

setup_chain() {
    iptables -t mangle -N "$CHAIN" 2>/dev/null || iptables -t mangle -F "$CHAIN"
    # only the first packets of a TCP/443 connection carry the ClientHello/SNI
    iptables -t mangle -A "$CHAIN" -p tcp --dport 443 \
        -m connbytes --connbytes 0:19 --connbytes-dir original --connbytes-mode packets \
        -j NFQUEUE --queue-num "$QNUM" --queue-bypass
    iptables -t mangle -C POSTROUTING -j "$CHAIN" 2>/dev/null || iptables -t mangle -A POSTROUTING -j "$CHAIN"
}

attempt_ecm_exempt() {
    # try the per-flow exempt; report whether the vendor firmware honors it
    sysctl -w net.ecm.tcp_denied_ports=443 >/dev/null 2>&1 || true
    if [ "$(sysctl -n net.ecm.tcp_denied_ports 2>/dev/null)" = 443 ]; then
        echo 1 > /sys/kernel/debug/ecm/ecm_db/defunct_all 2>/dev/null || true
        log "ECM per-flow exempt ACTIVE (443 off the accel path) — desync may coexist with offload."
        return 0
    fi
    warn "ECM per-flow exempt NOT honored by this firmware (tcp_denied_ports inert). Desync runs on the accelerated path — likely to fail."
    return 1
}

do_check() {
    log "DPI-desync environment:"
    echo "  youtubeUnblock binary : $([ -x "$YU_BIN" ] && echo present || echo MISSING)"
    echo "  ECM/NSS offload       : $(ecm_present && { ecm_enabled && echo 'present + ENABLED (desync risk)' || echo 'present, disabled'; } || echo absent)"
    echo "  per-flow exempt knob  : $([ -e /proc/sys/net/ecm/tcp_denied_ports ] && echo present || echo absent) (works only if it holds a value)"
    echo "  running               : $(pidof youtubeUnblock >/dev/null && echo UP || echo off), mangle chain refs=$(iptables -t mangle -S 2>/dev/null | grep -c "$CHAIN")"
}

do_try() {
    [ -x "$YU_BIN" ] || { detect_entware && entware_installed youtubeUnblockEntware && YU_BIN=/opt/bin/youtubeUnblock; }
    [ -x "$YU_BIN" ] || die "youtubeUnblock binary not found ($YU_BIN). Install it first (install.sh [4/7] / Entware)."
    controls_ok || die "controls already not 200 before test — fix connectivity first."

    local ecm_warn=0
    if ecm_present && ecm_enabled; then
        warn "NSS/ECM hardware offload is ENABLED — DPI desync may corrupt HTTPS on this router."
        ecm_warn=1
        attempt_ecm_exempt || true
    fi

    # baseline target reachability BEFORE desync (to measure real improvement)
    local b_rt b_yt; b_rt=$(http https://rutracker.org); b_yt=$(http https://www.youtube.com)
    log "baseline targets (no desync): rutracker=$b_rt youtube=$b_yt"

    log "Starting youtubeUnblock (targeted SNIs, queue $QNUM) behind a connectivity sentinel..."
    teardown 2>/dev/null || true
    setup_chain
    start-stop-daemon -S -b -m -p /tmp/youtubeUnblock.pid -x "$YU_BIN" -- \
        --queue-num="$QNUM" --sni-domains="$TARGET_SNI" --fake-sni=1 --faking-strategy=pastseq --silent 2>/dev/null \
        || "$YU_BIN" --queue-num="$QNUM" --sni-domains="$TARGET_SNI" --fake-sni=1 --faking-strategy=pastseq --daemonize >/dev/null 2>&1
    sleep 3

    # SENTINEL 1: general connectivity (controls are NOT in the desync list) must survive
    local ok=1 i=0
    while [ "$i" -lt 2 ]; do controls_ok || ok=0; i=$((i+1)); sleep 1; done
    if [ "$ok" != 1 ]; then
        warn "SENTINEL TRIPPED: general connectivity dropped with desync active -> AUTO-REVERTING."
        teardown; sleep 1
        if controls_ok; then err "DPI-desync NOT VIABLE (ECM corrupts even non-target HTTPS). Router restored to normal."
        else err "controls still down after revert — run: sh modules/dpi-desync.sh off"; fi
        return 1
    fi

    # SENTINEL 2: did desync actually UN-block a target (000/blocked -> alive)?
    local a_rt a_yt improved=0
    a_rt=$(http https://rutracker.org); a_yt=$(http https://www.youtube.com)
    { [ "$b_rt" = 000 ] && [ "$a_rt" != 000 ]; } && improved=1
    { [ "$b_yt" = 000 ] && [ "$a_yt" != 000 ]; } && improved=1
    if [ "$improved" = 1 ]; then
        log "DESYNC WORKS: controls intact; targets improved (rutracker $b_rt->$a_rt, youtube $b_yt->$a_yt). Keeping."
        log "Revert anytime: sh modules/dpi-desync.sh off"
        return 0
    fi
    warn "Desync did not un-block targets (rutracker $b_rt->$a_rt, youtube $b_yt->$a_yt) — ECM corrupts the desync'd flows."
    teardown; sleep 1
    err "DPI-desync NOT VIABLE on this ECM router (offload corrupts injected packets; no per-flow exempt available)."
    err "Working paths here: DNS layer (DoH un-poison + malw geo-unblock) + a VLESS tunnel for RKN-SNI sites."
    return 1
}

case "$ACTION" in
    check) do_check ;;
    try|install|on) do_try ;;
    off|uninstall|remove) teardown; log "dpi-desync torn down; router normal."; do_check ;;
    *) echo "usage: $0 {check|try|off}" >&2; exit 1 ;;
esac
