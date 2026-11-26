#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Boot-time creation of the mtkmipc WAN interface (issue #2, final piece).
# Port of the stock etc/init.d/mipc_wan.init role: netifd only calls the
# mtkmipc proto handler once network.wan exists, so this one-shot creates
# the minimal section (proto/ifname). No APN data is written here: the
# proto's mtkmipc_apn_provision() fills apn/auth/user/password/iptype/
# rattype/... from the SIM database on bring-up (auto_conf, default 1).
#
# Started once from /etc/init.d/mt6890-apn at S99 (stock mipc_wan.init
# timing: after the S01 modem daemon stack and its radio_on step). No
# respawn, no retry: if the modem stack was down at boot, re-run
# `/etc/init.d/mt6890-apn start` manually.
#
# MTKMIPC_NETWORK_CFG / MTKMIPC_DT_BOOT override the config / DT paths
# for the host tests (same convention as MTKMIPC_LOCK in the proto).

set -u

NETWORK_CFG="${MTKMIPC_NETWORK_CFG:-/etc/config/network}"
DT_BOOT="${MTKMIPC_DT_BOOT:-/proc/device-tree/chosen/atag,boot}"

log() {
	logger -t mt6890-apn "$*"
}

MTKMIPC_CLI_TIMEOUT="${MTKMIPC_CLI_TIMEOUT:-10}"

# mipc_wan_cli has no timeout and blocks forever when the MIPC server is
# down (dead MD); cap every call so callers can react. POSIX sh (busybox).
mipc_wd() {
	mipc_wan_cli "$@" &
	local cli_pid=$! i=0
	while kill -0 "$cli_pid" 2>/dev/null; do
		i=$((i + 1))
		if [ "$i" -ge "$MTKMIPC_CLI_TIMEOUT" ]; then
			kill "$cli_pid" 2>/dev/null
			wait "$cli_pid" 2>/dev/null
			logger -t mtkmipc-wd "mipc_wan_cli $* timed out after ${MTKMIPC_CLI_TIMEOUT}s"
			return 124
		fi
		sleep 1
	done
	wait "$cli_pid" 2>/dev/null
	return $?
}

# guard: meta/factory boot mode (stock: atag,boot hexdump field 6 = 0001)
if [ -e "$DT_BOOT" ]; then
	bootmode="$(hexdump -v "$DT_BOOT" 2>/dev/null | awk '{print $6; exit}')"
	if [ "$bootmode" = "0001" ]; then
		log "meta boot mode ($DT_BOOT = $bootmode): skip"
		exit 0
	fi
fi

# guard: a network config to extend
if [ ! -s "$NETWORK_CFG" ]; then
	log "$NETWORK_CFG missing or empty: skip"
	exit 0
fi

# guard: stock WAN/LAN auto-adapt owns the port layout
auto="$(uci -q get system.@system[0].ql_wan_lan_auto_adapt)"
if [ "$auto" = "1" ]; then
	log "system ql_wan_lan_auto_adapt=1: skip"
	exit 0
fi

# guard: WAN already driven by a MIPC proto
proto="$(uci -q get network.wan.proto)"
case "$proto" in
	mipc|ql_mipc|mtkmipc)
		log "network.wan.proto already '$proto': skip"
		exit 0
		;;
esac

# guard: SIM auto-provisioning must be on (proto default 1)
auto_conf="$(uci -q get network.wan.auto_conf)"
[ -z "$auto_conf" ] && auto_conf=1
if [ "$auto_conf" != "1" ]; then
	log "network.wan.auto_conf=$auto_conf: skip"
	exit 0
fi

# radio on (stock mipc_wan.init check_sim first line; idempotent — the
# S01 modem init also sets it at boot+25s). The mtkmipc proto verifies
# the radio state on interface bring-up; setting it here (S99, before
# the wan section exists) removes the boot-ordering race.
mipc_wd --nw_radio_state_set 1 >/dev/null 2>&1 || \
	log "mipc_wan_cli radio-on failed (modem stack down?)"

uci batch <<-EOF
	set network.wan.proto='mtkmipc'
	set network.wan.ifname='ccmni'
	set network.wan6.ifname='ccmni'
	commit network
EOF

log "created network.wan (proto mtkmipc, APN from SIM): restarting network"
service network restart
exit 0
