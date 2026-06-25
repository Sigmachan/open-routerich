#!/bin/sh
# openwrt-zapret-universal :: modules/awg-warp.sh
# Universal port of routerich awg_config.sh — AmneziaWG WARP tunnel for ANY
# OpenWrt router. kmod/tools/luci are pulled from Slava-Shchipunov/awg-openwrt
# (release tag == OpenWrt version), arch/target/subtarget detected at runtime.
# WARP creds are auto-generated (several public generators tried) or entered by
# hand. Firewall zones resolved dynamically. No Routerich model guard.
#
# Usage: sh modules/awg-warp.sh [--manual] [--iface awg10] [--lan-zone lan]
set -eu

ZU_BASE_URL="${ZU_BASE_URL:-https://raw.githubusercontent.com/Sigmachan/openwrt-zapret-universal/main}"
_self="$(cd "$(dirname -- "$0" 2>/dev/null)/.." 2>/dev/null && pwd || true)"
if [ -n "$_self" ] && [ -f "$_self/lib/common.sh" ]; then
    . "$_self/lib/common.sh"
elif [ -n "$ZU_BASE_URL" ]; then
    eval "$(wget -qO- --no-check-certificate "$ZU_BASE_URL/lib/common.sh" 2>/dev/null \
            || uclient-fetch -qO- "$ZU_BASE_URL/lib/common.sh")"
else
    echo "lib/common.sh not found. Run from a clone, or set ZU_BASE_URL." >&2; exit 1
fi

MANUAL=0; IFACE="awg10"; LAN_ZONE="lan"
while [ $# -gt 0 ]; do
    case "$1" in
        --manual)   MANUAL=1 ;;
        --iface)    IFACE="$2"; shift ;;
        --lan-zone) LAN_ZONE="$2"; shift ;;
        *) warn "unknown option: $1" ;;
    esac; shift
done
CFG="amneziawg_$IFACE"; ZONE="awg"; PROTO="amneziawg"

ARCH="$(detect_pkgarch)"; VER="$(detect_version)"
TARGET="$(detect_target)"; SUB="$(detect_subtarget)"
log "AWG install: OpenWrt $VER  arch $ARCH  target ${TARGET}/${SUB}"

# ---------------------------------------------------------------------------
# install amneziawg (kmod must match the EXACT running kernel/version)
# ---------------------------------------------------------------------------
awg_pick_tag() {
    # exact version first, then newest tag of the same major.minor
    _exact="v$VER"
    if gh_asset_url Slava-Shchipunov/awg-openwrt "$_exact" \
        "kmod-amneziawg_${_exact}_${ARCH}_${TARGET}_${SUB}\.(ipk|apk)$" >/dev/null 2>&1; then
        echo "$_exact"; return
    fi
    _minor="$(detect_minor)"
    fetch_stdout "https://api.github.com/repos/Slava-Shchipunov/awg-openwrt/releases?per_page=100" 2>/dev/null \
        | sed -n 's/.*"tag_name" *: *"\(v[0-9][^"]*\)".*/\1/p' \
        | grep -E "^v${_minor}\." | head -n1
}
awg_install_one() { # awg_install_one <pkgbase> <tag>
    _base="$1"; _tag="$2"
    pm_installed "$_base" && { log "$_base already installed"; return 0; }
    _ext="$(pm_ext)"
    _re="${_base}_${_tag}_${ARCH}_${TARGET}_${SUB}\.${_ext}$"
    _url="$(gh_asset_url Slava-Shchipunov/awg-openwrt "$_tag" "$_re")"
    [ -n "$_url" ] || die "No $_base build for ${ARCH}_${TARGET}_${SUB} in $_tag. Build via build/build-packages.sh (target $TARGET/$SUB)."
    fetch_to "$_url" "/tmp/$_base.$_ext" || die "download failed: $_url"
    pm_install_file "/tmp/$_base.$_ext" || die "install failed: $_base"
    rm -f "/tmp/$_base.$_ext"
    log "$_base installed from awg-openwrt $_tag"
}
install_amneziawg() {
    if pm_installed kmod-amneziawg && pm_installed amneziawg-tools; then
        log "amneziawg already installed"; return 0
    fi
    _tag="$(awg_pick_tag)"
    [ -n "$_tag" ] || die "awg-openwrt has no release matching OpenWrt $VER. Recompile via build/build-packages.sh."
    log "Using awg-openwrt release: $_tag"
    awg_install_one kmod-amneziawg   "$_tag"
    awg_install_one amneziawg-tools  "$_tag"
    awg_install_one luci-app-amneziawg "$_tag" 2>/dev/null || warn "luci-app-amneziawg not installed (optional)"
}

# ---------------------------------------------------------------------------
# WARP config generators (public; same set routerich used)
# ---------------------------------------------------------------------------
gen_warp() {
    # try generators in order, echo a wg-style [Interface]/[Peer] config or "Error"
    for g in 1 2 3 4; do
        case $g in
        1) r=$(curl -s --connect-timeout 20 --max-time 60 'https://warp.llimonix.pw/api/warp' \
               -H 'Content-Type: application/json' \
               --data-raw '{"selectedServices":[],"siteMode":"all","deviceType":"computer"}' 2>/dev/null)
           c=$(echo "$r" | jq -r '.content.configBase64 // empty' 2>/dev/null)
           [ -n "$c" ] && { echo "$c" | base64 -d 2>/dev/null && return 0; } ;;
        2) r=$(curl -s --connect-timeout 20 --max-time 60 'https://topor-warp.vercel.app/generate' \
               -H 'Content-Type: application/json' --data-raw '{"platform":"all"}' 2>/dev/null)
           [ -n "$r" ] && echo "$r" | grep -q 'PrivateKey' && { echo "$r"; return 0; } ;;
        3) r=$(curl -s --connect-timeout 20 --max-time 60 'https://warp-gen.vercel.app/generate-config' 2>/dev/null)
           c=$(echo "$r" | jq -r '.config // empty' 2>/dev/null)
           [ -n "$c" ] && { echo "$c"; return 0; } ;;
        4) r=$(curl -s --connect-timeout 20 --max-time 60 'https://config-generator-warp.vercel.app/warp' 2>/dev/null)
           c=$(echo "$r" | jq -r '.content // empty' 2>/dev/null)
           [ -n "$c" ] && { echo "$c" | base64 -d 2>/dev/null && return 0; } ;;
        esac
        warn "WARP generator #$g failed, trying next..."
    done
    echo "Error"; return 1
}

parse_warp() { # parse_warp <config-text> ; sets globals
    PrivateKey=""; Address=""; DNS=""; PublicKey=""; Endpoint=""
    S1=0; S2=0; Jc=4; Jmin=40; Jmax=70; H1=1; H2=2; H3=3; H4=4; MTU=1280
    while IFS= read -r line; do
        case "$line" in
            *=*) k=$(echo "${line%%=*}" | tr -d ' '); v=$(echo "${line#*=}" | sed 's/^ *//;s/ *$//')
                 case "$k" in
                    PrivateKey) PrivateKey="$v" ;;  Address) Address="$v" ;;
                    DNS) DNS="$v" ;;  PublicKey) PublicKey="$v" ;;
                    Endpoint) Endpoint="$v" ;;       MTU) MTU="$v" ;;
                    S1) S1="$v";; S2) S2="$v";; Jc) Jc="$v";; Jmin) Jmin="$v";; Jmax) Jmax="$v";;
                    H1) H1="$v";; H2) H2="$v";; H3) H3="$v";; H4) H4="$v";;
                 esac ;;
        esac
    done <<EOF
$1
EOF
    Address="$(echo "$Address" | cut -d, -f1)"
    DNS="$(echo "$DNS" | cut -d, -f1)"
    EndpointIP="$(echo "$Endpoint" | cut -d: -f1)"
    EndpointPort="$(echo "$Endpoint" | cut -d: -f2)"
    [ -n "$EndpointPort" ] || EndpointPort=51820
}

manual_warp() {
    printf "Private key (Interface): "; read -r PrivateKey
    printf "Address (e.g. 172.16.0.2/32): "; read -r Address
    printf "Public key (Peer): "; read -r PublicKey
    printf "Endpoint host: "; read -r EndpointIP
    printf "Endpoint port [51820]: "; read -r EndpointPort; [ -n "$EndpointPort" ] || EndpointPort=51820
    printf "Jc [4]: "; read -r Jc; [ -n "$Jc" ] || Jc=4
    printf "Jmin [40]: "; read -r Jmin; [ -n "$Jmin" ] || Jmin=40
    printf "Jmax [70]: "; read -r Jmax; [ -n "$Jmax" ] || Jmax=70
    printf "S1 [0]: "; read -r S1; [ -n "$S1" ] || S1=0
    printf "S2 [0]: "; read -r S2; [ -n "$S2" ] || S2=0
    printf "H1 [1]: "; read -r H1; [ -n "$H1" ] || H1=1
    printf "H2 [2]: "; read -r H2; [ -n "$H2" ] || H2=2
    printf "H3 [3]: "; read -r H3; [ -n "$H3" ] || H3=3
    printf "H4 [4]: "; read -r H4; [ -n "$H4" ] || H4=4
    MTU=1280
}

configure_tunnel() {
    log "Configuring AmneziaWG interface network.$IFACE ..."
    uci set "network.$IFACE=interface"
    uci set "network.$IFACE.proto=$PROTO"
    uci show network 2>/dev/null | grep -q "=$CFG$" || uci add network "$CFG" >/dev/null
    uci set "network.$IFACE.private_key=$PrivateKey"
    uci -q del "network.$IFACE.addresses" || true
    uci add_list "network.$IFACE.addresses=$Address"
    uci set "network.$IFACE.mtu=$MTU"
    uci set "network.$IFACE.awg_jc=$Jc"
    uci set "network.$IFACE.awg_jmin=$Jmin"
    uci set "network.$IFACE.awg_jmax=$Jmax"
    uci set "network.$IFACE.awg_s1=$S1"
    uci set "network.$IFACE.awg_s2=$S2"
    uci set "network.$IFACE.awg_h1=$H1"
    uci set "network.$IFACE.awg_h2=$H2"
    uci set "network.$IFACE.awg_h3=$H3"
    uci set "network.$IFACE.awg_h4=$H4"
    uci set "network.$IFACE.nohostroute=1"
    uci set "network.@${CFG}[-1].description=${IFACE}_peer"
    uci set "network.@${CFG}[-1].public_key=$PublicKey"
    uci set "network.@${CFG}[-1].endpoint_host=$EndpointIP"
    uci set "network.@${CFG}[-1].endpoint_port=$EndpointPort"
    uci set "network.@${CFG}[-1].persistent_keepalive=25"
    uci set "network.@${CFG}[-1].allowed_ips=0.0.0.0/0"
    uci set "network.@${CFG}[-1].route_allowed_ips=0"
    uci commit network

    if ! uci show firewall | grep -q "@zone.*name='$ZONE'"; then
        uci add firewall zone >/dev/null
        uci set "firewall.@zone[-1].name=$ZONE"
        uci set "firewall.@zone[-1].network=$IFACE"
        uci set "firewall.@zone[-1].forward=REJECT"
        uci set "firewall.@zone[-1].output=ACCEPT"
        uci set "firewall.@zone[-1].input=REJECT"
        uci set "firewall.@zone[-1].masq=1"
        uci set "firewall.@zone[-1].mtu_fix=1"
        uci set "firewall.@zone[-1].family=ipv4"
        uci commit firewall
    fi
    if ! uci show firewall | grep -q "@forwarding.*dest='$ZONE'"; then
        uci add firewall forwarding >/dev/null
        uci set "firewall.@forwarding[-1].dest=$ZONE"
        uci set "firewall.@forwarding[-1].src=$(fw_zone_for "$LAN_ZONE")"
        uci set "firewall.@forwarding[-1].family=ipv4"
        uci commit firewall
    fi
    service firewall restart
    ifdown "$IFACE" 2>/dev/null || true
    ifup "$IFACE" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
pm_update || warn "package list update failed"
ensure_pkg jq 1; ensure_pkg curl 1; ensure_pkg coreutils-base64 0
install_amneziawg

if [ "$MANUAL" = 1 ]; then
    manual_warp
else
    log "Generating WARP config..."
    cfg="$(gen_warp)" || true
    [ "$cfg" = "Error" ] || [ -z "$cfg" ] && die "All WARP generators failed. Re-run with --manual."
    parse_warp "$cfg"
fi
[ -n "${PrivateKey:-}" ] && [ -n "${PublicKey:-}" ] && [ -n "${EndpointIP:-}" ] \
    || die "Incomplete WARP parameters."
configure_tunnel

log "Waiting 10s for tunnel..."
sleep 10
if ping -c1 -I "$IFACE" 8.8.8.8 >/dev/null 2>&1; then
    log "AmneziaWG WARP is UP on $IFACE."
else
    warn "Tunnel up but ping via $IFACE failed — check creds/endpoint."
fi
