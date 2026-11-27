#!/bin/sh
# v311-verify.sh — DWR-2000M A3 v3.1.1 full-stack validation + log collector
# Read-only (one 3x ping to 8.8.8.8). POSIX sh / BusyBox ash. Safe via wget|sh.
probe() {
  ( "$@" </dev/null >/tmp/.g_out 2>&1 & gp=$!; sleep 8
    kill $gp >/dev/null 2>&1
    wait $gp >/dev/null 2>&1 )
  out=$(cat /tmp/.g_out 2>/dev/null)
}
ok()   { echo "  [OK]   $*"; }
warn() { echo "  [WARN] $*"; }
fail() { echo "  [FAIL] $*"; FAILS=$((FAILS+1)); }
FAILS=0

echo "==============================================================="
echo " v3.1.1 FULL-STACK VALIDATION"
echo "==============================================================="

echo "== L0 identity / slot =="
cat /etc/openwrt_version 2>/dev/null
uname -r; uptime
mt6890-bootctl status 2>/dev/null

echo "== L1 kernel =="
echo "  dmesg error lines: $(dmesg 2>/dev/null | grep -ciE 'error|oops|panic')"
dmesg 2>/dev/null | grep -iE 'ubi|led' | tail -3 | sed 's/^/  /'

echo "== L2 services =="
for s in mt6890-wifi mt6890-modem mt6890-apn mt6890-leds uhttpd firewall network; do
  [ -x /etc/init.d/$s ] && ok "init.d/$s" || fail "init.d/$s MISSING"
done
echo "  procd lines touching port services: $(logread 2>/dev/null | grep procd | grep -cE 'mt6890-(wifi|modem|apn|leds)')"

echo "== L3 storage =="
echo "  vendor/ubi mounts: $(mount 2>/dev/null | grep -cE 'mtdblock|ubi|jffs2|yaffs2')"
[ -d /vendor/etc/md ] && ok "/vendor/etc/md" || fail "/vendor/etc/md MISSING"
df -h /overlay /tmp 2>/dev/null | sed 's/^/  /'

echo "== L4 wifi =="
ip link show ra0 2>/dev/null | head -1
ip link show rai0 2>/dev/null | head -1
echo "  wifi-iface sections: $(uci show wireless 2>/dev/null | grep -c wifi-iface)"
echo "  mt6890-wifi log:"
logread 2>/dev/null | grep mt6890-wifi | tail -3 | sed 's/^/    /'

echo "== L5 cellular chain =="
for d in nvram_daemon cci_fsd cci_mdinit ql_ril_service mipc_submonitor; do
  pidof $d >/dev/null 2>&1 && ok "$d" || fail "$d NOT running"
done
echo "-- sim (8s guard):"; probe mipc_wan_cli --show_sim_status; echo "   $out"
echo "-- radio (8s guard):"; probe mipc_wan_cli --nw_radio_state_get 0; echo "   $out"
echo "-- register (8s guard):"; probe mipc_wan_cli --show_register_status; echo "   $out"
echo "-- rat (8s guard):"; probe mipc_wan_cli --nw_get_rat; echo "   $out"
echo "-- ccmni:"; ip link 2>/dev/null | grep ccmni | sed 's/^/   /'
echo "-- routes:"; ip route 2>/dev/null | sed 's/^/   /'
echo "-- resolv:"; cat /tmp/resolv.conf.auto 2>/dev/null | sed 's/^/   /'
echo "  mt6890-apn log:"; logread 2>/dev/null | grep mt6890-apn | tail -6 | sed 's/^/    /'
echo "  mt6890-modem log:"; logread 2>/dev/null | grep mt6890-modem | tail -4 | sed 's/^/    /'
echo "-- ping E2E (3x 8.8.8.8):"; ping -c 3 8.8.8.8 2>&1 | tail -2 | sed 's/^/   /'

echo "== L6 firewall / NAT =="
/etc/init.d/firewall show 2>/dev/null | grep -E '^zone|^forward' | sed 's/^/  /'
uci show firewall 2>/dev/null | grep -iE 'wan.*(device|network)' | sed 's/^/  /'

echo "== L7 LuCI =="
pidof uhttpd >/dev/null 2>&1 && ok "uhttpd" || fail "uhttpd DOWN"
[ -d /www/luci ] && ok "/www/luci" || fail "/www/luci MISSING"
echo "  http /luci/ (first 100B):"
wget -q -O- --timeout=5 http://127.0.0.1/luci/ 2>/dev/null | head -c 100; echo
[ -f /usr/share/ucode/template/themes/bootstrap/footer.ut ] && ok "footer.ut" || fail "footer.ut MISSING"
echo "  luci packages installed: $(opkg list-installed 2>/dev/null | grep -c '^luci')"

echo "== L8 LEDs =="
found=
for p in /proc/[0-9]*; do tr '\0' ' ' < "$p/cmdline" 2>/dev/null | grep -q "led9514" && found=1; done
[ -n "$found" ] && ok "leds service running" || fail "leds service NOT running"
for n in led9514:green:power led9511:green:lte-rssi led9508:green:nr-rssi led9502:red:cellular-stat led9507:red:nr-rssi; do
  echo "  $n brightness=$(cat /sys/class/leds/$n/brightness 2>/dev/null)"
done
echo "  mt6890-leds log:"; logread 2>/dev/null | grep mt6890-leds | tail -4 | sed 's/^/    /'

echo "== L9 packages =="
echo "  installed: $(opkg list-installed 2>/dev/null | wc -l)"
for p in mt6890-mtkmipc mt6890-mtkwifi mt6890-sysupgrade mt6890-luci-footer; do
  opkg list-installed 2>/dev/null | grep -q "^$p " && ok "$p" || fail "$p NOT installed"
done

echo "== L10 system =="
echo "  date: $(date) (clock unverified until NTP)"
echo "  logread lines: $(logread 2>/dev/null | wc -l)"

echo "==============================================================="
echo " LOG COLLECTOR -> /tmp/v311-logs.tar.gz"
echo "==============================================================="
D=/tmp/v311-logs; rm -rf $D; mkdir -p $D
logread > $D/01-logread-full.txt 2>/dev/null
logread 2>/dev/null | grep -E "mt6890-wifi|mt6890-modem|mt6890-apn|mt6890-leds|mtkmipc|mtkwifi" > $D/02-port-services.txt
dmesg > $D/03-dmesg.txt 2>/dev/null
ps w > $D/04-ps.txt 2>/dev/null
mt6890-bootctl status > $D/05-bootctl.txt 2>&1
mount > $D/06-mounts.txt 2>&1
cat /proc/mtd > $D/07-mtd.txt 2>&1
ip addr > $D/09-ip-addr.txt 2>&1
ip route > $D/10-ip-route.txt 2>&1
/etc/init.d/firewall show > $D/11-firewall.txt 2>&1
uci show > $D/12-uci-show.txt 2>&1
ifstatus br-lan > $D/13-ifstatus-br-lan.txt 2>&1
cat /tmp/resolv.conf.auto > $D/14-resolv.txt 2>&1
opkg list-installed > $D/15-opkg.txt 2>&1
for n in /sys/class/leds/*/brightness; do echo "$n = $(cat $n 2>/dev/null)"; done > $D/16-leds-brightness.txt 2>&1
for n in /sys/class/leds/*/trigger; do echo "$n = $(cat $n 2>/dev/null)"; done > $D/17-leds-triggers.txt 2>&1
{ probe mipc_wan_cli --show_sim_status; echo ---
  probe mipc_wan_cli --nw_radio_state_get 0; echo ---
  probe mipc_wan_cli --show_register_status; echo ---
  probe mipc_wan_cli --nw_get_rat; echo ---
  probe mipc_wan_cli --nw_get_signal; } > $D/18-mipc-state.txt 2>&1
{ cat /etc/openwrt_version; date; df -h; free; } > $D/19-system.txt 2>&1
tar -czf /tmp/v311-logs.tar.gz -C /tmp v311-logs 2>/dev/null || tar -cf /tmp/v311-logs.tar -C /tmp v311-logs
ls -la /tmp/v311-logs.tar* 2>/dev/null
echo "==============================================================="
echo " DONE. FAIL count this run: $FAILS"
echo " Pull logs from WSL: scp -O root@192.168.1.1:/tmp/v311-logs.tar.gz ."
echo "==============================================================="
