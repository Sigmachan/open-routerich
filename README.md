# open-routerich

Универсальный, 1:1 порт проекта **[routerich/RouterichAX3000_configs](https://github.com/routerich/RouterichAX3000_configs)** — обход DPI-блокировок для **любого** роутера на OpenWrt, а не только для Routerich AX3000.

Оригинал намертво привязан к одной модели и одной прошивке (`23.05.5`). Здесь всё захардкоженное определяется на лету: модель, архитектура, версия, секции UCI, пакетный менеджер. Работает от **OpenWrt 18.06 до 25.12 / SNAPSHOT**, включая **vendor-форки с read-only root** (Xiaomi на IPQ5424/IPQ9554).

```
                ┌─ doh-unpoison    (DoH AdGuard+Google: обходит DNS-отравление RKN на :53)
обход блокировок ┤─ malw-hosts      (гео-разблок dns.malw.link SNI-прокси; adblock-синкхол отфильтрован)
                ├─ dpi-desync       (youtubeUnblock; ECM-aware, сам откатывается если ломает HTTPS)
                ├─ https-dns-proxy  (DoH на мутабельном OpenWrt + dnsmasq-редирект)
                ├─ QUIC block       (REJECT UDP 80/443 lan→wan)
                ├─ AmneziaWG WARP   (модуль: туннель + WARP6/IPv6)
                ├─ podkop           (модуль: доменный роутинг)
                └─ opera-proxy+sing-box (модуль: free-WARP цепочка)
```

Три способа поставить: **CLI** (`wget | sh`), **веб-панель прямо в роутере**, **десктопный GUI** (Linux/macOS/Windows).

---

## Реальность на vendor/ECM-роутерах (Xiaomi IPQ и т.п.)

На Xiaomi BE-серии (IPQ5424) с аппаратным **NSS/ECM-оффлоадом** проверено вживую, что именно работает:

| Слой | На ECM-роутере | Что чинит |
|---|:---:|---|
| **doh-unpoison** (DoH) | ✅ работает | RKN травит DNS на :53 для всех резолверов (8.8.8.8/9.9.9.9/AdGuard/comss → `rutracker.org` отдаёт отравленный `94.230.*`). Шифрованный DoH возвращает настоящий IP. |
| **malw-hosts** (гео) | ✅ работает | Сервисы, баняющие RU-IP со своей стороны (ChatGPT/Spotify/…). Чистый hosts-оверрайд, оффлоад не мешает. |
| **dpi-desync** (youtubeUnblock) | ⚠️ не вывозит | NSS/ECM корёжит fake/frag-пакеты десинка → таргеты `000`. Пер-флоу exempt (`net.ecm.tcp_denied_ports`) на vendor-прошивке **инертен**; глобально гасить ECM нельзя (убьёт throughput). Модуль это детектит и **сам откатывается** — связь не ломается. |
| **VLESS-туннель** | ✅ единственный для RKN-SNI | Для сайтов, заблокированных RKN по SNI, рабочий путь — туннель до достижимого сервера (sing-box/xray, userspace TUN; kernel-WG/TPROXY на vendor-ядре нет). |

**Вывод:** на таком железе бесплатный «обход без сервера» = **DoH un-poison + malw гео-разблок** (это и закрывает большую часть). DPI-десинк — best-effort с авто-откатом. Полный обход RKN-SNI — только свой VLESS.

## Чем отличается от оригинала

| Захардкожено у routerich | Здесь |
|---|---|
| guard `cat /tmp/sysinfo/model \| grep Routerich → exit 1` | **убран** (декодирован из base64, см. «Точность порта») |
| `aarch64_cortex-a53` для opera-proxy / sing-box / YU | арх из `opkg print-architecture` |
| youtubeUnblock пин `v1.0.0 … openwrt-23.05` | релиз под ветку: 23.05→v1.1.1, 24.10→v1.3.1, 25.12→apk, Entware→entware-сборка |
| UCI-секция dnsmasq `cfg01411c` | резолвится динамически |
| `exit 1` если версия ≠ 23.05.5 | **18.06 → 25.12 / SNAPSHOT** |
| только opkg | opkg **и** apk, **и** Entware (`/opt`) |
| только мутабельный root | + **immutable/vendor режим** (Xiaomi IPQ): UCI-only, без записи в squashfs |
| `firewall.@zone[1].masq6` (warp6) | WAN-зона по имени |

---

## Поддерживаемые версии

Ядро (DoH + dnsmasq-редирект + QUIC) использует только штатные пакеты и работает на **всех** ветках ≥ 18.06.

| OpenWrt | Ядро | youtubeUnblock | AmneziaWG |
|--------:|:----:|:--------------:|:---------:|
| 18.06 / 19.07 / 21.02 | ✅ | сборка из исходников¹ | сборка¹ |
| 22.03 | ✅ | сборка¹ | пребилт `22.03.7` / сборка¹ |
| 23.05 / 24.10 | ✅ | ✅ пребилт | ✅ пребилт |
| 25.12 / SNAPSHOT | ✅ | ✅ пребилт (apk) | ✅ пребилт |
| Xiaomi IPQ (vendor 18.06) | ✅ (UCI-only) | ✅ через Entware (USB) | ✗ (нет kmod под vendor-ядро) |

¹ — `build/build-packages.sh` собирает недостающие `.ipk` через официальный OpenWrt SDK. Если пакета нет — установщик **не падает**, настраивает остальное и подсказывает команду сборки.

---

## Способ 1. CLI (как оригинал)

На роутере по SSH (root):

```sh
# полный обход: youtubeUnblock + DoH + dnsmasq-редирект + QUIC-блок
wget -O - https://raw.githubusercontent.com/Sigmachan/open-routerich/main/install.sh | sh

# откат
wget -O - https://raw.githubusercontent.com/Sigmachan/open-routerich/main/uninstall.sh | sh
```

Флаги `install.sh`:

```
--no-quic / --no-redirect / --no-overrides
--no-malw                      не ставить malw-гео-разблок (addn-hosts)
--no-doh-unpoison              не ставить DoH un-poison (immutable+Entware)
--doh-addr A#PORT   локальный DoH-резолвер для редиректов
--immutable / --no-immutable   принудительный режим vendor-root
--entware / --no-entware       путь через Entware (/opt на USB)
--profile xiaomi-vendor        пресет для Xiaomi IPQ
--lan-zone / --wan-zone NAME   имена зон фаервола
--cron                         ежедневный авто-апдейт
-y                             без вопросов
```

## Способ 2. Веб-панель прямо в роутере (в т.ч. Xiaomi)

Ставит красивую страницу управления в WebUI роутера. **Не трогает read-only root** — файлы кладутся в writable-каталог (`/opt` → `/data` → `/root`), страница подключается к `uhttpd` через UCI. Работает и на immutable Xiaomi.

```sh
wget -O - https://raw.githubusercontent.com/Sigmachan/open-routerich/main/webui/install-webui.sh | sh
# затем открой http://<ip-роутера>:8088/
```

Панель показывает статус (модель, версия, режим, что включено) и кнопками включает/откатывает обход и запускает модули. Снять: `sh <dest>/webui/uninstall-webui.sh`.

> Панель крутит CGI под root без авторизации — держи её только в LAN (дефолтный фаервол блокирует WAN).

## Способ 3. Десктопный установщик (Linux / macOS / Windows)

Красивый GUI без зависимостей: только `python3` + системный `ssh`. Поднимает локальное веб-приложение, открывает браузер и настраивает роутер по SSH.

```sh
python3 gui/open-routerich-gui.py        # или: gui/run.sh  (mac/Linux) | gui\run.bat (Windows)
```

Вводишь IP/логин/пароль(или ключ) → «Определить» → ставишь обход, веб-панель или модули в пару кликов.

---

## Модули

```sh
# DNS-слой (работает на vendor/ECM-роутерах — не трогает пакеты)
sh modules/doh-unpoison.sh install   # 2× https-dns-proxy (DoH) -> dnsmasq noresolv, un-poison; off для отката
sh modules/malw-hosts.sh   install   # dns.malw.link гео-разблок -> dnsmasq addn-hosts (синкхол отфильтрован); update, off
sh modules/dpi-desync.sh   try       # youtubeUnblock ECM-aware: сам откатывается если ломает HTTPS; check | off

# Туннели/роутинг (нужен мутабельный root или kmod)
sh modules/awg-warp.sh            # AmneziaWG WARP (авто-генерация), --manual для ручного ввода
sh modules/warp6.sh               # IPv6 WARP поверх AmneziaWG (после awg-warp)
sh modules/podkop.sh              # podkop (официальный инсталлер) + routerich-роутинг; --profile main|second|youtube
sh modules/proxy.sh               # opera-proxy (:18080) + sing-box (tproxy :1100) — free-WARP цепочка
```

- **doh-unpoison** — RKN травит DNS на :53 для ЛЮБОГО резолвера; поднимает локальный DoH и заворачивает dnsmasq на него (`noresolv`). Сентинел и watchdog-фоллбэк на ISP-DNS: LAN никогда не остаётся без резолва. Нужен `bind-dig` для health-проверки.
- **malw-hosts** — статический гео-разблок (ChatGPT/Spotify/Notion и т.п., которые сами баняют RU-IP) через SNI-прокси dns.malw.link. Чистый hosts-оверрайд, **ECM-safe**. По умолчанию ставится ТОЛЬКО гео-разблок (real-IP прокси-маппинги, ~200 записей); ad/tracker-синкхол malw (`0.0.0.0`, ~30k) **отфильтрован** — он глушит легитимные asset/CDN-домены (`csi.gstatic.com` и т.п.) и ломает иконки/картинки на сайтах. `MALW_BLOCKLIST=1` — добавить полный adblock-список.
- **dpi-desync** — youtubeUnblock с детектом NSS/ECM, пер-флоу exempt-попыткой и **двойным сентинелом** (общая связь + реальное оживание таргетов): если десинк ломает HTTPS или не обходит — авто-откат, роутер в норме.
- **awg-warp** тянет `kmod-amneziawg`/`amneziawg-tools`/`luci` из [awg-openwrt](https://github.com/Slava-Shchipunov/awg-openwrt) строго под версию/ядро.
- **podkop** ставит podkop официальным способом itdoginfo и применяет тюнингованный роутинг (youtube/rutracker/instagram/discord + second-профиль на `127.0.0.1:18080`).
- **proxy** = opera-proxy + sing-box; пара к `podkop --profile second`.

---

## Пересборка пакетов (ветки без пребилтов)

```sh
ubus call system board                       # узнать target/subtarget на роутере
build/build-packages.sh -v 21.02.7 -t ramips -s mt7621            # оба пакета
build/build-packages.sh -v 21.02.7 -t ramips -s mt7621 --only yu  # только youtubeUnblock
```

Скрипт качает официальный OpenWrt SDK нужной версии (vermagic ядра совпадёт), подключает фиды `Waujito/youtubeUnblock` и `amnezia-vpn/amneziawg-openwrt`, компилит и складывает `.ipk` в `output/`. CI намеренно нет — сборка локальная.

---

## Точность порта (1:1)

Проект полностью изучен и портирован 1:1. Единственная **удалённая** логика — base64-guard, который декодируется так:

```sh
model=$(cat /tmp/sysinfo/model)
if ! echo "$model" | grep -q "Routerich"; then echo "...only Routerich..."; exit 1; fi
```

Проверено `diff`-ом: список из 50 гео-доменов и 5 A-записей совпадает с оригиналом байт-в-байт. Все `eval` в оригинале — это парсинг WARP-конфига (`key=value`), он воспроизведён в `parse_warp()`. Блоб `awg_i1` в WARP6 — протокольная обфускация AmneziaWG, перенесён дословно. podkop-ipk у routerich — ванильный ITDog 0.2.5; здесь ставится официальный (свежий).

---

## Структура

```
install.sh / uninstall.sh   универсальный установщик / откат (ядро обхода)
lib/common.sh               детект арх/версии/PM/immutable/Entware, резолверы UCI и gh-релизов
modules/awg-warp.sh         AmneziaWG WARP
modules/warp6.sh            IPv6 WARP
modules/podkop.sh           podkop + тюнингованный роутинг
modules/proxy.sh            opera-proxy + sing-box
config_files/               UCI-шаблоны + списки доменов
webui/                      веб-панель в роутере (uhttpd + CGI, immutable-safe)
gui/                        десктопный установщик (python stdlib, SSH)
build/build-packages.sh     пересборка YU + amneziawg через OpenWrt SDK
```

---

## Кредиты

- [routerich/RouterichAX3000_configs](https://github.com/routerich/RouterichAX3000_configs) — исходный проект
- [Waujito/youtubeUnblock](https://github.com/Waujito/youtubeUnblock) · [Slava-Shchipunov/awg-openwrt](https://github.com/Slava-Shchipunov/awg-openwrt) · [amnezia-vpn/amneziawg-openwrt](https://github.com/amnezia-vpn/amneziawg-openwrt) · [itdoginfo/podkop](https://github.com/itdoginfo/podkop)

## Дисклеймер

Только для образовательных и исследовательских целей. Использование подобных инструментов может быть ограничено законами твоей юрисдикции. Ответственность — на пользователе.

MIT © Sigmachan
