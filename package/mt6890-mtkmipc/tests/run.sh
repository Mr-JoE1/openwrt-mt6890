#!/bin/sh
# Host tests for the mtkmipc netifd proto. POSIX sh; no root, no network.
#
# The proto itself is run the way netifd runs it:
#   <proto.sh> mtkmipc setup|teardown <interface> '<config json>' '<ifname>'
# from inside lib/netifd/proto/ of a scratch root, using the real
# netifd-proto.sh/utils.sh from the staging dir and the host jshn.
# PROTO_SHELL: shell to run the proto with (jshn.sh needs ash/bash, not dash).

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PKG="$(cd "$HERE/.." && pwd)"
TOP="${OPENWRT_TOP:-$(cd "$PKG/../.." && pwd)}"
PROTO="$PKG/files/lib/netifd/proto/mtkmipc.sh"

if [ -z "${PROTO_SHELL:-}" ]; then
	if command -v busybox >/dev/null 2>&1; then PROTO_SHELL="busybox ash"
	else PROTO_SHELL=bash; fi
fi

JSHN_SH="$TOP/staging_dir/host/share/libubox/jshn.sh"
NETIFD_SRC="$(ls -d "$TOP"/staging_dir/target-*/root-*/lib/netifd 2>/dev/null | head -n1)"
[ -f "$JSHN_SH" ] && [ -x "$TOP/staging_dir/host/bin/jshn" ] || { echo "missing host jshn"; exit 2; }
[ -f "$NETIFD_SRC/netifd-proto.sh" ] || { echo "missing netifd-proto.sh in staging"; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/mtkmipc-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT INT TERM

# scratch root
mkdir -p "$T/root/lib/netifd/proto" "$T/bin" "$T/state"
sed "s|/usr/share/libubox/jshn.sh|$JSHN_SH|" "$NETIFD_SRC/netifd-proto.sh" \
	> "$T/root/lib/netifd/netifd-proto.sh"
cp "$NETIFD_SRC/utils.sh" "$T/root/lib/netifd/utils.sh"
cp "$PROTO" "$T/root/lib/netifd/proto/mtkmipc.sh"
cp "$HERE/mock-mipc_wan_cli" "$T/bin/mipc_wan_cli"
chmod +x "$T/bin/mipc_wan_cli"
# ubus stub: record notify_proto payloads
cat > "$T/bin/ubus" <<'EOF'
#!/bin/sh
for a in "$@"; do last="$a"; done
echo "$last" >> "$MOCK_UBUS_LOG"
EOF
printf '#!/bin/sh\nexit 0\n' > "$T/bin/logger"
chmod +x "$T/bin/ubus" "$T/bin/logger"

export PATH="$T/bin:$TOP/staging_dir/host/bin:$PATH"
export NETIFD_MAIN_DIR="$T/root/lib/netifd"
export MTKMIPC_LOCK="$T/mtkmipc.lock" MTKMIPC_STATEDIR="$T/state"
export MOCK_MIPC_LOG="$T/argv.log" MOCK_UBUS_LOG="$T/ubus.log"
export MTKMIPC_RETRY_SLEEP=0

PASS=0 FAIL=0
ok()   { PASS=$((PASS + 1)); echo "[PASS] $*"; }
bad()  { FAIL=$((FAIL + 1)); echo "[FAIL] $*"; }
check() { # check <desc> <cmd...>
	d="$1"; shift
	if "$@"; then ok "$d"; else bad "$d"; fi
}
has()   { grep -qF -- "$2" "$1"; }
hasnt() { ! grep -qF -- "$2" "$1"; }

proto() { # proto <cmd> <iface> <json> -> stdout in $T/out
	( cd "$T/root/lib/netifd/proto" && \
	  $PROTO_SHELL ./mtkmipc.sh mtkmipc "$1" "$2" "$3" "" ) > "$T/out" 2> "$T/err"
}
reset() { : > "$MOCK_MIPC_LOG"; : > "$MOCK_UBUS_LOG"; }

echo "PROTO_SHELL=$PROTO_SHELL"

# --- dump (netifd probes the handler) ---
( cd "$T/root/lib/netifd/proto" && $PROTO_SHELL ./mtkmipc.sh mtkmipc dump ) > "$T/out" 2>"$T/err"
check "dump: name mtkmipc" has "$T/out" '"name": "mtkmipc"'
check "dump: pdn option" has "$T/out" '"pdn"'
check "dump: vlan option (stock)" has "$T/out" '"vlan"'
check "dump: sim option" has "$T/out" '"sim"'

# --- 1. setup, primary PDN ---
reset
export MOCK_MIPC_ACT=ok MOCK_MIPC_CID=3
proto setup wan '{"apn":"apn1.example","plmn":"00101","auto_conf":0,"sim":1,"metric":10}'
rc=$?
check "setup: rc 0" [ "$rc" -eq 0 ]
check "setup: prints ifname line" has "$T/out" "ifname ccmni3"
check "setup: prints metric" has "$T/out" "metric 10"
check "setup: prints dns" has "$T/out" "dns 94.200.200.200 94.200.200.201 2001:db8::53"
check "setup: radio check argv" has "$MOCK_MIPC_LOG" "--nw_radio_state_get | 0"
check "setup: check_ia argv" has "$MOCK_MIPC_LOG" "--check_ia | apn1.example | 0 | 3 | 3 |  |  | 0 | 0xfffdffff"
check "setup: primary deact_apn argv" has "$MOCK_MIPC_LOG" "--data_call_deact_apn | apn1.example"
act="$(grep -F -- '--data_call_act' "$MOCK_MIPC_LOG")"
check "setup: data_call_act single JSON arg" \
	[ "$act" = '--data_call_act | { "apn": "apn1.example", "ip_type": 3, "roaming_type": 3, "auth_type": 0, "username": "", "password": "", "bearer_bitmask": "0xfffdffff", "mtu": 1500, "mode": 1 }' ]
check "setup: no apn provisioning when auto_conf=0" hasnt "$MOCK_MIPC_LOG" "--apn_provision_by_sim"
check "setup: state file" [ -f "$T/state/mtkmipc-wan.state" ]
check "setup: state cid=3" has "$T/state/mtkmipc-wan.state" "cid=3"
check "setup: state pdn=0" has "$T/state/mtkmipc-wan.state" "pdn=0"
check "setup: notify ifname" has "$MOCK_UBUS_LOG" '"ifname": "ccmni3"'
check "setup: notify ipv4" has "$MOCK_UBUS_LOG" '"ipaddr": "10.20.30.40"'
check "setup: notify data.cid" has "$MOCK_UBUS_LOG" '"cid": "3"'

# --- 2. status ---
( cd "$T/root/lib/netifd/proto" && $PROTO_SHELL ./mtkmipc.sh mtkmipc status wan ) > "$T/out" 2>&1
check "status: cid" has "$T/out" "cid 3"
check "status: ifname" has "$T/out" "ifname ccmni3"
check "status: state up" has "$T/out" "state up"

# --- 3. vlan -> pdn alias (second interface, secondary PDN) ---
reset
export MOCK_MIPC_CID=5
proto setup wan2 '{"apn":"apn2.example","iaapn":"ia.apn2.example","vlan":2,"auto_conf":1}'
check "alias: rc 0" [ $? -eq 0 ]
check "alias: state pdn=2 from vlan" has "$T/state/mtkmipc-wan2.state" "pdn=2"
check "alias: secondary skips deact_apn" hasnt "$MOCK_MIPC_LOG" "--data_call_deact_apn"
check "alias: secondary forces auto_conf=0" hasnt "$MOCK_MIPC_LOG" "--apn_provision_by_sim"
check "alias: iaapn used for check_ia" has "$MOCK_MIPC_LOG" "--check_ia | ia.apn2.example |"
check "alias: ifname ccmni5" has "$T/out" "ifname ccmni5"
reset
proto setup wan3 '{"apn":"x","vlan":2,"pdn":1}'
check "alias: pdn wins over vlan" has "$T/state/mtkmipc-wan3.state" "pdn=1"
proto teardown wan3 '{}'

# --- 4. teardown releases only the saved CID ---
reset
proto teardown wan '{"apn":"apn1.example"}'
check "teardown: rc 0" [ $? -eq 0 ]
check "teardown: deact argv = saved cid" [ "$(cat "$MOCK_MIPC_LOG")" = "--data_call_deact | 3" ]
check "teardown: state removed" [ ! -f "$T/state/mtkmipc-wan.state" ]
check "teardown: wan2 state untouched" has "$T/state/mtkmipc-wan2.state" "cid=5"
check "teardown: link-down notify" has "$MOCK_UBUS_LOG" '"link-up": false'
reset
proto teardown wan '{}'
check "teardown again: no mipc call" [ ! -s "$MOCK_MIPC_LOG" ]
( cd "$T/root/lib/netifd/proto" && $PROTO_SHELL ./mtkmipc.sh mtkmipc status wan ) > "$T/out" 2>&1
check "status after teardown: down" has "$T/out" "state down"
reset
proto teardown wan2 '{}'
check "teardown wan2: deact cid 5" [ "$(cat "$MOCK_MIPC_LOG")" = "--data_call_deact | 5" ]

# --- 5. failure case ---
reset
export MOCK_MIPC_ACT=fail
proto setup wan '{"apn":"apn1.example","auto_conf":0,"retry":2}'
rc=$?
check "fail: rc != 0" [ "$rc" -ne 0 ]
check "fail: retried retry=2 times" [ "$(grep -cF -- '--data_call_act' "$MOCK_MIPC_LOG")" -eq 2 ]
check "fail: no ifname line" hasnt "$T/out" "ifname"
check "fail: no state file" [ ! -f "$T/state/mtkmipc-wan.state" ]
check "fail: error notified" has "$MOCK_UBUS_LOG" "CONNECT_FAILED_RETRY_LATER"
export MOCK_MIPC_ACT=ok

# --- 6. SIM not ready / invalid sim ---
reset
MOCK_MIPC_SIM=MIPC_SIM_STATUS_SIM_PIN proto setup wan '{"apn":"apn1.example","auto_conf":0}'
check "sim pin: rc != 0" [ $? -ne 0 ]
check "sim pin: error" has "$MOCK_UBUS_LOG" "SIM_PIN_LOCKED"
check "sim pin: no data call" hasnt "$MOCK_MIPC_LOG" "--data_call_act"
reset
proto setup wan '{"apn":"apn1.example","sim":7}'
check "invalid sim: rc != 0" [ $? -ne 0 ]
check "invalid sim: no mipc call" [ ! -s "$MOCK_MIPC_LOG" ]

# --- 7. auto APN provisioning fills an empty APN ---
reset
MOCK_MIPC_PROV='{"apn":"apn1.example","auth_type":"0","user":"","password":"","protocol":"3","iaapn":"apn1.example","rattype":"0","plmn":"00101"}' \
	proto setup wan '{"plmn":"00101"}'
check "autoapn: rc 0" [ $? -eq 0 ]
check "autoapn: provisioning called" has "$MOCK_MIPC_LOG" "--apn_provision_by_sim"
check "autoapn: apn from SIM db" has "$MOCK_MIPC_LOG" '"apn": "apn1.example"'
proto teardown wan '{}'

# --- 8. lock file used ---
check "flock: lock file created" [ -e "$MTKMIPC_LOCK" ]

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
