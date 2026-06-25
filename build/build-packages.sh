#!/usr/bin/env bash
# openwrt-zapret-universal :: build/build-packages.sh
# Recompile the arch/kernel-specific pieces of the toolkit for ANY OpenWrt
# target that has no prebuilt release asset:
#   * youtubeUnblock + luci-app-youtubeUnblock   (Waujito/youtubeUnblock)
#   * kmod-amneziawg + amneziawg-tools + luci    (amnezia-vpn/amneziawg-openwrt)
#
# Runs on a Linux build host. Uses the official OpenWrt SDK for the exact
# release/target so the kmod vermagic matches the router's running kernel.
#
# Usage:
#   build/build-packages.sh --version 24.10.7 --target mediatek --subtarget filogic
#   build/build-packages.sh -v 23.05.5 -t ramips -s mt7621
#   # discover target/subtarget on the router:  ubus call system board
#
# Output ipks land in ./output/<version>-<target>-<subtarget>/
set -euo pipefail

VERSION=""; TARGET=""; SUBTARGET=""
ONLY=""   # yu | awg | (empty = both)
JOBS="$(nproc 2>/dev/null || echo 4)"
SDK_BASE="https://downloads.openwrt.org/releases"

usage() { sed -n '2,30p' "$0"; exit "${1:-0}"; }
while [ $# -gt 0 ]; do
    case "$1" in
        -v|--version)   VERSION="$2"; shift ;;
        -t|--target)    TARGET="$2"; shift ;;
        -s|--subtarget) SUBTARGET="$2"; shift ;;
        --only)         ONLY="$2"; shift ;;
        -j|--jobs)      JOBS="$2"; shift ;;
        -h|--help)      usage 0 ;;
        *) echo "unknown arg: $1" >&2; usage 1 ;;
    esac; shift
done
[ -n "$VERSION" ] && [ -n "$TARGET" ] && [ -n "$SUBTARGET" ] || usage 1

for t in wget tar make git; do command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 1; }; done

WORK="$(pwd)/.sdkbuild/${VERSION}-${TARGET}-${SUBTARGET}"
OUT="$(pwd)/output/${VERSION}-${TARGET}-${SUBTARGET}"
mkdir -p "$WORK" "$OUT"
cd "$WORK"

# ---------------------------------------------------------------------------
# 1. download + extract the matching SDK (name has a varying gcc/libc suffix)
# ---------------------------------------------------------------------------
DIR_URL="${SDK_BASE}/${VERSION}/targets/${TARGET}/${SUBTARGET}"
echo ">> resolving SDK from ${DIR_URL}"
SUMS="$(wget -qO- "${DIR_URL}/sha256sums" || true)"
[ -n "$SUMS" ] || { echo "cannot read ${DIR_URL}/sha256sums — check version/target/subtarget" >&2; exit 1; }
SDK_NAME="$(echo "$SUMS" | grep -oE 'openwrt-sdk-[^ ]*\.Linux-x86_64\.tar\.(xz|zst)' | head -n1)"
[ -n "$SDK_NAME" ] || { echo "no SDK tarball listed for this target" >&2; exit 1; }

if [ ! -d "sdk" ]; then
    echo ">> downloading $SDK_NAME"
    wget -q --show-progress -O "$SDK_NAME" "${DIR_URL}/${SDK_NAME}"
    echo ">> extracting"
    case "$SDK_NAME" in
        *.tar.zst) command -v zstd >/dev/null || { echo "install zstd to extract .tar.zst" >&2; exit 1; }
                   tar --use-compress-program=unzstd -xf "$SDK_NAME" ;;
        *.tar.xz)  tar -xJf "$SDK_NAME" ;;
    esac
    mv openwrt-sdk-* sdk
fi
cd sdk

# ---------------------------------------------------------------------------
# 2. wire feeds for youtubeUnblock + amneziawg, keep defaults
# ---------------------------------------------------------------------------
echo ">> configuring feeds"
cp feeds.conf.default feeds.conf
grep -q 'youtubeUnblock' feeds.conf || \
    echo 'src-git youtubeUnblock https://github.com/Waujito/youtubeUnblock.git' >> feeds.conf
grep -q 'awgopenwrt' feeds.conf || \
    echo 'src-git awgopenwrt https://github.com/amnezia-vpn/amneziawg-openwrt.git' >> feeds.conf

./scripts/feeds update -a >/dev/null
# youtubeUnblock ships its package under owrt/ — install both the bin and luci pkg
./scripts/feeds install -a -p youtubeUnblock >/dev/null 2>&1 || true
./scripts/feeds install youtubeUnblock luci-app-youtubeUnblock >/dev/null 2>&1 || true
./scripts/feeds install kmod-amneziawg amneziawg-tools luci-app-amneziawg >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# 3. select packages + compile
# ---------------------------------------------------------------------------
echo ">> generating .config"
make defconfig >/dev/null
enable() { grep -q "^CONFIG_PACKAGE_$1=" .config && sed -i "s/^CONFIG_PACKAGE_$1=.*/CONFIG_PACKAGE_$1=m/" .config || echo "CONFIG_PACKAGE_$1=m" >> .config; }

PKGS=""
case "$ONLY" in
    yu)  PKGS="youtubeUnblock luci-app-youtubeUnblock" ;;
    awg) PKGS="kmod-amneziawg amneziawg-tools luci-app-amneziawg" ;;
    *)   PKGS="youtubeUnblock luci-app-youtubeUnblock kmod-amneziawg amneziawg-tools luci-app-amneziawg" ;;
esac
for p in $PKGS; do enable "$p"; done
make defconfig >/dev/null

echo ">> compiling: $PKGS  (-j$JOBS)"
for p in $PKGS; do
    echo "   == $p =="
    make "package/$p/compile" V=s -j"$JOBS" || make "package/feeds/youtubeUnblock/$p/compile" V=s -j"$JOBS" \
        || make "package/feeds/awgopenwrt/$p/compile" V=s -j"$JOBS" || {
            echo "!! failed to compile $p" >&2; exit 1; }
done

# ---------------------------------------------------------------------------
# 4. collect artifacts
# ---------------------------------------------------------------------------
echo ">> collecting ipks into $OUT"
find bin -name '*.ipk' \( -name '*youtubeUnblock*' -o -name '*amneziawg*' \) -exec cp -v {} "$OUT/" \;

echo
echo "Built packages:"
ls -1 "$OUT"
echo
echo "Copy to the router and install, e.g.:"
echo "  scp $OUT/*.ipk root@192.168.1.1:/tmp/"
echo "  ssh root@192.168.1.1 'opkg install /tmp/*.ipk'"
