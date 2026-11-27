#!/bin/sh
# Host tests for the mtwifi netifd wireless handler. POSIX sh; no root, no
# network, no vendor bytes (synthetic l1profile/.dat built below).
#
# The handler is run the way netifd runs it:
#   mtwifi.sh mtwifi setup|teardown <device> '<json>'      and   '' dump
# with the real netifd-wireless.sh (wifi-scripts) + utils.sh (staging) and the
# host jshn. Mocks: datconf (argv + edits the fake .dat), /sbin/wifi (argv +
# toggles fake sysfs flags), ubus (records network.wireless notify payloads).
# DRV_SHELL: shell to run the handler with (jshn.sh needs ash/bash, not dash).

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PKG="$(cd "$HERE/.." && pwd)"
TOP="${OPENWRT_TOP:-$(cd "$PKG/../.." && pwd)}"
DRV="$PKG/files/lib/netifd/wireless/mtwifi.sh"

if [ -z "${DRV_SHELL:-}" ]; then
	if command -v busybox >/dev/null 2>&1; then DRV_SHELL="busybox ash"
	else DRV_SHELL=bash; fi
fi

JSHN_SH="$TOP/staging_dir/host/share/libubox/jshn.sh"
WLSH="$TOP/package/network/config/wifi-scripts/files/lib/netifd/netifd-wireless.sh"
UTILS="$(ls "$TOP"/staging_dir/target-*/root-*/lib/netifd/utils.sh 2>/dev/null | head -n1)"
[ -f "$JSHN_SH" ] && [ -x "$TOP/staging_dir/host/bin/jshn" ] || { echo "missing host jshn"; exit 2; }
[ -f "$WLSH" ] || { echo "missing netifd-wireless.sh"; exit 2; }
[ -f "$UTILS" ] || { echo "missing netifd utils.sh in staging"; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/mtwifi-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT INT TERM

mkdir -p "$T/root/lib/netifd/wireless" "$T/bin" "$T/wl/mediatek" "$T/sys/ra0" "$T/sys/rai0"
sed "s|/usr/share/libubox/jshn.sh|$JSHN_SH|" "$WLSH" > "$T/root/lib/netifd/netifd-wireless.sh"
cp "$UTILS" "$T/root/lib/netifd/utils.sh"
cp "$DRV" "$T/root/lib/netifd/wireless/mtwifi.sh"
cp "$HERE/mock-datconf" "$T/bin/datconf"
cp "$HERE/mock-wifi" "$T/bin/wifi"
cat > "$T/bin/ubus" <<'EOF'
#!/bin/sh
for a in "$@"; do last="$a"; done
echo "$last" >> "$MOCK_UBUS_LOG"
EOF
chmod +x "$T/bin/datconf" "$T/bin/wifi" "$T/bin/ubus"

# synthetic l1profile, same keys/shape as the stock MT7915D DBDC one
cat > "$T/wl/l1profile.dat" <<EOF
Default
INDEX0=MT7915D
INDEX0_profile_path=$T/wl/mediatek/b0.dat;$T/wl/mediatek/b1.dat
INDEX0_init_script=/lib/wifi/mt7615e.lua;/lib/wifi/mt7615e.lua
INDEX0_init_compatible=mt7615e;mt7615e
INDEX0_main_ifname=ra0;rai0
INDEX0_ext_ifname=ra;rai
INDEX0_apcli_ifname=apcli;apclii
EOF
mkdat() { # <file> <WirelessMode> <Channel> <ssid>
	cat > "$1" <<EOF
Default
AuthMode=OPEN
AutoChannelSelect=0
BssidNum=1
Channel=$3
CountryCode=US
EncrypType=NONE
HideSSID=0
HT_BW=1
NoForwarding=0
SSID1=$4
VHT_BW=0
WirelessMode=$2
WPAPSK1=
EOF
}
reset_state() {
	mkdat "$T/wl/mediatek/b0.dat" 16 6 tmpl24
	mkdat "$T/wl/mediatek/b1.dat" 17 36 tmpl5
	echo 0x1002 > "$T/sys/ra0/flags"
	echo 0x1002 > "$T/sys/rai0/flags"
	: > "$MOCK_DATCONF_LOG"; : > "$MOCK_WIFI_LOG"; : > "$MOCK_UBUS_LOG"
}

export PATH="$T/bin:$TOP/staging_dir/host/bin:$PATH"
export NETIFD_MAIN_DIR="$T/root/lib/netifd"
export MTWIFI_L1PROFILE="$T/wl/l1profile.dat" MTWIFI_SYSNET="$T/sys"
export MTWIFI_WIFI="$T/bin/wifi" MTWIFI_DATCONF="$T/bin/datconf"
export MOCK_DATCONF_LOG="$T/datconf.log" MOCK_WIFI_LOG="$T/wifi.log" MOCK_UBUS_LOG="$T/ubus.log"

PASS=0 FAIL=0
ok()   { PASS=$((PASS + 1)); echo "[PASS] $*"; }
bad()  { FAIL=$((FAIL + 1)); echo "[FAIL] $*"; }
check() { d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
has()   { grep -qF -- "$2" "$1"; }
hasnt() { ! grep -qF -- "$2" "$1"; }
empty() { [ ! -s "$1" ]; }

drv() { # drv <setup|teardown> <device> <json>
	(cd "$T/root/lib/netifd/wireless" && $DRV_SHELL ./mtwifi.sh mtwifi "$@") > "$T/out" 2>&1
}
# json <device-config> <iface-config> [<iface2-config>]
json() {
	if [ $# -ge 3 ]; then
		printf '{"config":{%s},"interfaces":{"0":{"config":{%s}},"1":{"config":{%s}}}}' "$1" "$2" "$3"
	else
		printf '{"config":{%s},"interfaces":{"0":{"config":{%s}}}}' "$1" "$2"
	fi
}

reset_state

# ---- dump: netifd handler registration
(cd "$T/root/lib/netifd/wireless" && $DRV_SHELL ./mtwifi.sh '' dump) > "$T/dump" 2>&1
check "dump: driver name mtwifi" has "$T/dump" '"name": "mtwifi"'
check "dump: device option main_ifname" has "$T/dump" '"main_ifname"'
check "dump: iface option hidden" has "$T/dump" '"hidden"'

# ---- detect lists both radios with the right band
$DRV_SHELL "$DRV" detect > "$T/detect" 2>&1
check "detect: ra0 wifi-device"  has "$T/detect" "config wifi-device 'ra0'"
check "detect: rai0 wifi-device" has "$T/detect" "config wifi-device 'rai0'"
check "detect: ra0 band 2g"  sh -c "grep -A3 \"wifi-device 'ra0'\" '$T/detect' | grep -q \"band '2g'\""
check "detect: rai0 band 5g" sh -c "grep -A3 \"wifi-device 'rai0'\" '$T/detect' | grep -q \"band '5g'\""
check "detect: type mtwifi x2" [ "$(grep -c "type 'mtwifi'" "$T/detect")" -eq 2 ]

# ---- up 2.4G: ssid+psk+channel to ra0's profile (b0) only
reset_state
drv setup ra0 "$(json '"main_ifname":"ra0","band":"2g","channel":"11","htmode":"HT20","country":"DE"' \
	'"mode":"ap","ssid":"DWR-2000M","encryption":"psk2","key":"secretpass1"')"
rc=$?
check "up ra0: rc 0" [ "$rc" -eq 0 ]
check "up ra0: SSID1 -> b0"    has "$MOCK_DATCONF_LOG" "datconf|-f|$T/wl/mediatek/b0.dat|set|SSID1|DWR-2000M"
check "up ra0: WPAPSK1 -> b0"  has "$MOCK_DATCONF_LOG" "datconf|-f|$T/wl/mediatek/b0.dat|set|WPAPSK1|secretpass1"
check "up ra0: Channel 11 -> b0" has "$MOCK_DATCONF_LOG" "datconf|-f|$T/wl/mediatek/b0.dat|set|Channel|11"
check "up ra0: AuthMode WPA2PSK" has "$MOCK_DATCONF_LOG" "b0.dat|set|AuthMode|WPA2PSK"
check "up ra0: EncrypType AES"   has "$MOCK_DATCONF_LOG" "b0.dat|set|EncrypType|AES"
check "up ra0: HT_BW 0 (HT20)"   has "$MOCK_DATCONF_LOG" "b0.dat|set|HT_BW|0"
check "up ra0: no VHT_BW on 2g"  hasnt "$MOCK_DATCONF_LOG" "VHT_BW"
check "up ra0: CountryCode DE"   has "$MOCK_DATCONF_LOG" "b0.dat|set|CountryCode|DE"
check "up ra0: 5G profile untouched" hasnt "$MOCK_DATCONF_LOG" "b1.dat"
check "up ra0: .dat really edited" has "$T/wl/mediatek/b0.dat" "SSID1=DWR-2000M"
check "up ra0: wifi down then up MT7915D.1.1" \
	[ "$(cat "$MOCK_WIFI_LOG")" = "wifi down MT7915D.1.1
wifi up MT7915D.1.1" ]
check "up ra0: ubus add vif ifname ra0" has "$MOCK_UBUS_LOG" '"ifname": "ra0"'
check "up ra0: ubus set_up (command 0)" has "$MOCK_UBUS_LOG" '"command": 0'
check "up ra0: sysfs flags up" [ "$(cat "$T/sys/ra0/flags")" = 0x1003 ]

# ---- up 5G with two BSS: second vif is rai1, per-BSS lists
reset_state
drv setup rai0 "$(json '"main_ifname":"rai0","band":"5g","channel":"100","htmode":"VHT80"' \
	'"mode":"ap","ssid":"DWR-2000M-5G","encryption":"psk2","key":"secretpass5"' \
	'"mode":"ap","ssid":"guest5","encryption":"none","hidden":"1"')"
rc=$?
check "up rai0: rc 0" [ "$rc" -eq 0 ]
check "up rai0: SSID1 -> b1"   has "$MOCK_DATCONF_LOG" "datconf|-f|$T/wl/mediatek/b1.dat|set|SSID1|DWR-2000M-5G"
check "up rai0: WPAPSK1 -> b1" has "$MOCK_DATCONF_LOG" "b1.dat|set|WPAPSK1|secretpass5"
check "up rai0: Channel 100"   has "$MOCK_DATCONF_LOG" "b1.dat|set|Channel|100"
check "up rai0: SSID2 guest5"  has "$MOCK_DATCONF_LOG" "b1.dat|set|SSID2|guest5"
check "up rai0: BssidNum 2"    has "$MOCK_DATCONF_LOG" "b1.dat|set|BssidNum|2"
check "up rai0: AuthMode list" has "$MOCK_DATCONF_LOG" "b1.dat|set|AuthMode|WPA2PSK;OPEN"
check "up rai0: EncrypType list" has "$MOCK_DATCONF_LOG" "b1.dat|set|EncrypType|AES;NONE"
check "up rai0: HideSSID list" has "$MOCK_DATCONF_LOG" "b1.dat|set|HideSSID|0;1"
check "up rai0: VHT_BW 1 (VHT80)" has "$MOCK_DATCONF_LOG" "b1.dat|set|VHT_BW|1"
check "up rai0: 2.4G profile untouched" hasnt "$MOCK_DATCONF_LOG" "b0.dat"
check "up rai0: no WPAPSK2 for open BSS" hasnt "$MOCK_DATCONF_LOG" "WPAPSK2"
check "up rai0: vif rai0 + rai1" sh -c "grep -qF '\"ifname\": \"rai0\"' '$MOCK_UBUS_LOG' && grep -qF '\"ifname\": \"rai1\"' '$MOCK_UBUS_LOG'"
check "up rai0: wifi up MT7915D.1.2" has "$MOCK_WIFI_LOG" "wifi up MT7915D.1.2"

# ---- auto channel
reset_state
drv setup ra0 "$(json '"main_ifname":"ra0","channel":"auto"' '"mode":"ap","ssid":"a","encryption":"none"')"
check "auto channel: AutoChannelSelect 3" has "$MOCK_DATCONF_LOG" "b0.dat|set|AutoChannelSelect|3"
check "auto channel: Channel 0" has "$MOCK_DATCONF_LOG" "b0.dat|set|Channel|0"

# ---- down
reset_state
echo 0x1003 > "$T/sys/rai0/flags"
drv teardown rai0 "$(json '"main_ifname":"rai0"' '"mode":"ap","ssid":"x"')"
check "down rai0: wifi down MT7915D.1.2 only" [ "$(cat "$MOCK_WIFI_LOG")" = "wifi down MT7915D.1.2" ]
check "down rai0: no profile writes" empty "$MOCK_DATCONF_LOG"
check "down rai0: sysfs flags down" [ "$(cat "$T/sys/rai0/flags")" = 0x1002 ]

# ---- status (canned sysfs + .dat)
reset_state
echo 0x1003 > "$T/sys/ra0/flags"
$DRV_SHELL "$DRV" status > "$T/status" 2>&1
check "status: ra0 up 2g ch6"   has "$T/status" "ra0 devname=MT7915D.1.1 band=2g state=up channel=6 ssid=tmpl24 auth=OPEN"
check "status: rai0 down 5g ch36" has "$T/status" "rai0 devname=MT7915D.1.2 band=5g state=down channel=36 ssid=tmpl5"

# ---- wrong-band option rejection (nothing applied, radio not bounced)
for case in \
	"band=2g on rai0|rai0|\"main_ifname\":\"rai0\",\"band\":\"2g\"|WRONG_BAND" \
	"band=5g on ra0|ra0|\"main_ifname\":\"ra0\",\"band\":\"5g\"|WRONG_BAND" \
	"channel 36 on ra0|ra0|\"main_ifname\":\"ra0\",\"channel\":\"36\"|WRONG_BAND_CHANNEL" \
	"channel 6 on rai0|rai0|\"main_ifname\":\"rai0\",\"channel\":\"6\"|WRONG_BAND_CHANNEL" \
	"VHT80 on ra0|ra0|\"main_ifname\":\"ra0\",\"htmode\":\"VHT80\"|WRONG_BAND_HTMODE"
do
	what="${case%%|*}"; r="${case#*|}"; dev="${r%%|*}"; r="${r#*|}"; cfg="${r%|*}"; err="${r##*|}"
	reset_state
	drv setup "$dev" "$(json "$cfg" '"mode":"ap","ssid":"x","encryption":"psk2","key":"secretpass1"')"
	rc=$?
	check "reject $what: rc!=0" [ "$rc" -ne 0 ]
	check "reject $what: $err reported" has "$T/out" "Device setup failed: $err"
	check "reject $what: no datconf"  empty "$MOCK_DATCONF_LOG"
	check "reject $what: no wifi up"  hasnt "$MOCK_WIFI_LOG" "wifi up"
done

# ---- other input validation
reset_state
drv setup ra0 "$(json '"main_ifname":"ra0"' '"mode":"ap","ssid":"x","encryption":"psk2","key":"short"')"
check "reject short psk: INVALID_KEY" has "$T/out" "Device setup failed: INVALID_KEY"
check "reject short psk: no datconf" empty "$MOCK_DATCONF_LOG"
reset_state
drv setup ra0 "$(json '"main_ifname":"ra0"' '"mode":"ap","ssid":"x","encryption":"wep-open","key":"12345"')"
check "reject wep: UNSUPPORTED_ENCRYPTION" has "$T/out" "Device setup failed: UNSUPPORTED_ENCRYPTION"
reset_state
rm -rf "$T/sys/ra0"
drv setup ra0 "$(json '"main_ifname":"ra0"' '"mode":"ap","ssid":"x"')"
check "missing ra0 netdev: IFNAME_MISSING" has "$T/out" "Device setup failed: IFNAME_MISSING"
mkdir -p "$T/sys/ra0"

# ---- shipped default UCI
U="$PKG/files/etc/config/wireless"
check "uci: two device sections type mtwifi" [ "$(grep -c "option type 'mtwifi'" "$U")" -eq 2 ]
check "uci: ra0 main_ifname"  has "$U" "option main_ifname 'ra0'"
check "uci: rai0 main_ifname" has "$U" "option main_ifname 'rai0'"
check "uci: no key in image"  hasnt "$U" "option key"

# ---- mt6890-wifi boot one-shot: bounded retry (v3.1.1 item 1); separate
# script, its per-check results are folded into this suite's totals
DRV_SHELL="$DRV_SHELL" OPENWRT_TOP="$TOP" sh "$HERE/wifi-boot.sh" > "$T/wifiboot.out" 2>&1
grep -E '^\[(PASS|FAIL)\] ' "$T/wifiboot.out"
wp="$(sed -n 's/^RESULT: \([0-9]*\) passed, \([0-9]*\) failed$/\1/p' "$T/wifiboot.out")"
wf="$(sed -n 's/^RESULT: \([0-9]*\) passed, \([0-9]*\) failed$/\2/p' "$T/wifiboot.out")"
if [ -n "$wp" ] && [ -n "$wf" ]; then
	PASS=$((PASS + wp)); FAIL=$((FAIL + wf))
else
	bad "wifi-boot.sh: no RESULT line"; cat "$T/wifiboot.out"
fi

echo "---"
echo "RESULT: $PASS passed, $FAIL failed (shell: $DRV_SHELL)"
[ "$FAIL" -eq 0 ]
