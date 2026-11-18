# SPDX-License-Identifier: GPL-2.0-only
# shellcheck shell=sh
#
# MT6890 (DWR-2000M A3) A/B sysupgrade hooks for OpenWrt 24.10 base-files.
#
# 24.10 call sites (package/base-files/files):
#   platform_check_image  usr/libexec/validate_firmware_image:59
#   platform_pre_upgrade  lib/upgrade/stage2:165   (real root, before ramfs)
#   platform_do_upgrade   lib/upgrade/do_stage2:9  (ramfs)
#   platform_copy_config  lib/upgrade/do_stage2:15 (ramfs, only with a backup)
# There is NO post_upgrade hook in 24.10: do_stage2 reboots right after
# copy_config. The slot switch ("post upgrade") therefore runs at the very
# end of platform_do_upgrade, after the new slot is written, verified and
# has received the config - i.e. misc is written LAST.
#
# Stock mechanism replicated (build/rootfs_a-full/lib/upgrade/):
#   rootfs write: `mtd erase <part>` + `... | mtd write - <part>`
#                 (platform.sh:98-101, target rootfs_<other> bootctrl.sh:402/430)
#   slot state:   misc record via dd-nand (see mt6890-bootctl.sh)
# Deltas vs stock (NOTES-p2 "P5"): misc read with dd (no nanddump), only the
# rootfs partition is written (no boot/lk/modem, no clone of the rest),
# boot_para is NOT erased (stock platform.sh:198), config goes to the new
# slot's rootfs_data (24.10 convention) instead of /data.
#
# Env for tests / dry runs: MT6890_DRYRUN=1, MT6890_PROC_MTD, MT6890_CMDLINE,
# MT6890_DEVDIR, MT6890_SYSUBI, MT6890_INTENT, MT6890_LIB.

MT6890_LIB="${MT6890_LIB:-/lib/upgrade/mt6890-bootctl.sh}"
. "$MT6890_LIB"

MT6890_INTENT="${MT6890_INTENT:-/tmp/mt6890-sysupgrade.intent}"
MT6890_SYSUBI="${MT6890_SYSUBI:-/sys/class/ubi}"
MT6890_MNT="${MT6890_MNT:-/tmp/mt6890-new-root}"
MT6890_FACTORY_SIZE=67108864

# dd-nand (+ libnandapi.so/libubox.so via ldd) must survive the ramfs switch
# (tr/head are not in the stage2 default list)
RAMFS_COPY_BIN="${RAMFS_COPY_BIN:-} /usr/sbin/dd-nand tr head"

type v >/dev/null 2>&1 || v() { echo "$*"; }
BACKUP_FILE="${BACKUP_FILE:-sysupgrade.tgz}"

mt6890_run() { # run or (dry run) print a simple command
	if mt6890_dryrun; then echo "DRYRUN: $*"; return 0; fi
	"$@"
}

mt6890_magic() { # <file> <offset> <nbytes> -> hex
	dd if="$1" bs=1 skip="$2" count="$3" 2>/dev/null | hexdump -v -e '1/1 "%02x"'
}

mt6890_fsize() { wc -c < "$1" | tr -d ' '; }

# image type: ubi | stocktar | unknown
mt6890_image_type() {
	case "$(mt6890_magic "$1" 0 4)" in
	55424923) echo ubi ;;
	1f8b*) echo stocktar ;;
	*) case "$(mt6890_magic "$1" 0 2)" in 1f8b) echo stocktar ;; *) echo unknown ;; esac ;;
	esac
}

# stock tar members (stock platform.sh:5-21 names); prints the rootfs member
mt6890_stocktar_rootfs() {
	local list m root="" other=""
	list="$(tar -tzf "$1" 2>/dev/null)" || return 1
	for m in $list; do
		case "$m" in
		*/) ;;
		*.squashfs) [ -z "$root" ] || { echo "MULTI:$m"; return 1; }; root="$m" ;;
		root_ro*.sig) ;;
		*) other="$other $m" ;;
		esac
	done
	[ -n "$other" ] && { echo "OTHER:${other# }"; return 1; }
	[ -n "$root" ] || { echo "NOROOT"; return 1; }
	echo "$root"
}

mt6890_slot_part() { echo "rootfs_$1"; }

# ---------------------------------------------------------------------------
platform_check_image() {
	local img="$1" type size psize es m r
	[ -f "$img" ] || { echo "Invalid image: $img not found"; return 1; }
	type="$(mt6890_image_type "$img")"
	size="$(mt6890_fsize "$img")"
	psize="$(mt6890_mtd_size rootfs_a)"; [ -n "$psize" ] || psize=$MT6890_FACTORY_SIZE
	es="$(mt6890_mtd_erasesize rootfs_a)"; [ -n "$es" ] || es=262144
	case "$type" in
	ubi)
		if [ "$size" -gt "$psize" ]; then
			echo "Invalid image: UBI image is $size bytes, rootfs slot holds $psize"
			return 1
		fi
		if [ $((size % es)) -ne 0 ]; then
			echo "Invalid image: UBI image size $size is not a multiple of the $es-byte eraseblock"
			return 1
		fi
		if [ "$size" -gt "$es" ] && [ "$(mt6890_magic "$img" "$es" 4)" != 55424923 ]; then
			echo "Invalid image: no UBI EC header at PEB 1 (offset $es) - PEB size mismatch"
			return 1
		fi
		# volume table (layout volume, PEB 0/1): need rootfs + rootfs_data
		m="$(dd if="$img" bs="$es" count=2 2>/dev/null | tr -c 'a-z_' '\n' | grep -x -e rootfs -e rootfs_data | sort -u | tr '\n' ' ')"
		if [ "$m" != "rootfs rootfs_data " ]; then
			echo "Invalid image: UBI volume table lacks rootfs/rootfs_data (found: ${m:-none})"
			return 1
		fi
		echo "mt6890: OK factory-rootfs UBI image ($size bytes)"
		return 0
		;;
	stocktar)
		r="$(mt6890_stocktar_rootfs "$img")" || {
			case "$r" in
			OTHER:*) echo "Invalid image: stock tar contains non-rootfs images (${r#OTHER:}); this platform only writes the rootfs slot - use the stock flasher for boot/lk/modem" ;;
			MULTI:*) echo "Invalid image: stock tar contains more than one *.squashfs" ;;
			NOROOT) echo "Invalid image: gzip tar without a stock rootfs (*.squashfs) member" ;;
			*) echo "Invalid image: not a readable gzip tar" ;;
			esac
			return 1
		}
		size="$(tar -xzOf "$img" "$r" | wc -c | tr -d ' ')"
		m="$(tar -xzOf "$img" "$r" | dd bs=4 count=1 2>/dev/null | hexdump -v -e '1/1 "%02x"')"
		if [ "$m" != 55424923 ]; then
			echo "Invalid image: stock rootfs member $r is not a UBI image (magic $m); the slot is UBI (ubi.mtd=), a raw squashfs would not boot"
			return 1
		fi
		if [ "$size" -gt "$psize" ]; then
			echo "Invalid image: stock rootfs $r is $size bytes, slot holds $psize"
			return 1
		fi
		echo "mt6890: OK stock sysupgrade tar (rootfs member $r, $size bytes)"
		return 0
		;;
	esac
	echo "Invalid image: unknown format (want UBI factory-rootfs.bin or stock sysupgrade .tar.gz)"
	return 1
}

# ---------------------------------------------------------------------------
# Decide current/target slot and record intent for do_upgrade.
mt6890_select() { # -> prints "current target source"
	local booted active rec
	booted="$(mt6890_slot_booted)" || booted=""
	rec="$(mt6890_bc_get)" || return 1
	active="$(mt6890_slot_active "$rec")" || active=""
	if [ -n "$booted" ]; then
		[ -n "$active" ] && [ "$active" != "$booted" ] && \
			mt6890_log "WARNING: misc selects slot $active but running from $booted (pending switch or fallback) - target = other of RUNNING slot"
		echo "$booted $(mt6890_slot_other "$booted") cmdline"
		return 0
	fi
	if [ -n "$active" ]; then
		echo "$active $(mt6890_slot_other "$active") misc"
		return 0
	fi
	mt6890_log "cannot determine current slot (no ubi.mtd=rootfs_a|b on cmdline, misc priorities equal)"
	return 1
}

platform_pre_upgrade() {
	local sel cur tgt src part num type
	rm -f "$MT6890_INTENT"
	sel="$(mt6890_select)" || { mt6890_log "pre_upgrade: slot selection failed - upgrade will be refused"; return 1; }
	set -- $sel "$1"
	cur="$1"; tgt="$2"; src="$3"
	part="$(mt6890_slot_part "$tgt")"
	num="$(mt6890_mtd_num "$part")" || { mt6890_log "pre_upgrade: no $part in /proc/mtd"; return 1; }
	type="$(mt6890_image_type "$4")"
	{
		echo "current=$cur"
		echo "target=$tgt"
		echo "source=$src"
		echo "part=$part"
		echo "mtd=$num"
		echo "type=$type"
	} > "$MT6890_INTENT"
	mt6890_log "pre_upgrade: running slot $cur ($src), writing slot $tgt ($part = mtd$num), image $type"
	return 0
}

mt6890_intent_get() { sed -n "s/^$1=//p" "$MT6890_INTENT" 2>/dev/null | head -n1; }

# number of leading eraseblocks that are not all-0xff
mt6890_used_blocks() { # <img> <erasesize>
	local n i
	n=$(( $(mt6890_fsize "$1") / $2 ))
	i=$n
	while [ "$i" -gt 0 ]; do
		[ "$(dd if="$1" bs="$2" skip=$((i - 1)) count=1 2>/dev/null | tr -d '\377' | wc -c | tr -d ' ')" -ne 0 ] && break
		i=$((i - 1))
	done
	echo "$i"
}

mt6890_ubi_attach() { # <mtdnum> -> prints ubi dev number
	local d=7
	while [ -e "$MT6890_SYSUBI/ubi$d" ] && [ "$d" -lt 31 ]; do d=$((d + 1)); done
	ubiattach -m "$1" -d "$d" >/dev/null 2>&1 || return 1
	[ -e "$MT6890_SYSUBI/ubi$d" ] || return 1
	echo "$d"
}

mt6890_ubi_vol() { # <ubidev> <name> -> volume device name (ubiD_N)
	local v
	for v in "$MT6890_SYSUBI/ubi$1_"*; do
		[ -f "$v/name" ] || continue
		[ "$(cat "$v/name")" = "$2" ] && { echo "${v##*/}"; return 0; }
	done
	return 1
}

# verify target UBI, store the config backup in its rootfs_data
mt6890_attach_and_config() { # <mtdnum> [attach-only]
	local d rv rc=0
	d="$(mt6890_ubi_attach "$1")" || { mt6890_log "verify: ubiattach of mtd$1 failed"; return 1; }
	if [ "${2:-}" = attach-only ]; then
		ubidetach -d "$d" >/dev/null 2>&1
		return 0
	fi
	if ! mt6890_ubi_vol "$d" rootfs >/dev/null; then
		mt6890_log "verify: volume 'rootfs' missing on mtd$1"; rc=1
	fi
	rv="$(mt6890_ubi_vol "$d" rootfs_data)" || { mt6890_log "verify: volume 'rootfs_data' missing on mtd$1"; rc=1; }
	if [ "$rc" = 0 ] && [ -n "${UPGRADE_BACKUP:-}" ] && [ -f "$UPGRADE_BACKUP" ]; then
		mkdir -p "$MT6890_MNT"
		if mount -t ubifs "$MT6890_DEVDIR/$rv" "$MT6890_MNT"; then
			cp -f "$UPGRADE_BACKUP" "$MT6890_MNT/$BACKUP_FILE" && sync && \
				[ -s "$MT6890_MNT/$BACKUP_FILE" ] && echo "config=saved" >> "$MT6890_INTENT" || \
				mt6890_log "config: copy to new rootfs_data failed (upgrade continues, config lost)"
			umount "$MT6890_MNT"
		else
			mt6890_log "config: cannot mount $rv (upgrade continues, config lost)"
		fi
		rmdir "$MT6890_MNT" 2>/dev/null
	fi
	ubidetach -d "$d" >/dev/null 2>&1
	return "$rc"
}

platform_do_upgrade() {
	local img="$1" tgt part num type es n dev ddn member a b
	tgt="$(mt6890_intent_get target)"; part="$(mt6890_intent_get part)"
	num="$(mt6890_intent_get mtd)"; type="$(mt6890_intent_get type)"
	if [ -z "$tgt" ] || [ -z "$part" ] || [ -z "$num" ]; then
		mt6890_log "do_upgrade: no intent from pre_upgrade ($MT6890_INTENT) - REFUSED, nothing written"
		return 1
	fi
	# re-check everything before the first write
	[ "$(mt6890_mtd_num "$part")" = "$num" ] || { mt6890_log "do_upgrade: $part is no longer mtd$num - REFUSED"; return 1; }
	[ "$(mt6890_slot_booted)" = "$tgt" ] && { mt6890_log "do_upgrade: target $part is the running root - REFUSED"; return 1; }
	mt6890_bc_get >/dev/null || { mt6890_log "do_upgrade: misc record unusable - REFUSED, nothing written"; return 1; }
	if ! mt6890_dryrun; then
		ddn="$(mt6890_ddnand)" || { mt6890_log "do_upgrade: dd-nand missing (cannot switch slot) - REFUSED, nothing written"; return 1; }
	fi
	[ "$(mt6890_image_type "$img")" = "$type" ] || { mt6890_log "do_upgrade: image type changed since pre_upgrade - REFUSED"; return 1; }
	es="$(mt6890_mtd_erasesize "$part")"
	dev="$MT6890_DEVDIR/mtd$num"

	case "$type" in
	ubi)
		n="$(mt6890_used_blocks "$img" "$es")"
		v "mt6890: writing $img ($n of $(( $(mt6890_fsize "$img") / es )) eraseblocks used) to $part"
		# stock platform.sh:98-101: erase, then raw mtd write
		mt6890_run mtd erase "$part" || return 1
		if mt6890_dryrun; then
			echo "DRYRUN: dd if=$img bs=$es count=$n | mtd write - $part"
		else
			dd if="$img" bs="$es" count="$n" 2>/dev/null | mtd write - "$part" || { mt6890_log "mtd write failed"; return 1; }
			a="$(dd if="$img" bs="$es" count="$n" 2>/dev/null | md5sum | cut -d' ' -f1)"
			b="$(dd if="$dev" bs="$es" count="$n" 2>/dev/null | md5sum | cut -d' ' -f1)"
			[ "$a" = "$b" ] || mt6890_log "verify: raw readback differs (bad block skip?) - relying on UBI attach check"
		fi
		if mt6890_dryrun; then
			echo "DRYRUN: ubiattach -m $num; check volumes rootfs/rootfs_data; copy ${UPGRADE_BACKUP:-<no backup>} -> rootfs_data/$BACKUP_FILE; ubidetach"
		else
			mt6890_attach_and_config "$num" || { mt6890_log "do_upgrade: new slot failed verification - misc NOT switched, old slot stays active"; return 1; }
		fi
		;;
	stocktar)
		member="$(mt6890_stocktar_rootfs "$img")" || { mt6890_log "do_upgrade: stock tar rejected ($member)"; return 1; }
		v "mt6890: writing stock $member to $part"
		mt6890_run mtd erase "$part" || return 1
		if mt6890_dryrun; then
			echo "DRYRUN: tar -xzf $img $member -O | mtd write - $part"
		else
			tar -xzf "$img" "$member" -O | mtd write - "$part" || { mt6890_log "mtd write failed"; return 1; }
			n="$(tar -xzOf "$img" "$member" | wc -c | tr -d ' ')"
			a="$(tar -xzOf "$img" "$member" | md5sum | cut -d' ' -f1)"
			b="$(dd if="$dev" bs="$es" count=$(( (n + es - 1) / es )) 2>/dev/null | head -c "$n" | md5sum | cut -d' ' -f1)"
			[ "$a" = "$b" ] || mt6890_log "verify: raw readback differs (bad block skip?) - relying on UBI attach check"
			mt6890_attach_and_config "$num" attach-only || { mt6890_log "do_upgrade: stock slot does not attach as UBI - misc NOT switched"; return 1; }
		fi
		mt6890_dryrun && echo "DRYRUN: ubiattach -m $num (attach check only); stock config is not carried"
		echo "config=stock-not-carried" >> "$MT6890_INTENT"
		;;
	*)
		mt6890_log "do_upgrade: unsupported image type '$type' - REFUSED"; return 1 ;;
	esac

	# "post upgrade": switch the boot slot LAST (no post hook in 24.10)
	mt6890_bc_set "$tgt" || { mt6890_log "do_upgrade: misc switch to slot $tgt FAILED - run 'mt6890-bootctl status' before rebooting"; return 1; }
	if ! mt6890_dryrun; then
		[ "$(mt6890_slot_active)" = "$tgt" ] || { mt6890_log "do_upgrade: misc readback does not select $tgt"; return 1; }
	fi
	echo "switched=$tgt" >> "$MT6890_INTENT"
	v "mt6890: slot $tgt written and selected for next boot"
	return 0
}

# Config was already stored in the new slot by platform_do_upgrade (before
# the misc switch). Only act if that did not happen (idempotent).
platform_copy_config() {
	local num
	grep -q '^config=' "$MT6890_INTENT" 2>/dev/null && return 0
	grep -q '^switched=' "$MT6890_INTENT" 2>/dev/null || return 0
	num="$(mt6890_intent_get mtd)"
	[ -n "$num" ] || return 0
	mt6890_dryrun && { echo "DRYRUN: copy config to mtd$num rootfs_data"; return 0; }
	mt6890_attach_and_config "$num"
}
