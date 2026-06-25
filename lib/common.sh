# shellcheck shell=ash
# openwrt-zapret-universal :: lib/common.sh
# Shared POSIX-sh helpers for a *universal* (any-router) port of the routerich
# RouterichAX3000_configs toolkit. No model guard, no hardcoded arch / version /
# UCI section ids. Source this from a runtime script:
#
#   . /path/to/lib/common.sh        # from a git clone
#   eval "$(wget -qO- "$ZU_BASE_URL/lib/common.sh")"   # when piped
#
# Every value the original project hardcoded for the Routerich AX3000 is derived
# here at runtime instead.

# ---------------------------------------------------------------------------
# logging
# ---------------------------------------------------------------------------
ZU_GREEN='\033[32;1m'; ZU_RED='\033[31;1m'; ZU_YEL='\033[33;1m'; ZU_NC='\033[0m'
log()  { printf "${ZU_GREEN}%s${ZU_NC}\n" "$*"; }
warn() { printf "${ZU_YEL}[warn]${ZU_NC} %s\n" "$*" >&2; }
err()  { printf "${ZU_RED}[err]${ZU_NC} %s\n" "$*" >&2; }
die()  { err "$*"; exit 1; }

# ---------------------------------------------------------------------------
# http: pick whatever fetcher the firmware ships (curl / wget / uclient-fetch)
# ---------------------------------------------------------------------------
# fetch_to <url> <dest>
fetch_to() {
    _u="$1"; _o="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 20 --max-time 600 -o "$_o" "$_u"
    elif command -v wget >/dev/null 2>&1 && wget --help 2>&1 | grep -q -- '--no-check-certificate'; then
        wget -q --no-check-certificate -O "$_o" "$_u"
    elif command -v uclient-fetch >/dev/null 2>&1; then
        uclient-fetch -q --no-check-certificate -O "$_o" "$_u"
    else
        wget -q -O "$_o" "$_u"
    fi
}
# fetch_stdout <url>
fetch_stdout() {
    _u="$1"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 20 --max-time 120 "$_u"
    elif command -v uclient-fetch >/dev/null 2>&1; then
        uclient-fetch -q --no-check-certificate -O- "$_u"
    else
        wget -q -O- "$_u"
    fi
}

# ---------------------------------------------------------------------------
# board / arch detection  (derives what routerich hardcoded)
# ---------------------------------------------------------------------------
# Highest-priority opkg architecture, e.g. aarch64_cortex-a53, x86_64, mipsel_24kc
detect_pkgarch() {
    opkg print-architecture 2>/dev/null \
        | awk 'BEGIN{max=-1}{if($3+0>max){max=$3+0;a=$2}}END{print a}'
}
_board() { ubus call system board 2>/dev/null; }
detect_target()    { _board | jsonfilter -e '@.release.target' 2>/dev/null | cut -d/ -f1; }
detect_subtarget() { _board | jsonfilter -e '@.release.target' 2>/dev/null | cut -d/ -f2; }
detect_version()   { _board | jsonfilter -e '@.release.version' 2>/dev/null; }   # 23.05.5 | 24.10.7 | SNAPSHOT
detect_model()     { cat /tmp/sysinfo/model 2>/dev/null; }
# major.minor only: 23.05 / 24.10 / 25.12   (empty for SNAPSHOT)
detect_minor()     { detect_version | grep -oE '^[0-9]+\.[0-9]+'; }

# ---------------------------------------------------------------------------
# package manager abstraction (opkg on 23.05/24.10, apk on 25.12/SNAPSHOT)
# ---------------------------------------------------------------------------
detect_pm() {
    if command -v opkg >/dev/null 2>&1; then echo opkg
    elif command -v apk  >/dev/null 2>&1; then echo apk
    else echo opkg; fi
}
ZU_PM="$(detect_pm)"

pm_update() {
    case "$ZU_PM" in
        opkg) opkg update ;;
        apk)  apk update ;;
    esac
}
# pm_installed <name>  -> 0 if installed
pm_installed() {
    case "$ZU_PM" in
        opkg) opkg list-installed 2>/dev/null | grep -q "^$1 " ;;
        apk)  apk list -I 2>/dev/null | grep -q "^$1-[0-9]" ;;
    esac
}
# pm_install <name...>
pm_install() {
    case "$ZU_PM" in
        opkg) opkg install "$@" ;;
        apk)  apk add --allow-untrusted "$@" ;;
    esac
}
# pm_install_file <path>
pm_install_file() {
    case "$ZU_PM" in
        opkg) opkg install "$1" ;;
        apk)  apk add --allow-untrusted "$1" ;;
    esac
}
# pm_remove <name>
pm_remove() {
    case "$ZU_PM" in
        opkg) opkg remove --force-removal-of-dependent-packages "$1" ;;
        apk)  apk del "$1" ;;
    esac
}
# pm_ext -> file extension this firmware consumes
pm_ext() { [ "$ZU_PM" = apk ] && echo apk || echo ipk; }

# ---------------------------------------------------------------------------
# immutable vendor root + Entware (Xiaomi IPQ / vendor-OpenWrt forks)
# ---------------------------------------------------------------------------
# Vendor routers (e.g. Xiaomi IPQ5424/IPQ9554 stock "18.06-SNAPSHOT" fork) run a
# read-only squashfs / with NO writable overlay: you CANNOT `opkg install` into
# the system. /etc/config is ubifs (persists), so UCI config still works.
# Native binaries instead live in Entware on a USB drive (/opt, opkg into /opt).
ENTWARE_OPKG="/opt/bin/opkg"
detect_entware() { [ -x "$ENTWARE_OPKG" ]; }
# highest-priority Entware arch token, e.g. aarch64-3.10 / x64-3.2 / mipsel-3.4
entware_arch() {
    "$ENTWARE_OPKG" print-architecture 2>/dev/null \
        | awk 'BEGIN{m=-1}{if($3+0>m){m=$3+0;a=$2}}END{print a}'
}
# true when the system root cannot be written (=> no opkg-into-/ possible)
detect_immutable() {
    if ( : > /usr/lib/.zu_wtest ) 2>/dev/null; then rm -f /usr/lib/.zu_wtest; return 1; fi
    return 0
}
# install a package into Entware
entware_install() { "$ENTWARE_OPKG" install "$@"; }
entware_installed() { "$ENTWARE_OPKG" list-installed 2>/dev/null | grep -q "^$1 "; }

# ensure_pkg <name> <required:1|0> [alt]
ensure_pkg() {
    _n="$1"; _req="$2"; _alt="$3"
    if pm_installed "$_n"; then log "$_n already installed"; return 0; fi
    if [ -n "$_alt" ] && pm_installed "$_alt"; then log "$_alt already installed"; return 0; fi
    log "Installing $_n ..."
    if pm_install "$_n"; then return 0; fi
    if [ "$_req" = 1 ]; then
        die "Cannot install $_n. Install it manually${_alt:+ (or $_alt)} and re-run."
    fi
    warn "Optional package $_n not installed (continuing)."
    return 0
}

# manage_service <name> <enable|disable> <start|stop|restart>
manage_service() {
    _n="$1"; _auto="$2"; _proc="$3"
    [ -x "/etc/init.d/$_n" ] || return 0
    case "$_auto" in
        enable)  "/etc/init.d/$_n" enable  2>/dev/null ;;
        disable) "/etc/init.d/$_n" disable 2>/dev/null ;;
    esac
    case "$_proc" in
        start)   "/etc/init.d/$_n" start   2>/dev/null ;;
        stop)    "/etc/init.d/$_n" stop    2>/dev/null ;;
        restart) "/etc/init.d/$_n" restart 2>/dev/null ;;
    esac
    return 0
}

# ---------------------------------------------------------------------------
# UCI helpers — resolve section ids dynamically (no hardcoded cfg01411c!)
# ---------------------------------------------------------------------------
# Return the section id of the first `config dnsmasq` block (named or anon).
dnsmasq_section() {
    _s=$(uci show dhcp 2>/dev/null | sed -n 's/^dhcp\.\([^.]*\)=dnsmasq$/\1/p' | head -n1)
    [ -n "$_s" ] && echo "$_s" || echo '@dnsmasq[0]'
}
# Return a firewall zone *name* whose network list contains the given iface,
# falling back to the literal arg. Used so we target real lan/wan names.
fw_zone_for() {
    _want="$1"
    uci show firewall 2>/dev/null \
        | sed -n "s/^firewall\.\([^.]*\)\.name='\?\([^']*\)'\?$/\2/p" \
        | grep -qx "$_want" && { echo "$_want"; return; }
    echo "$_want"
}
# uci_add_list_once <config> <section.option> <value>  (idempotent add_list)
uci_add_list_once() {
    _cfg="$1"; _key="$2"; _val="$3"
    if ! uci -q get "$_key" 2>/dev/null | tr ' ' '\n' | grep -qxF "$_val"; then
        uci add_list "$_key=$_val" 2>/dev/null
    fi
}

# ---------------------------------------------------------------------------
# GitHub release asset resolver (version/hash-agnostic)
# ---------------------------------------------------------------------------
# gh_asset_url <owner/repo> <tag> <ERE-on-filename>
# Echoes the first browser_download_url whose filename matches the ERE.
gh_asset_url() {
    _repo="$1"; _tag="$2"; _re="$3"
    fetch_stdout "https://api.github.com/repos/$_repo/releases/tags/$_tag" 2>/dev/null \
        | tr ',{}[]' '\n' \
        | sed -n 's/.*"browser_download_url" *: *"\(https[^"]*\)".*/\1/p' \
        | grep -E "$_re" | head -n1
}

# ---------------------------------------------------------------------------
# Version support matrix (OpenWrt 18.06 .. 25.12 / SNAPSHOT)
# ---------------------------------------------------------------------------
# Prebuilt coverage (upstream GitHub releases):
#   youtubeUnblock : 23.05 / 24.10 / 25.12 only
#   awg-openwrt    : 22.03.7, 23.05.x, 24.10.x, 25.12.x, SNAPSHOT
# Everything older (18.06 / 19.07 / 21.02 / most 22.03) has NO prebuilt and is
# served by build/build-packages.sh (OpenWrt SDK). The DoH + dnsmasq redirect +
# QUIC-block core uses only stock packages and works on every branch >= 18.06.
ZU_MIN_BRANCH="18.06"

# branch_ge <a> <b> : true if openwrt minor a >= b  (e.g. 23.05 >= 21.02)
branch_ge() {
    _a="${1:-0.0}"; _b="$2"
    _am="${_a%%.*}"; _an="${_a#*.}"; _bm="${_b%%.*}"; _bn="${_b#*.}"
    [ "$_am" -gt "$_bm" ] && return 0
    [ "$_am" -lt "$_bm" ] && return 1
    [ "${_an#0}" -ge "${_bn#0}" ]
}

# youtubeUnblock — pick the right prebuilt for THIS firmware.
# Echoes "<tag> <openwrt-token> <ext>" when a prebuilt exists, else
# "NONE <minor> <ext>" (caller must build from source or skip).
yu_target() {
    _minor="$(detect_minor)"
    _ext="$(pm_ext)"
    case "$_minor" in
        23.05)                    echo "v1.1.1 23.05 ipk" ;;
        24.10)                    echo "v1.3.1 24.10 ipk" ;;
        25.12)                    echo "v1.3.1 25.12 apk" ;;
        "")                       echo "v1.3.1 25.12 apk" ;;   # SNAPSHOT -> newest apk
        18.06|19.07|21.02|22.03)  echo "NONE $_minor $_ext" ;;  # no prebuilt -> SDK build
        *)  # unknown/newer minor: apk firmwares -> newest apk, else build from src
            if [ "$_ext" = apk ]; then echo "v1.3.1 25.12 apk"; else echo "NONE $_minor ipk"; fi ;;
    esac
}

# youtubeUnblock for Entware (/opt on USB) — branch-independent userland build.
# Echoes "<tag> <entware-arch> ipk" (e.g. "v1.3.1 aarch64-3.10 ipk"), or "" if
# no Entware arch could be resolved.
YU_ENTWARE_TAG="v1.3.1"
yu_entware_target() {
    _ea="$(entware_arch)"
    [ -n "$_ea" ] || return 1
    echo "$YU_ENTWARE_TAG $_ea ipk"
}
