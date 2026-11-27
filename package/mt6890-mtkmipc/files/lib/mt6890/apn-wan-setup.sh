#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Boot-time cellular WAN bring-up (v3.1.1 item 2): retry until registered.
# Port of the stock etc/init.d/mipc_wan.init role. Started once from
# /etc/init.d/mt6890-apn (procd one-shot, no respawn) so the ~15 min budget
# never holds up boot.
#
# State machine (total budget ~15 min, then exit 0):
#   1. poll --show_register_status every 30 s
#        HOME / ROAMING           -> 2
#        NOT_REGISTERED/SEARCHING -> keep polling (UNKNOWN too: MD answers)
#        no response (MD down)    -> re-run ccci_mdinit 0 (max 3x total)
#   2. --data_call_act (apn "0" = network default); accept "result": 0;
#        anything else (1316594 = no registered network) -> back to 1
#   3. configure from the reply JSON (plain-shell parsed):
#        network.wan = proto none, device <ifname>, dns v4_dns1/v4_dns2
#        (netifd owns resolv.conf.auto; network.wan sits in the firewall
#        wan zone) + <ifname> added to the wan zone explicitly (masq on),
#        then ip link up / addr add / default route (EEXIST tolerated: the
#        ccmni driver auto-assigns the PDP address)
#   4. success -> exit 0; budget exhausted -> log, exit 0
# Every mipc_wan_cli call goes through the 8 s probe() watchdog (live-
# proven pattern, verbatim): the CLI hangs forever when MIPC is down.
# POSIX sh (busybox ash: no timeout, no jq).
#
# Test-only overrides: MTKMIPC_NETWORK_CFG, MTKMIPC_DT_BOOT, MTKMIPC_MDINIT,
# MT6890_INITD, MT6890_APN_BUDGET (s), MT6890_APN_POLL (s), MT6890_APN_SETTLE (s).

set -u

NETWORK_CFG="${MTKMIPC_NETWORK_CFG:-/etc/config/network}"
DT_BOOT="${MTKMIPC_DT_BOOT:-/proc/device-tree/chosen/atag,boot}"
MDINIT="${MTKMIPC_MDINIT:-/usr/bin/ccci_mdinit}"
INITD="${MT6890_INITD:-/etc/init.d}"
BUDGET="${MT6890_APN_BUDGET:-900}"
POLL="${MT6890_APN_POLL:-30}"
SETTLE="${MT6890_APN_SETTLE:-3}"
MDINIT_MAX=3
PATH="$PATH:/usr/bin:/usr/sbin"

# network default APN; never a hardcoded operator APN
ACT_JSON='{"apn":"0","ip_type":3,"roaming_type":3,"auth_type":0,"username":"","password":"","bearer_bitmask":"0xfffdffff","mtu":1500,"mode":1}'

log() {
	logger -t mt6890-apn "$*"
}

probe() {
  ( "$@" >/tmp/.g_out 2>&1 & gp=$!; sleep 8; kill $gp >/dev/null 2>&1
    wait $gp >/dev/null 2>&1 )
  out=$(cat /tmp/.g_out 2>/dev/null)
}

# jget <key>: value of "key": <v> / "key": "<v>" from the reply in $out
jget() {
	echo "$out" | sed -n "s/.*\"$1\": *\"\{0,1\}\([^\", }]*\)\"\{0,1\}.*/\1/p" | head -n1
}

# run "ip ..." tolerating EEXIST (address/route already there)
ip_tol() {
	local res
	res="$(ip "$@" 2>&1)" && return 0
	case "$res" in
	*"File exists"*|*EEXIST*) log "ip $*: already present (ok)"; return 0 ;;
	esac
	log "ip $* failed: $res"
	return 1
}

# put <ifn> into network.wan (proto none) + the firewall wan zone
uci_wan() {
	local ifn="$1" dns1="$2" dns2="$3" zone fwd
	# network.wan: the data call is placed here, so netifd only has to
	# own the device + DNS (proto none: no second data call via mtkmipc)
	[ -n "$(uci -q get network.wan)" ] || uci -q set network.wan=interface
	uci -q set network.wan.proto='none'
	uci -q delete network.wan.ifname
	uci -q set network.wan.device="$ifn"
	uci -q delete network.wan.dns
	[ -n "$dns1" ] && uci -q add_list network.wan.dns="$dns1"
	[ -n "$dns2" ] && uci -q add_list network.wan.dns="$dns2"
	uci -q commit network

	# firewall wan zone: covers network 'wan' (default config) AND gets
	# <ifn> as an explicit device so LAN->WAN forward + NAT always match
	zone="$(uci -q show firewall | sed -n "s/^firewall\.\([^.]*\)\.name='wan'$/\1/p" | head -n1)"
	if [ -z "$zone" ]; then
		log "no firewall wan zone: creating one"
		zone="$(uci -q add firewall zone)"
		uci -q set firewall."$zone".name='wan'
		uci -q set firewall."$zone".input='REJECT'
		uci -q set firewall."$zone".output='ACCEPT'
		uci -q set firewall."$zone".forward='REJECT'
		uci -q set firewall."$zone".mtu_fix='1'
		uci -q add_list firewall."$zone".network='wan'
		fwd="$(uci -q add firewall forwarding)"
		uci -q set firewall."$fwd".src='lan'
		uci -q set firewall."$fwd".dest='wan'
	fi
	uci -q set firewall."$zone".masq='1'
	uci -q del_list firewall."$zone".device="$ifn"
	uci -q add_list firewall."$zone".device="$ifn"
	uci -q commit firewall
}

configure() { # configure: from the data_call_act reply in $out
	local ifn addr mask gw dns1 dns2
	ifn="$(jget ifname)"
	addr="$(jget v4_addr)"
	mask="$(jget v4_mask)"
	gw="$(jget v4_gw)"
	dns1="$(jget v4_dns1)"
	dns2="$(jget v4_dns2)"
	case "$mask" in
	''|*[!0-9]*) mask=32 ;;
	esac
	if [ -z "$ifn" ] || [ -z "$addr" ]; then
		log "data call reply lacks ifname/v4_addr: '$out'"
		return 1
	fi
	log "data call up: $ifn $addr/$mask gw ${gw:-none} dns ${dns1:-} ${dns2:-}"

	uci_wan "$ifn" "$dns1" "$dns2"
	"$INITD/network" reload >/dev/null 2>&1
	"$INITD/firewall" reload >/dev/null 2>&1
	# let netifd claim the device before adding the route it must not drop
	sleep "$SETTLE"

	ip_tol link set "$ifn" up
	ip_tol addr add "$addr/$mask" dev "$ifn"
	if [ -n "$gw" ]; then
		ip_tol route add default via "$gw" dev "$ifn"
	else
		ip_tol route add default dev "$ifn"
	fi
	return 0
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

# guard: WAN driven by a stock vendor MIPC proto, or a user-configured
# mtkmipc one (APN set). v3.1's auto-created mtkmipc section (no APN) is
# ours and gets replaced.
proto="$(uci -q get network.wan.proto)"
case "$proto" in
	mipc|ql_mipc)
		log "network.wan.proto already '$proto': skip"
		exit 0
		;;
	mtkmipc)
		if [ -n "$(uci -q get network.wan.apn)" ]; then
			log "network.wan is a configured mtkmipc interface: skip"
			exit 0
		fi
		;;
esac

# guard: auto provisioning must be on (default 1); 0 = manual APN setup
auto_conf="$(uci -q get network.wan.auto_conf)"
[ -z "$auto_conf" ] && auto_conf=1
if [ "$auto_conf" != "1" ]; then
	log "network.wan.auto_conf=$auto_conf: skip"
	exit 0
fi

elapsed=0 mdinit_n=0 retrig=
log "waiting for network registration (budget ${BUDGET}s, poll ${POLL}s)"
while [ "$elapsed" -lt "$BUDGET" ]; do
	spent=8
	probe mipc_wan_cli --show_register_status
	case "$out" in
	*MIPC_NW_REGISTER_STATE_HOME*|*MIPC_NW_REGISTER_STATE_ROAMING*)
		log "registered after ${elapsed}s: data call"
		probe mipc_wan_cli --data_call_act "$ACT_JSON"
		spent=16
		result="$(jget result)"
		if [ "$result" = 0 ]; then
			if configure; then
				log "WAN up after ${elapsed}s"
				exit 0
			fi
		elif [ "$result" = 1316594 ]; then
			log "data call: no registered network (1316594): back to polling"
		else
			log "data call failed (result='${result:-none}'): back to polling"
		fi
		;;
	*MIPC_NW_REGISTER_STATE_*)
		if [ -n "$retrig" ]; then
			# MD came back after a re-trigger: its radio boots off
			probe mipc_wan_cli --nw_radio_state_set 1
			spent=16 retrig=
		fi
		;;
	*)
		if [ "$mdinit_n" -lt "$MDINIT_MAX" ]; then
			mdinit_n=$((mdinit_n + 1))
			log "MD not answering: re-running ccci_mdinit ($mdinit_n/$MDINIT_MAX)"
			# long-running daemon: background it, never block on it
			"$MDINIT" 0 >/dev/null 2>&1 &
			retrig=1
		fi
		;;
	esac
	# one poll per POLL seconds (probe time included)
	if [ "$spent" -lt "$POLL" ]; then
		sleep $((POLL - spent))
		spent=$POLL
	fi
	elapsed=$((elapsed + spent))
done

log "no WAN after ${elapsed}s (budget ${BUDGET}s, ccci_mdinit re-runs: $mdinit_n): giving up"
exit 0
