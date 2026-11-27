#!/bin/sh
# Regression test (v3.1.1 item 1): the mt6890-wifi boot one-shot retries
# `/sbin/wifi up` (bounded, 10 x 15 s) until ra0 is UP/LOWER_UP and always
# exits 0. POSIX sh; no root, no network.
#
# The one-shot body (WIFI_UP_SH) is taken from the real init script; the
# procd wiring is checked with stub procd_* helpers.
# Stubs: wifi (MT6890_WIFI_BIN; counts calls, ra0 comes up on call
# MOCK_UP_AT), ip (`ip link show ra0` prints a canned iproute2 line, DOWN or
# UP per the wifi stub's state file), sleep (logs its arg, no real wait),
# logger (records).
#
# Standalone: sh package/mt6890-mtkwifi/tests/wifi-boot.sh
# Also run (and counted) by tests/run.sh.

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PKG="$(cd "$HERE/.." && pwd)"
TOP="${OPENWRT_TOP:-$(cd "$PKG/../.." && pwd)}"
INIT="$TOP/target/linux/mt6890/base-files/etc/init.d/mt6890-wifi"
SH="${DRV_SHELL:-sh}"

command -v timeout >/dev/null 2>&1 || { echo "missing host timeout"; exit 2; }
[ -f "$INIT" ] || { echo "missing $INIT"; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/mt6890-wifiboot.XXXXXX")"
trap 'rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/bin"

cat > "$T/bin/wifi" <<'EOF'
#!/bin/sh
echo "wifi $*" >> "$MOCK_WIFI_LOG"
n=$(grep -c . "$MOCK_WIFI_LOG")
echo "vendor lua noise on stderr" >&2
[ "$1" = up ] && [ "$n" -ge "${MOCK_UP_AT:-1}" ] && echo up > "$MOCK_RA0_STATE"
exit 0
EOF
cat > "$T/bin/ip" <<'EOF'
#!/bin/sh
echo "ip $*" >> "$MOCK_IP_LOG"
[ "$*" = "link show ra0" ] || exit 1
[ -n "${MOCK_NO_RA0:-}" ] && { echo 'Device "ra0" does not exist.' >&2; exit 1; }
case "$(cat "$MOCK_RA0_STATE" 2>/dev/null)" in
up) echo "9: ra0: <BROADCAST,MULTICAST,${MOCK_UP_FLAGS:-UP,LOWER_UP}> mtu 1500 qdisc mq state UNKNOWN mode DEFAULT group default qlen 1000" ;;
*)  echo "9: ra0: <BROADCAST,MULTICAST> mtu 1500 qdisc noop state DOWN mode DEFAULT group default qlen 1000" ;;
esac
echo "    link/ether 00:00:00:00:00:00 brd ff:ff:ff:ff:ff:ff"
EOF
cat > "$T/bin/sleep" <<'EOF'
#!/bin/sh
echo "$*" >> "$MOCK_SLEEP_LOG"
exit 0
EOF
cat > "$T/bin/logger" <<'EOF'
#!/bin/sh
echo "$*" >> "$MOCK_LOGGER_LOG"
exit 0
EOF
chmod +x "$T/bin/wifi" "$T/bin/ip" "$T/bin/sleep" "$T/bin/logger"

export MOCK_WIFI_LOG="$T/wifi.log" MOCK_IP_LOG="$T/ip.log" MOCK_SLEEP_LOG="$T/sleep.log"
export MOCK_LOGGER_LOG="$T/logger.log" MOCK_RA0_STATE="$T/ra0.state"
export MT6890_WIFI_BIN="$T/bin/wifi"

PASS=0 FAIL=0
ok()   { PASS=$((PASS + 1)); echo "[PASS] $*"; }
bad()  { FAIL=$((FAIL + 1)); echo "[FAIL] $*"; }
check() { d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
has()   { grep -qF -- "$2" "$1"; }
lines() { grep -c . "$1"; }
reset() {
	: > "$MOCK_WIFI_LOG"; : > "$MOCK_IP_LOG"; : > "$MOCK_SLEEP_LOG"; : > "$MOCK_LOGGER_LOG"
	rm -f "$MOCK_RA0_STATE"
	export MOCK_UP_AT=1 MOCK_NO_RA0= MOCK_UP_FLAGS=
}
run_boot() { # bounded run of the one-shot body; sets rc
	( PATH="$T/bin:$PATH" timeout 30 $SH -c "$BODY" ) > "$T/out" 2> "$T/err"
	rc=$?
}

# --- W0. body extraction + procd wiring ---
BODY="$($SH -c ". '$INIT'; printf '%s' \"\$WIFI_UP_SH\"")"
check "wifi boot: WIFI_UP_SH defined" [ -n "$BODY" ]
check "wifi boot: no one-shot 'sleep 3'" eval "! grep -v '^[[:space:]]*#' '$INIT' | grep -qF 'sleep 3;'"
$SH -c "
procd_open_instance() { echo \"open \$1\"; }
procd_set_param() { echo \"param \$*\"; }
procd_close_instance() { echo close; }
. '$INIT'
start_service
" > "$T/procd" 2>&1
check "wifi boot: instance wifi opened" has "$T/procd" "open wifi"
check "wifi boot: one-shot (exit 0)" eval "grep -qx 'param exit 0' '$T/procd'"
check "wifi boot: no respawn" eval "! grep -q respawn '$T/procd'"
check "wifi boot: command runs WIFI_UP_SH" has "$T/procd" "param command /bin/sh -c tries="

# --- W1. ra0 up after the first attempt ---
reset
run_boot
check "1st try: rc 0" [ "$rc" -eq 0 ]
check "1st try: wifi up once" [ "$(cat "$MOCK_WIFI_LOG")" = "wifi up" ]
check "1st try: slept 15 s once" [ "$(cat "$MOCK_SLEEP_LOG")" = "15" ]
check "1st try: checked ip link show ra0" has "$MOCK_IP_LOG" "ip link show ra0"
check "1st try: logged success 1/10" has "$MOCK_LOGGER_LOG" "ra0 up after attempt 1/10"
check "1st try: vendor stderr discarded" [ ! -s "$T/err" ]

# --- W2. ra0 comes up on attempt 4 (boot race) ---
reset
export MOCK_UP_AT=4
run_boot
check "4th try: rc 0" [ "$rc" -eq 0 ]
check "4th try: wifi up x4" [ "$(lines "$MOCK_WIFI_LOG")" -eq 4 ]
check "4th try: sleep 15 x4" [ "$(grep -cx 15 "$MOCK_SLEEP_LOG")" -eq 4 ]
check "4th try: 3 not-up logs" [ "$(grep -c 'not up after attempt' "$MOCK_LOGGER_LOG")" -eq 3 ]
check "4th try: logged success 4/10" has "$MOCK_LOGGER_LOG" "ra0 up after attempt 4/10"

# --- W3. UP without LOWER_UP also counts ---
reset
export MOCK_UP_FLAGS=UP
run_boot
check "UP only: success on attempt 1" [ "$(lines "$MOCK_WIFI_LOG")" -eq 1 ]

# --- W4. LOWER_UP without UP also counts ---
reset
export MOCK_UP_FLAGS=LOWER_UP
run_boot
check "LOWER_UP only: success on attempt 1" [ "$(lines "$MOCK_WIFI_LOG")" -eq 1 ]

# --- W5. look-alike flags (e.g. M-DOWN / NO-CARRIER) are not UP ---
reset
export MOCK_UP_FLAGS=NO-CARRIER MT6890_WIFI_TRIES=2
run_boot
unset MT6890_WIFI_TRIES
check "NO-CARRIER: not treated as up (2 tries)" [ "$(lines "$MOCK_WIFI_LOG")" -eq 2 ]

# --- W6. ra0 never up: exactly 10 attempts, give-up logged, exit 0 ---
reset
export MOCK_UP_AT=1000
run_boot
check "never up: rc 0" [ "$rc" -eq 0 ]
check "never up: wifi up x10 (bounded)" [ "$(lines "$MOCK_WIFI_LOG")" -eq 10 ]
check "never up: sleep 15 x10" [ "$(grep -cx 15 "$MOCK_SLEEP_LOG")" -eq 10 ]
check "never up: logged give-up" has "$MOCK_LOGGER_LOG" "ra0 still down after 10 attempts; giving up"

# --- W7. ra0 netdev missing entirely: still bounded, exit 0 ---
reset
export MOCK_NO_RA0=1
run_boot
check "no ra0: rc 0" [ "$rc" -eq 0 ]
check "no ra0: wifi up x10" [ "$(lines "$MOCK_WIFI_LOG")" -eq 10 ]
check "no ra0: ip stderr discarded" [ ! -s "$T/err" ]

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
