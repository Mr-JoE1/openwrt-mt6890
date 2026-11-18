#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# import-stock.sh - populate the LOCAL-ONLY package
#   openwrt/package/vendor/vendor-kernel-4.19.205/files/
# from the owner's own stock module backup. Nothing produced here may be
# committed (openwrt/ and package/vendor/ are git-ignored).
#
# Pinning: every .ko from the tgz must be byte-identical (full sha256) to
# the reference tree build/modules-extracted/modules/4.19.205/, AND its
# sha256 must start with the 12-hex prefix recorded in
# docs/PORTING-ANALYSIS.md §2.1 (embedded below). Any mismatch, missing or
# extra module -> refuse, nothing is installed.
#
# Autoload: /etc/modules.d lists are the stock groups (stock rootfs
# /etc/modules.d, §2 "stock autoload" column) with built-in (no .ko) names
# removed. bluetooth (autoload N) is loaded as a dependency of btmtk_uart.
#
# Phase 2 (vendor): finds the §6.2-2 files by name anywhere in the extracted
# stock squashfs (build/rootfs_a-squashfs) and copies them (modes preserved)
# into vendor-modem-stack / vendor-mtwifi-fw / vendor-compat-libs files/.
# Every source is sha256-pinned in build/vendor-files.sha256 on first import;
# re-runs refuse if any pinned source changed, vanished or a new one appeared
# (--repin to accept deliberately). Absent files -> "MISSING: <name>", never
# substituted. Stock init/upgrade scripts are never imported.

set -euo pipefail

KVER=4.19.205
NKO=136

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

Phase "kernel": copy the stock ${KVER} modules into the vendor-kernel package
and write /etc/modules.d autoload lists. Refuses on any sha256 mismatch.
Phase "vendor": copy the stock modem / MT7915 wifi / compat-lib files from
the extracted stock rootfs into the other three vendor packages, sha256-pinned.

Options:
  -p, --phase P     kernel | vendor | all (default: all)
  -t, --tgz FILE    module tarball      (default: evidence/modules-${KVER}.tgz)
  -r, --ref DIR     pinned reference    (default: build/modules-extracted/modules/${KVER})
  -o, --out DIR     kernel files dir    (default: openwrt/package/vendor/vendor-kernel-${KVER}/files)
  -s, --rootfs DIR  stock rootfs tree   (default: build/rootfs_a-squashfs)
  -V, --vendor DIR  vendor package dir  (default: openwrt/package/vendor)
  -m, --pins FILE   vendor pin manifest (default: build/vendor-files.sha256)
  -f, --force       kernel: replace an existing populated files/ dir
      --repin       vendor: discard the manifest and pin the current sources
  -h, --help        this help
Paths are relative to the project root (parent of scripts/).
A populated kernel files/ whose SHA256SUMS still verifies is skipped (rc 0)
unless --force; one that fails verification is refused.
EOF
}

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TGZ="$ROOT/evidence/modules-${KVER}.tgz"
REF="$ROOT/build/modules-extracted/modules/${KVER}"
OUT="$ROOT/openwrt/package/vendor/vendor-kernel-${KVER}/files"
ROOTFS="$ROOT/build/rootfs_a-squashfs"
VPKG="$ROOT/openwrt/package/vendor"
VPINS="$ROOT/build/vendor-files.sha256"
PHASE=all
FORCE=0
REPIN=0

while [ $# -gt 0 ]; do
	case "$1" in
	-p|--phase) PHASE="$2"; shift 2 ;;
	-t|--tgz) TGZ="$2"; shift 2 ;;
	-r|--ref) REF="$2"; shift 2 ;;
	-o|--out) OUT="$2"; shift 2 ;;
	-s|--rootfs) ROOTFS="$2"; shift 2 ;;
	-V|--vendor) VPKG="$2"; shift 2 ;;
	-m|--pins) VPINS="$2"; shift 2 ;;
	-f|--force) FORCE=1; shift ;;
	--repin) REPIN=1; shift ;;
	-h|--help) usage; exit 0 ;;
	*) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
	esac
done
case "$PHASE" in kernel|vendor|all) ;; *) echo "bad --phase: $PHASE" >&2; usage >&2; exit 2 ;; esac

die() { echo "import-stock: ERROR: $*" >&2; exit 1; }

command -v sha256sum >/dev/null || die "sha256sum not found"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

###########################################################################
# Phase 2: vendor modem / wifi-fw / compat-libs from the stock rootfs
###########################################################################

# §6.2-2 file list. "<pkg> <kind> <name-or-glob>"; kind decides the dest dir:
#   bin   -> usr/bin (usr/sbin if the stock file lives in an sbin dir)
#   lib   -> usr/lib       conf -> etc/conf
#   fw    -> lib/firmware  wl   -> etc/wireless   wlmtk -> etc/wireless/mediatek
#   P4 stock Lua wifi stack (X28 lineage /sbin/wifi + mtkwifi.lua; top level
#   only, the stock LuCI tree is not imported):
#   wlsig -> etc/wireless/sigma_test   stock -> same path (sbin/, usr/bin/)
#   luamod -> usr/lib/lua   libwifi -> lib/wifi   kvcutil -> lib
# Exact names are reported MISSING when absent; globs (containing *) are
# reported MISSING when they match nothing.
VENDOR_SPEC='
vendor-modem-stack bin ccci_fsd
vendor-modem-stack bin ccci_mdinit
vendor-modem-stack bin nvram_daemon
vendor-modem-stack bin ql_ril_service
vendor-modem-stack bin ql_netd
vendor-modem-stack bin mipc_submonitor
vendor-modem-stack bin atcid
vendor-modem-stack bin mipc_wan_cli
vendor-modem-stack bin cpe_sim
vendor-modem-stack bin dd-nand
vendor-modem-stack lib libmipc_msg.so
vendor-modem-stack lib libql_at.so
vendor-modem-stack lib libdtmf_detect.so
vendor-modem-stack lib libnandapi.so
vendor-modem-stack conf apns-conf_8.xml
vendor-mtwifi-fw fw *mt7915*
vendor-mtwifi-fw fw *MT7915*
vendor-mtwifi-fw fw mt7915_patch_e2_hdr.bin
vendor-mtwifi-fw fw WIFI_RAM_CODE_MT7915*
vendor-mtwifi-fw fw 7915_WACPU_RAM_CODE_release.bin
vendor-mtwifi-fw wl l1profile.dat
vendor-mtwifi-fw wlmtk *.dat
vendor-mtwifi-fw wlmtk mt7915.dbdc.b0.dat
vendor-mtwifi-fw wlmtk mt7915.dbdc.b1.dat
vendor-mtwifi-fw wlmtk e2p*
vendor-mtwifi-fw wlmtk version
vendor-mtwifi-fw wlsig *.dat
vendor-mtwifi-fw stock wifi
vendor-mtwifi-fw stock lua
vendor-mtwifi-fw stock datconf
vendor-mtwifi-fw luamod *.lua
vendor-mtwifi-fw luamod *.so
vendor-mtwifi-fw libwifi *.lua
vendor-mtwifi-fw kvcutil libkvcutil.so.1.0.0.0
vendor-compat-libs lib libjson-c.so.2*
vendor-compat-libs lib libubox.so
vendor-compat-libs lib libuci.so
vendor-modem-stack lib libccci.so
vendor-modem-stack lib libfile_op.so
vendor-modem-stack lib libmtk_audio_mixer_ctrl.so
vendor-modem-stack lib libnvram.so
vendor-modem-stack lib libql_mipc.so
vendor-modem-stack lib libql_qlog.so
vendor-modem-stack lib libquectel_atcmd.so
vendor-modem-stack lib libubus.so.20210603
vendor-modem-stack lib libgnsshal.so
vendor-modem-stack lib libql_comtools.so
vendor-modem-stack lib libqlslic.so
vendor-modem-stack lib libaudio-ctrl-service-interface.so
'
VENDOR_PKGS="vendor-modem-stack vendor-mtwifi-fw vendor-compat-libs"

# SONAMEs a 24.10 package provides at that exact name (vendor ELF NEEDED
# check). libubox.so / libuci.so ARE now imported from the stock rootfs
# (vendor-compat-libs) because the vendor ELFs' NEEDED entries require the
# plain SONAMEs, which 24.10 libubox / libuci do not install (they only
# install the ABI-versioned libX.so.<abi>; see NOTES-p2 P2c).
SONAME_2410='libc.so libgcc_s.so.1 libasound.so.2 libpthread.so.0 libdl.so.2 librt.so.1 libm.so.6'

# search scope per kind (relative to rootfs; -path patterns for find)
vendor_scope() {
	case "$1" in
	fw) echo "lib/firmware" ;;
	wl) echo "etc/wireless" ;;
	wlmtk) echo "etc/wireless/mediatek" ;;
	wlsig) echo "etc/wireless/sigma_test" ;;
	stock) echo "sbin usr/bin" ;;
	luamod) echo "usr/lib/lua" ;;
	libwifi) echo "lib/wifi" ;;
	kvcutil) echo "lib" ;;
	*) echo "." ;;
	esac
}

# find depth limit per kind (stock Lua stack: top level only - the stock
# LuCI tree under usr/lib/lua/luci/ is deliberately NOT imported)
vendor_depth() {
	case "$1" in
	stock|luamod|libwifi|kvcutil|wlsig) echo "-maxdepth 1" ;;
	*) echo "" ;;
	esac
}

vendor_dest() { # kind src-rel -> dest-rel
	local kind="$1" src="$2" base
	base="$(basename "$src")"
	case "$kind" in
	bin) case "$(dirname "$src")" in */sbin|sbin) echo "usr/sbin/$base" ;; *) echo "usr/bin/$base" ;; esac ;;
	lib) echo "usr/lib/$base" ;;
	conf) echo "etc/conf/$base" ;;
	fw) echo "lib/firmware/$base" ;;
	wl) echo "etc/wireless/$base" ;;
	wlmtk) echo "etc/wireless/mediatek/$base" ;;
	wlsig) echo "etc/wireless/sigma_test/$base" ;;
	stock) echo "$src" ;;                 # keep the stock path (sbin/wifi, usr/bin/lua, usr/bin/datconf)
	luamod) echo "usr/lib/lua/$base" ;;
	libwifi) echo "lib/wifi/$base" ;;
	kvcutil) echo "lib/$base" ;;          # SONAME links made by the package Makefile
	*) die "internal: kind $kind" ;;
	esac
}

phase_vendor() {
	[ -d "$ROOTFS" ] || die "stock rootfs dir missing: $ROOTFS"
	[ -d "$VPKG" ] || die "vendor package dir missing: $VPKG"
	local p
	for p in $VENDOR_PKGS; do
		[ -f "$VPKG/$p/Makefile" ] || die "missing $VPKG/$p/Makefile"
	done

	local cur="$TMP/vendor.cur" nmiss=0 fail=0
	: > "$cur"
	declare -A TAKEN=()
	local pkg kind pat scope src rel dest h mode
	while read -r pkg kind pat; do
		[ -n "$pkg" ] || continue
		local hits=0 sdir depth
		depth="$(vendor_depth "$kind")"
		for sdir in $(vendor_scope "$kind"); do
		scope="$sdir"
		if [ -d "$ROOTFS/$scope" ]; then
			while IFS= read -r -d '' src; do
				rel="${src#"$ROOTFS"/}"
				rel="${rel#./}"
				# never import stock init / upgrade machinery
				case "$rel" in etc/init.d/*|etc/rc.d/*|lib/upgrade/*) continue ;; esac
				hits=$((hits + 1))
				[ -z "${TAKEN[$rel]:-}" ] || continue   # already matched by an earlier rule
				if [ -L "$src" ] || [ ! -f "$src" ]; then
					echo "import-stock: REFUSED non-regular file: $rel" >&2; fail=1; continue
				fi
				dest="$(vendor_dest "$kind" "$rel")"
				TAKEN[$rel]="$pkg/$dest"
				h="$(sha256sum < "$src" | cut -d' ' -f1)"
				mode="$(stat -c %a "$src")"
				printf '%s %s %s %s %s\n' "$h" "$mode" "$pkg" "$rel" "$dest" >> "$cur"
			# shellcheck disable=SC2086
			done < <(find "$ROOTFS/$scope" $depth \( -type f -o -type l \) -name "$pat" -print0)
		fi
		done
		if [ "$hits" -eq 0 ]; then
			echo "MISSING: $pat ($pkg)"
			nmiss=$((nmiss + 1))
		fi
	done <<< "$VENDOR_SPEC"
	[ "$fail" -eq 0 ] || die "non-regular source files - nothing installed"

	# two sources must not land on one destination
	local dup
	dup="$(awk '{print $3"/"$5}' "$cur" | sort | uniq -d)"
	[ -z "$dup" ] || die "ambiguous: several stock files map to: $dup"

	LC_ALL=C sort -k3,3 -k5,5 -o "$cur" "$cur"

	# pin / verify
	if [ -f "$VPINS" ] && [ "$REPIN" -ne 1 ]; then
		if ! diff -u <(grep -v '^#' "$VPINS") "$cur" > "$TMP/pins.diff"; then
			cat "$TMP/pins.diff" >&2
			die "stock sources differ from pinned $VPINS (--repin to accept) - nothing installed"
		fi
		echo "import-stock: $(wc -l < "$cur") vendor sources match pins in ${VPINS#"$ROOT"/}"
	else
		mkdir -p "$(dirname "$VPINS")"
		{
			echo "# import-stock.sh vendor pins: sha256 mode package src(rel. stock rootfs) dest(rel. files/)"
			echo "# rootfs: ${ROOTFS#"$ROOT"/}"
			cat "$cur"
		} > "$VPINS.new"
		mv "$VPINS.new" "$VPINS"
		echo "import-stock: pinned $(wc -l < "$cur") vendor sources -> ${VPINS#"$ROOT"/}"
	fi

	# stage per package, verify against pins, swap in
	for p in $VENDOR_PKGS; do
		local stage="$TMP/stage-$p" n=0
		rm -rf "$stage"; mkdir -p "$stage"
		while read -r h mode pkg rel dest; do
			[ "$pkg" = "$p" ] || continue
			mkdir -p "$stage/$(dirname "$dest")"
			cp -p "$ROOTFS/$rel" "$stage/$dest"
			chmod "$mode" "$stage/$dest"
			[ "$(sha256sum < "$stage/$dest" | cut -d' ' -f1)" = "$h" ] || die "copy mismatch: $rel"
			n=$((n + 1))
		done < "$cur"
		local out="$VPKG/$p/files"
		if [ "$n" -eq 0 ]; then
			echo "import-stock: $p: 0 files found - files/ left unpopulated (package build will refuse)"
			rm -rf "$out"
			continue
		fi
		(cd "$stage" && find . -type f ! -name SHA256SUMS | sed 's|^\./||' | LC_ALL=C sort | xargs sha256sum) > "$stage/SHA256SUMS"
		rm -rf "$out.new"
		mv "$stage" "$out.new"
		rm -rf "$out"
		mv "$out.new" "$out"
		echo "import-stock: $p: $n files -> ${out#"$ROOT"/}"
	done

	# NEEDED SONAMEs of the imported ELFs not satisfied by the import itself
	# or by a 24.10 package of that exact SONAME (informational)
	if command -v readelf >/dev/null; then
		declare -A HAVE=()
		local s
		for s in $SONAME_2410; do HAVE[$s]=24.10; done
		while read -r h mode pkg rel dest; do HAVE[$(basename "$dest")]=import; done < "$cur"
		while read -r h mode pkg rel dest; do
			readelf -h "$ROOTFS/$rel" >/dev/null 2>&1 || continue
			for s in $(readelf -d "$ROOTFS/$rel" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p'); do
				[ -n "${HAVE[$s]:-}" ] || echo "UNSATISFIED-NEEDED: $rel -> $s"
			done
		done < "$cur"
	fi
	echo "import-stock: vendor phase done ($nmiss MISSING)"
}

###########################################################################
# Phase 1: vendor-kernel modules
###########################################################################

# sha256[:12] + module, from PORTING-ANALYSIS.md §2.1 (136 rows)
PINS='
834ac873f602 act_connmark 892fb11afe7b act_skbedit 7a4fb230c1ca af_alg
7ea0755e0989 algif_hash 3a543168abbe algif_skcipher 038ac1d3b998 bluetooth
dca3ae257573 br_netfilter b4f5e2ec399c btmtk_uart be0bc8271d15 cls_basic
83a2689849cd cls_matchall f6df92aee19c cls_route 01427fd97189 cls_tcindex
996ab95f1b79 conninfra d57587bfba52 crc-ccitt 6548ee994c16 cryptodev
1299835c9dd6 ebt_802_3 d40672f3d00f ebt_among 05a7ef070ac6 ebt_arp
c004286545ff ebt_arpreply 0218f3e95b90 ebt_dnat 25da8608b349 ebt_ip
4e11ebe2556d ebt_ip6 21678c6cb197 ebt_limit 51183475b6f0 ebt_log
6705fba687c7 ebt_mark 07faadd4c9dd ebt_mark_m 9d07c67f50bc ebt_nflog
0d8e8bca00c2 ebt_pkttype e4f62b45f86d ebt_redirect b9ad60cdf9f6 ebt_snat
916e817d42f3 ebt_stp 603898258717 ebt_vlan a77848f530fe ebtable_broute
41d845e45a5f ebtable_filter 03fdcb44dd61 ebtable_nat 6257598ada71 ebtables
6222368c8773 gps_drv 1afc66ce70a8 hw_nat 517a6a6a5c6b ifb
1fb35d15f0bb ip6_gre b5a9885c0fd7 ip6_tables 0bd2894b955c ip6t_REJECT
19d54eebcbb5 ip6table_filter afd6d1c50ddb ip6table_mangle 5dadf47546d2 ip_gre
897ff7ad4879 ip_set c37cb4a724ba ip_set_bitmap_ip 0b6f18dde8b3 ip_set_bitmap_ipmac
3023f4c8db47 ip_set_bitmap_port b32514277f84 ip_set_hash_ip 0dc3847414f2 ip_set_hash_ipmark
63cb12a28fd3 ip_set_hash_ipport dca2a14debc1 ip_set_hash_ipportip eb189d3e6b27 ip_set_hash_ipportnet
8048076c5711 ip_set_hash_mac 125d6bce03a1 ip_set_hash_net d24043f1a3d2 ip_set_hash_netiface
00d05389ef9c ip_set_hash_netnet 2cf33e17fafb ip_set_hash_netport e6047782793c ip_set_hash_netportnet
ff06c95a57b6 ip_set_list_set 7c2de0723f11 ip_tables a1dc844f207d ipt_ECN
6c498e346ebb ipt_MASQUERADE ac7a836232ac ipt_REJECT cf1ac1e8ab8a iptable_filter
5ef2bb6e7ae6 iptable_mangle bf521c611fab iptable_nat 630bf386af13 iptable_raw
72bec2b770e3 l2tp_eth 1dfc9eb6237e l2tp_ip 2da0d68c195b l2tp_ip6
d6bd9544ea1f mapfilter cff751c51c2f mt_wifi 465639084594 mtk_warp
26e325b0aaea mtk_warp_proxy 45741dc53422 nat46 d8e550bd220d nf_conncount
86d86bd2168f nf_conntrack d1eeba8ed559 nf_conntrack_ftp 098c6b714301 nf_conntrack_netlink
a26d93897705 nf_conntrack_rtcache 4fdb213a8375 nf_defrag_ipv4 53aa062ed6e2 nf_defrag_ipv6
81d69b8c8ba0 nf_log_common b10d70810d74 nf_log_ipv4 17a459631e69 nf_log_ipv6
f803f429aa32 nf_nat f5a330361e8f nf_nat_ftp 895f0a5d9e0e nf_nat_ipv4
c6a59f7dc233 nf_reject_ipv4 6cdc1d204df5 nf_reject_ipv6 be406f608a3c nfnetlink
3b64d55e06a7 ppp_async 9bd8f368dc32 pppoe c66ddd550fb9 sch_hfsc
00e3c4756aa7 sch_tbf 86d4025a305d snd-compress ee5f474e0191 snd-mixer-oss
3bfc0e9e3abf snd-pcm-oss 52cb93290c83 ts_bm 69329dbdaaf0 ts_fsm
a017b885e464 ts_kmp a6c834a02118 wifi_md_coex 096b5f1bf088 x_tables
05690fae0093 xt_CLASSIFY 7734727f11e0 xt_CT 0b762870283a xt_DSCP
773fdd330a16 xt_HL c6c6ada6335d xt_LOG fef657a85300 xt_REDIRECT
d67fe235f787 xt_TCPMSS 7f474e8c87b4 xt_bpf 48102b9998af xt_comment
8e6984bbaf8f xt_connbytes 1f9bca4d267b xt_connlimit 08e1eaa95b0c xt_connmark
12c6ab2d146f xt_conntrack a5cdca6df4ae xt_dscp 1ea5185ac5ae xt_ecn
34ed97fc4220 xt_helper 8c520e6ed5db xt_hl f06e61a69655 xt_length
22210faadc3e xt_limit d1511c8a48da xt_mac 2e1fd51e0f8b xt_mark
a563b8a96f6e xt_multiport fde2d9803036 xt_nat ce66fa2e1b7d xt_recent
868d67608e8b xt_set 1bf3014ef1e1 xt_state ffe0f16eb646 xt_statistic
13fbc605cecc xt_string ed7d69da9785 xt_tcpmss de4e5042f84a xt_tcpudp
651fac419d19 xt_time
'

# Stock /etc/modules.d groups: "<file>: <module> [<module> ...]".
# Built-ins (no .ko) are filtered out below against the pinned set; a
# module argument like cryptodev_verbosity=-1 is kept with its module.
MODULES_D='
02-crypto-hash: crypto_hash
04-crypto-crc32c: crc32c_generic
09-crypto-aead: aead
09-crypto-authenc: authenc
09-crypto-ecb: ecb
09-crypto-manager: cryptomgr
09-crypto-null: crypto_null
09-crypto-sha1: sha1_generic
09-crypto-user: af_alg algif_hash algif_skcipher
15-libphy: libphy
20-lib-crc16: crc16
30-conninfra: conninfra
30-fs-autofs4: autofs4
30-fs-ext4: ext4 jbd2 mbcache
30-sound-core: snd snd-compress snd-hwdep snd-mixer-oss snd-pcm snd-pcm-oss snd-rawmidi snd-seq-device snd-timer soundcore
30-tun: tun
31-iptunnel: ip_tunnel
31-iptunnel6: tunnel6
32-ip6-tunnel: ip6_tunnel
32-l2tp: l2tp_core l2tp_netlink
32-udptunnel4: udp_tunnel
32-udptunnel6: ip6_udp_tunnel
33-l2tp-eth: l2tp_eth
33-l2tp-ip: l2tp_ip l2tp_ip6
33-nat46: nat46
34-ifb: ifb
39-gre: gre ip_gre
39-gre6: ip6_gre
41-swconfig: swconfig
42-ip6tables: ip6t_REJECT ip6table_filter ip6table_mangle nf_log_ipv6
49-ipt-ipset: ip_set ip_set_bitmap_ip ip_set_bitmap_ipmac ip_set_bitmap_port ip_set_hash_ip ip_set_hash_ipmark ip_set_hash_ipport ip_set_hash_ipportip ip_set_hash_ipportnet ip_set_hash_mac ip_set_hash_net ip_set_hash_netiface ip_set_hash_netnet ip_set_hash_netport ip_set_hash_netportnet ip_set_list_set xt_set
50-cryptodev: cryptodev=cryptodev_verbosity=-1
50-gps_drv: gps_drv
60-warp: mtk_warp
70-hw_nat: hw_nat
70-sched-core: act_mirred act_skbedit cls_basic cls_flow cls_fw cls_matchall cls_route cls_tcindex cls_u32 em_u32 sch_fq_codel sch_hfsc sch_htb sch_ingress sch_tbf
71-sched-connmark: act_connmark
br-netfilter: br_netfilter
btmtk_uart: btmtk_uart
ebtables: ebt_802_3 ebt_among ebt_limit ebt_mark ebt_mark_m ebt_pkttype ebt_redirect ebt_stp ebt_vlan ebtable_broute ebtable_filter ebtable_nat ebtables
ebtables-ipv4: ebt_arp ebt_arpreply ebt_dnat ebt_ip ebt_snat
ebtables-ipv6: ebt_ip6
ebtables-watchers: ebt_log ebt_nflog
ipt-conntrack: xt_CT xt_conntrack xt_state
ipt-conntrack-extra: nf_conncount xt_connbytes xt_connlimit xt_connmark xt_helper xt_recent
ipt-core: ipt_REJECT iptable_filter iptable_mangle nf_log_common nf_log_ipv4 xt_LOG xt_TCPMSS xt_comment xt_limit xt_mac xt_mark xt_multiport xt_tcpudp xt_time
ipt-filter: xt_bpf xt_string
ipt-ipopt: ipt_ECN xt_CLASSIFY xt_DSCP xt_HL xt_dscp xt_ecn xt_hl xt_length xt_statistic xt_tcpmss
ipt-nat: ipt_MASQUERADE iptable_nat xt_REDIRECT xt_nat
ipt-raw: iptable_raw
lib-crc-ccitt: crc-ccitt
lib-textsearch: ts_bm ts_fsm ts_kmp
mapfilter: mapfilter
mppe: ppp_mppe
mt_wifi: mt_wifi mtk_warp_proxy
nf-conntrack: nf_conntrack nf_conntrack_rtcache nf_defrag_ipv4 nf_defrag_ipv6
nf-conntrack-netlink: nf_conntrack_netlink
nf-ipt: ip_tables x_tables
nf-ipt6: ip6_tables
nf-nat: nf_nat nf_nat_ipv4
nf-nathelper: nf_conntrack_ftp nf_nat_ftp
nf-reject: nf_reject_ipv4
nf-reject6: nf_reject_ipv6
nfnetlink: nfnetlink
ppp: ppp_async
pppoe: pppoe
pppol2tp: l2tp_ppp
pptp: pptp
wifi_md_coex: wifi_md_coex
'

declare -A PIN
set -f
# shellcheck disable=SC2086
set -- $PINS
set +f
while [ $# -ge 2 ]; do PIN["$2"]="$1"; shift 2; done
[ "${#PIN[@]}" -eq "$NKO" ] || die "internal: ${#PIN[@]} pins, expected $NKO"

phase_kernel() {
if [ -e "$OUT/SHA256SUMS" ] && [ "$FORCE" -ne 1 ]; then
	if (cd "$OUT" && sha256sum -c --quiet SHA256SUMS); then
		echo "import-stock: ${OUT#"$ROOT"/} already populated and verified - skipped (--force to replace)"
		return 0
	fi
	die "$OUT populated but SHA256SUMS fails (use --force to replace)"
fi

[ -r "$TGZ" ] || die "tarball not readable: $TGZ"
[ -d "$REF" ] || die "reference dir missing: $REF"

echo "import-stock: extracting $TGZ"
tar -xzf "$TGZ" -C "$TMP" --no-same-owner --no-same-permissions
SRC="$TMP/modules/$KVER"
[ -d "$SRC" ] || die "tarball has no modules/$KVER/"

# 1. exact set: tgz == pins == reference
fail=0
declare -A SEEN
for f in "$SRC"/*.ko; do
	[ -f "$f" ] || die "no .ko in tarball"
	[ ! -L "$f" ] || { echo "symlink refused: $f" >&2; fail=1; continue; }
	m="$(basename "$f" .ko)"
	SEEN["$m"]=1
	pfx="${PIN[$m]:-}"
	if [ -z "$pfx" ]; then echo "UNPINNED module in tarball: $m" >&2; fail=1; continue; fi
	ref="$REF/$m.ko"
	[ -f "$ref" ] || { echo "MISSING in reference: $m" >&2; fail=1; continue; }
	h="$(sha256sum < "$f" | cut -d' ' -f1)"
	r="$(sha256sum < "$ref" | cut -d' ' -f1)"
	if [ "$h" != "$r" ]; then
		echo "MISMATCH vs reference: $m ($h != $r)" >&2; fail=1; continue
	fi
	if [ "${h:0:12}" != "$pfx" ]; then
		echo "MISMATCH vs §2 pin: $m (${h:0:12} != $pfx)" >&2; fail=1; continue
	fi
done
for m in "${!PIN[@]}"; do
	[ -n "${SEEN[$m]:-}" ] || { echo "MISSING in tarball: $m" >&2; fail=1; }
done
n_ref="$(find "$REF" -maxdepth 1 -name '*.ko' | wc -l)"
[ "$n_ref" -eq "$NKO" ] || { echo "reference has $n_ref .ko, expected $NKO" >&2; fail=1; }
[ "$fail" -eq 0 ] || die "sha256 pinning failed - nothing installed"
echo "import-stock: $NKO/$NKO modules match reference and §2 pins"

# 2. stage into a new tree, then swap in atomically
STAGE="$TMP/files"
mkdir -p "$STAGE/lib/modules/$KVER" "$STAGE/etc/modules.d"
cp -p "$SRC"/*.ko "$STAGE/lib/modules/$KVER/"
chmod 0644 "$STAGE/lib/modules/$KVER/"*.ko

# 3. modules.d autoload lists (built-ins dropped, empty files skipped)
nfiles=0
nmods=0
while IFS= read -r line; do
	[ -n "$line" ] || continue
	file="${line%%:*}"
	mods="${line#*: }"
	body=""
	for spec in $mods; do
		m="${spec%%=*}"
		arg=""
		[ "$spec" = "$m" ] || arg=" ${spec#*=}"
		[ -n "${PIN[$m]:-}" ] || continue   # built-in to stock vmlinux
		body="${body}${m}${arg}"$'\n'
		nmods=$((nmods + 1))
	done
	[ -n "$body" ] || continue
	printf '%s' "$body" > "$STAGE/etc/modules.d/$file"
	nfiles=$((nfiles + 1))
done <<< "$MODULES_D"
echo "import-stock: wrote $nfiles modules.d files ($nmods autoload entries)"

(cd "$STAGE" && find lib etc -type f | LC_ALL=C sort | xargs sha256sum) > "$STAGE/SHA256SUMS"

mkdir -p "$(dirname "$OUT")"
rm -rf "$OUT.new"
mv "$STAGE" "$OUT.new"
rm -rf "$OUT"
mv "$OUT.new" "$OUT"
echo "import-stock: done -> $OUT"
}

case "$PHASE" in
kernel) phase_kernel ;;
vendor) phase_vendor ;;
all) phase_kernel; phase_vendor ;;
esac
