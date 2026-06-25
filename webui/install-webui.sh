#!/bin/sh
# open-routerich :: webui/install-webui.sh
# Installs the on-router control panel and wires it into uhttpd WITHOUT touching
# the read-only squashfs root — everything lives in a writable dir and uhttpd is
# configured via UCI (persists on ubifs). Works on normal AND immutable/vendor
# routers (Xiaomi IPQ5424/IPQ9554 etc.).
#
# Usage:
#   sh webui/install-webui.sh [--port 8088] [--dest /opt/open-routerich]
#   sh -c "$(wget -qO- https://raw.githubusercontent.com/Sigmachan/open-routerich/main/webui/install-webui.sh)"
set -eu

ZU_BASE_URL="${ZU_BASE_URL:-https://raw.githubusercontent.com/Sigmachan/open-routerich/main}"
TARBALL="https://github.com/Sigmachan/open-routerich/archive/refs/heads/main.tar.gz"
_self="$(cd "$(dirname -- "$0" 2>/dev/null)/.." 2>/dev/null && pwd || true)"
if [ -n "$_self" ] && [ -f "$_self/lib/common.sh" ]; then
    . "$_self/lib/common.sh"
else
    eval "$(wget -qO- --no-check-certificate "$ZU_BASE_URL/lib/common.sh" 2>/dev/null \
            || uclient-fetch -qO- "$ZU_BASE_URL/lib/common.sh")" || { echo "cannot load common.sh" >&2; exit 1; }
fi

PORT=8088; DEST=""
while [ $# -gt 0 ]; do
    case "$1" in
        --port) PORT="$2"; shift ;;
        --dest) DEST="$2"; shift ;;
        *) warn "unknown option: $1" ;;
    esac; shift
done

# pick a writable home for the toolkit (never the immutable root)
if [ -z "$DEST" ]; then
    if [ -d /opt ] && ( : > /opt/.zu_wtest ) 2>/dev/null; then rm -f /opt/.zu_wtest; DEST=/opt/open-routerich
    elif [ -d /data ] && ( : > /data/.zu_wtest ) 2>/dev/null; then rm -f /data/.zu_wtest; DEST=/data/open-routerich
    else DEST=/root/open-routerich; fi
fi
log "Install dir: $DEST  (writable, not squashfs root)"
mkdir -p "$DEST"

# populate DEST: from local clone, else download repo tarball
if [ -n "$_self" ] && [ -f "$_self/install.sh" ]; then
    if [ "$_self" = "$DEST" ]; then
        log "Already in install dir, skipping copy."
    else
        log "Copying toolkit from local clone..."
        cp -rf "$_self/." "$DEST/"
    fi
else
    log "Downloading toolkit tarball..."
    fetch_to "$TARBALL" /tmp/open-routerich.tgz || die "tarball download failed"
    ( cd /tmp && tar xzf open-routerich.tgz )
    cp -rf /tmp/open-routerich-main/. "$DEST/"
    rm -rf /tmp/open-routerich.tgz /tmp/open-routerich-main
fi
chmod +x "$DEST"/install.sh "$DEST"/uninstall.sh "$DEST"/modules/*.sh \
         "$DEST"/webui/www/cgi-bin/open-routerich 2>/dev/null || true

DOCROOT="$DEST/webui/www"
[ -f "$DOCROOT/index.html" ] || die "panel files missing at $DOCROOT"

# wire uhttpd via UCI (new dedicated instance; does not disturb LuCI on :80)
log "Configuring uhttpd instance 'openrouterich' on port $PORT ..."
command -v uhttpd >/dev/null 2>&1 || ensure_pkg uhttpd 0
uci -q delete uhttpd.openrouterich 2>/dev/null || true
uci set uhttpd.openrouterich=uhttpd
uci -q delete uhttpd.openrouterich.listen_http 2>/dev/null || true
uci add_list uhttpd.openrouterich.listen_http="0.0.0.0:$PORT"
uci set uhttpd.openrouterich.home="$DOCROOT"
uci set uhttpd.openrouterich.cgi_prefix="/cgi-bin"
uci set uhttpd.openrouterich.script_timeout="600"
uci set uhttpd.openrouterich.max_requests="5"
uci set uhttpd.openrouterich.no_dirlists="1"
uci commit uhttpd
manage_service uhttpd "" restart

LANIP="$(uci -q get network.lan.ipaddr 2>/dev/null || echo 192.168.1.1)"
log "Panel installed."
log "Open:  http://$LANIP:$PORT/"
warn "The panel runs CGI as root and has NO auth — keep it LAN-only (default firewall blocks WAN)."
log "Remove: sh $DEST/webui/uninstall-webui.sh"
