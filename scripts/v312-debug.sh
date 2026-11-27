#!/bin/sh
# v312-debug.sh - DWR-2000M A3 (MT6890) one-shot full debug: egress + SIM-swap
#
# Checks : identity/slot, services, vendor daemons, MIPC state (8s watchdog on
#          every mipc call), data-plane egress (ping/DNS/HTTP + ccmni1 counters),
#          firewall/NAT, LuCI + overlay forensics (whiteouts), SIM/PLMN state,
#          NVRAM listing, LED map.
# Trials : T1 LED-service A/B on MIPC request path + egress (root-cause test)
#          T2 cci_mdinit 0 + mt6890-apn re-dial (only if egress dead after T1)
# Output : verdict block on stdout + /tmp/v312-debug-logs.tar.gz
# State  : leds stop/start; T2: cci_mdinit 0 + apn restart. No uci, no sysupgrade.
# POSIX sh / BusyBox ash. Safe via wget|sh. Total runtime ~3-6 min, hands off.

id -u | grep -q '^0$' || { echo "must run as root"; exit 1; }
W=/tmp/v312d
rm -rf "$W"; mkdir -p "$W"
T="$W/trials.txt"; : > "$T"
LOG() { echo "$@"; echo "$@" >> "$T"; }

probe() {  # 8s watchdog on every mipc call
  ( "$@" </dev/null >"$W/.out" 2>&1 & gp=$!; sleep 8
    kill $gp >/dev/null 2>&1
    wait $gp >/dev/null 2>&1 )
  out=$(cat "$W/.out" 2>/dev/null)
}
pingn() { ping -c 5 8.8.8.8 2>&1 | grep -c 'bytes from'; }
ccmni() { awk '$1=="ccmni1:"{print "rx_b="$2" rx_p="$3" tx_b="$10" tx_p="$11}' /proc/net/dev; }
leds_on() { f=; for p in /proc/[0-9]*; do tr '\0' ' ' < "$p/cmdline" 2>/dev/null | grep -q "led9514" && f=1; done; [ -n "$f" ]; }
egress() {  # $1=label -> one-line summary, appends to trials log
  L="$1"
  P=$(pingn)
  D=$(nslookup -timeout=5 downloads.openwrt.org 8.8.8.8 2>&1 | tail -1)
  H=$(wget -O- --timeout=8 http://downloads.openwrt.org/releases/ 2>&1 | head -c 80 | tr '\n' '~')
  echo "$L: ping=$P/5 dns=[$D] http=[$H]" | tee -a "$T"
  LAST_PING=$P
}

echo "==============================================================="
echo " v3.1.2 FULL DEBUG (egress + SIM-swap)  $(date)"
echo "==============================================================="

echo "== P0 baseline =="
cat /etc/openwrt_version 2>/dev/null; uname -r; uptime
mt6890-bootctl status 2>/dev/null
for s in mt6890-wifi mt6890-modem mt6890-apn mt6890-leds uhttpd firewall network; do
  echo "  init.d/$s: $([ -x /etc/init.d/$s ] && echo present || echo MISSING)"
done
pidof ql_ril_service >/dev/null 2>&1 && RIL=up || RIL=down
pidof mipc_submonitor >/dev/null 2>&1 && SUB=up || SUB=down
echo "  vendor daemons: ql_ril_service=$RIL mipc_submonitor=$SUB"
echo "  leds service: $(leds_on && echo on || echo off)"
echo "  ccmni1: $(ccmni)"
echo "  default gw: $(ip route 2>/dev/null | awk '/^default/{print $3}')"

echo "== P1 MIPC baseline + egress (leds as-is) =="
leds_on && LS=on || LS=off
probe mipc_wan_cli --show_sim_status;      echo "  sim:      $out"
probe mipc_wan_cli --show_register_status; echo "  register: $out"; REG0=$out
probe mipc_wan_cli --nw_get_rat;           echo "  rat:      $out"
probe mipc_wan_cli --nw_get_signal;        echo "  signal:   $out"
egress "P1-baseline leds=$LS"

echo "== T1: LED A/B trial (MIPC request path + egress) =="
if leds_on; then
  echo "  [T1] leds ON -> stopping..."
  /etc/init.d/mt6890-leds stop; sleep 3
  probe mipc_wan_cli --show_register_status; echo "  [T1] probe leds-OFF: [$out]" | tee -a "$T"
  egress "T1-LED-off"
  POFF=$LAST_PING
  echo "  [T1] starting leds (12s for one poll cycle)..."
  /etc/init.d/mt6890-leds start; sleep 12
  probe mipc_wan_cli --show_register_status; echo "  [T1] probe leds-ON:  [$out]" | tee -a "$T"
  egress "T1-LED-on"
  PON=$LAST_PING
else
  echo "  [T1] leds already OFF"
  egress "T1-LED-off"
  POFF=$LAST_PING
  echo "  [T1] starting leds (12s for one poll cycle)..."
  /etc/init.d/mt6890-leds start; sleep 12
  probe mipc_wan_cli --show_register_status; echo "  [T1] probe leds-ON:  [$out]" | tee -a "$T"
  egress "T1-LED-on"
  PON=$LAST_PING
fi
if [ "$POFF" -gt "$PON" ]; then
  /etc/init.d/mt6890-leds stop
  T1V="LED service implicated (off=$POFF on=$PON) -> left STOPPED"
else
  T1V="LED not implicated (off=$POFF on=$PON) -> left running"
fi
LOG "T1 verdict: $T1V"

echo "== P2 LuCI / overlay forensics =="
echo "  /www: $(ls /www 2>/dev/null | tr '\n' ' ')"
echo "  /www/luci: $([ -d /www/luci ] && echo present || echo MISSING)"
echo "  /overlay/upper: $(ls /overlay/upper 2>/dev/null | tr '\n' ' ')"
WH=$(find /overlay/upper/www -type c 2>/dev/null | wc -l)
echo "  whiteouts under /overlay/upper/www: $WH"
echo "  luci ipks installed: $(opkg list-installed 2>/dev/null | grep -c '^luci')"
echo "  local /luci/: $(wget -q -O- --timeout=5 http://127.0.0.1/luci/ 2>/dev/null | head -c 60 | tr '\n' '~')"
echo "  squashfs/ubi-error dmesg lines: $(dmesg 2>/dev/null | grep -ciE 'squashfs|ubi.*error')"

echo "== P3 SIM / PLMN state =="
probe mipc_wan_cli --show_register_status; echo "  register: $out"; REG1=$out
probe mipc_wan_cli --show_sim_status; echo "  sim: $out"
logread 2>/dev/null | grep -iE 'plmn|search|attach|camp' | tail -5 | sed 's/^/  log: /'
echo "  nvram dir:"; ls -la /mnt/vendor/nvram/ 2>/dev/null | head -8 | sed 's/^/    /'

echo "== T2 (conditional): MD re-init + APN re-dial =="
T2RAN=no
if [ "$POFF" -eq 0 ] && [ "$PON" -eq 0 ]; then
  T2RAN=yes
  echo "  [T2] egress dead after T1 -> cci_mdinit 0 + apn re-dial"
  ccci_mdinit 0 2>&1 | tee -a "$T"
  sleep 10
  probe mipc_wan_cli --show_register_status; echo "  [T2] after mdinit register: [$out]" | tee -a "$T"
  /etc/init.d/mt6890-apn restart
  i=1
  while [ $i -le 6 ]; do
    sleep 15
    GW=$(ip route 2>/dev/null | awk '/^default/{print $3}')
    P=$(ping -c 3 8.8.8.8 2>&1 | grep -c 'bytes from')
    LOG "T2 poll $i: gw=$GW ping=$P/3 ccmni1=$(ccmni)"
    [ "$P" -ge 1 ] && break
    i=$((i+1))
  done
  egress "T2-post"
  PT2=$LAST_PING
else
  echo "  [T2] skipped (egress alive after T1)"
  PT2=$PON
fi
logread 2>/dev/null | grep mt6890-apn | tail -4 | sed 's/^/  apn log: /' | tee -a "$T"

echo "== P4 final state =="
echo "  default gw: $(ip route 2>/dev/null | awk '/^default/{print $3}')"
echo "  ccmni1: $(ccmni)"
echo "  leds: $(leds_on && echo on || echo off)"
egress "FINAL"
PF=$LAST_PING

echo "==============================================================="
echo " LOG COLLECTOR -> /tmp/v312-debug-logs.tar.gz"
echo "==============================================================="
D=$W/logs; rm -rf "$D"; mkdir -p "$D"
logread > "$D/01-logread-full.txt" 2>/dev/null
logread 2>/dev/null | grep -E "mt6890-wifi|mt6890-modem|mt6890-apn|mt6890-leds|mtkmipc|mtkwifi|ccci|mipc" > "$D/02-modem-chain.txt"
dmesg > "$D/03-dmesg.txt" 2>/dev/null
ps w > "$D/04-ps.txt" 2>/dev/null
mt6890-bootctl status > "$D/05-bootctl.txt" 2>&1
{ mount; echo ---; cat /proc/mtd; } > "$D/06-mounts-mtd.txt" 2>&1
{ ip addr; echo ---; ip route; echo ---; cat /tmp/resolv.conf.auto 2>/dev/null; } > "$D/07-net.txt" 2>&1
uci show > "$D/08-uci-show.txt" 2>&1
{ /etc/init.d/firewall show; echo ---; iptables -S -t filter 2>/dev/null; echo ---; iptables -S -t nat 2>/dev/null; } > "$D/09-firewall.txt" 2>&1
{ ifstatus br-lan 2>/dev/null; echo ---; ifstatus wan 2>/dev/null; } > "$D/10-ifstatus.txt" 2>&1
opkg list-installed > "$D/11-opkg.txt" 2>&1
{ for n in /sys/class/leds/*/brightness; do echo "$n=$(cat $n 2>/dev/null)"; done; echo ---; logread 2>/dev/null | grep mt6890-leds | tail -10; } > "$D/12-leds.txt" 2>&1
{ probe mipc_wan_cli --show_sim_status; echo ---
  probe mipc_wan_cli --nw_radio_state_get 0; echo ---
  probe mipc_wan_cli --show_register_status; echo ---
  probe mipc_wan_cli --nw_get_rat; echo ---
  probe mipc_wan_cli --nw_get_signal; } > "$D/13-mipc-final.txt" 2>&1
{ ls -la /www 2>&1; echo ---; ls -la /overlay/upper 2>&1; echo ---
  find /overlay/upper -maxdepth 3 -name 'luci*' 2>&1 | head -20; echo ---
  find /overlay/upper/www -type c 2>&1 | head -20; echo ---
  opkg files luci-base 2>&1 | head -10; } > "$D/14-www-forensics.txt" 2>&1
{ ls -la /mnt/vendor/nvram/ 2>&1; echo ---; ls -la /mnt/vendor/nvram/raw 2>&1; echo ---
  ls -la /mnt/vendor/nvdata/ 2>&1; } > "$D/15-nvram.txt" 2>&1
cp "$T" "$D/16-trials.txt" 2>/dev/null
{ cat /etc/openwrt_version; date; uptime; df -h; free; } > "$D/17-system.txt" 2>&1
tar -czf /tmp/v312-debug-logs.tar.gz -C "$W" logs 2>/dev/null || tar -cf /tmp/v312-debug-logs.tar -C "$W" logs
ls -la /tmp/v312-debug-logs.tar* 2>/dev/null

echo "==============================================================="
echo " VERDICT"
echo "==============================================================="
echo " Egress: T1 off=$POFF on=$PON | T2 $T2RAN post=$PT2 | final=$PF/5"
echo " T1 LED: $T1V"
echo " MIPC:   baseline register=[$REG0]  final=[$REG1]  (empty = request path wedged)"
echo " LuCI:   /www/luci $([ -d /www/luci ] && echo present || echo MISSING), whiteouts=$WH"
echo " SIM:    if final=0/5 and register says NOT_REGISTERED/SIM -> insert SIM, re-run once"
echo " Logs:   /tmp/v312-debug-logs.tar.gz"
echo " Pull:   scp -O root@192.168.1.1:/tmp/v312-debug-logs.tar.gz ."
echo "==============================================================="
