#!/bin/sh
# Regression test (v3.1.1 item 3): mt6890-leds cellular status LED service.
# State -> brightness table, 2-poll debounce, MD-down (hung CLI) handling,
# "never write other nodes", own probe temp file. POSIX sh; no root.
#
# The loop body (LEDS_SH) is taken from the real init script and run against
# a fake sysfs (MT6890_LEDS_SYSFS) for a bounded number of polls
# (MT6890_LEDS_POLLS). Stubs: `sleep` (logs its arg; the 8 s probe window
# sleeps MOCK_PROBE_REAL real seconds, anything else returns at once),
# mipc_wan_cli (scripted per poll from MOCK_SEQ, one word per poll; the poll
# index advances on each --show_sim_status), logger (records).
# Note: the probe() writes /tmp/.mt6890_leds_g_out (device path) on the host.
#
# Poll words: lte nr roam5 roam4 search notreg unknown mdown regmdown
#             norat lte5old (rat: earlier line 5G, last line 4G)
#
# Standalone: sh package/mt6890-mtkmipc/tests/leds.sh
# Also run (and counted) by tests/run.sh.

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PKG="$(cd "$HERE/.." && pwd)"
TOP="${OPENWRT_TOP:-$(cd "$PKG/../.." && pwd)}"
INIT="$TOP/target/linux/mt6890/base-files/etc/init.d/mt6890-leds"
SH="${PROTO_SHELL:-sh}"

command -v timeout >/dev/null 2>&1 || { echo "missing host timeout"; exit 2; }
[ -f "$INIT" ] || { echo "missing $INIT"; exit 2; }
REAL_SLEEP="$(command -v sleep)"

T="$(mktemp -d "${TMPDIR:-/tmp}/mt6890-leds.XXXXXX")"
HANG_PIDS="$T/hang.pids"
reap() {
	[ -f "$HANG_PIDS" ] || return 0
	while read -r p; do kill "$p" 2>/dev/null; done < "$HANG_PIDS"
}
trap 'reap; rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/bin"

cat > "$T/bin/mipc_wan_cli" <<EOF
#!/bin/sh
echo "\$*" >> "\$MOCK_MIPC_LOG"
if [ "\$1" = --show_sim_status ]; then
	n=\$(cat "\$MOCK_CALLS" 2>/dev/null || echo 0); n=\$((n + 1)); echo "\$n" > "\$MOCK_CALLS"
	w=mdown i=0
	for s in \$MOCK_SEQ; do i=\$((i + 1)); [ "\$i" -eq "\$n" ] && w="\$s"; done
	echo "\$w" > "\$MOCK_CUR"
fi
cur=\$(cat "\$MOCK_CUR" 2>/dev/null)
hang() { echo "\$\$" >> "$HANG_PIDS"; exec "$REAL_SLEEP" 300; }
case "\$1" in
--show_sim_status)
	[ "\$cur" = mdown ] && hang
	echo MIPC_SIM_STATUS_COMPLETE_READY ;;
--show_register_status)
	case "\$cur" in
	lte|nr|lte5old|norat) echo MIPC_NW_REGISTER_STATE_HOME ;;
	roam4|roam5) echo MIPC_NW_REGISTER_STATE_ROAMING ;;
	search) echo MIPC_NW_REGISTER_STATE_SEARCHING ;;
	notreg) echo MIPC_NW_REGISTER_STATE_NOT_REGISTERED ;;
	unknown) echo MIPC_NW_REGISTER_STATE_UNKNOWN ;;
	regmdown) hang ;;
	esac ;;
--nw_get_rat)
	case "\$cur" in
	nr|roam5) printf 'RAT info\nCurrent: 5G\n\n' ;;
	lte|roam4) echo "Current: 4G" ;;
	lte5old) printf 'Supported: 5G\nCurrent: 4G\n' ;;
	norat) hang ;;
	esac ;;
*) echo "unexpected \$1" >&2; exit 1 ;;
esac
exit 0
EOF
cat > "$T/bin/sleep" <<EOF
#!/bin/sh
echo "\$*" >> "\$MOCK_SLEEP_LOG"
# the 8 s probe window gets 1 s real time (fast stub replies must never be
# cut off by the watchdog under host load); the poll interval is instant
[ "\$1" = 8 ] && exec "$REAL_SLEEP" "\${MOCK_PROBE_REAL:-1}"
exit 0
EOF
cat > "$T/bin/logger" <<'EOF'
#!/bin/sh
echo "$*" >> "$MOCK_LOGGER_LOG"
exit 0
EOF
chmod +x "$T/bin/mipc_wan_cli" "$T/bin/sleep" "$T/bin/logger"

export MOCK_MIPC_LOG="$T/argv.log" MOCK_LOGGER_LOG="$T/logger.log"
export MOCK_SLEEP_LOG="$T/sleep.log" MOCK_CALLS="$T/calls" MOCK_CUR="$T/cur"
SYS="$T/sys"

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

PWR="led9514:green:power"; G4="led9511:green:lte-rssi"; G5="led9508:green:nr-rssi"
R4="led9502:red:cellular-stat"; R5="led9507:red:nr-rssi"
# nodes with no visible light / wifi / other functions: must never be written
OTHERS="led9501:red:sim led9504:red:cellular-data led9505:red:cellular-rat \
led9509:blue:nr-rssi led9510:red:lte-rssi led9512:blue:lte-rssi \
led9513:red:power led9515:blue:power led9515:red:wifi-led \
led9516:green:wifi-led led9517:blue:wifi-led"

mknode() { # mknode <name> <brightness> <max>
	mkdir -p "$SYS/$1"
	echo "$2" > "$SYS/$1/brightness"; echo "$3" > "$SYS/$1/max_brightness"
	echo "timer" > "$SYS/$1/trigger"
}
reset() {
	rm -rf "$SYS"; mkdir -p "$SYS"
	for n in $PWR $G4 $G5 $R4 $R5; do mknode "$n" 0 1; done
	for n in $OTHERS; do mknode "$n" 7 1; done
	: > "$MOCK_MIPC_LOG"; : > "$MOCK_LOGGER_LOG"; : > "$MOCK_SLEEP_LOG"
	: > "$HANG_PIDS"; echo 0 > "$MOCK_CALLS"; : > "$MOCK_CUR"
}
br() { cat "$SYS/$1/brightness"; }
leds() { echo "$(br $PWR)$(br $G4)$(br $G5)$(br $R4)$(br $R5)"; } # pwr 4G 5G 4R 5R
run_leds() { # run_leds <polls> <seq words...>; sets rc
	p="$1"; shift
	( PATH="$T/bin:$PATH" MOCK_SEQ="$*" MT6890_LEDS_SYSFS="$SYS" \
	  MT6890_LEDS_POLLS="$p" timeout 120 $SH -c "$BODY" ) > "$T/out" 2> "$T/err"
	rc=$?
}
others_untouched() {
	for n in $OTHERS; do
		[ "$(br "$n")" = 7 ] && [ "$(cat "$SYS/$n/trigger")" = timer ] || return 1
	done
}

# --- L0. extract the loop body + check the procd wiring / watchdog ---
BODY="$($SH -c ". '$INIT'; printf '%s' \"\$LEDS_SH\"")"
check "leds: LEDS_SH defined" [ -n "$BODY" ]
check "leds: 8 s probe watchdog (own temp file)" \
	eval "printf '%s' \"\$BODY\" | grep -qF '( \"\$@\" >/tmp/.mt6890_leds_g_out 2>&1 & gp=\$!; sleep 8; kill \$gp >/dev/null 2>&1'"
check "leds: probe reads its own temp file" \
	eval "printf '%s' \"\$BODY\" | grep -qF 'out=\$(cat /tmp/.mt6890_leds_g_out 2>/dev/null)'"
check "leds: never the shared /tmp/.g_out (apn runs concurrently)" \
	eval "! grep -v '^[[:space:]]*#' '$INIT' | grep -qF '/tmp/.g_out'"
check "leds: every mipc_wan_cli call via probe" \
	eval "[ \"\$(printf '%s' \"\$BODY\" | grep -c 'mipc_wan_cli')\" -eq \"\$(printf '%s' \"\$BODY\" | grep -c 'probe mipc_wan_cli')\" ]"
check "leds: no stale leds-update.sh loop" eval "! grep -qF 'leds-update.sh' '$INIT'"
$SH -c "
procd_open_instance() { echo \"open \$1\"; }
procd_set_param() { echo \"param \$*\"; }
procd_close_instance() { echo close; }
. '$INIT'
start_service
" > "$T/procd" 2>&1
check "leds: instance opened" has "$T/procd" "open leds"
check "leds: respawn (long-running)" has "$T/procd" "param respawn"
check "leds: command runs LEDS_SH" has "$T/procd" "param command /bin/sh -c PATH="
check "leds: USE_PROCD=1" has "$INIT" "USE_PROCD=1"

# --- L1. state -> brightness table (2 identical polls each) ---
# expected: pwr 4G-green 5G-green 4G-red 5G-red
table() { # table <word> <expected leds> <state name>
	reset
	run_leds 2 "$1" "$1"
	check "table $1: rc 0" [ "$rc" -eq 0 ]
	check "table $1: leds=$2" [ "$(leds)" = "$2" ]
	check "table $1: logged state $3" has "$MOCK_LOGGER_LOG" "state -> $3"
	check "table $1: other nodes untouched" others_untouched
}
table lte      11000 lte
table nr       10100 nr
table roam4    11000 lte
table roam5    10100 nr
table lte5old  11000 lte
table search   10010 search
table notreg   10010 search
table unknown  10010 search
table mdown    10001 mdown
table regmdown 10001 mdown
table norat    11000 lte

# --- L2. probe sequence / RAT only when registered ---
reset
run_leds 2 search search
check "probe: no nw_get_rat when not registered" hasnt "$MOCK_MIPC_LOG" "--nw_get_rat"
check "probe: sim + register per poll" [ "$(cnt "$MOCK_MIPC_LOG" '--show_register_status')" -eq 2 ]
reset
run_leds 2 nr nr
check "probe: nw_get_rat when registered" [ "$(cnt "$MOCK_MIPC_LOG" '--nw_get_rat')" -eq 2 ]
reset
run_leds 2 mdown mdown
check "probe: MD down skips register query" hasnt "$MOCK_MIPC_LOG" "--show_register_status"
check "probe: hung CLIs killed" eval "! alive"
check "probe: watchdog sleep 8 used" has "$MOCK_SLEEP_LOG" "8"
check "probe: poll interval 10 s" [ "$(cnt "$MOCK_SLEEP_LOG" '10')" -eq 1 ]

# --- L3. debounce ---
reset
run_leds 1 lte
check "debounce 1 poll: rc 0" [ "$rc" -eq 0 ]
check "debounce 1 poll: power on, status LEDs untouched" [ "$(leds)" = 10000 ]
check "debounce 1 poll: nothing applied" hasnt "$MOCK_LOGGER_LOG" "state ->"

reset
run_leds 3 lte search lte
check "debounce flap: nothing applied" [ "$(leds)" = 10000 ]
check "debounce flap: no state log" hasnt "$MOCK_LOGGER_LOG" "state ->"

reset
run_leds 5 lte lte search lte lte
check "debounce blip: lte shown" [ "$(leds)" = 11000 ]
check "debounce blip: single search poll ignored" hasnt "$MOCK_LOGGER_LOG" "state -> search"
check "debounce blip: lte applied once" [ "$(cnt "$MOCK_LOGGER_LOG" 'state -> lte')" -eq 1 ]

reset
run_leds 4 lte lte search search
check "debounce change: search applied after 2 polls" [ "$(leds)" = 10010 ]
check "debounce change: lte then search" \
	[ "$(sed -n 's/^.*state -> //p' "$MOCK_LOGGER_LOG" | tr '\n' ' ')" = "lte search " ]

reset
run_leds 6 search search nr nr mdown mdown
check "debounce sequence: final mdown" [ "$(leds)" = 10001 ]
check "debounce sequence: search nr mdown" \
	[ "$(sed -n 's/^.*state -> //p' "$MOCK_LOGGER_LOG" | tr '\n' ' ')" = "search nr mdown " ]
check "debounce sequence: other nodes untouched" others_untouched

reset
run_leds 5 nr nr nr nr nr
check "debounce steady: applied once (no rewrites)" [ "$(cnt "$MOCK_LOGGER_LOG" 'state ->')" -eq 1 ]

# --- L4. sysfs edge cases ---
reset
echo 255 > "$SYS/$G5/max_brightness"; echo 255 > "$SYS/$PWR/max_brightness"
run_leds 2 nr nr
check "max_brightness: 5G green = 255" [ "$(br $G5)" = 255 ]
check "max_brightness: power = 255" [ "$(br $PWR)" = 255 ]
check "trigger: driven nodes set to none" [ "$(cat "$SYS/$G5/trigger")" = none ]
check "trigger: power trigger untouched" [ "$(cat "$SYS/$PWR/trigger")" = timer ]

reset
rm -rf "$SYS/$G4"
run_leds 2 lte lte
check "missing node: rc 0" [ "$rc" -eq 0 ]
check "missing node: not created" [ ! -e "$SYS/$G4" ]
check "missing node: others still driven" [ "$(br $PWR)$(br $R4)$(br $R5)" = 100 ]

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
