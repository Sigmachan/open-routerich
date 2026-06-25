#!/bin/sh
# open-routerich :: modules/doh-unpoison.sh
# Un-poison DNS via DoH. Russia (and similar regimes) inject spoofed answers for
# blocked domains on plain UDP/TCP port 53 for EVERY upstream resolver — proven:
# 8.8.8.8 / 9.9.9.9 / AdGuard / comss all returned rutracker.org -> a poisoned
# 94.230.x stub. Only ENCRYPTED DNS (DoH) bypasses in-transit poisoning.
#
# This runs two local https-dns-proxy instances (DoH) and points dnsmasq at them
# with `noresolv` so the ISP's poisoned 53 is never consulted. A /data watchdog
# keeps them alive across the vendor router's /etc ramfs reset and FALLS BACK to
# ISP DNS if both DoH die (the LAN never loses resolution). Sentinel auto-revert
# guards the live switch.
#
# Vendor/immutable + Entware path (binary lives in /opt on USB). On a normal
# writable OpenWrt, install.sh's stock https-dns-proxy + UCI path already covers
# this; this module is the Entware/immutable implementation.
#
# Usage: sh modules/doh-unpoison.sh [install|uninstall]
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

# --- DoH resolvers (instance "port|bootstrap|resolver_url"). Non-CF by default:
# Cloudflare is throttled/blocked in some regions; AdGuard + Google are reachable
# and un-poison correctly (verified). Edit freely. ---
DOH_INSTANCES="${DOH_INSTANCES:-5353|94.140.14.14,94.140.15.15|https://dns.adguard-dns.com/dns-query
5354|8.8.8.8,8.8.4.4|https://dns.google/dns-query}"

INIT=/opt/etc/init.d/S09https-dns-proxy
WATCHDOG=/data/dns-stack.sh
ACTION="${1:-install}"

# cat a repo config_file from local clone, else fetch from ZU_BASE_URL.
cfg_file() {
    if [ -n "$_self" ] && [ -f "$_self/config_files/$1" ]; then cat "$_self/config_files/$1"
    else fetch_stdout "$ZU_BASE_URL/config_files/$1"; fi
}

doh_ports() { printf '%s\n' "$DOH_INSTANCES" | while IFS='|' read -r p _ _; do [ -n "$p" ] && printf '%s ' "$p"; done; }

uninstall_doh() {
    log "doh-unpoison: removing DoH layer..."
    [ -x "$INIT" ] && "$INIT" stop 2>/dev/null || true
    killall https-dns-proxy 2>/dev/null || true
    # neutralize Entware autostart (rename out of S* so rc.unslung skips it)
    [ -f "$INIT" ] && mv "$INIT" "${INIT%/*}/K09https-dns-proxy.disabled" 2>/dev/null || true
    # drop watchdog cron + file
    [ -f /etc/crontabs/root ] && { sed -i '\#/data/dns-stack.sh#d' /etc/crontabs/root; manage_service cron "" restart 2>/dev/null || /etc/init.d/crond restart 2>/dev/null || true; }
    rm -f "$WATCHDOG"
    # revert dnsmasq to ISP DNS
    local sec; sec="$(dnsmasq_section)"
    for p in $(doh_ports); do uci -q del_list "dhcp.$sec.server=127.0.0.1#$p" 2>/dev/null || true; done
    uci -q set "dhcp.$sec.noresolv=0" 2>/dev/null || true
    uci commit dhcp 2>/dev/null || true
    manage_service dnsmasq "" restart
    log "doh-unpoison removed; dnsmasq back to ISP DNS."
}

install_doh() {
    detect_entware || die "doh-unpoison needs Entware (/opt/bin/opkg). Set it up first: modules/entware-install.sh"
    entware_installed https-dns-proxy || { log "Installing https-dns-proxy (Entware)..."; "$ENTWARE_OPKG" update >/dev/null 2>&1 || true; entware_install https-dns-proxy || die "https-dns-proxy install failed"; }
    # bind-dig: REQUIRED for the watchdog's functional health probe. Without it
    # the watchdog cannot verify DoH actually resolves and will keep the safe
    # ISP-DNS fallback (online but poisoned) instead of un-poisoning.
    entware_installed bind-dig || "$ENTWARE_OPKG" install bind-dig >/dev/null 2>&1 || true
    [ -x /opt/bin/dig ] || warn "bind-dig missing: un-poisoning will fall back to ISP DNS via the watchdog. Install bind-dig for un-poisoned DNS."

    log "Deploying DoH init + watchdog..."
    cfg_file S09https-dns-proxy > "$INIT" || die "cannot write $INIT"
    chmod +x "$INIT"
    cfg_file dns-stack.sh > "$WATCHDOG" || die "cannot write $WATCHDOG"
    chmod +x "$WATCHDOG"

    "$INIT" restart >/dev/null 2>&1
    sleep 6

    # health: at least one DoH instance answers
    local ok=0 dig=/opt/bin/dig
    for p in $(doh_ports); do
        if [ -x "$dig" ]; then "$dig" @127.0.0.1 -p "$p" ya.ru +short +time=4 +tries=1 2>/dev/null | grep -qE '^[0-9]' && { ok=1; break; }
        elif netstat -lnu 2>/dev/null | grep -q "127.0.0.1:$p "; then ok=1; break; fi
    done
    [ "$ok" = 1 ] || { warn "DoH instances unhealthy; not touching dnsmasq."; return 1; }

    # snapshot revert state, wire dnsmasq -> DoH (noresolv)
    local sec; sec="$(dnsmasq_section)"
    local prev_nores; prev_nores="$(uci -q get "dhcp.$sec.noresolv" || echo 0)"
    for p in $(doh_ports); do uci_add_list_once dhcp "dhcp.$sec.server" "127.0.0.1#$p"; done
    uci set "dhcp.$sec.noresolv=1"
    uci commit dhcp
    manage_service dnsmasq "" restart
    sleep 3

    # SENTINEL: success = LAN DNS RESOLVES via DoH. HTTP(google) is informational
    # only — gating on it would falsely revert on transient web failures or when
    # curl is unavailable (the malw module's model).
    local up norm rt g
    up=$(pidof dnsmasq >/dev/null && echo 1 || echo 0)
    if [ -x /opt/bin/dig ]; then
        norm=$(/opt/bin/dig @127.0.0.1 ya.ru +short +time=4 +tries=1 2>/dev/null | grep -cE '^[0-9]+\.' || true)
    else
        norm=$(nslookup ya.ru 127.0.0.1 2>/dev/null | sed -n '/[Nn]ame:/,$p' | grep -cE '([0-9]{1,3}\.){3}[0-9]{1,3}' || true)
    fi
    if [ "$up" = 1 ] && [ "$norm" -ge 1 ]; then
        if [ -x /opt/bin/dig ]; then rt=$(/opt/bin/dig @127.0.0.1 rutracker.org +short +time=4 +tries=1 2>/dev/null | grep -E '^[0-9]' | head -1)
        else rt=$(nslookup rutracker.org 127.0.0.1 2>/dev/null | sed -n '/[Nn]ame:/,$p' | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1); fi
        g=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 https://www.google.com 2>/dev/null || echo 000)
        log "DoH un-poisoning ACTIVE (dnsmasq->DoH, noresolv). rutracker.org=$rt google=$g"
        case "$rt" in 94.230.*|"") warn "rutracker still looks poisoned ($rt) — check DoH reachability";; *) log "Un-poison confirmed (real IP).";; esac
    else
        warn "Sentinel failed (dnsmasq=$up resolve=$norm) -> reverting DoH wiring."
        for p in $(doh_ports); do uci -q del_list "dhcp.$sec.server=127.0.0.1#$p" 2>/dev/null || true; done
        uci -q set "dhcp.$sec.noresolv=$prev_nores" 2>/dev/null || true; uci -q commit dhcp 2>/dev/null || true
        manage_service dnsmasq "" restart
        return 1
    fi

    # persist across /etc ramfs reset
    if [ -f /etc/crontabs/root ]; then
        grep -q '/data/dns-stack.sh' /etc/crontabs/root || echo '*/5 * * * * /data/dns-stack.sh' >> /etc/crontabs/root
        manage_service cron "" restart 2>/dev/null || /etc/init.d/crond restart 2>/dev/null || true
    fi
    log "doh-unpoison installed & persisted."
}

case "$ACTION" in
    install) install_doh ;;
    uninstall|remove|off) uninstall_doh ;;
    *) echo "usage: $0 {install|uninstall}" >&2; exit 1 ;;
esac
