#!/bin/sh
# open-routerich :: DNS stack watchdog / boot re-apply (idempotent).
# Survives /etc ramfs reset on vendor routers. Ensures: DoH instances up,
# dnsmasq points at the local DoH (noresolv) + malw geo-unblock addn-hosts.
# SAFETY: if both DoH die, fall back to ISP DNS so the LAN never loses
# resolution; restore DoH-only the moment a resolver is healthy again.
# Install: copy to /data/dns-stack.sh + cron "*/5 * * * * /data/dns-stack.sh".
DIG=/opt/bin/dig
INIT=/opt/etc/init.d/S09https-dns-proxy
MALW=/data/malw-hosts
DOH_PORTS="5353 5354"

# 1) ensure DoH instances running (start if fewer than expected)
want=$(echo $DOH_PORTS | wc -w)
[ "$(pidof https-dns-proxy 2>/dev/null | wc -w)" -lt "$want" ] && [ -x "$INIT" ] && "$INIT" start >/dev/null 2>&1
sleep 1

# 2) DoH health: REQUIRE a real resolution probe. A bound-but-non-resolving DoH
# must NOT read as healthy (that would keep noresolv=1 and SERVFAIL all LAN DNS
# forever). Without dig we cannot functionally verify DoH -> treat as unhealthy
# and fall back to ISP DNS (online, poisoned) per the HARD never-break rule.
healthy=0
if [ -x "$DIG" ]; then
	for p in $DOH_PORTS; do
		"$DIG" @127.0.0.1 -p "$p" ya.ru +short +time=3 +tries=1 2>/dev/null | grep -qE '^[0-9]' && { healthy=1; break; }
	done
else
	logger -t dns-stack "dig absent: cannot verify DoH health -> ISP fallback (install bind-dig for un-poisoning)"
fi

CHG=0
# malw geo-unblock (independent of DoH health)
if [ -f "$MALW" ]; then
	uci -q get dhcp.@dnsmasq[0].addnhosts | grep -q "$MALW" || { uci add_list dhcp.@dnsmasq[0].addnhosts="$MALW"; CHG=1; }
fi

if [ "$healthy" = 1 ]; then
	for p in $DOH_PORTS; do
		uci -q get dhcp.@dnsmasq[0].server | grep -q "127.0.0.1#$p" || { uci add_list dhcp.@dnsmasq[0].server="127.0.0.1#$p"; CHG=1; }
	done
	[ "$(uci -q get dhcp.@dnsmasq[0].noresolv)" = 1 ] || { uci set dhcp.@dnsmasq[0].noresolv='1'; CHG=1; }
else
	# SAFETY FALLBACK: DoH down -> allow ISP DNS so the LAN stays online, and drop
	# the dead DoH server lines so strictorder doesn't add a timeout per query.
	if [ "$(uci -q get dhcp.@dnsmasq[0].noresolv)" = 1 ]; then
		uci set dhcp.@dnsmasq[0].noresolv='0'; CHG=1
		for p in $DOH_PORTS; do uci -q del_list dhcp.@dnsmasq[0].server="127.0.0.1#$p" 2>/dev/null && CHG=1; done
		logger -t dns-stack "DoH unhealthy: temporary ISP-DNS fallback (poisoned but online)"
	fi
fi

if [ "$CHG" = 1 ]; then uci commit dhcp; /etc/init.d/dnsmasq restart >/dev/null 2>&1; logger -t dns-stack "re-applied (healthy=$healthy)"; fi
