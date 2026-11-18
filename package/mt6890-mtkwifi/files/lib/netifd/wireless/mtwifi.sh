#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# netifd wireless handler "mtwifi" for the stock MTK mt_wifi.ko (MT7915 DBDC,
# WEXT/ioctl, no cfg80211). Open half: contains no vendor bytes.
#
# The radio is driven exactly the way the stock X28-lineage stack does it:
#   * settings live in the per-band .dat profile named by
#     /etc/wireless/l1profile.dat (INDEXn_profile_path), written with the
#     stock `datconf -f <dat> set KEY VAL` (as stock lib/wifi/mt7615e.lua:160
#     and mtkwifi.save_profile, mtkwifi.lua:218-231 via datconf:merge);
#   * the interface is (re)started with the stock `/sbin/wifi down|up
#     <devname>` where devname = INDEX.mainidx.subidx (l1dat_parser.lua:267),
#     which dispatches to mt7615e_down/mt7615e_up (sbin/wifi:131-139).
#
# netifd calls:  mtwifi.sh '' dump | mtwifi.sh mtwifi setup|teardown <dev> <json>
# extra (CLI):   mtwifi.sh detect | mtwifi.sh status

MTWIFI_L1PROFILE="${MTWIFI_L1PROFILE:-/etc/wireless/l1profile.dat}"
MTWIFI_SYSNET="${MTWIFI_SYSNET:-/sys/class/net}"
MTWIFI_WIFI="${MTWIFI_WIFI:-/sbin/wifi}"
MTWIFI_DATCONF="${MTWIFI_DATCONF:-datconf}"

# ---------------------------------------------------------------- helpers
# l1profile value of INDEX0_<key> (single MT7915D card on this board)
l1_get() {
	sed -n "s/^INDEX0_$1=//p" "$MTWIFI_L1PROFILE" 2>/dev/null | head -n1
}

# token n (1-based) of a ';' list
tok() {
	echo "$1" | cut -d';' -f"$2"
}

# token_set <list> <n> <value>: mtkwifi.token_set (mtkwifi.lua:973-992),
# holes are padded with <value>
token_set() {
	local list="$1" n="$2" v="$3" out="" i=1 t cnt
	cnt=$(echo "$list" | awk -F';' '{print ($0=="" ? 0 : NF)}')
	while [ "$i" -le "$cnt" ] || [ "$i" -le "$n" ]; do
		if [ "$i" -eq "$n" ]; then t="$v"
		elif [ "$i" -le "$cnt" ]; then t="$(tok "$list" "$i")"
		else t="$v"; fi
		out="${out:+$out;}$t"
		i=$((i + 1))
	done
	echo "$out"
}

dat_get() { # <dat> <key>
	sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n1
}

# mtkwifi.band (mtkwifi.lua:944-959) on WirelessMode token 1
dat_band() {
	case "$(tok "$(dat_get "$1" WirelessMode)" 1)" in
	0|1|4|6|7|9|16) echo 2g ;;
	18) echo 6g ;;
	"") echo "" ;;
	*) echo 5g ;;
	esac
}

# radio_count: number of bands on the card (INDEX0_main_ifname tokens)
radio_count() {
	l1_get main_ifname | awk -F';' '{print ($0=="" ? 0 : NF)}'
}

# radio_load <main_ifname>: sets r_idx r_ifname r_ext r_dat r_devname r_band
radio_load() {
	local want="$1" n i
	n=$(radio_count)
	i=1
	while [ "$i" -le "$n" ]; do
		if [ "$(tok "$(l1_get main_ifname)" "$i")" = "$want" ]; then
			r_idx=$i
			r_ifname="$want"
			r_ext="$(tok "$(l1_get ext_ifname)" "$i")"
			r_dat="$(tok "$(l1_get profile_path)" "$i")"
			# devname = INDEX.mainidx.subidx (l1dat_parser.lua:267); one chip -> mainidx 1
			r_devname="$(sed -n 's/^INDEX0=//p' "$MTWIFI_L1PROFILE" | head -n1).1.$i"
			r_band="$(dat_band "$r_dat")"
			return 0
		fi
		i=$((i + 1))
	done
	return 1
}

radio_state() { # up|down|absent
	local f="$MTWIFI_SYSNET/$1/flags" v
	[ -e "$MTWIFI_SYSNET/$1" ] || { echo absent; return; }
	v=$(cat "$f" 2>/dev/null || echo 0)
	[ $(( v & 1 )) -eq 1 ] && echo up || echo down
}

# --------------------------------------------------- detect / status (CLI)
mtwifi_detect() {
	local n i ifn
	n=$(radio_count)
	i=1
	while [ "$i" -le "$n" ]; do
		ifn="$(tok "$(l1_get main_ifname)" "$i")"
		radio_load "$ifn"
		cat <<EOF
config wifi-device '$ifn'
	option type 'mtwifi'
	option main_ifname '$ifn'
	option band '$r_band'
	option channel '$(dat_get "$r_dat" Channel)'

config wifi-iface 'default_$ifn'
	option device '$ifn'
	option network 'lan'
	option mode 'ap'
	option ssid '$(dat_get "$r_dat" SSID1)'
	option encryption 'none'

EOF
		i=$((i + 1))
	done
}

mtwifi_status() {
	local n i ifn
	n=$(radio_count)
	i=1
	while [ "$i" -le "$n" ]; do
		ifn="$(tok "$(l1_get main_ifname)" "$i")"
		radio_load "$ifn"
		echo "$ifn devname=$r_devname band=$r_band state=$(radio_state "$ifn")" \
			"channel=$(dat_get "$r_dat" Channel)" \
			"ssid=$(dat_get "$r_dat" SSID1)" \
			"auth=$(tok "$(dat_get "$r_dat" AuthMode)" 1)" \
			"profile=$r_dat"
		i=$((i + 1))
	done
}

case "$1" in
detect) mtwifi_detect; exit 0 ;;
status) mtwifi_status; exit 0 ;;
esac

# ---------------------------------------------------------- netifd driver
. "${NETIFD_MAIN_DIR:-/lib/netifd}/netifd-wireless.sh"

init_wireless_driver "$@"

drv_mtwifi_init_device_config() {
	config_add_string main_ifname country
}

drv_mtwifi_init_iface_config() {
	config_add_boolean hidden isolate
}

drv_mtwifi_init_vlan_config() { :; }
drv_mtwifi_init_station_config() { :; }
drv_mtwifi_cleanup() { :; }

# UCI encryption -> mt_wifi AuthMode / EncrypType (lists: mtkwifi.lua:884-930)
mtwifi_crypto() {
	case "$1" in
	none|"")           m_auth=OPEN;           m_enc=NONE ;;
	psk2|psk2+ccmp|psk2+aes) m_auth=WPA2PSK;  m_enc=AES ;;
	psk2+tkip+ccmp|psk2+tkip+aes|psk-mixed*) m_auth=WPAPSKWPA2PSK; m_enc=TKIPAES ;;
	sae|psk3)          m_auth=WPA3PSK;        m_enc=AES ;;
	sae-mixed|psk3-mixed) m_auth=WPA2PSKWPA3PSK; m_enc=AES ;;
	owe)               m_auth=OWE;            m_enc=AES ;;
	*) return 1 ;;
	esac
}

# collects "KEY<TAB>VALUE" lines in $m_set; vif list in $m_vifs
mtwifi_add() { m_set="${m_set}$1	$2
"; }

mtwifi_setup_vif() {
	local name="$1" mode ssid encryption key hidden isolate vifname
	json_select config
	json_get_vars mode ssid encryption key hidden isolate
	json_select ..

	[ "$mode" = "ap" ] || {
		echo "mtwifi: interface $name: mode '$mode' not supported (ap only)"
		return 0
	}
	m_j=$((m_j + 1))
	[ -n "$ssid" ] || { m_err=MISSING_SSID; return 0; }
	mtwifi_crypto "$encryption" || { m_err=UNSUPPORTED_ENCRYPTION; return 0; }
	if [ "$m_enc" != NONE ] && [ "$m_auth" != OWE ]; then
		case "${#key}" in
		8|9|[1-5][0-9]|6[0-3]) ;;
		64) echo "$key" | grep -qE '^[0-9a-fA-F]{64}$' || { m_err=INVALID_KEY; return 0; } ;;
		*) m_err=INVALID_KEY; return 0 ;;
		esac
		mtwifi_add "WPAPSK$m_j" "$key"
	fi

	mtwifi_add "SSID$m_j" "$ssid"
	m_authl="$(token_set "$m_authl" "$m_j" "$m_auth")"
	m_encl="$(token_set "$m_encl" "$m_j" "$m_enc")"
	m_hidel="$(token_set "$m_hidel" "$m_j" "${hidden:-0}")"
	m_nofwl="$(token_set "$m_nofwl" "$m_j" "${isolate:-0}")"

	# vif naming: mtkwifi.__setup_vifs, mtkwifi.lua:1105-1106
	if [ "$m_j" -eq 1 ]; then vifname="$r_ifname"; else vifname="$r_ext$((m_j - 1))"; fi
	m_vifs="$m_vifs $name=$vifname"
}

drv_mtwifi_setup() {
	local main_ifname country cfg_band channel htmode
	json_select config
	json_get_vars main_ifname country htmode
	json_get_var channel channel
	json_get_var cfg_band band
	json_select ..
	main_ifname="${main_ifname:-$1}"

	radio_load "$main_ifname" || { wireless_setup_failed RADIO_NOT_FOUND; return 1; }
	[ -e "$MTWIFI_SYSNET/$r_ifname" ] || { wireless_setup_failed IFNAME_MISSING; return 1; }

	# --- band checks: the radio's band comes from its .dat (WirelessMode)
	if [ -n "$cfg_band" ] && [ "$cfg_band" != "$r_band" ]; then
		echo "mtwifi: $r_ifname is $r_band, config asks band=$cfg_band"
		wireless_setup_failed WRONG_BAND; return 1
	fi
	case "$channel" in ""|auto) channel=0 ;; esac
	case "$channel" in *[!0-9]*) wireless_setup_failed INVALID_CHANNEL; return 1 ;; esac
	if [ "$channel" -ne 0 ]; then
		case "$r_band" in
		2g) [ "$channel" -ge 1 ] && [ "$channel" -le 14 ] ;;
		5g) [ "$channel" -ge 36 ] && [ "$channel" -le 177 ] ;;
		6g) [ "$channel" -ge 1 ] && [ "$channel" -le 233 ] ;;
		*) false ;;
		esac || {
			echo "mtwifi: channel $channel not valid for $r_ifname ($r_band)"
			wireless_setup_failed WRONG_BAND_CHANNEL; return 1
		}
	fi
	# htmode -> HT_BW/VHT_BW (inverse of mtkwifi.lua:1385-1398)
	local ht_bw="" vht_bw=""
	case "$htmode" in
	"") ;;
	HT20|VHT20|HE20) ht_bw=0; vht_bw=0 ;;
	HT40|VHT40|HE40) ht_bw=1; vht_bw=0 ;;
	VHT80|HE80)      ht_bw=1; vht_bw=1 ;;
	VHT160|HE160)    ht_bw=1; vht_bw=2 ;;
	*) wireless_setup_failed INVALID_HTMODE; return 1 ;;
	esac
	if [ "$r_band" = 2g ] && [ "${vht_bw:-0}" -gt 0 ]; then
		echo "mtwifi: htmode $htmode not valid for $r_ifname (2g)"
		wireless_setup_failed WRONG_BAND_HTMODE; return 1
	fi

	# --- per-BSS settings
	m_set="" m_vifs="" m_err="" m_j=0
	m_authl="$(dat_get "$r_dat" AuthMode)"
	m_encl="$(dat_get "$r_dat" EncrypType)"
	m_hidel="$(dat_get "$r_dat" HideSSID)"
	m_nofwl="$(dat_get "$r_dat" NoForwarding)"
	for_each_interface "ap sta adhoc mesh monitor" mtwifi_setup_vif
	[ -z "$m_err" ] || { wireless_setup_failed "$m_err"; return 1; }
	[ "$m_j" -gt 0 ] || { wireless_setup_failed NO_AP_INTERFACE; return 1; }

	# trim per-BSS lists to BssidNum tokens
	m_authl="$(echo "$m_authl" | cut -d';' -f1-"$m_j")"
	m_encl="$(echo "$m_encl" | cut -d';' -f1-"$m_j")"
	m_hidel="$(echo "$m_hidel" | cut -d';' -f1-"$m_j")"
	m_nofwl="$(echo "$m_nofwl" | cut -d';' -f1-"$m_j")"

	mtwifi_add BssidNum "$m_j"
	mtwifi_add AuthMode "$m_authl"
	mtwifi_add EncrypType "$m_encl"
	mtwifi_add HideSSID "$m_hidel"
	mtwifi_add NoForwarding "$m_nofwl"
	if [ "$channel" -eq 0 ]; then
		mtwifi_add AutoChannelSelect 3
		mtwifi_add Channel 0
	else
		mtwifi_add AutoChannelSelect 0
		mtwifi_add Channel "$channel"
	fi
	[ -z "$ht_bw" ] || mtwifi_add HT_BW "$ht_bw"
	[ -z "$vht_bw" ] || [ "$r_band" = 2g ] || mtwifi_add VHT_BW "$vht_bw"
	[ -z "$country" ] || mtwifi_add CountryCode "$country"

	# --- apply: profile first, then bounce the band via the stock /sbin/wifi
	local k v
	printf '%s' "$m_set" | while IFS='	' read -r k v; do
		[ -n "$k" ] || continue
		"$MTWIFI_DATCONF" -f "$r_dat" set "$k" "$v" || echo "mtwifi: datconf set $k failed"
	done
	"$MTWIFI_WIFI" down "$r_devname"
	"$MTWIFI_WIFI" up "$r_devname"

	local p
	for p in $m_vifs; do
		wireless_add_vif "${p%%=*}" "${p#*=}"
	done
	wireless_set_up
}

drv_mtwifi_teardown() {
	local main_ifname
	json_select config
	json_get_vars main_ifname
	json_select ..
	main_ifname="${main_ifname:-$1}"
	radio_load "$main_ifname" || return 0
	"$MTWIFI_WIFI" down "$r_devname"
}

add_driver mtwifi
