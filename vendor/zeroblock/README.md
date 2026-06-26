# vendor/zeroblock

ZeroBlock is routerich's **closed, MIT-licensed** transparent-proxy manager
(sing-box/xray + FakeIP DNS + nftables tproxy). It has **no public opkg feed**,
so `modules/zeroblock.sh` does not download it — you drop the `.ipk` files here.

Place the two packages routerich ships (matching your router's opkg arch):

```
vendor/zeroblock/zeroblock_<ver>_<arch>.ipk          # e.g. zeroblock_0.8.2-r212_aarch64_cortex-a53.ipk
vendor/zeroblock/luci-app-zeroblock_<ver>_all.ipk
```

`*.ipk` is git-ignored, so these blobs are **never committed** — they stay local
to your clone (and are carried to the router by the WebUI installer's copy).

Then install:

```sh
sh modules/zeroblock.sh --ipk-dir vendor/zeroblock                 # defaults, configure in LuCI
sh modules/zeroblock.sh --ipk-dir vendor/zeroblock --vless 'vless://...'   # seed a proxy section
sh modules/zeroblock.sh --ipk-dir vendor/zeroblock --sub 'https://...'     # seed a subscription
```

Or point at any folder / URL:

```sh
sh modules/zeroblock.sh --ipk-url https://host/zeroblock.ipk --luci-url https://host/luci-app-zeroblock.ipk
ZB_IPK_DIR=/mnt/usb/zb sh modules/zeroblock.sh
```

## Limits (the module enforces these)

- **opkg firmware only.** The `.ipk` is opkg-format with opkg lib deps; apk-based
  OpenWrt (25.12 / SNAPSHOT) can't install it.
- **mutable root only.** Needs `opkg install` into `/` + `kmod-nft-tproxy`.
  Immutable vendor roots (Xiaomi IPQ stock) can't — use `modules/proxy.sh` or a
  hand-rolled sing-box TUN there instead.
- **ABI-pinned.** routerich builds against a specific OpenWrt ABI (closest: recent
  23.05 / 24.10). On far-off branches it may install with `--force-depends` but
  fail to load. Verify: `zeroblock dns_check_fakeip ya.ru` (must hit 198.18.0.0/15).

## Why this layer

On ECM/NSS/SFE hardware-offload routers, packet-desync (youtubeUnblock) is mangled
by the offload and fails. A FakeIP+tproxy proxy **terminates locally** on the
router, so the accelerated *forwarding* path never sees it — the tunnel survives
offload. This is the realistic full RKN-SNI bypass that open-routerich's DNS layer
leaves to "your own VLESS".
