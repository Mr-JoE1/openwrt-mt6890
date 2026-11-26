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
proto setup wan '{"apn":"du","plmn":"42403","auto_conf":0,"sim":1,"metric":10}'
rc=$?
check "setup: rc 0" [ "$rc" -eq 0 ]
check "setup: prints ifname line" has "$T/out" "ifname ccmni3"
check "setup: prints metric" has "$T/out" "metric 10"
check "setup: prints dns" has "$T/out" "dns 94.200.200.200 94.200.200.201 2001:db8::53"
check "setup: radio check argv" has "$MOCK_MIPC_LOG" "--nw_radio_state_get | 0"
check "setup: check_ia argv" has "$MOCK_MIPC_LOG" "--check_ia | du | 0 | 3 | 3 |  |  | 0 | 0xfffdffff"
check "setup: primary deact_apn argv" has "$MOCK_MIPC_LOG" "--data_call_deact_apn | du"
act="$(grep -F -- '--data_call_act' "$MOCK_MIPC_LOG")"
check "setup: data_call_act single JSON arg" \
	[ "$act" = '--data_call_act | { "apn": "du", "ip_type": 3, "roaming_type": 3, "auth_type": 0, "username": "", "password": "", "bearer_bitmask": "0xfffdffff", "mtu": 1500, "mode": 1 }' ]
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
proto setup wan2 '{"apn":"uenms","iaapn":"etisalat.ae","vlan":2,"auto_conf":1}'
check "alias: rc 0" [ $? -eq 0 ]
check "alias: state pdn=2 from vlan" has "$T/state/mtkmipc-wan2.state" "pdn=2"
check "alias: secondary skips deact_apn" hasnt "$MOCK_MIPC_LOG" "--data_call_deact_apn"
check "alias: secondary forces auto_conf=0" hasnt "$MOCK_MIPC_LOG" "--apn_provision_by_sim"
check "alias: iaapn used for check_ia" has "$MOCK_MIPC_LOG" "--check_ia | etisalat.ae |"
check "alias: ifname ccmni5" has "$T/out" "ifname ccmni5"
reset
proto setup wan3 '{"apn":"x","vlan":2,"pdn":1}'
check "alias: pdn wins over vlan" has "$T/state/mtkmipc-wan3.state" "pdn=1"
proto teardown wan3 '{}'

# --- 4. teardown releases only the saved CID ---
reset
proto teardown wan '{"apn":"du"}'
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
proto setup wan '{"apn":"du","auto_conf":0,"retry":2}'
rc=$?
check "fail: rc != 0" [ "$rc" -ne 0 ]
check "fail: retried retry=2 times" [ "$(grep -cF -- '--data_call_act' "$MOCK_MIPC_LOG")" -eq 2 ]
check "fail: no ifname line" hasnt "$T/out" "ifname"
check "fail: no state file" [ ! -f "$T/state/mtkmipc-wan.state" ]
check "fail: error notified" has "$MOCK_UBUS_LOG" "CONNECT_FAILED_RETRY_LATER"
export MOCK_MIPC_ACT=ok

# --- 6. SIM not ready / invalid sim ---
reset
MOCK_MIPC_SIM=MIPC_SIM_STATUS_SIM_PIN proto setup wan '{"apn":"du","auto_conf":0}'
check "sim pin: rc != 0" [ $? -ne 0 ]
check "sim pin: error" has "$MOCK_UBUS_LOG" "SIM_PIN_LOCKED"
check "sim pin: no data call" hasnt "$MOCK_MIPC_LOG" "--data_call_act"
reset
proto setup wan '{"apn":"du","sim":7}'
check "invalid sim: rc != 0" [ $? -ne 0 ]
check "invalid sim: no mipc call" [ ! -s "$MOCK_MIPC_LOG" ]

# --- 7. auto APN provisioning fills an empty APN ---
reset
MOCK_MIPC_PROV='{"apn":"du","auth_type":"0","user":"","password":"","protocol":"3","iaapn":"du","rattype":"0","plmn":"42403"}' \
	proto setup wan '{"plmn":"42403"}'
check "autoapn: rc 0" [ $? -eq 0 ]
check "autoapn: provisioning called" has "$MOCK_MIPC_LOG" "--apn_provision_by_sim"
check "autoapn: apn from SIM db" has "$MOCK_MIPC_LOG" '"apn": "du"'
proto teardown wan '{}'

# --- 8. lock file used ---
check "flock: lock file created" [ -e "$MTKMIPC_LOCK" ]

# --- 9. apn-wan-setup.sh: boot-time WAN creation guards (issue #2) ---
APN="$PKG/files/lib/mt6890/apn-wan-setup.sh"
APNBIN="$T/apnbin"
APN_NET="$T/apn/network"
MOCK_UCI_LOG="$T/apn-uci.log"
MOCK_SERVICE_LOG="$T/apn-service.log"
MOCK_APN_LOG="$T/apn-logger.log"
mkdir -p "$APNBIN" "$(dirname "$APN_NET")"

# stubs on a private PATH (proto tests above are unaffected):
#   uci      -q get <selector> answers from MOCK_UCI_AUTOADAPT/_PROTO/_AUTOCONF
#             (empty = option unset); `uci batch` records its stdin
#   service  records "network restart"
#   hexdump  one canned line, MOCK_HEXDUMP_LINE (field 6 = meta flag)
#   logger   records every call (tag must be mt6890-apn)
cat > "$APNBIN/uci" <<'EOF'
#!/bin/sh
if [ "${2:-}" = get ]; then
	if [ "$3" = "system.@system[0].ql_wan_lan_auto_adapt" ]; then
		[ -n "${MOCK_UCI_AUTOADAPT:-}" ] && echo "$MOCK_UCI_AUTOADAPT"
	elif [ "$3" = "network.wan.proto" ]; then
		[ -n "${MOCK_UCI_PROTO:-}" ] && echo "$MOCK_UCI_PROTO"
	elif [ "$3" = "network.wan.auto_conf" ]; then
		[ -n "${MOCK_UCI_AUTOCONF:-}" ] && echo "$MOCK_UCI_AUTOCONF"
	elif [ "$3" = "network.wan" ] || [ "$3" = "network.wan6" ]; then
		[ -n "${MOCK_UCI_HAVE_WAN:-}" ] && echo interface
	fi
	exit 0
fi
# sequence log: every non-get call, in order ("batch" for uci batch)
if [ "${1:-}" = batch ]; then
	echo batch >> "${MOCK_UCI_SEQ:-/dev/null}"
	cat >> "${MOCK_UCI_LOG:-/dev/null}"
else
	echo "$*" >> "${MOCK_UCI_SEQ:-/dev/null}"
fi
exit 0
EOF
cat > "$APNBIN/service" <<'EOF'
#!/bin/sh
echo "$*" >> "${MOCK_SERVICE_LOG:-/dev/null}"
exit 0
EOF
cat > "$APNBIN/hexdump" <<'EOF'
#!/bin/sh
echo "${MOCK_HEXDUMP_LINE:-0000000 0000 0000 0000 0000 0000 0000 0000 0000}"
exit 0
EOF
cat > "$APNBIN/logger" <<'EOF'
#!/bin/sh
echo "$*" >> "${MOCK_APN_LOG:-/dev/null}"
exit 0
EOF
chmod +x "$APNBIN/uci" "$APNBIN/service" "$APNBIN/hexdump" "$APNBIN/logger"
MOCK_UCI_SEQ="$T/apn-uci-seq.log"
MOCK_MDINIT_LOG="$T/apn-mdinit.log"
# ccci_mdinit stub: records argv; MOCK_MDINIT_RADIO_ON=1 -> MD comes up
# (the mock CLI then reports radio ON via MOCK_MIPC_RADIO_FILE)
cat > "$APNBIN/ccci_mdinit" <<'EOF'
#!/bin/sh
echo "$*" >> "${MOCK_MDINIT_LOG:-/dev/null}"
[ -n "${MOCK_MDINIT_RADIO_ON:-}" ] && echo ON > "$MOCK_MIPC_RADIO_FILE"
exit 0
EOF
chmod +x "$APNBIN/ccci_mdinit"
export MOCK_UCI_LOG MOCK_SERVICE_LOG MOCK_APN_LOG MOCK_UCI_SEQ MOCK_MDINIT_LOG
export MOCK_MIPC_RADIO_FILE="$T/apn-radio"
export MOCK_UCI_AUTOADAPT= MOCK_UCI_PROTO= MOCK_UCI_AUTOCONF= MOCK_HEXDUMP_LINE=
export MOCK_UCI_HAVE_WAN= MOCK_MDINIT_RADIO_ON=

apn_reset() {
	: > "$MOCK_UCI_LOG"; : > "$MOCK_SERVICE_LOG"; : > "$MOCK_APN_LOG"
	: > "$MOCK_UCI_SEQ"; : > "$MOCK_MDINIT_LOG"; : > "$MOCK_MIPC_LOG"
	rm -f "$MOCK_MIPC_RADIO_FILE"
	printf 'config interface "loopback"\n' > "$APN_NET"
	export MOCK_UCI_AUTOADAPT= MOCK_UCI_PROTO= MOCK_UCI_AUTOCONF= MOCK_HEXDUMP_LINE=
	export MOCK_UCI_HAVE_WAN= MOCK_MDINIT_RADIO_ON= MOCK_MIPC_HANG=
}
apn_run() { # apn_run [dt_node] (default: node does not exist); bounded
	( PATH="$APNBIN:$PATH" \
	  MTKMIPC_NETWORK_CFG="$APN_NET" \
	  MTKMIPC_DT_BOOT="${1:-$T/apn/no-such-dt-node}" \
	  MTKMIPC_MDINIT="$APNBIN/ccci_mdinit" \
	  MTKMIPC_MDINIT_SLEEP="${APN_MDINIT_SLEEP:-0}" \
	  timeout 120 sh "$APN" ) > "$T/apn-out" 2> "$T/apn-err"
}

# meta boot mode: atag,boot hexdump field 6 == 0001 -> skip (guard 1)
apn_reset
export MOCK_HEXDUMP_LINE="0000000 0000 0000 0000 0000 0001"
apn_run "$APN_NET"
rc=$?
check "apn meta: rc 0" [ "$rc" -eq 0 ]
check "apn meta: no uci batch" [ ! -s "$MOCK_UCI_LOG" ]
check "apn meta: no network restart" [ ! -s "$MOCK_SERVICE_LOG" ]
check "apn meta: logged skip" has "$MOCK_APN_LOG" "mt6890-apn"

# /etc/config/network empty -> skip (guard 2)
apn_reset
: > "$APN_NET"
apn_run
rc=$?
check "apn empty cfg: rc 0" [ "$rc" -eq 0 ]
check "apn empty cfg: no uci batch" [ ! -s "$MOCK_UCI_LOG" ]
check "apn empty cfg: logged skip" has "$MOCK_APN_LOG" "mt6890-apn"

# stock ql_wan_lan_auto_adapt=1 -> skip (guard 3)
apn_reset
export MOCK_UCI_AUTOADAPT=1
apn_run
rc=$?
check "apn autoadapt: rc 0" [ "$rc" -eq 0 ]
check "apn autoadapt: no uci batch" [ ! -s "$MOCK_UCI_LOG" ]
check "apn autoadapt: no network restart" [ ! -s "$MOCK_SERVICE_LOG" ]
check "apn autoadapt: logged skip" has "$MOCK_APN_LOG" "mt6890-apn"

# WAN proto already mipc/ql_mipc/mtkmipc -> skip (guard 4)
for p in mtkmipc ql_mipc mipc; do
	apn_reset
	export MOCK_UCI_PROTO="$p"
	apn_run
	rc=$?
	check "apn proto=$p: rc 0" [ "$rc" -eq 0 ]
	check "apn proto=$p: no uci batch" [ ! -s "$MOCK_UCI_LOG" ]
	check "apn proto=$p: no network restart" [ ! -s "$MOCK_SERVICE_LOG" ]
done

# auto_conf=0 -> skip (guard 5)
apn_reset
export MOCK_UCI_AUTOCONF=0
apn_run
rc=$?
check "apn auto_conf=0: rc 0" [ "$rc" -eq 0 ]
check "apn auto_conf=0: no uci batch" [ ! -s "$MOCK_UCI_LOG" ]
check "apn auto_conf=0: logged skip" has "$MOCK_APN_LOG" "mt6890-apn"

# fresh config (auto_conf unset = default 1), DT node present, not meta:
# minimal batch + service network restart
apn_reset
apn_run "$APN_NET"
rc=$?
check "apn fresh: rc 0" [ "$rc" -eq 0 ]
check "apn fresh: batch sets proto" has "$MOCK_UCI_LOG" "set network.wan.proto='mtkmipc'"
check "apn fresh: batch sets ifname" has "$MOCK_UCI_LOG" "set network.wan.ifname='ccmni'"
check "apn fresh: batch sets wan6 ifname" has "$MOCK_UCI_LOG" "set network.wan6.ifname='ccmni'"
check "apn fresh: batch commits" has "$MOCK_UCI_LOG" "commit network"
check "apn fresh: batch is exactly 4 lines" [ "$(grep -c . "$MOCK_UCI_LOG")" -eq 4 ]
check "apn fresh: no apn/auth fields cached" hasnt "$MOCK_UCI_LOG" "network.wan.apn"
check "apn fresh: service network restart" [ "$(cat "$MOCK_SERVICE_LOG")" = "network restart" ]
check "apn fresh: logged success" has "$MOCK_APN_LOG" "mt6890-apn"
check "apn fresh: no stderr noise" [ ! -s "$T/apn-err" ]

# non-MIPC proto: stock semantics replace it (only mipc protos are kept)
apn_reset
export MOCK_UCI_PROTO=dhcp
apn_run
rc=$?
check "apn proto=dhcp: rc 0" [ "$rc" -eq 0 ]
check "apn proto=dhcp: uci batch written" has "$MOCK_UCI_LOG" "set network.wan.proto='mtkmipc'"

# v3.1 D1: no wan/wan6 sections (device default) -> created before the batch
apn_reset
apn_run
rc=$?
seq1="$(sed -n 1p "$MOCK_UCI_SEQ")"; seq2="$(sed -n 2p "$MOCK_UCI_SEQ")"; seq3="$(sed -n 3p "$MOCK_UCI_SEQ")"
check "apn no-wan: rc 0" [ "$rc" -eq 0 ]
check "apn no-wan: 1st creates network.wan" [ "$seq1" = "-q set network.wan=interface" ]
check "apn no-wan: 2nd creates network.wan6" [ "$seq2" = "-q set network.wan6=interface" ]
check "apn no-wan: batch only after both exist" [ "$seq3" = "batch" ]
check "apn no-wan: batch sets proto" has "$MOCK_UCI_LOG" "set network.wan.proto='mtkmipc'"

# v3.1 D1: sections already present -> not re-created
apn_reset
export MOCK_UCI_HAVE_WAN=1
apn_run
check "apn have-wan: rc 0" [ $? -eq 0 ]
check "apn have-wan: only the batch" [ "$(cat "$MOCK_UCI_SEQ")" = "batch" ]

# v3.1 D2: radio ON -> health gate passes, no MD re-trigger
apn_reset
apn_run
check "apn gate on: radio state queried" has "$MOCK_MIPC_LOG" "--nw_radio_state_get | 0"
check "apn gate on: no ccci_mdinit" [ ! -s "$MOCK_MDINIT_LOG" ]

# v3.1 D2: radio OFF, MD comes back after re-trigger -> stop polling early
apn_reset
export MOCK_MIPC_RADIO=OFF MOCK_MDINIT_RADIO_ON=1
# 1 s poll: ccci_mdinit is backgrounded, give the stub time to "bring up" the MD
APN_MDINIT_SLEEP=1 apn_run
rc=$?
check "apn gate recover: rc 0" [ "$rc" -eq 0 ]
check "apn gate recover: ccci_mdinit 0 called" [ "$(cat "$MOCK_MDINIT_LOG")" = "0" ]
check "apn gate recover: logged re-trigger" has "$MOCK_APN_LOG" "re-triggering cci_mdinit"
check "apn gate recover: 2 radio queries (1 + 1 poll)" \
	[ "$(grep -cF -- '--nw_radio_state_get' "$MOCK_MIPC_LOG")" -eq 2 ]
check "apn gate recover: no still-off log" eval "! grep -qF 'still off' '$MOCK_APN_LOG'"
check "apn gate recover: wan created" has "$MOCK_UCI_LOG" "set network.wan.proto='mtkmipc'"

# v3.1 D2: radio stays OFF -> bounded 6 polls, logged, boot continues
apn_reset
export MOCK_MIPC_RADIO=OFF
apn_run
rc=$?
check "apn gate dead: rc 0" [ "$rc" -eq 0 ]
check "apn gate dead: 1 + 6 radio queries" \
	[ "$(grep -cF -- '--nw_radio_state_get' "$MOCK_MIPC_LOG")" -eq 7 ]
check "apn gate dead: logged still off" has "$MOCK_APN_LOG" "radio still off after re-trigger; continuing boot"
check "apn gate dead: wan still created" has "$MOCK_UCI_LOG" "set network.wan.proto='mtkmipc'"
check "apn gate dead: network restart" [ "$(cat "$MOCK_SERVICE_LOG")" = "network restart" ]

# v3.1 D2: MIPC server down (CLI hangs) -> every gate call watchdog-capped
apn_reset
export MOCK_MIPC_RADIO= MOCK_MIPC_HANG=1
export MTKMIPC_CLI_TIMEOUT=1
t0=$(date +%s)
apn_run
rc=$?
el=$(( $(date +%s) - t0 ))
unset MTKMIPC_CLI_TIMEOUT
export MOCK_MIPC_HANG=
check "apn gate hang: rc 0 (not killed by outer timeout)" [ "$rc" -eq 0 ]
check "apn gate hang: bounded (<60 s, took ${el}s)" [ "$el" -lt 60 ]
check "apn gate hang: watchdog logged" has "$MOCK_APN_LOG" "-t mtkmipc-wd"
check "apn gate hang: ccci_mdinit re-triggered" [ "$(cat "$MOCK_MDINIT_LOG")" = "0" ]
check "apn gate hang: wan still created" has "$MOCK_UCI_LOG" "set network.wan.proto='mtkmipc'"
export MOCK_MIPC_RADIO=

# --- 10. hanging mipc_wan_cli (MIPC server down): watchdog (v3.1 C) ---
# Separate script (own scratch root, bounded by host `timeout`); its
# per-check results are folded into this suite's totals.
PROTO_SHELL="$PROTO_SHELL" OPENWRT_TOP="$TOP" sh "$HERE/hang-cli.sh" > "$T/hang.out" 2>&1
grep -E '^\[(PASS|FAIL)\] ' "$T/hang.out"
hp="$(sed -n 's/^RESULT: \([0-9]*\) passed, \([0-9]*\) failed$/\1/p' "$T/hang.out")"
hf="$(sed -n 's/^RESULT: \([0-9]*\) passed, \([0-9]*\) failed$/\2/p' "$T/hang.out")"
if [ -n "$hp" ] && [ -n "$hf" ]; then
	PASS=$((PASS + hp)); FAIL=$((FAIL + hf))
else
	bad "hang-cli.sh: no RESULT line"; cat "$T/hang.out"
fi

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
