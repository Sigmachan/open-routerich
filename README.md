# open-routerich

Универсальный порт проекта **[routerich/RouterichAX3000_configs](https://github.com/routerich/RouterichAX3000_configs)** — обход DPI-блокировок для **любого** роутера на OpenWrt, а не только для Routerich AX3000.

Оригинальные скрипты намертво привязаны к одной модели и одной прошивке. Здесь всё, что было захардкожено под Routerich, определяется на лету. Запускается на чём угодно от OpenWrt 18.06 до 25.12 / SNAPSHOT.

```
                ┌─ youtubeUnblock  (десинхронизация DPI: TLS ClientHello + QUIC)
обход блокировок ┼─ https-dns-proxy (DoH: AdGuard / Google / Cloudflare / Comss)
                ├─ dnsmasq redirect (гео-разблок доменов через Comss DoH)
                ├─ QUIC block       (REJECT UDP 80/443 lan→wan)
                └─ AmneziaWG WARP   (опционально, туннель + WARP6/IPv6)
```

---

## Чем отличается от оригинала

| Захардкожено у routerich | Здесь |
|---|---|
| guard `cat /tmp/sysinfo/model \| grep Routerich → exit 1` | **убран** — работает на любой модели |
| `aarch64_cortex-a53` для opera-proxy / sing-box / YU | арх определяется через `opkg print-architecture` |
| youtubeUnblock пин `v1.0.0 … openwrt-23.05` | релиз подбирается под ветку (23.05→v1.1.1, 24.10→v1.3.1, 25.12→apk) |
| UCI-секция dnsmasq `cfg01411c` | резолвится: `dhcp.@dnsmasq[0]` / именованная секция |
| жёсткий `exit 1` если версия ≠ 23.05.5 | поддержка **18.06 → 25.12 / SNAPSHOT** |
| только opkg | opkg **и** apk (25.12+) |
| `firewall.@zone[1].masq6` (warp6) | WAN-зона ищется по имени |
| `awg-openwrt` тег = точная версия | точная версия → fallback на ближайший тег ветки |

---

## Поддерживаемые версии

Ядро (DoH + dnsmasq-редирект + QUIC-блок) использует только штатные пакеты и работает на **всех** ветках ≥ 18.06.

| OpenWrt | Ядро | youtubeUnblock | AmneziaWG |
|--------:|:----:|:--------------:|:---------:|
| 18.06 / 19.07 / 21.02 | ✅ | сборка из исходников¹ | сборка¹ |
| 22.03 | ✅ | сборка¹ | пребилт `22.03.7` / сборка¹ |
| 23.05 | ✅ | ✅ пребилт | ✅ пребилт |
| 24.10 | ✅ | ✅ пребилт | ✅ пребилт |
| 25.12 / SNAPSHOT | ✅ | ✅ пребилт (apk) | ✅ пребилт |

¹ — где у апстрима нет готового `.ipk`, его собирает `build/build-packages.sh` через официальный OpenWrt SDK (см. ниже). Если пакет недоступен — установщик **не падает**, а настраивает остальное и подсказывает команду сборки.

---

## Установка

На роутере (SSH под root). Через GitHub, как и оригинал:

```sh
# полный набор: youtubeUnblock + DoH + dnsmasq-редирект + QUIC-блок
wget -O - https://raw.githubusercontent.com/Sigmachan/open-routerich/main/install.sh | sh
```

Откат:

```sh
wget -O - https://raw.githubusercontent.com/Sigmachan/open-routerich/main/uninstall.sh | sh
```

Либо клонировать и запускать локально (тогда сеть нужна только для пакетов):

```sh
git clone https://github.com/Sigmachan/open-routerich
cd open-routerich
sh install.sh
```

### Флаги `install.sh`

```
--no-quic        не добавлять REJECT UDP 80/443 (QUIC-блок)
--no-redirect    не пушить список гео-разблок доменов в dnsmasq
--no-overrides   не добавлять статические A-записи (chatgpt/openai)
--cron           ежедневный авто-апдейт через cron
--lan-zone NAME  имя LAN-зоны фаервола (по умолчанию lan)
--wan-zone NAME  имя WAN-зоны фаервола (по умолчанию wan)
-y, --yes        без вопросов
```

---

## Модули

### AmneziaWG WARP (туннель Cloudflare WARP)

```sh
sh modules/awg-warp.sh            # авто-генерация конфига WARP
sh modules/awg-warp.sh --manual   # ввести параметры AmneziaWG вручную
```

Тянет `kmod-amneziawg` / `amneziawg-tools` / `luci-app-amneziawg` из
[Slava-Shchipunov/awg-openwrt](https://github.com/Slava-Shchipunov/awg-openwrt)
строго под версию/ядро роутера, поднимает интерфейс `awg10`, зону `awg`,
форвардинг и проверяет связь пингом.

### WARP6 (IPv6 WARP поверх AmneziaWG)

```sh
sh modules/awg-warp.sh   # сначала поставить amneziawg
sh modules/warp6.sh      # затем поднять wan6
```

---

## Пересборка пакетов (для веток без пребилтов)

Если у апстрима нет готового `.ipk` под твой таргет/версию (18.06–22.03 или
редкая архитектура) — собери сам на ПК с Linux. Нужен только интернет и место.

```sh
# узнать target/subtarget на роутере:
ubus call system board     # -> "target": "ramips/mt7621"

# собрать оба пакета:
build/build-packages.sh -v 21.02.7 -t ramips -s mt7621

# только youtubeUnblock / только amneziawg:
build/build-packages.sh -v 21.02.7 -t ramips -s mt7621 --only yu
build/build-packages.sh -v 21.02.7 -t ramips -s mt7621 --only awg
```

Скрипт сам качает официальный OpenWrt SDK нужной версии (vermagic ядра
совпадёт), подключает фиды `Waujito/youtubeUnblock` и
`amnezia-vpn/amneziawg-openwrt`, компилит и складывает `.ipk` в
`output/<версия>-<target>-<subtarget>/`. Дальше:

```sh
scp output/*/*.ipk root@192.168.1.1:/tmp/
ssh root@192.168.1.1 'opkg install /tmp/*.ipk'
```

> CI намеренно нет — пересборка локальная. Зависит только от тебя и SDK, не от чужих раннеров.

---

## Структура

```
install.sh              универсальный установщик (ядро обхода DPI)
uninstall.sh            откат: восстановление бэкапов + остановка сервисов
lib/common.sh           детект арх/версии/PM, резолвер UCI-секций и gh-релизов
modules/awg-warp.sh     AmneziaWG WARP (авто/ручной)
modules/warp6.sh        IPv6 WARP поверх AmneziaWG
config_files/           UCI-шаблоны (https-dns-proxy, youtubeUnblock) + списки доменов
build/build-packages.sh пересборка YU + amneziawg через OpenWrt SDK
```

---

## Кредиты

- [routerich/RouterichAX3000_configs](https://github.com/routerich/RouterichAX3000_configs) — исходный проект
- [Waujito/youtubeUnblock](https://github.com/Waujito/youtubeUnblock) — DPI desync
- [Slava-Shchipunov/awg-openwrt](https://github.com/Slava-Shchipunov/awg-openwrt) — сборки AmneziaWG
- [amnezia-vpn/amneziawg-openwrt](https://github.com/amnezia-vpn/amneziawg-openwrt) — исходники AmneziaWG

## Дисклеймер

Только для образовательных и исследовательских целей. Использование подобных
инструментов может быть ограничено законами твоей юрисдикции. Ответственность —
на пользователе.

MIT © Sigmachan
