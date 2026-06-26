#!/bin/sh
# open-routerich :: modules/zeroblock.sh
# Thin installer for routerich's ZeroBlock — a transparent VLESS/sing-box tproxy
# manager (FakeIP DNS + nftables tproxy). This is the polished implementation of
# the "own VLESS tunnel" layer that open-routerich's DNS-bypass stack leaves to
# you: a local-terminating tproxy survives hardware offload (ECM/NSS/SFE) where
# packet-desync (youtubeUnblock) does not, so this is the realistic full RKN-SNI
# bypass on accelerated vendor routers.
#
# ZeroBlock is a CLOSED, MIT-licensed compiled binary that routerich builds
# against a specific (opkg-based) OpenWrt ABI. There is no public opkg feed, so
# YOU supply the .ipk source (--ipk-url / --ipk-dir / ZB_IPK_URL). Community-list
# API v2 needs a *verified routerich device*; on other hardware ZeroBlock falls
# back transparently to API v1 + the public itdoginfo/allow-domains GitHub lists.
#
# Hard limits (honest):
#   - opkg firmware only. The .ipk is opkg-format with opkg lib deps; apk-based
#     OpenWrt (25.12 / SNAPSHOT) cannot install it.
#   - mutable root only. Needs `opkg install` into / and kmod-nft-tproxy. Immutable
#     vendor roots (Xiaomi IPQ stock) can't — use modules/proxy.sh (static sing-box)
#     or a hand-rolled sing-box TUN there instead.
#   - lib ABI is pinned to routerich's build target; closest match is recent
#     23.05/24.10. On far-off branches the binary may install (--force-depends) but
#     fail to load. Verify with `zeroblock dns_check_fakeip ya.ru`.
#
# Usage:
#   sh modules/zeroblock.sh --ipk-dir /path/with/zeroblock_*.ipk [seed flags]
#   sh modules/zeroblock.sh --ipk-url URL [--luci-url URL] [seed flags]
#
# Seed flags (optional — without them ZeroBlock installs with package defaults and
# you configure it in LuCI -> Services -> ZeroBlock):
#   --vless 'vless://...'      enabled proxy section routing --lists through it
#   --sub   'https://...'      subscription section instead of a single proxy
#   --lists 'youtube discord'  community lists for the seeded section (default: youtube)
#   --iface br-lan             source interface for the seeded section (default: auto LAN)
#   --dns-type doh|dot|udp|doq engine DNS type      (default: keep package default)
#   --dns-server 8.8.8.8       engine DNS server     (default: keep package default)
#   --no-singbox               do not auto-install a sing-box engine
#   --no-force                 do NOT pass opkg --force-depends (default: force on)
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

# --- args -------------------------------------------------------------------
IPK_URL=""; LUCI_URL=""; IPK_DIR=""
VLESS=""; SUB=""; LISTS="youtube"; IFACE=""
DNS_TYPE=""; DNS_SERVER=""
WANT_SINGBOX=1; FORCE=1
[ -n "${ZB_IPK_URL:-}" ]  && IPK_URL="$ZB_IPK_URL"
[ -n "${ZB_LUCI_URL:-}" ] && LUCI_URL="$ZB_LUCI_URL"
[ -n "${ZB_IPK_DIR:-}" ]  && IPK_DIR="$ZB_IPK_DIR"
while [ $# -gt 0 ]; do
    case "$1" in
        --ipk-url)    IPK_URL="$2"; shift 2 ;;
        --luci-url)   LUCI_URL="$2"; shift 2 ;;
        --ipk-dir)    IPK_DIR="$2"; shift 2 ;;
        --vless)      VLESS="$2"; shift 2 ;;
        --sub)        SUB="$2"; shift 2 ;;
        --lists)      LISTS="$2"; shift 2 ;;
        --iface)      IFACE="$2"; shift 2 ;;
        --dns-type)   DNS_TYPE="$2"; shift 2 ;;
        --dns-server) DNS_SERVER="$2"; shift 2 ;;
        --no-singbox) WANT_SINGBOX=0; shift ;;
        --no-force)   FORCE=0; shift ;;
        -h|--help)    sed -n '1,46p' "$0" 2>/dev/null | grep '^#' | cut -c3-; exit 0 ;;
        *) warn "unknown arg: $1"; shift ;;
    esac
done

ARCH="$(detect_pkgarch)"
MINOR="$(detect_minor)"
log "zeroblock module: arch ${ARCH:-?}, branch ${MINOR:-SNAPSHOT}, pm $ZU_PM"

# --- preflight: hard limits -------------------------------------------------
[ "$ZU_PM" = opkg ] || die "ZeroBlock ships as an opkg .ipk; this firmware uses '$ZU_PM'. Not installable here. Use modules/proxy.sh or a manual sing-box TUN."
if detect_immutable; then
    die "Immutable/vendor root detected — ZeroBlock needs 'opkg install' into / and kmod-nft-tproxy, which a read-only squashfs root can't provide. On Xiaomi IPQ stock use modules/proxy.sh (static sing-box) or a hand-rolled sing-box TUN."
fi

# --- resolve .ipk sources ---------------------------------------------------
# ZeroBlock has no public feed; you point this at routerich's .ipk files.
ZB_IPK=""; ZB_LUCI=""
_find_in_dir() { # _find_in_dir <dir> <glob>
    for f in "$1"/$2; do [ -f "$f" ] && { echo "$f"; return 0; }; done
    return 1
}
if [ -n "$IPK_DIR" ]; then
    ZB_IPK="$(_find_in_dir "$IPK_DIR" "zeroblock_*_${ARCH}.ipk" || _find_in_dir "$IPK_DIR" "zeroblock_*.ipk" || true)"
    ZB_LUCI="$(_find_in_dir "$IPK_DIR" "luci-app-zeroblock_*.ipk" || true)"
fi
if [ -z "$ZB_IPK" ] && [ -n "$IPK_URL" ]; then
    fetch_to "$IPK_URL" /tmp/zeroblock.ipk && ZB_IPK=/tmp/zeroblock.ipk || die "download failed: $IPK_URL"
fi
if [ -z "$ZB_LUCI" ] && [ -n "$LUCI_URL" ]; then
    fetch_to "$LUCI_URL" /tmp/luci-app-zeroblock.ipk && ZB_LUCI=/tmp/luci-app-zeroblock.ipk || warn "luci download failed: $LUCI_URL"
fi
[ -n "$ZB_IPK" ] || die "no ZeroBlock .ipk found. Point --ipk-dir at a folder holding zeroblock_*_${ARCH}.ipk (+ luci-app-zeroblock_*.ipk), or pass --ipk-url URL. routerich distributes ZeroBlock; there is no public feed."
log "ZeroBlock package: $ZB_IPK${ZB_LUCI:+ + $ZB_LUCI}"

# --- runtime deps (force-depends skips opkg's own dep pull, so do it here) ---
pm_update >/dev/null 2>&1 || warn "opkg update failed (continuing)"
ensure_pkg kmod-nft-tproxy 1            # tproxy is the whole point
ensure_pkg nftables-json   0 nftables
ensure_pkg conntrack-tools 0 conntrack
ensure_pkg libyaml         0
ensure_pkg ca-bundle       0
ensure_pkg curl            0

# --- sing-box engine (ZeroBlock execs /usr/bin/sing-box at runtime) ----------
ensure_singbox() {
    [ -x /usr/bin/sing-box ] && { log "sing-box present (/usr/bin/sing-box)"; return 0; }
    pm_installed sing-box && { log "sing-box already installed"; return 0; }
    if pm_install sing-box 2>/dev/null && { [ -x /usr/bin/sing-box ] || pm_installed sing-box; }; then
        log "sing-box installed from feed"; return 0
    fi
    warn "sing-box not in feed; trying SagerNet ipk for $ARCH ..."
    _tag="$(fetch_stdout 'https://api.github.com/repos/SagerNet/sing-box/releases?per_page=30' 2>/dev/null \
            | sed -n 's/.*"tag_name" *: *"\(v[0-9][^"]*\)".*/\1/p' | grep -vE 'alpha|beta|rc' | head -n1)"
    [ -n "$_tag" ] || { warn "cannot resolve sing-box release"; return 1; }
    _url="$(gh_asset_url SagerNet/sing-box "$_tag" "sing-box_${_tag#v}_openwrt_${ARCH}\.ipk$")"
    [ -n "$_url" ] || { warn "no SagerNet ipk for $ARCH; install sing-box manually"; return 1; }
    fetch_to "$_url" /tmp/sing-box.ipk && pm_install_file /tmp/sing-box.ipk && rm -f /tmp/sing-box.ipk \
        && { log "sing-box installed from SagerNet"; return 0; }
    warn "sing-box install failed; install it manually before starting ZeroBlock"; return 1
}
[ "$WANT_SINGBOX" = 1 ] && { ensure_singbox || warn "sing-box engine missing — ZeroBlock won't route until it exists"; }

# --- install ZeroBlock + LuCI app -------------------------------------------
zb_opkg_install() { # zb_opkg_install <ipk>
    if [ "$FORCE" = 1 ]; then opkg install --force-depends "$1"; else opkg install "$1"; fi
}
zb_opkg_install "$ZB_IPK" || die "zeroblock install failed (try without --no-force, or check ABI/branch). $MINOR vs routerich build target."
[ -n "$ZB_LUCI" ] && { zb_opkg_install "$ZB_LUCI" || warn "luci-app-zeroblock install failed (CLI still works)"; }
[ -x /usr/bin/zeroblock ] || die "zeroblock binary not present after install — ABI mismatch likely. Verify the .ipk matches your OpenWrt branch ($MINOR)."

# opkg runs /etc/uci-defaults on install; run it explicitly if config is absent.
if [ ! -f /etc/config/zeroblock ] && [ -x /etc/uci-defaults/99-zeroblock ]; then
    sh /etc/uci-defaults/99-zeroblock 2>/dev/null || true
fi
[ -f /etc/config/zeroblock ] || die "/etc/config/zeroblock missing after install."

# --- engine DNS override (optional) -----------------------------------------
if [ -n "$DNS_TYPE" ];   then uci set zeroblock.engine.dns_type="$DNS_TYPE";     fi
if [ -n "$DNS_SERVER" ]; then uci set zeroblock.engine.dns_server="$DNS_SERVER"; fi

# --- seed a routing section (optional) --------------------------------------
seed_section() {
    _sec="or_proxy"
    [ -z "$IFACE" ] && IFACE="$(uci -q get network.lan.device 2>/dev/null || uci -q get network.lan.ifname 2>/dev/null || echo br-lan)"
    # (re)create the section cleanly so re-runs are idempotent
    uci -q delete "zeroblock.$_sec" 2>/dev/null || true
    uci set "zeroblock.$_sec=section"
    uci set "zeroblock.$_sec.enabled=1"
    uci set "zeroblock.$_sec.connection_type=proxy"
    uci -q delete "zeroblock.$_sec.source_interface" 2>/dev/null || true
    uci add_list "zeroblock.$_sec.source_interface=$IFACE"
    if [ -n "$SUB" ]; then
        uci set "zeroblock.$_sec.proxy_config_type=subscription"
        uci set "zeroblock.$_sec.subscription_url=$SUB"
    else
        uci set "zeroblock.$_sec.proxy_config_type=url"
        uci set "zeroblock.$_sec.proxy_string=$VLESS"
    fi
    uci -q delete "zeroblock.$_sec.community_lists" 2>/dev/null || true
    for _l in $LISTS; do uci add_list "zeroblock.$_sec.community_lists=$_l"; done
    log "seeded section '$_sec' (${SUB:+subscription}${VLESS:+url}, iface=$IFACE, lists=$LISTS)"
}
if [ -n "$VLESS" ] || [ -n "$SUB" ]; then
    seed_section
else
    log "no --vless/--sub given — installed with defaults; add a proxy in LuCI -> Services -> ZeroBlock."
fi
uci commit zeroblock 2>/dev/null || true

# --- enable + start ---------------------------------------------------------
manage_service sing-box disable stop 2>/dev/null || true   # ZeroBlock owns sing-box lifecycle
manage_service zeroblock enable restart
/usr/bin/zeroblock reload >/dev/null 2>&1 || true

log "ZeroBlock installed and started."
log "Verify FakeIP+tproxy actually bypasses offload:"
log "    zeroblock dns_check_fakeip ya.ru      # should resolve into 198.18.0.0/15"
log "    zeroblock check_outbounds             # outbound connectivity (JSON)"
log "    zeroblock dpi_check                   # DPI-block status per URL"
log "Manage in LuCI -> Services -> ZeroBlock (or /etc/config/zeroblock). Remove: opkg remove luci-app-zeroblock zeroblock"
[ -z "$VLESS$SUB" ] && log "Reminder: a 'proxy' section needs a real VLESS/subscription to route anything."
