#!/bin/sh
# open-routerich :: uninstall.sh
# Universal port of routerich off_*.sh — restores backups taken by install.sh
# and disables the services it enabled. Section ids are resolved dynamically.
set -eu

ZU_BASE_URL="${ZU_BASE_URL:-https://raw.githubusercontent.com/Sigmachan/open-routerich/main}"
_self="$(cd "$(dirname -- "$0" 2>/dev/null)" 2>/dev/null && pwd || true)"
if [ -n "$_self" ] && [ -f "$_self/lib/common.sh" ]; then
    . "$_self/lib/common.sh"
elif [ -n "$ZU_BASE_URL" ]; then
    eval "$(wget -qO- --no-check-certificate "$ZU_BASE_URL/lib/common.sh" 2>/dev/null \
            || uclient-fetch -qO- "$ZU_BASE_URL/lib/common.sh")"
else
    echo "lib/common.sh not found. Run from a clone, or set ZU_BASE_URL." >&2
    exit 1
fi

BACKUP_DIR="/root/zapret-universal-backup"

run_module() { # local clone first, else fetch+pipe
    _m="$1"; shift
    if [ -n "$_self" ] && [ -f "$_self/modules/$_m.sh" ]; then sh "$_self/modules/$_m.sh" "$@"
    else ZU_BASE_URL="$ZU_BASE_URL" sh -c "$(fetch_stdout "$ZU_BASE_URL/modules/$_m.sh")" -- "$@"; fi
}

log "Stopping & disabling DPI-bypass services..."
manage_service youtubeUnblock  disable stop
manage_service https-dns-proxy disable stop
# remove the DNS layer added by the modules (DoH un-poisoning + malw geo-unblock)
run_module doh-unpoison uninstall 2>/dev/null || true
run_module malw-hosts   uninstall 2>/dev/null || true

if [ -d "$BACKUP_DIR" ]; then
    log "Restoring config backups from $BACKUP_DIR ..."
    for f in "$BACKUP_DIR"/*; do
        [ -f "$f" ] || continue
        n="$(basename "$f")"
        cp -f "$f" "/etc/config/$n"
        log "  restored /etc/config/$n"
    done
    rm -rf "$BACKUP_DIR"
else
    warn "No backup dir ($BACKUP_DIR). Removing rules added by install.sh manually..."
    DNSSEC="$(dnsmasq_section)"
    # strip our DoH loopback servers + comss redirects
    uci -q del "dhcp.$DNSSEC.strictorder" || true
    while uci -q show "dhcp.$DNSSEC.server" 2>/dev/null | grep -q '127.0.0.1#505'; do
        idx=$(uci -q get "dhcp.$DNSSEC.server" | tr ' ' '\n' | grep -n '127.0.0.1#505' | head -n1 | cut -d: -f1)
        [ -n "$idx" ] || break
        uci -q del_list "dhcp.$DNSSEC.server=$(uci -q get "dhcp.$DNSSEC.server" | awk -v i="$idx" '{print $i}')" || break
    done
    uci -q commit dhcp || true
    # remove QUIC rules
    while uci -q show firewall | grep -q "name='Block_UDP_"; do
        sec=$(uci -q show firewall | sed -n "s/^firewall\.\(@rule\[[0-9]*\]\)\.name='Block_UDP_.*/\1/p" | head -n1)
        [ -n "$sec" ] || break
        uci -q delete "firewall.$sec" || break
    done
    uci -q commit firewall || true
fi

# re-enable native youtubeUnblock if the user still wants it standalone? No —
# uninstall means off. Leave packages installed but services stopped.

log "Restarting firewall, dnsmasq, odhcpd..."
manage_service firewall "" restart
manage_service dnsmasq  "" restart
manage_service odhcpd   "" restart

# drop the self-update cron line if present
if [ -n "$ZU_BASE_URL" ] && [ -f /etc/crontabs/root ]; then
    grep -vF "$ZU_BASE_URL/install.sh" /etc/crontabs/root > /etc/crontabs/root.tmp 2>/dev/null \
        && mv /etc/crontabs/root.tmp /etc/crontabs/root && manage_service cron "" restart || true
fi

log "Uninstall complete. (Installed packages kept; remove with: opkg remove youtubeUnblock https-dns-proxy)"
