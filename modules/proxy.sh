#!/bin/sh
# open-routerich :: modules/proxy.sh
# Universal port of routerich's opera-proxy + sing-box chain (the free-WARP
# fallback in universal_config.sh): opera-proxy exposes a local HTTP proxy on
# 127.0.0.1:18080, sing-box tproxy(:1100) forwards to it, and podkop's "second"
# profile routes selected domains through 127.0.0.1:18080.
#
# sing-box  : official feed first (opkg install sing-box), else SagerNet ipk,
#             else static binary (immutable/Entware path).
# opera-proxy: NitroOxid ipk (prebuilt for aarch64 only) — skipped elsewhere.
#
# Usage: sh modules/proxy.sh
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

ARCH="$(detect_pkgarch)"
IMMUTABLE=0; detect_immutable && IMMUTABLE=1
log "proxy module: arch $ARCH, $( [ "$IMMUTABLE" = 1 ] && echo immutable || echo normal )"

# opkg-arch -> GOARCH (for static binaries on immutable routers)
goarch() {
    case "$1" in
        aarch64*)  echo arm64 ;;
        x86_64)    echo amd64 ;;
        i386_*|x86) echo 386 ;;
        arm_*|arm) echo arm ;;
        mips_*)    echo mips ;;
        mipsel_*)  echo mipsle ;;
        *)         echo "" ;;
    esac
}

# ---------------------------------------------------------------------------
# sing-box
# ---------------------------------------------------------------------------
singbox_latest_stable() {
    gh api repos/SagerNet/sing-box/releases --jq '.[].tag_name' 2>/dev/null \
        | grep -vE 'alpha|beta|rc' | head -n1 2>/dev/null \
    || fetch_stdout "https://api.github.com/repos/SagerNet/sing-box/releases?per_page=30" \
        | sed -n 's/.*"tag_name" *: *"\(v[0-9][^"]*\)".*/\1/p' | grep -vE 'alpha|beta|rc' | head -n1
}
install_singbox() {
    if [ "$IMMUTABLE" = 0 ] && pm_installed sing-box; then log "sing-box already installed"; return 0; fi
    if [ "$IMMUTABLE" = 0 ]; then
        pm_update >/dev/null 2>&1 || true
        if pm_install sing-box 2>/dev/null && pm_installed sing-box; then
            log "sing-box installed from feed"; return 0
        fi
        warn "sing-box not in feed; trying SagerNet ipk..."
        _tag="$(singbox_latest_stable)"; _ver="${_tag#v}"
        _url="$(gh_asset_url SagerNet/sing-box "$_tag" "sing-box_${_ver}_openwrt_${ARCH}\.ipk$")"
        if [ -n "$_url" ]; then
            fetch_to "$_url" /tmp/sing-box.ipk && pm_install_file /tmp/sing-box.ipk && { rm -f /tmp/sing-box.ipk; log "sing-box installed from SagerNet"; return 0; }
        fi
    fi
    # immutable / no ipk: static binary
    _ga="$(goarch "$ARCH")"; [ -n "$_ga" ] || { warn "no GOARCH mapping for $ARCH; install sing-box manually"; return 1; }
    _tag="$(singbox_latest_stable)"; _ver="${_tag#v}"
    _url="$(gh_asset_url SagerNet/sing-box "$_tag" "sing-box-${_ver}-linux-${_ga}\.tar\.gz$")"
    [ -n "$_url" ] || { warn "no sing-box static build for $_ga"; return 1; }
    _dest="/opt/sbin"; [ -d "$_dest" ] || _dest="/usr/bin"
    [ -w "$_dest" ] || _dest="/tmp"
    fetch_to "$_url" /tmp/sb.tgz || { warn "sing-box download failed"; return 1; }
    ( cd /tmp && tar xzf sb.tgz && find . -name sing-box -type f -exec cp {} "$_dest/sing-box" \; && chmod +x "$_dest/sing-box" )
    rm -f /tmp/sb.tgz
    log "sing-box static binary installed to $_dest (immutable). Persist /etc/sing-box on /data + @reboot if root /etc is ramfs."
}

# ---------------------------------------------------------------------------
# opera-proxy  (free HTTP proxy on 127.0.0.1:18080)
# ---------------------------------------------------------------------------
install_opera() {
    if [ "$IMMUTABLE" = 1 ]; then warn "opera-proxy: immutable root — install manually into Entware/USB; skipping"; return 0; fi
    pm_installed opera-proxy && { log "opera-proxy already installed"; return 0; }
    _ext="$(pm_ext)"
    _tag="$(gh api repos/NitroOxid/openwrt-opera-proxy-bin/releases --jq '.[0].tag_name' 2>/dev/null \
            || fetch_stdout https://api.github.com/repos/NitroOxid/openwrt-opera-proxy-bin/releases | sed -n 's/.*"tag_name" *: *"\([^"]*\)".*/\1/p' | head -n1)"
    [ -n "$_tag" ] || { warn "cannot resolve opera-proxy release"; return 0; }
    _url="$(gh_asset_url NitroOxid/openwrt-opera-proxy-bin "$_tag" "opera-proxy_[^_]*_${ARCH}\.${_ext}$")"
    if [ -z "$_url" ]; then
        warn "opera-proxy prebuilt exists only for aarch64_cortex-a53 (yours: $ARCH). Skipping — sing-box still set up."
        return 0
    fi
    service stop vpn >/dev/null 2>&1 || true
    rm -f /usr/bin/vpns /etc/init.d/vpn 2>/dev/null || true
    fetch_to "$_url" /tmp/opera-proxy.$_ext && pm_install_file /tmp/opera-proxy.$_ext && log "opera-proxy installed" || warn "opera-proxy install failed"
    rm -f /tmp/opera-proxy.$_ext
}

# ---------------------------------------------------------------------------
# sing-box config (1:1 with routerich: tproxy :1100 -> http 127.0.0.1:18080)
# ---------------------------------------------------------------------------
write_singbox_config() {
    mkdir -p /etc/sing-box 2>/dev/null || true
    cat > /etc/sing-box/config.json <<'EOF'
{
  "log": { "disabled": true, "level": "error" },
  "inbounds": [
    { "type": "tproxy", "listen": "::", "listen_port": 1100, "sniff": false }
  ],
  "outbounds": [
    { "type": "http", "server": "127.0.0.1", "server_port": 18080 }
  ],
  "route": { "auto_detect_interface": true }
}
EOF
    if [ -f /etc/config/sing-box ]; then
        uci set sing-box.main.enabled='1' 2>/dev/null || true
        uci set sing-box.main.user='root' 2>/dev/null || true
        uci commit sing-box 2>/dev/null || true
    fi
    log "sing-box config written (/etc/sing-box/config.json)"
}

ensure_pkg jq 0; ensure_pkg curl 0
install_singbox || warn "sing-box setup incomplete"
install_opera
write_singbox_config
manage_service opera-proxy enable start
manage_service sing-box   enable restart

log "proxy chain ready: domains -> podkop 'second' -> 127.0.0.1:18080 (opera-proxy) ; sing-box tproxy :1100."
log "Pair with: sh modules/podkop.sh --profile second"
