#!/bin/sh
# open-routerich :: webui/uninstall-webui.sh
# Removes the uhttpd panel instance and (optionally) the install dir.
# Does NOT touch the DPI-bypass config — use ../uninstall.sh for that.
set -eu

ZU_BASE_URL="${ZU_BASE_URL:-https://raw.githubusercontent.com/Sigmachan/open-routerich/main}"
_self="$(cd "$(dirname -- "$0" 2>/dev/null)/.." 2>/dev/null && pwd || true)"
if [ -n "$_self" ] && [ -f "$_self/lib/common.sh" ]; then . "$_self/lib/common.sh"
else eval "$(wget -qO- --no-check-certificate "$ZU_BASE_URL/lib/common.sh" 2>/dev/null || uclient-fetch -qO- "$ZU_BASE_URL/lib/common.sh")"; fi

KEEP=0
[ "${1:-}" = "--keep-files" ] && KEEP=1

log "Removing uhttpd panel instance..."
uci -q delete uhttpd.openrouterich 2>/dev/null || true
uci commit uhttpd
manage_service uhttpd "" restart

if [ "$KEEP" = 0 ]; then
    for d in /opt/open-routerich /data/open-routerich /root/open-routerich; do
        [ -d "$d" ] && { rm -rf "$d"; log "removed $d"; }
    done
fi
log "Panel removed. (DPI config untouched; use uninstall.sh to revert that.)"
