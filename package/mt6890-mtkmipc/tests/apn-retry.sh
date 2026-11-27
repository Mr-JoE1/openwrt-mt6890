#!/bin/sh
# Regression test (v3.1.1 item 2): apn-wan-setup.sh retry-until-registered
# state machine. POSIX sh; no root, no network. Needs host `timeout`.
#
# Stubs on a private PATH:
#   mipc_wan_cli  --show_register_status answers from MOCK_REG_SEQ (space
#                 separated, one word per call, last word repeats; DOWN =
#                 hang like the real CLI with MIPC down); --data_call_act
#                 answers from MOCK_ACT_SEQ the same way (0 = success reply
#                 in the live shape, other = {"result": N})
#   sleep         logs its arg, sleeps MOCK_SLEEP_REAL real seconds (the 8 s
#                 probe window and the 30 s poll stay fast)
#   ip            logs argv; MOCK_IP_EEXIST=1 -> addr/route add fail EEXIST
#   uci           logs argv; `show firewall` -> MOCK_FW_SHOW; `add` -> cfgNEW
#   ccci_mdinit, logger, hexdump, $MT6890_INITD/{network,firewall}: record
# Note: the verbatim probe() writes /tmp/.g_out (device path) on the host too.
#
# Standalone: sh package/mt6890-mtkmipc/tests/apn-retry.sh
# Also run (and counted) by tests/run.sh.

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PKG="$(cd "$HERE/.." && pwd)"
APN="$PKG/files/lib/mt6890/apn-wan-setup.sh"
INIT="$PKG/files/etc/init.d/mt6890-apn"
SH="${PROTO_SHELL:-sh}"

command -v timeout >/dev/null 2>&1 || { echo "missing host timeout"; exit 2; }
REAL_SLEEP="$(command -v sleep)"

T="$(mktemp -d "${TMPDIR:-/tmp}/mt6890-apn.XXXXXX")"
HANG_PIDS="$T/hang.pids"
reap() {
	[ -f "$HANG_PIDS" ] || return 0
	while read -r p; do kill "$p" 2>/dev/null; done < "$HANG_PIDS"
}
trap 'reap; rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/bin" "$T/initd"

cat > "$T/bin/mipc_wan_cli" <<EOF
#!/bin/sh
echo "\$*" >> "\$MOCK_MIPC_LOG"
pick() { # pick <seq> <counter file>
	n=\$(cat "\$2" 2>/dev/null || echo 0); n=\$((n + 1)); echo "\$n" > "\$2"
	i=0 w=
	for x in \$1; do i=\$((i + 1)); w="\$x"; [ "\$i" -ge "\$n" ] && break; done
	echo "\$w"
}
case "\$1" in
--show_register_status)
	s=\$(pick "\${MOCK_REG_SEQ:-HOME}" "$T/reg.n")
	if [ "\$s" = DOWN ]; then
		echo "\$\$" >> "$HANG_PIDS"
		exec "$REAL_SLEEP" 300
	fi
	echo "MIPC_NW_REGISTER_STATE_\$s" ;;
--data_call_act)
	r=\$(pick "\${MOCK_ACT_SEQ:-0}" "$T/act.n")
	if [ "\$r" = 0 ]; then
		echo '{ "ifname": "ccmni1", "cid": 1, "v4_addr": "10.11.12.13", "v4_mask": 29, "v4_gw": "10.11.12.14", "v4_dns1": "192.0.2.53", "v4_dns2": "198.51.100.53", "result": 0 }'
	else
		echo "{ \"result\": \$r }"
	fi ;;
--nw_radio_state_set) echo OK ;;
*) echo "unexpected \$1" >&2; exit 1 ;;
esac
exit 0
EOF
cat > "$T/bin/sleep" <<EOF
#!/bin/sh
echo "\$*" >> "\$MOCK_SLEEP_LOG"
exec "$REAL_SLEEP" "\${MOCK_SLEEP_REAL:-0.3}"
EOF
cat > "$T/bin/ip" <<'EOF'
#!/bin/sh
echo "$*" >> "$MOCK_IP_LOG"
if [ -n "${MOCK_IP_EEXIST:-}" ] && [ "$2" = add ]; then
	echo "RTNETLINK answers: File exists" >&2
	exit 2
fi
exit 0
EOF
cat > "$T/bin/uci" <<'EOF'
#!/bin/sh
[ "${1:-}" = -q ] && shift
case "$1" in
get)
	case "$2" in
	network.wan.proto) [ -n "${MOCK_UCI_PROTO:-}" ] && echo "$MOCK_UCI_PROTO" ;;
	network.wan.auto_conf) [ -n "${MOCK_UCI_AUTOCONF:-}" ] && echo "$MOCK_UCI_AUTOCONF" ;;
	esac
	exit 0 ;;
show)
	[ "$2" = firewall ] && printf '%s\n' "${MOCK_FW_SHOW:-}"
	exit 0 ;;
add)
	echo "$*" >> "$MOCK_UCI_LOG"
	echo "cfgnew$3"
	exit 0 ;;
esac
echo "$*" >> "$MOCK_UCI_LOG"
exit 0
EOF
cat > "$T/bin/ccci_mdinit" <<'EOF'
#!/bin/sh
echo "$*" >> "$MOCK_MDINIT_LOG"
exit 0
EOF
cat > "$T/bin/logger" <<'EOF'
#!/bin/sh
echo "$*" >> "$MOCK_LOGGER_LOG"
exit 0
EOF
cat > "$T/bin/hexdump" <<'EOF'
#!/bin/sh
echo "0000000 0000 0000 0000 0000 0000 0000 0000 0000"
EOF
for s in network firewall; do
	printf '#!/bin/sh\necho "%s $*" >> "$MOCK_INITD_LOG"\n' "$s" > "$T/initd/$s"
done
chmod +x "$T/bin/"* "$T/initd/"*
printf 'config interface "loopback"\n' > "$T/network"

export MOCK_MIPC_LOG="$T/argv.log" MOCK_LOGGER_LOG="$T/logger.log"
export MOCK_SLEEP_LOG="$T/sleep.log" MOCK_IP_LOG="$T/ip.log"
export MOCK_UCI_LOG="$T/uci.log" MOCK_MDINIT_LOG="$T/mdinit.log"
export MOCK_INITD_LOG="$T/initd.log"
FW_DEFAULT="firewall.cfg03dc81=zone
firewall.cfg03dc81.name='wan'
firewall.cfg03dc81.network='wan' 'wan6'"

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
	for f in "$MOCK_MIPC_LOG" "$MOCK_LOGGER_LOG" "$MOCK_SLEEP_LOG" "$MOCK_IP_LOG" \
		"$MOCK_UCI_LOG" "$MOCK_MDINIT_LOG" "$MOCK_INITD_LOG" "$HANG_PIDS"; do
		: > "$f"
	done
	rm -f "$T/reg.n" "$T/act.n"
	export MOCK_REG_SEQ=HOME MOCK_ACT_SEQ=0 MOCK_IP_EEXIST= MOCK_FW_SHOW="$FW_DEFAULT"
	export MOCK_UCI_PROTO= MOCK_UCI_AUTOCONF=
}
run_apn() { # bounded run; sets rc, el
	t0=$(date +%s)
	( PATH="$T/bin:$PATH" MTKMIPC_NETWORK_CFG="$T/network" \
	  MTKMIPC_DT_BOOT="$T/no-such-dt" MTKMIPC_MDINIT="$T/bin/ccci_mdinit" \
	  MT6890_INITD="$T/initd" MT6890_APN_SETTLE=0 \
	  timeout 120 $SH "$APN" ) > "$T/out" 2> "$T/err"
	rc=$?
	el=$(( $(date +%s) - t0 ))
}

# --- A0. static checks: watchdog everywhere, scrub, procd one-shot ---
check "apn: verbatim 8 s probe watchdog" \
	has "$APN" '( "$@" >/tmp/.g_out 2>&1 & gp=$!; sleep 8; kill $gp >/dev/null 2>&1'
check "apn: every mipc_wan_cli call via probe" \
	[ "$(grep -v '^[[:space:]]*#' "$APN" | grep -c 'mipc_wan_cli')" -eq \
	  "$(grep -v '^[[:space:]]*#' "$APN" | grep -c 'probe mipc_wan_cli')" ]
check "apn: no old 10 s mipc_wd watchdog" hasnt "$APN" "mipc_wd"
check "apn: data call uses network-default apn \"0\"" has "$APN" '{"apn":"0","ip_type":3,"roaming_type":3,"auth_type":0,"username":"","password":"","bearer_bitmask":"0xfffdffff","mtu":1500,"mode":1}'
$SH -c "
procd_open_instance() { echo \"open \$1\"; }
procd_set_param() { echo \"param \$*\"; }
procd_close_instance() { echo close; }
. '$INIT'
start_service
" > "$T/procd" 2>&1
check "init: USE_PROCD" has "$INIT" "USE_PROCD=1"
check "init: START=99" has "$INIT" "START=99"
check "init: runs apn-wan-setup.sh" has "$T/procd" "param command /bin/sh /lib/mt6890/apn-wan-setup.sh"
check "init: one-shot (exit 0)" has "$T/procd" "param exit 0"
check "init: no respawn" hasnt "$T/procd" "respawn"

# --- A1. not-registered x3 -> home -> result 0 -> configured ---
reset
export MOCK_REG_SEQ="NOT_REGISTERED SEARCHING NOT_REGISTERED HOME"
run_apn
echo "  happy: rc=$rc elapsed=${el}s"
check "happy: rc 0" [ "$rc" -eq 0 ]
check "happy: 4 register polls" [ "$(cnt "$MOCK_MIPC_LOG" '--show_register_status')" -eq 4 ]
check "happy: 1 data call" [ "$(cnt "$MOCK_MIPC_LOG" '--data_call_act')" -eq 1 ]
check "happy: data call JSON (apn 0, one arg)" \
	has "$MOCK_MIPC_LOG" '--data_call_act {"apn":"0","ip_type":3,"roaming_type":3,"auth_type":0,"username":"","password":"","bearer_bitmask":"0xfffdffff","mtu":1500,"mode":1}'
check "happy: poll every 30 s (8 s probe + sleep 22)" [ "$(cnt "$MOCK_SLEEP_LOG" 22)" -eq 3 ]
check "happy: ip link set ccmni1 up" has "$MOCK_IP_LOG" "link set ccmni1 up"
check "happy: ip addr from reply (/29)" has "$MOCK_IP_LOG" "addr add 10.11.12.13/29 dev ccmni1"
check "happy: default route via v4_gw" has "$MOCK_IP_LOG" "route add default via 10.11.12.14 dev ccmni1"
check "happy: ifname parsed (not ccmni0)" hasnt "$MOCK_IP_LOG" "ccmni0"
check "happy: link before addr before route" \
	[ "$(cut -d' ' -f1 "$MOCK_IP_LOG" | tr '\n' ' ')" = "link addr route " ]
check "happy: wan proto none" has "$MOCK_UCI_LOG" "set network.wan.proto=none"
check "happy: wan device = ifname" has "$MOCK_UCI_LOG" "set network.wan.device=ccmni1"
check "happy: dns1 on wan" has "$MOCK_UCI_LOG" "add_list network.wan.dns=192.0.2.53"
check "happy: dns2 on wan" has "$MOCK_UCI_LOG" "add_list network.wan.dns=198.51.100.53"
check "happy: commit network" has "$MOCK_UCI_LOG" "commit network"
check "happy: ifname in existing wan zone" has "$MOCK_UCI_LOG" "add_list firewall.cfg03dc81.device=ccmni1"
check "happy: wan zone masq" has "$MOCK_UCI_LOG" "set firewall.cfg03dc81.masq=1"
check "happy: commit firewall" has "$MOCK_UCI_LOG" "commit firewall"
check "happy: no new zone" hasnt "$MOCK_UCI_LOG" "add firewall zone"
check "happy: network + firewall reloaded" \
	[ "$(cat "$MOCK_INITD_LOG" | tr '\n' ' ')" = "network reload firewall reload " ]
check "happy: no ccci_mdinit" [ ! -s "$MOCK_MDINIT_LOG" ]
check "happy: logged WAN up" has "$MOCK_LOGGER_LOG" "WAN up after"

# --- A2. 1316594 (no registered network) -> back to polling -> ok ---
reset
export MOCK_REG_SEQ=HOME MOCK_ACT_SEQ="1316594 1316594 0"
run_apn
check "noreg: rc 0" [ "$rc" -eq 0 ]
check "noreg: 3 data calls" [ "$(cnt "$MOCK_MIPC_LOG" '--data_call_act')" -eq 3 ]
check "noreg: re-polled register status each time" [ "$(cnt "$MOCK_MIPC_LOG" '--show_register_status')" -eq 3 ]
check "noreg: logged 1316594" has "$MOCK_LOGGER_LOG" "no registered network (1316594)"
check "noreg: configured at the end" has "$MOCK_IP_LOG" "addr add 10.11.12.13/29 dev ccmni1"

# --- A3. EEXIST (ccmni auto-assigned the address) tolerated ---
reset
export MOCK_IP_EEXIST=1
run_apn
check "eexist: rc 0" [ "$rc" -eq 0 ]
check "eexist: route still attempted" has "$MOCK_IP_LOG" "route add default via 10.11.12.14 dev ccmni1"
check "eexist: logged already present" has "$MOCK_LOGGER_LOG" "already present (ok)"
check "eexist: logged WAN up" has "$MOCK_LOGGER_LOG" "WAN up after"

# --- A4. no wan zone in firewall config -> zone + lan->wan forwarding ---
reset
export MOCK_FW_SHOW=
run_apn
check "nozone: rc 0" [ "$rc" -eq 0 ]
check "nozone: zone created" has "$MOCK_UCI_LOG" "add firewall zone"
check "nozone: zone named wan" has "$MOCK_UCI_LOG" "set firewall.cfgnewzone.name=wan"
check "nozone: ifname in new zone" has "$MOCK_UCI_LOG" "add_list firewall.cfgnewzone.device=ccmni1"
check "nozone: masq" has "$MOCK_UCI_LOG" "set firewall.cfgnewzone.masq=1"
check "nozone: lan->wan forwarding" has "$MOCK_UCI_LOG" "set firewall.cfgnewforwarding.dest=wan"

# --- A5. MD down for the whole budget: ccci_mdinit cap 3, exit 0 at ~15 min ---
reset
export MOCK_REG_SEQ=DOWN
run_apn
echo "  md-down: rc=$rc elapsed=${el}s"
check "md down: rc 0 (not killed by outer timeout)" [ "$rc" -eq 0 ]
check "md down: ccci_mdinit re-run exactly 3x" [ "$(cnt "$MOCK_MDINIT_LOG" 0)" -eq 3 ]
check "md down: 30 polls in the 900 s budget" [ "$(cnt "$MOCK_MIPC_LOG" '--show_register_status')" -eq 30 ]
check "md down: no data call" hasnt "$MOCK_MIPC_LOG" "--data_call_act"
check "md down: no ip config" [ ! -s "$MOCK_IP_LOG" ]
check "md down: logged give-up" has "$MOCK_LOGGER_LOG" "no WAN after 900s"
check "md down: hung CLIs killed" eval "! alive"

# --- A6. MD down twice, back after re-trigger: radio on, then registers ---
reset
export MOCK_REG_SEQ="DOWN DOWN SEARCHING HOME"
run_apn
check "md recover: rc 0" [ "$rc" -eq 0 ]
check "md recover: ccci_mdinit 2x" [ "$(cnt "$MOCK_MDINIT_LOG" 0)" -eq 2 ]
check "md recover: radio set 1 after MD back" has "$MOCK_MIPC_LOG" "--nw_radio_state_set 1"
check "md recover: configured" has "$MOCK_IP_LOG" "addr add 10.11.12.13/29 dev ccmni1"
check "md recover: hung CLIs killed" eval "! alive"

# --- A7. never registers: timeout path exits 0, no data call ---
reset
export MOCK_REG_SEQ=SEARCHING
run_apn
echo "  never-reg: rc=$rc elapsed=${el}s"
check "never reg: rc 0" [ "$rc" -eq 0 ]
check "never reg: 30 polls (~15 min)" [ "$(cnt "$MOCK_MIPC_LOG" '--show_register_status')" -eq 30 ]
check "never reg: no data call" hasnt "$MOCK_MIPC_LOG" "--data_call_act"
check "never reg: no ccci_mdinit (MD answers)" [ ! -s "$MOCK_MDINIT_LOG" ]
check "never reg: no uci writes" [ ! -s "$MOCK_UCI_LOG" ]
check "never reg: logged give-up" has "$MOCK_LOGGER_LOG" "no WAN after 900s"

# --- A8. ROAMING accepted like HOME ---
reset
export MOCK_REG_SEQ=ROAMING
run_apn
check "roaming: data call placed" has "$MOCK_MIPC_LOG" "--data_call_act"
check "roaming: configured" has "$MOCK_IP_LOG" "link set ccmni1 up"

# --- A9. v3.1 mtkmipc wan section is replaced (not skipped) ---
reset
export MOCK_UCI_PROTO=mtkmipc
run_apn
check "v3.1 mtkmipc wan: rc 0" [ "$rc" -eq 0 ]
check "v3.1 mtkmipc wan: replaced by proto none" has "$MOCK_UCI_LOG" "set network.wan.proto=none"
check "v3.1 mtkmipc wan: old ifname dropped" has "$MOCK_UCI_LOG" "delete network.wan.ifname"

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
