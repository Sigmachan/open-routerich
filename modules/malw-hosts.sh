#!/bin/sh
# open-routerich :: modules/malw-hosts.sh
# Geo-unblock layer via the dns.malw.link hosts list (ImMALWARE). Maps ~30k
# domains that block Russian IPs *from the service side* (ChatGPT, Spotify,
# Notion, ...) onto malw's SNI-proxy IPs, so they open without a VPN. This is a
# pure DNS/hosts override: it does NOT touch packets, so it is fully compatible
# with hardware NSS/ECM offload (unlike DPI desync). It does NOT bypass RKN SNI
# blocks — pair it with the DoH layer + (for RKN) a VLESS tunnel.
#
# Installs the list as a dnsmasq addn-hosts file under /data (persists on the
# vendor router's ubifs), wires dnsmasq, and is kept applied by dns-stack.sh.
#
# Usage: sh modules/malw-hosts.sh [install|uninstall|update]
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

HOSTS=/data/malw-hosts
TMP=/tmp/malw-hosts.dl
# Fetch order: jsdelivr (github mirror, usually reachable where raw.githubusercontent
# is DPI-blocked) -> GitHub API (needs GH_TOKEN) -> codeload tarball.
MALW_SOURCES="${MALW_SOURCES:-https://cdn.jsdelivr.net/gh/ImMALWARE/dns.malw.link@master/hosts
https://fastly.jsdelivr.net/gh/ImMALWARE/dns.malw.link@master/hosts
https://raw.githubusercontent.com/ImMALWARE/dns.malw.link/master/hosts}"
ACTION="${1:-install}"

fetch_hosts() {
    local u
    for u in $MALW_SOURCES; do
        log "fetching malw hosts: $u"
        rm -f "$TMP"
        fetch_to "$u" "$TMP" 2>/dev/null || continue
        # reject HTML viewer pages / empty
        [ -s "$TMP" ] || continue
        head -1 "$TMP" | grep -qi '<!DOCTYPE\|<html' && { warn "got HTML, not raw"; continue; }
        # need a meaningful number of "IP host" lines
        local n; n=$(grep -cE '^[0-9a-fA-F:.]+[[:space:]]+[A-Za-z0-9._-]+' "$TMP" 2>/dev/null || true); n=${n:-0}
        if [ "$n" -ge 1000 ]; then log "fetched $n host entries"; return 0; fi
        warn "only $n entries from $u, trying next"
    done
    # GitHub API fallback (authenticated) when a token is present
    if [ -n "${GH_TOKEN:-}" ]; then
        log "trying GitHub API (token)"
        if fetch_to "https://api.github.com/repos/ImMALWARE/dns.malw.link/contents/hosts" "$TMP.json" 2>/dev/null; then
            sed -n 's/.*"content": *"\(.*\)".*/\1/p' "$TMP.json" | sed 's/\\n//g' | base64 -d > "$TMP" 2>/dev/null || true
            [ -s "$TMP" ] && grep -qE '^[0-9].* ' "$TMP" && return 0
        fi
    fi
    return 1
}

install_malw() {
    local RAW=/tmp/malw-hosts.raw have=0
    [ -f "$HOSTS" ] && [ "$(grep -cE '^[0-9a-fA-F:.]+[[:space:]]+' "$HOSTS" 2>/dev/null || true)" -ge 50 ] && have=1
    if [ "$ACTION" = update ] || [ "$have" = 0 ]; then
        if fetch_hosts; then
            tr -d '\r' < "$TMP" > "$RAW"; rm -f "$TMP" "$TMP.json"
        elif [ "$have" = 1 ]; then
            warn "fetch failed; re-normalizing existing $HOSTS"; cp "$HOSTS" "$RAW"
        else
            die "could not fetch malw hosts from any source (DPI? set GH_TOKEN or MALW_SOURCES)"
        fi
    else
        log "existing $HOSTS present; re-normalizing (run 'update' to refresh from source)"; cp "$HOSTS" "$RAW"
    fi
    # NORMALIZE: keep only valid "IP host" lines. By DEFAULT drop the ad/tracker
    # sinkhole (0.0.0.0 / :: / 127.x) — malw's list null-routes ~30k domains incl
    # legit asset/CDN hosts (csi.gstatic.com, cloudfront, ...) which breaks site
    # icons/images. Geo-unblock = only the real-IP proxy mappings. Set
    # MALW_BLOCKLIST=1 to keep the full adblock sinkhole as well.
    if [ "${MALW_BLOCKLIST:-0}" = 1 ]; then
        grep -E '^[0-9a-fA-F:.]+[[:space:]]+[A-Za-z0-9._-]' "$RAW" > "$HOSTS"
    else
        grep -E '^[0-9a-fA-F:.]+[[:space:]]+[A-Za-z0-9._-]' "$RAW" | grep -vE '^[[:space:]]*(0\.0\.0\.0|::|127\.)' > "$HOSTS"
    fi
    rm -f "$RAW"
    local n; n=$(grep -cE '^[0-9a-fA-F:.]+[[:space:]]+' "$HOSTS" || true); n=${n:-0}
    log "using $HOSTS ($n entries$([ "${MALW_BLOCKLIST:-0}" = 1 ] && echo ', incl adblock sinkhole' || echo ', geo-unblock only'), $(wc -c < "$HOSTS") bytes)"
    # validate via dnsmasq before wiring
    if command -v dnsmasq >/dev/null 2>&1; then
        dnsmasq --test --addn-hosts="$HOSTS" 2>&1 | grep -qi 'syntax check OK' || { warn "dnsmasq rejected the hosts file; aborting"; return 1; }
    fi
    local sec; sec="$(dnsmasq_section)"
    uci_add_list_once dhcp "dhcp.$sec.addnhosts" "$HOSTS"
    uci commit dhcp
    manage_service dnsmasq "" restart
    sleep 2
    # sentinel
    local up norm g
    up=$(pidof dnsmasq >/dev/null && echo 1 || echo 0)
    norm=$(nslookup ya.ru 127.0.0.1 2>/dev/null | grep -c 'Address 1' || true)
    g=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 https://www.google.com 2>/dev/null || echo 000)
    if [ "$up" = 1 ] && [ "$norm" -ge 1 ]; then
        local probe; probe=$(grep -m1 -iE '^[0-9].*(chatgpt|spotify|openai)\b' "$HOSTS" | awk '{print $2}')
        local ip; [ -n "$probe" ] && ip=$(nslookup "$probe" 127.0.0.1 2>/dev/null | sed -n 's/^Address 1: //p' | grep -v 127.0.0.1 | head -1)
        log "malw geo-unblock ACTIVE. ${probe:-sample} -> ${ip:-?} ; google=$g"
    else
        warn "Sentinel failed (dnsmasq=$up resolve=$norm) -> reverting addn-hosts."
        uci -q del_list "dhcp.$sec.addnhosts=$HOSTS"; uci commit dhcp
        manage_service dnsmasq "" restart
        return 1
    fi
    # persistence: dns-stack.sh watchdog re-applies it; add a minimal cron if absent
    if [ ! -f /data/dns-stack.sh ] && [ -f /etc/crontabs/root ]; then
        grep -q 'malw-hosts re-apply' /etc/crontabs/root || \
            printf '%s\n' "*/5 * * * * uci -q get dhcp.@dnsmasq[0].addnhosts | grep -q $HOSTS || { uci add_list dhcp.@dnsmasq[0].addnhosts=$HOSTS; uci commit dhcp; /etc/init.d/dnsmasq restart; } # malw-hosts re-apply" >> /etc/crontabs/root
        manage_service cron "" restart 2>/dev/null || /etc/init.d/crond restart 2>/dev/null || true
    fi
    log "malw-hosts installed & persisted."
}

uninstall_malw() {
    log "malw-hosts: removing geo-unblock layer..."
    local sec; sec="$(dnsmasq_section)"
    uci -q del_list "dhcp.$sec.addnhosts=$HOSTS" 2>/dev/null || true
    uci commit dhcp 2>/dev/null || true
    [ -f /etc/crontabs/root ] && { sed -i '/malw-hosts re-apply/d' /etc/crontabs/root; manage_service cron "" restart 2>/dev/null || /etc/init.d/crond restart 2>/dev/null || true; }
    rm -f "$HOSTS"
    manage_service dnsmasq "" restart
    log "malw-hosts removed."
}

case "$ACTION" in
    install|update) install_malw ;;
    uninstall|remove|off) uninstall_malw ;;
    *) echo "usage: $0 {install|uninstall|update}" >&2; exit 1 ;;
esac
