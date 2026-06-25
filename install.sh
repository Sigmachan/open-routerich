#!/bin/sh
# open-routerich :: install.sh
# Universal port of routerich `configure_zaprets.sh` / `universal_config.sh`.
# DPI bypass for ANY OpenWrt router: youtubeUnblock (DPI desync) + https-dns-proxy
# (DoH) + dnsmasq geo-unblock redirect + optional QUIC block.
#
# Works on:
#   * mainline OpenWrt 18.06 .. 25.12 / SNAPSHOT  (opkg & apk)
#   * vendor forks with read-only squashfs root (Xiaomi IPQ5424/IPQ9554 etc.):
#     auto "immutable" mode -> UCI-only (DoH redirect + QUIC), no opkg-into-/;
#     youtubeUnblock via Entware on USB when present.
#
# De-routerich-ified: no /tmp/sysinfo/model guard; arch/version/UCI section all
# detected at runtime.
#
# Usage:
#   sh install.sh [options]
#   sh -c "$(wget -qO- https://raw.githubusercontent.com/Sigmachan/open-routerich/main/install.sh)"
#
# Options:
#   --no-quic           do not add QUIC (UDP/80,443) reject rules
#   --no-redirect       do not push the geo-unblock dnsmasq redirect list
#   --no-overrides      do not add static A-record DNS overrides
#   --doh-addr A#PORT   local DoH resolver for redirects (default: https-dns-proxy
#                       127.0.0.1#5056, or 127.0.0.1#5353 in immutable mode = AdGuard Home)
#   --immutable         force immutable/vendor mode (UCI-only, no opkg-into-/)
#   --no-immutable      force normal mode even if root looks read-only
#   --entware           force Entware path for native packages (/opt on USB)
#   --no-entware        never use Entware
#   --profile NAME      preset: xiaomi-vendor | generic
#   --cron              install a daily self-update cron
#   --lan-zone NAME     firewall LAN zone name (default: lan)
#   --wan-zone NAME     firewall WAN zone name (default: wan)
#   -y, --yes           non-interactive
#   -h, --help          this help
set -eu

# ----------------------------------------------------------------------------
# bootstrap shared library (local clone first, remote when piped)
# ----------------------------------------------------------------------------
ZU_BASE_URL="${ZU_BASE_URL:-https://raw.githubusercontent.com/Sigmachan/open-routerich/main}"
_self="$(cd "$(dirname -- "$0" 2>/dev/null)" 2>/dev/null && pwd || true)"
if [ -n "$_self" ] && [ -f "$_self/lib/common.sh" ]; then
    . "$_self/lib/common.sh"
elif [ -n "$ZU_BASE_URL" ]; then
    eval "$(wget -qO- --no-check-certificate "$ZU_BASE_URL/lib/common.sh" 2>/dev/null \
            || uclient-fetch -qO- "$ZU_BASE_URL/lib/common.sh")" \
        || { echo "failed to load lib/common.sh from $ZU_BASE_URL" >&2; exit 1; }
else
    echo "lib/common.sh not found. Run from a clone, or set ZU_BASE_URL." >&2
    exit 1
fi

# ----------------------------------------------------------------------------
# options
# ----------------------------------------------------------------------------
DO_QUIC=1; DO_REDIRECT=1; DO_OVERRIDES=1; DO_CRON=0; ASSUME_YES=0
LAN_ZONE="lan"; WAN_ZONE="wan"
DOH_ADDR=""; FORCE_IMMUTABLE=""; FORCE_ENTWARE=""; PROFILE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --no-quic)      DO_QUIC=0 ;;
        --no-redirect)  DO_REDIRECT=0 ;;
        --no-overrides) DO_OVERRIDES=0 ;;
        --doh-addr)     DOH_ADDR="$2"; shift ;;
        --immutable)    FORCE_IMMUTABLE=1 ;;
        --no-immutable) FORCE_IMMUTABLE=0 ;;
        --entware)      FORCE_ENTWARE=1 ;;
        --no-entware)   FORCE_ENTWARE=0 ;;
        --profile)      PROFILE="$2"; shift ;;
        --cron)         DO_CRON=1 ;;
        --lan-zone)     LAN_ZONE="$2"; shift ;;
        --wan-zone)     WAN_ZONE="$2"; shift ;;
        -y|--yes)       ASSUME_YES=1 ;;
        -h|--help)      sed -n '2,40p' "$0" 2>/dev/null; exit 0 ;;
        *)              warn "unknown option: $1" ;;
    esac
    shift
done

# profile presets
case "$PROFILE" in
    xiaomi-vendor) FORCE_IMMUTABLE=1; [ -z "$DOH_ADDR" ] && DOH_ADDR="127.0.0.1#5353" ;;
    generic|"")    : ;;
    *) warn "unknown profile: $PROFILE" ;;
esac

# ----------------------------------------------------------------------------
# detection
# ----------------------------------------------------------------------------
ARCH="$(detect_pkgarch)"; VER="$(detect_version)"; MINOR="$(detect_minor)"
if [ -n "$FORCE_IMMUTABLE" ]; then IMMUTABLE="$FORCE_IMMUTABLE"
elif detect_immutable; then IMMUTABLE=1; else IMMUTABLE=0; fi
if [ "$FORCE_ENTWARE" = 0 ]; then ENTWARE=0
elif [ "$FORCE_ENTWARE" = 1 ]; then ENTWARE=1
elif detect_entware; then ENTWARE=1; else ENTWARE=0; fi

log "Router: $(detect_model)  |  OpenWrt $VER  |  arch $ARCH  |  pm $ZU_PM"
log "Mode: $( [ "$IMMUTABLE" = 1 ] && echo 'immutable/vendor (UCI-only)' || echo 'normal' )$( [ "$ENTWARE" = 1 ] && echo ' + Entware' )"
[ -n "$ARCH" ] || [ "$IMMUTABLE" = 1 ] || die "Could not detect package architecture (is this OpenWrt?)."
if [ -n "$MINOR" ] && ! branch_ge "$MINOR" "$ZU_MIN_BRANCH"; then
    die "OpenWrt $VER is older than the supported floor ($ZU_MIN_BRANCH)."
fi

# DoH resolver target for dnsmasq redirects
if [ -n "$DOH_ADDR" ]; then
    DOH_SERVERS="$DOH_ADDR"; DOH_REDIRECT="$DOH_ADDR"
elif [ "$IMMUTABLE" = 1 ]; then
    DOH_ADDR="127.0.0.1#5353"; DOH_SERVERS="$DOH_ADDR"; DOH_REDIRECT="$DOH_ADDR"   # AdGuard Home default
else
    DOH_SERVERS="127.0.0.1#5053 127.0.0.1#5054 127.0.0.1#5055 127.0.0.1#5056"
    DOH_REDIRECT="127.0.0.1#5056"
fi

BACKUP_DIR="/root/zapret-universal-backup"
mkdir -p "$BACKUP_DIR" 2>/dev/null || BACKUP_DIR="/tmp/zapret-universal-backup"
mkdir -p "$BACKUP_DIR"

backup_once() { # backup_once <etc-config-name>
    [ -f "/etc/config/$1" ] && [ ! -f "$BACKUP_DIR/$1" ] \
        && cp -f "/etc/config/$1" "$BACKUP_DIR/$1" || true
}
push_config() { # push_config <name> [dest-config-dir]
    _n="$1"; _dir="${2:-/etc/config}"; [ "$_dir" = /etc/config ] && backup_once "$_n"
    [ -d "$_dir" ] || return 1
    if [ -n "$_self" ] && [ -f "$_self/config_files/$_n" ]; then
        cp -f "$_self/config_files/$_n" "$_dir/$_n"
    elif [ -n "$ZU_BASE_URL" ]; then
        fetch_to "$ZU_BASE_URL/config_files/$_n" "$_dir/$_n" || die "cannot fetch config_files/$_n"
    else
        return 1
    fi
}
read_list() { # read_list <name>
    _n="$1"
    if [ -n "$_self" ] && [ -f "$_self/config_files/$_n" ]; then cat "$_self/config_files/$_n"
    elif [ -n "$ZU_BASE_URL" ]; then fetch_stdout "$ZU_BASE_URL/config_files/$_n"; fi
}

# ============================================================================
log "[1/7] Updating package lists..."
if [ "$IMMUTABLE" = 1 ]; then
    [ "$ENTWARE" = 1 ] && { "$ENTWARE_OPKG" update >/dev/null 2>&1 || warn "entware opkg update failed"; }
    log "immutable root: skipping system opkg (read-only /)"
else
    pm_update || warn "package list update failed (continuing with cache)"
    ensure_pkg jq 0; ensure_pkg curl 0; ensure_pkg ca-bundle 0
fi

# ============================================================================
log "[2/7] dnsmasq-full ..."
if [ "$IMMUTABLE" = 1 ]; then
    log "immutable: keeping vendor dnsmasq (cannot swap to dnsmasq-full)"
elif pm_installed dnsmasq-full; then
    log "dnsmasq-full already installed"
elif [ "$ZU_PM" = opkg ]; then
    ( cd /tmp && opkg download dnsmasq-full 2>/dev/null \
        && { opkg remove dnsmasq 2>/dev/null; opkg install --cache /tmp ./dnsmasq-full*.ipk 2>/dev/null \
             || opkg install dnsmasq-full --cache /tmp 2>/dev/null; } \
        && { [ -f /etc/config/dhcp-opkg ] && cp /etc/config/dhcp /etc/config/dhcp-old \
             && mv /etc/config/dhcp-opkg /etc/config/dhcp; true; } ) \
        || warn "dnsmasq-full swap failed; plain dnsmasq may lack filter_aaaa"
else
    apk del dnsmasq 2>/dev/null; pm_install dnsmasq-full 2>/dev/null \
        || warn "dnsmasq-full install failed on apk"
fi

DNSSEC="$(dnsmasq_section)"
log "dnsmasq UCI section: dhcp.$DNSSEC ; DoH resolver: $DOH_REDIRECT"
uci set "dhcp.$DNSSEC.confdir=/tmp/dnsmasq.d" 2>/dev/null || true
uci commit dhcp 2>/dev/null || true

# ============================================================================
log "[3/7] DoH (https-dns-proxy) ..."
if [ "$IMMUTABLE" = 1 ]; then
    warn "immutable: not installing https-dns-proxy. Redirects point at $DOH_ADDR"
    warn "  -> make sure a DoH resolver listens there (AdGuard Home / Entware https-dns-proxy)."
else
    ensure_pkg https-dns-proxy 0 luci-app-doh-proxy
    ensure_pkg luci-app-https-dns-proxy 0
    ensure_pkg luci-i18n-https-dns-proxy-ru 0
    push_config https-dns-proxy && log "https-dns-proxy config applied" \
        || warn "no https-dns-proxy template available; keeping existing config"
fi

# ============================================================================
log "[4/7] youtubeUnblock (DPI desync) ..."
YU_OK=0
install_yu_system() {
    pm_installed youtubeUnblock && { log "youtubeUnblock already installed"; YU_OK=1; return 0; }
    for dep in kmod-nfnetlink-queue kmod-nft-queue kmod-nf-conntrack; do ensure_pkg "$dep" 0; done
    set -- $(yu_target); _tag="$1"; _owrt="$2"; _ext="$3"
    if [ "$_tag" = NONE ]; then
        warn "No youtubeUnblock prebuilt for OpenWrt $_owrt — trying feed..."
        if ensure_pkg youtubeUnblock 0 && pm_installed youtubeUnblock; then YU_OK=1; return 0; fi
        warn "youtubeUnblock has no build for this branch. Compile on a PC:"
        warn "  build/build-packages.sh -v $VER -t <target> -s <subtarget> --only yu"
        warn "Continuing WITHOUT youtubeUnblock (DoH + redirect + QUIC still apply)."
        return 0
    fi
    log "youtubeUnblock release: $_tag (openwrt-$_owrt, .$_ext, arch $ARCH)"
    _url="$(gh_asset_url Waujito/youtubeUnblock "$_tag" "youtubeUnblock-[0-9].*-${ARCH}-openwrt-${_owrt}\.${_ext}$")"
    if [ -z "$_url" ]; then
        warn "No youtubeUnblock asset for arch=$ARCH openwrt=$_owrt in $_tag."
        warn "Compile: build/build-packages.sh -v $VER -t <target> -s <subtarget> --only yu"
        return 0
    fi
    fetch_to "$_url" "/tmp/youtubeUnblock.$_ext" || { warn "download failed: $_url"; return 0; }
    pm_install_file "/tmp/youtubeUnblock.$_ext" || { warn "youtubeUnblock install failed"; rm -f "/tmp/youtubeUnblock.$_ext"; return 0; }
    rm -f "/tmp/youtubeUnblock.$_ext"; YU_OK=1
    _lurl="$(gh_asset_url Waujito/youtubeUnblock "$_tag" "luci-app-youtubeUnblock-[0-9].*\.${_ext}$")"
    [ -n "$_lurl" ] && { fetch_to "$_lurl" "/tmp/luci-yu.$_ext" && pm_install_file "/tmp/luci-yu.$_ext" 2>/dev/null || true; rm -f "/tmp/luci-yu.$_ext"; }
}
install_yu_entware() {
    detect_entware || { warn "Entware not found (/opt/bin/opkg). Set it up first: modules/entware-install.sh"; return 0; }
    entware_installed youtubeUnblock && { log "youtubeUnblock (Entware) already installed"; YU_OK=1; return 0; }
    "$ENTWARE_OPKG" update >/dev/null 2>&1 || true
    _t="$(yu_entware_target)" || { warn "cannot resolve Entware arch"; return 0; }
    set -- $_t; _tag="$1"; _ea="$2"
    log "youtubeUnblock (Entware) release: $_tag arch $_ea"
    _url="$(gh_asset_url Waujito/youtubeUnblock "$_tag" "youtubeUnblock-[0-9].*-entware-${_ea}\.ipk$")"
    [ -n "$_url" ] || { warn "no Entware youtubeUnblock for $_ea"; return 0; }
    fetch_to "$_url" "/tmp/yu-entware.ipk" || { warn "download failed"; return 0; }
    entware_install "/tmp/yu-entware.ipk" || { warn "entware install failed"; rm -f /tmp/yu-entware.ipk; return 0; }
    rm -f /tmp/yu-entware.ipk; YU_OK=1
    [ -d /opt/etc/config ] && push_config youtubeUnblock /opt/etc/config && log "youtubeUnblock config -> /opt/etc/config"
    log "youtubeUnblock installed into Entware ($_ea). Service: /opt/etc/init.d/S*youtubeUnblock*"
    for s in /opt/etc/init.d/S*youtubeUnblock*; do [ -x "$s" ] && "$s" restart 2>/dev/null || true; done
}
if [ "$IMMUTABLE" = 1 ]; then
    if [ "$ENTWARE" = 1 ]; then install_yu_entware
    else warn "immutable + no Entware: skipping youtubeUnblock (DNS/QUIC only). See README (Entware on USB)."; fi
else
    install_yu_system
    [ "$YU_OK" = 1 ] && { push_config youtubeUnblock && log "youtubeUnblock config applied" || warn "no youtubeUnblock template"; }
fi

# ============================================================================
log "[5/7] dnsmasq redirects on dhcp.$DNSSEC ..."
uci set "dhcp.$DNSSEC.strictorder=1"
if pm_installed dnsmasq-full || [ "$IMMUTABLE" = 1 ]; then
    uci set "dhcp.$DNSSEC.filter_aaaa=1" 2>/dev/null || true
else
    warn "filter_aaaa skipped (needs dnsmasq-full)"
fi
for s in $DOH_SERVERS; do uci_add_list_once dhcp "dhcp.$DNSSEC.server" "$s"; done
if [ "$DO_REDIRECT" = 1 ]; then
    read_list redirect-domains.txt | while IFS= read -r d; do
        [ -n "$d" ] || continue; case "$d" in \#*) continue ;; esac
        uci_add_list_once dhcp "dhcp.$DNSSEC.server" "/$d/$DOH_REDIRECT"
    done
    log "geo-unblock redirect list applied ($(read_list redirect-domains.txt | grep -c .) domains -> $DOH_REDIRECT)"
fi
uci commit dhcp

if [ "$DO_OVERRIDES" = 1 ]; then
    log "Adding static DNS A-record overrides..."
    read_list dns-overrides.txt | while IFS=' ' read -r name ip; do
        [ -n "$name" ] && [ -n "$ip" ] || continue; case "$name" in \#*) continue ;; esac
        grep -q "option name '$name'" /etc/config/dhcp 2>/dev/null && continue
        uci add dhcp domain >/dev/null
        uci set "dhcp.@domain[-1].name=$name"; uci set "dhcp.@domain[-1].ip=$ip"
    done
    uci commit dhcp
fi

# ============================================================================
if [ "$DO_QUIC" = 1 ]; then
    log "[6/7] QUIC block (REJECT UDP 80/443 ${LAN_ZONE}->${WAN_ZONE})..."
    _lz="$(fw_zone_for "$LAN_ZONE")"; _wz="$(fw_zone_for "$WAN_ZONE")"
    if ! grep -q "option name 'Block_UDP_443'" /etc/config/firewall 2>/dev/null; then
        backup_once firewall
        for pp in 80 443; do
            uci add firewall rule >/dev/null
            uci set "firewall.@rule[-1].name=Block_UDP_$pp"
            uci add_list "firewall.@rule[-1].proto=udp"
            uci set "firewall.@rule[-1].src=$_lz"
            uci set "firewall.@rule[-1].dest=$_wz"
            uci set "firewall.@rule[-1].dest_port=$pp"
            uci set "firewall.@rule[-1].target=REJECT"
        done
        uci commit firewall; log "QUIC block rules added"
    else
        log "QUIC block already present"
    fi
else
    log "[6/7] QUIC block skipped (--no-quic)"
fi

# ============================================================================
log "[7/7] Enabling services & restarting..."
# routerich parity: disable routing tools that conflict with the DPI-only path
manage_service podkop disable stop
manage_service ruantiblock disable stop
[ "$IMMUTABLE" = 1 ] || manage_service https-dns-proxy enable start
[ "$YU_OK" = 1 ] && [ "$IMMUTABLE" = 0 ] && manage_service youtubeUnblock enable restart
manage_service dnsmasq "" restart
manage_service odhcpd  "" restart
[ "$DO_QUIC" = 1 ] && manage_service firewall "" restart

if [ "$DO_CRON" = 1 ] && [ -n "$ZU_BASE_URL" ]; then
    _line="0 4 * * * ZU_BASE_URL=$ZU_BASE_URL sh -c \"\$(wget -qO- $ZU_BASE_URL/install.sh)\" -- -y"
    grep -qF "$ZU_BASE_URL/install.sh" /etc/crontabs/root 2>/dev/null \
        || { echo "$_line" >> /etc/crontabs/root; manage_service cron enable restart; log "daily self-update cron installed"; }
fi

log "Done. DPI bypass configured for $(detect_model) (OpenWrt $VER, ${ARCH:-vendor})."
[ "$IMMUTABLE" = 1 ] && log "Immutable mode: DNS redirect ($DOH_REDIRECT) + QUIC block active. youtubeUnblock via Entware${ENTWARE:+ (done)}."
log "Rollback: sh uninstall.sh"
