#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# netifd protocol "mtkmipc": MT6890 MIPC data call via mipc_wan_cli.
# Derived from the stock /lib/netifd/proto/ql_mipc.sh (see docs/NOTES-p2.md "P3").
#
# UCI options: stock ql_mipc superset
#   apn auth username password iptype roamingtype iaapn iaiptype iaroamingtype
#   rattype plmn mtu auto_conf retry bearer_bitmask iabearer_bitmask mode vlan
# plus renamed/new:
#   pdn  (stock "vlan": PDN index, NOT 802.1Q; 0 = primary, >0 = secondary)
#   sim  (1|2|3; informational here, SIM switching is done by mt6890-modem)
# New names win; stock names are used when the new ones are absent.

MTKMIPC_LOCK="${MTKMIPC_LOCK:-/var/run/mtkmipc.lock}"
MTKMIPC_STATEDIR="${MTKMIPC_STATEDIR:-/tmp}"

proto_mtkmipc_init_config() {
	available=1
	no_device=1
	teardown_on_l3_link_down=1

	proto_config_add_string apn
	proto_config_add_int auth
	proto_config_add_string username
	proto_config_add_string password
	proto_config_add_int iptype
	proto_config_add_int roamingtype
	proto_config_add_string iaapn
	proto_config_add_int iaiptype
	proto_config_add_int iaroamingtype
	proto_config_add_int rattype
	proto_config_add_string plmn
	proto_config_add_int mtu
	proto_config_add_int auto_conf
	proto_config_add_int retry
	proto_config_add_string bearer_bitmask
	proto_config_add_string iabearer_bitmask
	proto_config_add_int mode
	proto_config_add_int vlan
	proto_config_add_int pdn
	proto_config_add_int sim
	proto_config_add_defaults
}

mtkmipc_state_file() {
	echo "$MTKMIPC_STATEDIR/mtkmipc-$1.state"
}

mtkmipc_log() {
	echo "mtkmipc: $*" >&2
	command -v logger >/dev/null 2>&1 && logger -t mtkmipc "$*"
	return 0
}

# Run mipc_wan_cli serialised on $MTKMIPC_LOCK (one modem call at a time).
mtkmipc_cli_locked() {
	(
		flock -w 120 9 || { mtkmipc_log "lock $MTKMIPC_LOCK timeout"; exit 1; }
		mipc_wan_cli "$@"
	) 9>"$MTKMIPC_LOCK"
}

# Resolve options into globals (new names first, stock names as fallback).
mtkmipc_get_options() {
	json_get_vars apn auth username password iptype roamingtype iaapn iaiptype \
		iaroamingtype rattype plmn mtu auto_conf retry bearer_bitmask \
		iabearer_bitmask mode vlan pdn sim metric

	[ -z "$pdn" ] && pdn="$vlan"
	[ -z "$pdn" ] && pdn=0
	[ -z "$retry" ] && retry=2
	[ -z "$roamingtype" ] && roamingtype=3
	[ -z "$iaroamingtype" ] && iaroamingtype="$roamingtype"
	[ -z "$iptype" ] && iptype=3
	[ -z "$rattype" ] && rattype=0
	[ -z "$mode" ] && mode=1
	[ -z "$mtu" ] && mtu=1500
	[ -z "$auto_conf" ] && auto_conf=1
	[ -z "$iaapn" ] && iaapn="$apn"
	[ -z "$iaiptype" ] && iaiptype="$iptype"
	[ -z "$auth" ] && auth=0
	[ -z "$bearer_bitmask" ] && bearer_bitmask=0xfffdffff
	[ -z "$iabearer_bitmask" ] && iabearer_bitmask="$bearer_bitmask"
	# secondary PDNs never auto-provision (stock ql_mipc.sh behaviour)
	[ "$pdn" -gt 0 ] && auto_conf=0
	return 0
}

# Stock check_auto_apn_prov equivalent: fill empty APN fields from the SIM DB.
mtkmipc_apn_provision() {
	local prov db_apn db_auth db_user db_pass db_proto db_iaapn db_rat db_plmn
	prov="$(mtkmipc_cli_locked --apn_provision_by_sim)" || return 0
	json_load "$prov" 2>/dev/null || return 0
	json_get_var db_apn apn
	[ -n "$db_apn" ] || return 0
	json_get_var db_auth auth_type
	json_get_var db_user user
	json_get_var db_pass password
	json_get_var db_proto protocol
	json_get_var db_iaapn iaapn
	json_get_var db_rat rattype
	json_get_var db_plmn plmn
	[ -n "$plmn" ] && [ -n "$db_plmn" ] && [ "$plmn" != "$db_plmn" ] && return 0
	[ -z "$apn" ] && apn="$db_apn" && iaapn="${db_iaapn:-$db_apn}"
	[ -z "$username" ] && username="$db_user"
	[ -z "$password" ] && password="$db_pass"
	[ -n "$db_auth" ] && [ "$auth" = 0 ] && auth="$db_auth"
	[ -n "$db_proto" ] && iptype="$db_proto"
	[ -n "$db_rat" ] && rattype="$db_rat"
	return 0
}

proto_mtkmipc_setup() {
	local interface="$1"
	local apn auth username password iptype roamingtype iaapn iaiptype iaroamingtype
	local rattype plmn mtu auto_conf retry bearer_bitmask iabearer_bitmask mode
	local vlan pdn sim metric
	local result cid ifname v4_addr v4_mask v4_gw v4_dns1 v4_dns2 v4_mtu
	local v6_addr v6_prefix v6_gw v6_dns1 v6_dns2 v6_mtu clatd odu_addr odu_dhcp_offset
	local sim_status tries cmd_args out dns state

	mtkmipc_get_options

	case "$sim" in
	""|1|2|3) ;;
	*)
		mtkmipc_log "$interface: invalid sim '$sim' (expected 1|2|3)"
		proto_notify_error "$interface" INVALID_SIM
		proto_block_restart "$interface"
		return 1
		;;
	esac

	[ "$auto_conf" = 1 ] && mtkmipc_apn_provision
	[ -z "$apn" ] && { apn=0; iaapn=0; }	# stock: empty APN => "0"

	# Radio must be on (stock: --nw_radio_state_get 0)
	out="$(mtkmipc_cli_locked --nw_radio_state_get 0)"
	if [ "$out" != "Get SW radio state:MIPC_NW_RADIO_STATE_ON" ]; then
		mtkmipc_log "$interface: radio off ($out)"
		proto_notify_error "$interface" CFUN_IS_OFF
		return 1
	fi

	mtkmipc_cli_locked --check_ia "$iaapn" "$rattype" "$iaiptype" "$iaroamingtype" \
		"$username" "$password" "$auth" "$iabearer_bitmask" >/dev/null

	sim_status="$(mtkmipc_cli_locked --show_sim_status)"
	case "$sim_status" in
	MIPC_SIM_STATUS_COMPLETE_READY) ;;
	MIPC_SIM_STATUS_SIM_PIN)
		proto_notify_error "$interface" SIM_PIN_LOCKED
		proto_block_restart "$interface"
		return 1 ;;
	MIPC_SIM_STATUS_SIM_PUK)
		proto_notify_error "$interface" SIM_PUK_LOCKED
		proto_block_restart "$interface"
		return 1 ;;
	*)
		# not ready yet: let netifd retry the setup later
		mtkmipc_log "$interface: SIM not ready ($sim_status)"
		proto_notify_error "$interface" SIM_NOT_INITIALIZED
		return 1 ;;
	esac

	mtkmipc_cli_locked --check_nw_status >/dev/null

	# Primary PDN: clear any stale call on this APN first (stock behaviour)
	[ "$pdn" -eq 0 ] && mtkmipc_cli_locked --data_call_deact_apn "$apn" >/dev/null

	json_init
	json_add_string "apn" "$apn"
	json_add_int "ip_type" "$iptype"
	json_add_int "roaming_type" "$roamingtype"
	json_add_int "auth_type" "$auth"
	json_add_string "username" "$username"
	json_add_string "password" "$password"
	json_add_string "bearer_bitmask" "$bearer_bitmask"
	json_add_int "mtu" "$mtu"
	json_add_int "mode" "$mode"
	cmd_args="$(json_dump)"

	tries="$retry"
	while :; do
		out="$(mtkmipc_cli_locked --data_call_act "$cmd_args")"
		result=
		json_load "$out" 2>/dev/null && json_get_var result result
		[ "$result" = 0 ] && break
		tries=$((tries - 1))
		if [ "$tries" -le 0 ]; then
			mtkmipc_log "$interface: data call failed (result='$result')"
			proto_notify_error "$interface" CONNECT_FAILED_RETRY_LATER
			proto_block_restart "$interface"
			return 1
		fi
		sleep "${MTKMIPC_RETRY_SLEEP:-3}"
	done

	json_get_vars cid ifname v4_addr v4_mask v4_gw v4_dns1 v4_dns2 v4_mtu \
		v6_addr v6_prefix v6_gw v6_dns1 v6_dns2 v6_mtu clatd odu_addr odu_dhcp_offset

	if [ -z "$cid" ] || [ -z "$ifname" ]; then
		mtkmipc_log "$interface: data call reply lacks cid/ifname"
		[ -n "$cid" ] && mtkmipc_cli_locked --data_call_deact "$cid" >/dev/null
		proto_notify_error "$interface" INVALID_REPLY
		return 1
	fi

	# Record state first, so teardown can always release this CID.
	state="$(mtkmipc_state_file "$interface")"
	{
		echo "interface=$interface"
		echo "cid=$cid"
		echo "ifname=$ifname"
		echo "pdn=$pdn"
		echo "sim=$sim"
		echo "apn=$apn"
		echo "mode=$mode"
		echo "v4_addr=$v4_addr"
		echo "v6_addr=$v6_addr"
		echo "state=up"
	} > "$state"

	dns=
	for out in "$v4_dns1" "$v4_dns2" "$v6_dns1" "$v6_dns2"; do
		[ -n "$out" ] && dns="${dns:+$dns }$out"
	done

	if [ "$mode" = 2 ]; then
		# bridge mode: addresses are handed to the LAN host by the modem
		proto_init_update "$ifname" 1 1
	else
		proto_init_update "$ifname" 1
		[ -n "$v4_addr" ] && proto_add_ipv4_address "$v4_addr" "${v4_mask:-32}"
		[ -n "$v4_gw" ] && proto_add_ipv4_route "0.0.0.0" 0 "$v4_gw" "$v4_addr"
		[ -n "$v6_addr" ] && proto_add_ipv6_address "$v6_addr" 128
		[ -n "$v6_gw" ] && proto_add_ipv6_route "::" 0 "$v6_gw"
		for out in $dns; do
			proto_add_dns_server "$out"
		done
	fi
	proto_set_keep 1
	proto_add_data
	json_add_string cid "$cid"
	json_add_string pdn "$pdn"
	json_add_string sim "$sim"
	json_add_string mode "$mode"
	json_add_string clatd "$clatd"
	[ -n "$v4_mtu" ] && json_add_string v4_mtu "$v4_mtu"
	[ -n "$v6_mtu" ] && json_add_string v6_mtu "$v6_mtu"
	[ -n "$v6_prefix" ] && json_add_string v6_prefix "$v6_prefix"
	[ -n "$odu_addr" ] && json_add_string odu_addr "$odu_addr"
	[ -n "$odu_dhcp_offset" ] && json_add_string odu_dhcp_offset "$odu_dhcp_offset"
	proto_close_data
	proto_send_update "$interface"

	# Interface result summary on stdout (task contract; netifd logs it)
	echo "ifname $ifname"
	[ -n "$metric" ] && echo "metric $metric"
	[ -n "$dns" ] && echo "dns $dns"
	return 0
}

proto_mtkmipc_teardown() {
	local interface="$1"
	local state cid

	state="$(mtkmipc_state_file "$interface")"
	if [ -f "$state" ]; then
		cid="$(sed -n 's/^cid=//p' "$state")"
		if [ -n "$cid" ]; then
			mtkmipc_log "$interface: deactivating cid $cid"
			mtkmipc_cli_locked --data_call_deact "$cid" >/dev/null
		fi
		rm -f "$state"
	fi

	proto_init_update "*" 0
	proto_send_update "$interface"
}

proto_mtkmipc_status() {
	local interface="$1"
	local state

	state="$(mtkmipc_state_file "$interface")"
	if [ -f "$state" ]; then
		local key val
		while IFS='=' read -r key val; do
			case "$key" in
			cid|ifname|pdn|sim|state) echo "$key $val" ;;
			esac
		done < "$state"
	else
		echo "state down"
	fi
}

# netifd never calls "status"; expose it for "ifstatus -p"/manual use:
#   sh /lib/netifd/proto/mtkmipc.sh mtkmipc status <interface>
[ -z "$INCLUDE_ONLY" ] && [ "$1" = mtkmipc ] && [ "$2" = status ] && {
	proto_mtkmipc_status "$3"
	exit 0
}

[ -n "$INCLUDE_ONLY" ] || {
	. ../netifd-proto.sh
	init_proto "$@"
	add_protocol mtkmipc
}
