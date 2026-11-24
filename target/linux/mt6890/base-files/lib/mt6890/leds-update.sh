#!/bin/sh
# LED state updater for the DWR-2000M A3 on 24.10 (called every 30 s by
# /etc/init.d/mt6890-leds). Any failed query leaves the affected LED off.

LED=/sys/class/leds
set_led() {
	[ -f "$LED/$1/brightness" ] && echo "$2" > "$LED/$1/brightness" 2>/dev/null
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
[ "$(mipc_wan_cli --show_sim_status 2>/dev/null | head -n1)" = "MIPC_SIM_STATUS_COMPLETE_READY" ] && sim=1
set_led sim $sim

# cellular stat: SIM ready and network query succeeds (verified verb)
if [ $sim = 1 ] && mipc_wan_cli --check_nw_status >/dev/null 2>&1; then
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
