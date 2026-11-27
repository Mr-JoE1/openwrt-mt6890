#!/bin/sh
# Regression test (v3.1.1 item 6): the mt6890-modem radio_on one-shot must
# wait for MIPC (watchdogged --show_sim_status), then set + verify the radio,
# and exit 0 bounded when MIPC never comes up. POSIX sh; no root, no network.
#
# The one-shot body (RADIO_ON_SH) is taken from the real init script; the
# procd wiring (start_service) is checked with stub procd_* helpers.
# Stubs: `sleep` (logs its arg, sleeps MOCK_SLEEP_REAL real seconds so the
# 8 s probe window stays fast), mipc_wan_cli (hangs like the real CLI with
# MIPC down for the first MOCK_DOWN_CALLS calls, then delegates to
# mock-mipc_wan_cli), logger (records).
# Note: the verbatim probe() writes /tmp/.g_out (device path) on the host too.
#
# Standalone: sh package/mt6890-mtkmipc/tests/radio-on.sh
# Also run (and counted) by tests/run.sh.

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PKG="$(cd "$HERE/.." && pwd)"
TOP="${OPENWRT_TOP:-$(cd "$PKG/../.." && pwd)}"
INIT="$TOP/target/linux/mt6890/base-files/etc/init.d/mt6890-modem"
SH="${PROTO_SHELL:-sh}"

command -v timeout >/dev/null 2>&1 || { echo "missing host timeout"; exit 2; }
[ -f "$INIT" ] || { echo "missing $INIT"; exit 2; }
REAL_SLEEP="$(command -v sleep)"

T="$(mktemp -d "${TMPDIR:-/tmp}/mt6890-radio.XXXXXX")"
HANG_PIDS="$T/hang.pids"
reap() {
	[ -f "$HANG_PIDS" ] || return 0
	while read -r p; do kill "$p" 2>/dev/null; done < "$HANG_PIDS"
}
trap 'reap; rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/bin"

cp "$HERE/mock-mipc_wan_cli" "$T/mock-cli"
cat > "$T/bin/mipc_wan_cli" <<EOF
#!/bin/sh
n=\$(cat "\$MOCK_CALLS" 2>/dev/null || echo 0); n=\$((n + 1)); echo "\$n" > "\$MOCK_CALLS"
if [ "\$n" -le "\${MOCK_DOWN_CALLS:-0}" ]; then
	echo "\$*" >> "\$MOCK_MIPC_LOG"
	echo "\$\$" >> "$HANG_PIDS"
	exec "$REAL_SLEEP" 300
fi
exec sh "$T/mock-cli" "\$@"
EOF
cat > "$T/bin/sleep" <<EOF
#!/bin/sh
echo "\$*" >> "\$MOCK_SLEEP_LOG"
exec "$REAL_SLEEP" "\${MOCK_SLEEP_REAL:-0.5}"
EOF
cat > "$T/bin/logger" <<'EOF'
#!/bin/sh
echo "$*" >> "$MOCK_LOGGER_LOG"
exit 0
EOF
chmod +x "$T/bin/mipc_wan_cli" "$T/bin/sleep" "$T/bin/logger"

export MOCK_MIPC_LOG="$T/argv.log" MOCK_LOGGER_LOG="$T/logger.log"
export MOCK_SLEEP_LOG="$T/sleep.log" MOCK_CALLS="$T/calls"
export MOCK_MIPC_HANG= MOCK_MIPC_RADIO= MOCK_MIPC_RADIO_FILE= MOCK_MIPC_SIM=

PASS=0 FAIL=0
ok()   { PASS=$((PASS + 1)); echo "[PASS] $*"; }
bad()  { FAIL=$((FAIL + 1)); echo "[FAIL] $*"; }
check() { d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
has()   { grep -qF -- "$2" "$1"; }
hasnt() { ! grep -qF -- "$2" "$1"; }
cnt()   { grep -cF -- "$2" "$1"; }
alive() {
	[ -f "$HANG_PIDS" ] || return 1
	while read -r p; do kill -0 "$p" 2>/dev/null && return 0; done < "$HANG_PIDS"
	return 1
}
reset() {
	: > "$MOCK_MIPC_LOG"; : > "$MOCK_LOGGER_LOG"; : > "$MOCK_SLEEP_LOG"
	: > "$HANG_PIDS"; echo 0 > "$MOCK_CALLS"
	export MOCK_DOWN_CALLS=0 MOCK_MIPC_RADIO=
}
run_radio() { # bounded run of the one-shot body; sets rc, el
	t0=$(date +%s)
	( PATH="$T/bin:$PATH" timeout 120 $SH -c "$BODY" ) > "$T/out" 2> "$T/err"
	rc=$?
	el=$(( $(date +%s) - t0 ))
}

# --- R0. extract the one-shot body + check the procd wiring ---
BODY="$($SH -c ". '$INIT'; printf '%s' \"\$RADIO_ON_SH\"")"
check "radio_on: RADIO_ON_SH defined" [ -n "$BODY" ]
check "radio_on: verbatim 8 s probe watchdog" \
	eval "printf '%s' \"\$BODY\" | grep -qF '( \"\$@\" >/tmp/.g_out 2>&1 & gp=\$!; sleep 8; kill \$gp >/dev/null 2>&1'"
check "radio_on: no unwatchdogged sleep 25" eval "! printf '%s' \"\$BODY\" | grep -qF 'sleep 25'"
check "radio_on: every mipc_wan_cli call via probe" \
	eval "[ \"\$(printf '%s' \"\$BODY\" | grep -c 'mipc_wan_cli')\" -eq \"\$(printf '%s' \"\$BODY\" | grep -c 'probe mipc_wan_cli')\" ]"
$SH -c "
procd_open_instance() { echo \"open \$1\"; }
procd_set_param() { echo \"param \$*\"; }
procd_close_instance() { echo close; }
. '$INIT'
start_service
" > "$T/procd" 2>&1
check "radio_on: instance opened" has "$T/procd" "open radio_on"
check "radio_on: instance is a one-shot (exit 0)" \
	eval "sed -n '/open radio_on/,/close/p' '$T/procd' | grep -qx 'param exit 0'"
check "radio_on: no respawn on radio_on" \
	eval "! sed -n '/open radio_on/,/close/p' '$T/procd' | grep -q respawn"
check "radio_on: command runs RADIO_ON_SH" \
	eval "sed -n '/open radio_on/,/close/p' '$T/procd' | grep -qF 'param command /bin/sh -c PATH='"
check "radio_on: other daemons kept" has "$T/procd" "open mipc_submonitor"

# --- R1. MIPC healthy at once: set + verify ON ---
reset
run_radio
check "healthy: rc 0" [ "$rc" -eq 0 ]
check "healthy: 1 sim probe" [ "$(cnt "$MOCK_MIPC_LOG" '--show_sim_status')" -eq 1 ]
check "healthy: radio set 1" has "$MOCK_MIPC_LOG" "--nw_radio_state_set | 1"
check "healthy: radio verified (get 0)" has "$MOCK_MIPC_LOG" "--nw_radio_state_get | 0"
check "healthy: set before get" \
	eval "[ \"\$(grep -n -- '--nw_radio_state_set' '$MOCK_MIPC_LOG' | cut -d: -f1)\" -lt \"\$(grep -n -- '--nw_radio_state_get' '$MOCK_MIPC_LOG' | cut -d: -f1)\" ]"
check "healthy: logged ON" has "$MOCK_LOGGER_LOG" "radio_on: radio state ON"
check "healthy: probes use sleep 8" [ "$(sort -u "$MOCK_SLEEP_LOG")" = "8" ]

# --- R2. MIPC down ~20 s (3 hung probes = 24 s) then up: radio still set ---
reset
export MOCK_DOWN_CALLS=3
run_radio
echo "  down-then-up: rc=$rc elapsed=${el}s"
check "down 20s: rc 0" [ "$rc" -eq 0 ]
check "down 20s: 4 sim probes (3 hung + 1 ok)" [ "$(cnt "$MOCK_MIPC_LOG" '--show_sim_status')" -eq 4 ]
check "down 20s: logged MIPC up after 32s" has "$MOCK_LOGGER_LOG" "MIPC up after 32s"
check "down 20s: radio set 1" has "$MOCK_MIPC_LOG" "--nw_radio_state_set | 1"
check "down 20s: radio verified ON" has "$MOCK_LOGGER_LOG" "radio_on: radio state ON"
check "down 20s: hung CLIs killed" eval "! alive"

# --- R3. MIPC never up: bounded ~90 s of probes, clean exit 0, no hang ---
reset
export MOCK_DOWN_CALLS=1000
run_radio
echo "  never-up: rc=$rc elapsed=${el}s"
check "never up: rc 0 (not killed by outer timeout)" [ "$rc" -eq 0 ]
check "never up: 12 sim probes (~96 s budget)" [ "$(cnt "$MOCK_MIPC_LOG" '--show_sim_status')" -eq 12 ]
check "never up: radio never set" hasnt "$MOCK_MIPC_LOG" "--nw_radio_state_set"
check "never up: logged give-up" has "$MOCK_LOGGER_LOG" "MIPC not answering after 96s"
check "never up: hung CLIs killed" eval "! alive"

# --- R4. MIPC up but radio stays OFF: logged, still exit 0 ---
reset
export MOCK_MIPC_RADIO=OFF
run_radio
check "radio off: rc 0" [ "$rc" -eq 0 ]
check "radio off: radio set attempted" has "$MOCK_MIPC_LOG" "--nw_radio_state_set | 1"
check "radio off: logged not confirmed" has "$MOCK_LOGGER_LOG" "radio not confirmed ON"

# --- R5. SIM not ready still means MIPC answers: radio is set ---
reset
MOCK_MIPC_SIM=MIPC_SIM_STATUS_NOT_INSERTED run_radio
check "sim absent: rc 0" [ "$rc" -eq 0 ]
check "sim absent: 1 sim probe" [ "$(cnt "$MOCK_MIPC_LOG" '--show_sim_status')" -eq 1 ]
check "sim absent: radio set 1" has "$MOCK_MIPC_LOG" "--nw_radio_state_set | 1"

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
