#!/bin/sh
# Regression test (v3.1 C): mipc_wan_cli hangs forever when the MIPC server
# is down; the proto must give up within MTKMIPC_CLI_TIMEOUT instead of
# wedging netifd. POSIX sh; no root, no network. Needs host `timeout`.
#
# Standalone (time it): OPENWRT_TOP=$PWD sh package/mt6890-mtkmipc/tests/hang-cli.sh
# Also run (and counted) by tests/run.sh.
#
# Every proto run is wrapped in `timeout $((MTKMIPC_CLI_TIMEOUT + 15))`, so
# without the watchdog the test FAILS bounded instead of hanging 300 s.

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PKG="$(cd "$HERE/.." && pwd)"
TOP="${OPENWRT_TOP:-$(cd "$PKG/../.." && pwd)}"
PROTO="$PKG/files/lib/netifd/proto/mtkmipc.sh"

if [ -z "${PROTO_SHELL:-}" ]; then
	if command -v busybox >/dev/null 2>&1; then PROTO_SHELL="busybox ash"
	else PROTO_SHELL=bash; fi
fi

command -v timeout >/dev/null 2>&1 || { echo "missing host timeout"; exit 2; }
JSHN_SH="$TOP/staging_dir/host/share/libubox/jshn.sh"
NETIFD_SRC="$(ls -d "$TOP"/staging_dir/target-*/root-*/lib/netifd 2>/dev/null | head -n1)"
[ -f "$JSHN_SH" ] && [ -x "$TOP/staging_dir/host/bin/jshn" ] || { echo "missing host jshn"; exit 2; }
[ -f "$NETIFD_SRC/netifd-proto.sh" ] || { echo "missing netifd-proto.sh in staging"; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/mtkmipc-hang.XXXXXX")"
MOCK_MIPC_HANG_PIDS="$T/hang.pids"
reap() { # kill any mock still sleeping (only matters when the test fails)
	[ -f "$MOCK_MIPC_HANG_PIDS" ] || return 0
	while read -r p; do kill "$p" 2>/dev/null; done < "$MOCK_MIPC_HANG_PIDS"
}
trap 'reap; rm -rf "$T"' EXIT INT TERM

# scratch root (same layout as run.sh)
mkdir -p "$T/root/lib/netifd/proto" "$T/bin" "$T/state"
sed "s|/usr/share/libubox/jshn.sh|$JSHN_SH|" "$NETIFD_SRC/netifd-proto.sh" \
	> "$T/root/lib/netifd/netifd-proto.sh"
cp "$NETIFD_SRC/utils.sh" "$T/root/lib/netifd/utils.sh"
cp "$PROTO" "$T/root/lib/netifd/proto/mtkmipc.sh"
cp "$HERE/mock-mipc_wan_cli" "$T/bin/mipc_wan_cli"
chmod +x "$T/bin/mipc_wan_cli"
cat > "$T/bin/ubus" <<'EOF'
#!/bin/sh
for a in "$@"; do last="$a"; done
echo "$last" >> "$MOCK_UBUS_LOG"
EOF
cat > "$T/bin/logger" <<'EOF'
#!/bin/sh
echo "$*" >> "${MOCK_LOGGER_LOG:-/dev/null}"
exit 0
EOF
chmod +x "$T/bin/ubus" "$T/bin/logger"

export PATH="$T/bin:$TOP/staging_dir/host/bin:$PATH"
export NETIFD_MAIN_DIR="$T/root/lib/netifd"
export MTKMIPC_LOCK="$T/mtkmipc.lock" MTKMIPC_STATEDIR="$T/state"
export MOCK_MIPC_LOG="$T/argv.log" MOCK_UBUS_LOG="$T/ubus.log"
export MOCK_LOGGER_LOG="$T/logger.log" MOCK_MIPC_HANG_PIDS
export MTKMIPC_RETRY_SLEEP=0
export MTKMIPC_CLI_TIMEOUT=3
# pin the mock (run.sh exports its own MOCK_* before calling us)
export MOCK_MIPC_ACT=ok MOCK_MIPC_CID=3 MOCK_MIPC_SIM= MOCK_MIPC_PROV= MOCK_MIPC_RADIO=
BOUND=$((MTKMIPC_CLI_TIMEOUT + 15))

PASS=0 FAIL=0
ok()   { PASS=$((PASS + 1)); echo "[PASS] $*"; }
bad()  { FAIL=$((FAIL + 1)); echo "[FAIL] $*"; }
check() { d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
has()   { grep -qF -- "$2" "$1"; }
reset() { : > "$MOCK_MIPC_LOG"; : > "$MOCK_UBUS_LOG"; : > "$MOCK_LOGGER_LOG"; : > "$MOCK_MIPC_HANG_PIDS"; }
alive() { # any hung mock still running?
	while read -r p; do kill -0 "$p" 2>/dev/null && return 0; done < "$MOCK_MIPC_HANG_PIDS"
	return 1
}
tproto() { # tproto <cmd> <iface> <json>: bounded run; sets rc, el
	t0=$(date +%s)
	( cd "$T/root/lib/netifd/proto" && \
	  timeout "$BOUND" $PROTO_SHELL ./mtkmipc.sh mtkmipc "$1" "$2" "$3" "" ) \
		> "$T/out" 2> "$T/err"
	rc=$?
	el=$(( $(date +%s) - t0 ))
}

echo "PROTO_SHELL=$PROTO_SHELL MTKMIPC_CLI_TIMEOUT=$MTKMIPC_CLI_TIMEOUT bound=${BOUND}s"

# --- H1. setup with a hanging CLI (MIPC server down) ---
reset
export MOCK_MIPC_HANG=1
tproto setup wan '{"apn":"du","auto_conf":0,"sim":1}'
echo "  setup: rc=$rc elapsed=${el}s"
check "hang setup: rc != 0" [ "$rc" -ne 0 ]
check "hang setup: not killed by outer timeout (rc != 124)" [ "$rc" -ne 124 ]
check "hang setup: returned within MTKMIPC_CLI_TIMEOUT+15 s" [ "$el" -lt "$BOUND" ]
check "hang setup: radio check was attempted" has "$MOCK_MIPC_LOG" "--nw_radio_state_get | 0"
check "hang setup: CFUN_IS_OFF notified" has "$MOCK_UBUS_LOG" "CFUN_IS_OFF"
check "hang setup: timeout logged" has "$MOCK_LOGGER_LOG" "timed out after ${MTKMIPC_CLI_TIMEOUT}s"
check "hang setup: no data call attempted" eval "! grep -qF -- --data_call_act '$MOCK_MIPC_LOG'"
check "hang setup: hung CLI was killed" eval "! alive"
check "hang setup: no state file" [ ! -f "$T/state/mtkmipc-wan.state" ]

# --- H2. teardown with a hanging CLI must not wedge either ---
reset
printf 'interface=wan\ncid=3\nstate=up\n' > "$T/state/mtkmipc-wan.state"
tproto teardown wan '{}'
echo "  teardown: rc=$rc elapsed=${el}s"
check "hang teardown: not killed by outer timeout (rc != 124)" [ "$rc" -ne 124 ]
check "hang teardown: returned within MTKMIPC_CLI_TIMEOUT+15 s" [ "$el" -lt "$BOUND" ]
check "hang teardown: deact attempted" has "$MOCK_MIPC_LOG" "--data_call_deact | 3"
check "hang teardown: state removed" [ ! -f "$T/state/mtkmipc-wan.state" ]
check "hang teardown: link-down notify" has "$MOCK_UBUS_LOG" '"link-up": false'
check "hang teardown: hung CLI was killed" eval "! alive"

# --- H3. healthy CLI through the watchdog: output and rc passed through ---
reset
export MOCK_MIPC_HANG=
tproto setup wan '{"apn":"du","auto_conf":0,"sim":1}'
check "watchdog passthrough: setup rc 0" [ "$rc" -eq 0 ]
check "watchdog passthrough: ifname from CLI stdout" has "$T/out" "ifname ccmni3"
check "watchdog passthrough: no timeout logged" eval "! grep -qF 'timed out' '$MOCK_LOGGER_LOG'"
tproto teardown wan '{}'

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
