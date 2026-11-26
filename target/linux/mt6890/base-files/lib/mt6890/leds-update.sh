#!/bin/sh
# LED state updater for the DWR-2000M A3 on 24.10 (called every 30 s by
# /etc/init.d/mt6890-leds). Any failed query leaves the affected LED off.

LED=/sys/class/leds
set_led() {
	[ -f "$LED/$1/brightness" ] && echo "$2" > "$LED/$1/brightness" 2>/dev/null
}

MTKMIPC_CLI_TIMEOUT="${MTKMIPC_CLI_TIMEOUT:-10}"

# mipc_wan_cli has no timeout and blocks forever when the MIPC server is
# down (dead MD); cap every call so callers can react. POSIX sh (busybox).
mipc_wd() {
	mipc_wan_cli "$@" &
	local cli_pid=$! i=0
	while kill -0 "$cli_pid" 2>/dev/null; do
		i=$((i + 1))
		if [ "$i" -ge "$MTKMIPC_CLI_TIMEOUT" ]; then
			kill "$cli_pid" 2>/dev/null
			wait "$cli_pid" 2>/dev/null
			logger -t mtkmipc-wd "mipc_wan_cli $* timed out after ${MTKMIPC_CLI_TIMEOUT}s"
			return 124
		fi
		sleep 1
	done
	wait "$cli_pid" 2>/dev/null
	return $?
}

# wifi green: at least one band AP is up (IFF_UP in /sys flags)
wifi=0
for d in ra0 rai0; do
	v=$(cat /sys/class/net/$d/flags 2>/dev/null)
	case "$v" in 0x*) [ $(( v & 1 )) -eq 1 ] && wifi=1 ;; esac
done
set_led wifi_green $wifi

# sim: SIM fully ready
sim=0
[ "$(mipc_wd --show_sim_status 2>/dev/null | head -n1)" = "MIPC_SIM_STATUS_COMPLETE_READY" ] && sim=1
set_led sim $sim

# cellular stat: SIM ready and network query succeeds (verified verb)
if [ $sim = 1 ] && mipc_wd --check_nw_status >/dev/null 2>&1; then
	set_led cell_stat 1
else
	set_led cell_stat 0
fi

# cellular data: the netifd wan interface (proto mtkmipc) is up
data=0
[ "$(ifstatus -o wan 2>/dev/null)" = "wan" ] && data=1
set_led cell_data $data

# rat/rssi LEDs (nr_*, lte_*): stock used cpe-daemon private MIPC
# notifications; no verified public CLI verb exists in our evidence.
# Leave them at their default (0) rather than fabricate state.
exit 0
