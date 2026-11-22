#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# shellcheck shell=sh
#
# dwr2000m-flash.sh v2.1 - first install of the 64 MiB UBI OpenWrt 24.10 image
# on a D-Link DWR-2000M A3 that still runs the stock firmware. It is the
# executable form of the wiki page "Flash-Plan" (public/wiki/Flash-Plan.md):
# preflight, config backup + mandatory off-device partition dumps, fetch the
# image into /tmp, gate it on size + sha256, erase and write the idle slot A
# (rootfs_a, mtd29), read slot A back and compare its sha256 with the image,
# and only then switch the misc A/B record to slot A with the stock dd-nand.
# Runs on the stock busybox ash (POSIX sh, no bashisms). The misc record
# logic mirrors openwrt/package/mt6890-sysupgrade/files/lib/upgrade/
# mt6890-bootctl.sh, which is the single source of truth for its semantics.
#
# v2 changes: write primitive chosen at runtime (mtd if present, else
# mtd-utils flash_erase + nandwrite -p); mandatory sha256 (argument and
# on-device sha256sum); sha256 readback gate of slot A before the record
# switch; rootfs_a bad-block gate (sysfs); decoded record + stock "clone B
# over A" warning in PHASE 0; mandatory off-device dump gate in PHASE 1;
# new 'rehearse' subcommand (record-only dress rehearsal); the image ships
# ARMED (mt6890-bootctl confirm).
#
# v2.1: PHASE 0 UBI-attach gate for rootfs_a; PHASE 1 hints: ssh user admin, ssh-rsa, ECC, live rootfs_b sha.
#
# Safety invariants:
#  * never writes the running slot: only the reference layout (stock booted
#    AND active on B = rootfs_b/mtd42) is accepted, rechecked right before
#    the erase; the only rootfs target is rootfs_a
#  * the misc record is switched last, only after erase + write returned 0
#    AND the sha256 of slot A read back equals the image's sha256
#  * every record write is read back (all 4 copies, magic + 8-byte payload);
#    any mismatch exits nonzero and prints the revert command
#  * never reboots the unit; no write happens before its gate has passed
#
# Usage:
#   dwr2000m-flash.sh flash <image-url> <expected-sha256>
#   dwr2000m-flash.sh rehearse
#   dwr2000m-flash.sh fingerprint <file>     (diagnostic only)
#   dwr2000m-flash.sh status
#   dwr2000m-flash.sh revert <backup-file>
#
# Environment (test hooks, mirroring the package): MT6890_PROC_MTD,
# MT6890_CMDLINE, MT6890_DEVDIR, MT6890_MISC_DEV (misc device, highest
# precedence), MT6890_DDNAND, MT6890_DRYRUN=1 (print mtd/flash_erase/
# nandwrite/dd-nand/tar/wget instead of running them), MT6890_TMPDIR
# (default /tmp), MT6890_BACKUP_PATHS (default "/etc /data"),
# MT6890_SYSFS_MTD (default /sys/class/mtd), MT6890_SYSFS_UBI (default
# /sys/class/ubi).
#
# Exit: 0 = ok, 1 = gate failed / aborted, 2 = usage error.

set -u

MT6890_PROC_MTD="${MT6890_PROC_MTD:-/proc/mtd}"
MT6890_CMDLINE="${MT6890_CMDLINE:-/proc/cmdline}"
MT6890_DEVDIR="${MT6890_DEVDIR:-/dev}"
MT6890_MISC_DEV="${MT6890_MISC_DEV:-}"
MT6890_DDNAND="${MT6890_DDNAND:-}"
MT6890_DRYRUN="${MT6890_DRYRUN:-0}"
MT6890_TMPDIR="${MT6890_TMPDIR:-/tmp}"
MT6890_BACKUP_PATHS="${MT6890_BACKUP_PATHS:-/etc /data}"
MT6890_SYSFS_MTD="${MT6890_SYSFS_MTD:-/sys/class/mtd}"
MT6890_SYSFS_UBI="${MT6890_SYSFS_UBI:-/sys/class/ubi}"
# mock-test hook only (deliberately not documented in usage)
MT6890_SKIP_DUMP_GATE="${MT6890_SKIP_DUMP_GATE:-0}"

# misc A/B record (mt6890-bootctl.sh)
BC_OFF=2048          # record offset in each copy
BC_SEEK0=2056        # BC_OFF + 8: start of the 8-byte payload (+8..+15)
BC_STRIDE=262144     # 256 KiB between copies
BC_COPIES="0 1 2 3"
BC_MAGIC=00414230    # "\0AB0"

IMG_SIZE=67108864    # 64 MiB UBI image
IMG_PEBS=256         # IMG_SIZE / 256 KiB
SLOT_A_MTD=rootfs_a; SLOT_A_NUM=29
SLOT_B_MTD=rootfs_b; SLOT_B_NUM=42
FALLBACK_TRIES=3     # tries byte written for slot A

PROG="${0##*/}"
DDN=""
MISC=""
RECS=""
REC0=""
WTOOL=""             # mtd | mtd-utils
ADEV=""              # /dev/mtdN of rootfs_a
BDEV=""              # /dev/mtdN of rootfs_b
BK=""                # backup dir
SHA_A=""; SHA_B=""   # PHASE 1 on-device sha256 of the full partitions

say() { printf '%s\n' "$*"; }
log() { printf '%s: %s\n' "$PROG" "$*" >&2; }
die() { printf '%s: ABORT: %s\n' "$PROG" "$*" >&2; exit 1; }
dryrun() { [ "$MT6890_DRYRUN" = 1 ]; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
	cat <<EOF
Usage: $PROG <command> [args]

  flash <image-url> <expected-sha256>
        first install of the 64 MiB UBI image into the idle slot A from
        stock (stock must run from B); interactive, gated, never reboots.
        The sha256 is mandatory and is checked on the unit with sha256sum,
        before the erase and again on slot A read back before the switch.
  rehearse
        zero-risk dress rehearsal with both slots still stock: preflight,
        backups, then ONLY the misc record is switched to slot A (rootfs
        is not written). Reboot, check, then 'revert' back to B.
  fingerprint <file>
        diagnostic only: size + hexdump -C of the first/last 1 KiB
  status
        dump all 4 misc records, active slot, booted slot (read-only)
  revert <backup-file>
        write the original 8-byte payload back to all 4 misc copies;
        <backup-file> = misc-records.txt (4 x 32 hex) or original-record.hex
        (16 hex = 8 bytes)

Only flash, rehearse and revert write. See the wiki page Flash-Plan.
EOF
	exit 2
}

confirm() { # <question>
	printf '%s [y/N] ' "$1"
	read -r ans || ans=""
	case "$ans" in y|Y|yes|YES) return 0 ;; esac
	return 1
}

run() { # mtd/flash_erase/nandwrite/wget/tar wrapper honouring MT6890_DRYRUN
	if dryrun; then say "DRYRUN: $*"; return 0; fi
	"$@"
}

# --- /proc/mtd: mtdN: <size hex> <erasesize hex> "<name>" -----------------
mtd_num() {
	_mn="$(sed -n "s/^mtd\([0-9]*\): [0-9a-fA-F]* [0-9a-fA-F]* \"$1\"\$/\1/p" "$MT6890_PROC_MTD" 2>/dev/null | head -n1)"
	[ -n "$_mn" ] && say "$_mn"
}
mtd_size() {
	_ms="$(sed -n "s/^mtd[0-9]*: \([0-9a-fA-F]*\) [0-9a-fA-F]* \"$1\"\$/\1/p" "$MT6890_PROC_MTD" 2>/dev/null | head -n1)"
	[ -n "$_ms" ] && printf '%d\n' "0x$_ms"
}
mtd_name() { # <num>
	_mm="$(sed -n "s/^mtd$1: [0-9a-fA-F]* [0-9a-fA-F]* \"\(.*\)\"\$/\1/p" "$MT6890_PROC_MTD" 2>/dev/null | head -n1)"
	[ -n "$_mm" ] && say "$_mm"
}

misc_dev() {
	if [ -n "$MT6890_MISC_DEV" ]; then say "$MT6890_MISC_DEV"; return 0; fi
	_md="$(mtd_num misc)" || return 1
	say "$MT6890_DEVDIR/mtd$_md"
}

ddnand_path() {
	if [ -n "$MT6890_DDNAND" ]; then say "$MT6890_DDNAND"; return 0; fi
	command -v dd-nand 2>/dev/null && return 0
	for _p in /usr/sbin/dd-nand /sbin/dd-nand; do
		[ -x "$_p" ] && { say "$_p"; return 0; }
	done
	return 1
}

# --- record read ------------------------------------------------------------
to_hex() { # stdin -> lowercase hex string
	if have hexdump; then
		hexdump -v -e '1/1 "%02x"'
	else
		od -An -v -tx1 | awk '{ for (i = 1; i <= NF; i++) printf "%s", $i }'
	fi
}

bc_read() { # <dev> <copy 0..3> -> 32 hex chars (16 bytes @ 2048 + 256 KiB*copy)
	_off=$((BC_STRIDE * $2 + BC_OFF))
	dd if="$1" bs=16 skip=$((_off / 16)) count=1 2>/dev/null | to_hex
}

bc_byte() { # <record32> <byte index 0..15> -> 2 hex chars
	say "$1" | cut -c$(($2 * 2 + 1))-$(($2 * 2 + 2))
}

# read + magic-check all copies; sets RECS (4 lines) and REC0
read_records() { # <dev>
	RECS=""; REC0=""; _rr=0
	for _c in $BC_COPIES; do
		_r="$(bc_read "$1" "$_c")"
		if [ "${#_r}" -ne 32 ]; then
			log "misc copy $_c: short read from $1 ('$_r')"; _rr=1
		elif [ "$(say "$_r" | cut -c1-8)" != "$BC_MAGIC" ]; then
			log "misc copy $_c: bad magic $(say "$_r" | cut -c1-8) (want $BC_MAGIC) - not an A/B record"; _rr=1
		fi
		RECS="$RECS$_r
"
		[ "$_c" = 0 ] && REC0="$_r"
	done
	return "$_rr"
}

print_records() {
	_i=0
	say "$RECS" | while read -r _r; do
		[ -n "$_r" ] || continue
		say "  copy $_i @$((BC_STRIDE * _i + BC_OFF)): $(say "$_r" | cut -c1-8) $(say "$_r" | cut -c9-16) | A $(bc_byte "$_r" 8) $(bc_byte "$_r" 9) $(bc_byte "$_r" 10) $(bc_byte "$_r" 11) | B $(bc_byte "$_r" 12) $(bc_byte "$_r" 13) $(bc_byte "$_r" 14) $(bc_byte "$_r" 15)"
		_i=$((_i + 1))
	done
	say "  (magic +4..7 | prio tries success uptype)"
}

decode_record() { # <record32>: full 16 bytes of one copy, decoded
	say "record copy 0 (16 bytes @$BC_OFF): $1"
	say "  +0..3  magic    $(say "$1" | cut -c1-8) (want $BC_MAGIC)"
	say "  +4..7  reserved $(say "$1" | cut -c9-16)"
	say "  +8..11 slot A   prio=$(bc_byte "$1" 8) tries=$(bc_byte "$1" 9) success=$(bc_byte "$1" 10) uptype=$(bc_byte "$1" 11)"
	say "  +12..15 slot B  prio=$(bc_byte "$1" 12) tries=$(bc_byte "$1" 13) success=$(bc_byte "$1" 14) uptype=$(bc_byte "$1" 15)"
}

records_consistent() {
	[ "$(say "$RECS" | sed '/^$/d' | sort -u | wc -l)" -eq 1 ]
}

slot_active() { # <record32>: higher priority byte wins
	_pa=$(printf '%d' "0x$(bc_byte "$1" 8)")
	_pb=$(printf '%d' "0x$(bc_byte "$1" 12)")
	if [ "$_pa" -gt "$_pb" ]; then say a
	elif [ "$_pb" -gt "$_pa" ]; then say b
	else log "SAME A/B PRIORITY ($_pa) in misc record"; return 1
	fi
}

cmdline_ubi_mtd() { # raw ubi.mtd= value (last one wins, as in slot_booted)
	_u=""
	[ -r "$MT6890_CMDLINE" ] || return 1
	_cl="$(cat "$MT6890_CMDLINE")"
	for _arg in $_cl; do
		case "$_arg" in ubi.mtd=*) _u="${_arg#ubi.mtd=}"; _u="${_u%%,*}" ;; esac
	done
	[ -n "$_u" ] && say "$_u"
}

slot_booted() { # ubi.mtd=<num|name> in cmdline, resolved to a name via /proc/mtd
	_v="$(cmdline_ubi_mtd)" || return 1
	case "$_v" in
	*[!0-9]*) _name="$_v" ;;
	*) _name="$(mtd_name "$_v")" ;;
	esac
	case "$_name" in
	"$SLOT_A_MTD") say a ;;
	"$SLOT_B_MTD") say b ;;
	*) return 1 ;;
	esac
}

# --- record write -----------------------------------------------------------
payload_slot_a() { # <record32>: A prio 0f tries 03 success 00, A uptype kept; B prio 0e, B tries/success/uptype kept
	say "0f0300$(bc_byte "$1" 11)0e$(bc_byte "$1" 13)$(bc_byte "$1" 14)$(bc_byte "$1" 15)"
}

hex_to_printf() { # 16 hex chars -> printf format with octal escapes
	_h="$1"; _out=""
	while [ -n "$_h" ]; do
		_b="$(say "$_h" | cut -c1-2)"; _h="$(say "$_h" | cut -c3-)"
		_out="$_out$(printf '\\%03o' "0x$_b")"
	done
	printf '%s' "$_out"   # not echo: dash's echo would interpret the escapes
}

verify_payload() { # <dev> <payload16>: all copies magic + payload byte-exact
	_vp=0
	for _c in $BC_COPIES; do
		_got="$(bc_read "$1" "$_c")"
		if [ "$(say "$_got" | cut -c1-8)" != "$BC_MAGIC" ] || [ "$(say "$_got" | cut -c17-32)" != "$2" ]; then
			log "misc copy $_c readback MISMATCH: got ${_got:-<empty>} want ${BC_MAGIC}........$2"
			_vp=1
		else
			say "  copy $_c readback OK: $_got"
		fi
	done
	return "$_vp"
}

write_payload() { # <dev> <payload16>: 8 bytes x4 copies via stock dd-nand, then readback
	_wfmt="$(hex_to_printf "$2")"
	_wfail=0
	for _c in $BC_COPIES; do
		_off=$((BC_SEEK0 + BC_STRIDE * _c))
		if dryrun; then
			say "DRYRUN: printf '$_wfmt' | $DDN of=$1 seek=$_off bs=1 count=8"
			continue
		fi
		# shellcheck disable=SC2059
		if ! printf "$_wfmt" | "$DDN" of="$1" seek="$_off" bs=1 count=8 >/dev/null 2>&1; then
			log "dd-nand FAILED on copy $_c (seek $_off) - no further copies written"
			_wfail=1
			break
		fi
		say "  copy $_c: dd-nand of=$1 seek=$_off bs=1 count=8 rc=0"
	done
	if dryrun; then say "DRYRUN: readback skipped"; return 0; fi
	verify_payload "$1" "$2" || _wfail=1
	return "$_wfail"
}

# --- flash I/O helpers --------------------------------------------------------
sha_file() { sha256sum "$1" | cut -d' ' -f1; }

dump_cmd() { # <dev>: the read command used for dumps (same on router and in the PC hint)
	if have nanddump; then say "nanddump -q $1"; else say "dd if=$1 bs=262144"; fi
}

part_sha() { # <dev>: sha256 of the whole partition, streamed (nothing stored)
	if have nanddump; then
		nanddump -q "$1" 2>/dev/null | sha256sum | cut -d' ' -f1
	else
		dd if="$1" bs=262144 2>/dev/null | sha256sum | cut -d' ' -f1
	fi
}

slot_readback_sha() { # <dev>: sha256 of the first IMG_SIZE bytes of the slot
	if have nanddump; then
		nanddump -q -l "$IMG_SIZE" "$1" 2>/dev/null | sha256sum | cut -d' ' -f1
	else
		dd if="$1" bs=262144 count="$IMG_PEBS" 2>/dev/null | sha256sum | cut -d' ' -f1
	fi
}

select_write_tool() {
	if have mtd; then
		WTOOL=mtd
		say "write primitive: mtd (mtd erase $SLOT_A_MTD; mtd write <img> $SLOT_A_MTD)"
	elif have flash_erase && have nandwrite; then
		WTOOL=mtd-utils
		say "write primitive: mtd-utils (flash_erase $ADEV 0 0; nandwrite -p $ADEV <img>) - 'mtd' not on PATH"
	else
		die "no write primitive: neither 'mtd' nor 'flash_erase' + 'nandwrite' on PATH (nothing written)"
	fi
	if have nanddump; then
		say "readback: nanddump -q -l $IMG_SIZE $ADEV | sha256sum"
	else
		say "readback: dd if=$ADEV bs=262144 count=$IMG_PEBS | sha256sum (nanddump not on PATH)"
	fi
}

bad_block_gate() {
	_bbf="$MT6890_SYSFS_MTD/mtd$SLOT_A_NUM/bad_blocks"
	if [ -r "$_bbf" ]; then
		_bb="$(cat "$_bbf" 2>/dev/null)"
		case "$_bb" in
		0) say "bad_blocks: $SLOT_A_MTD = 0 OK" ;;
		*) die "bad_blocks: $SLOT_A_MTD (mtd$SLOT_A_NUM) reports '${_bb:-?}' bad block(s). The 64 MiB image fills the exactly-64 MiB partition completely, so there is no spare eraseblock to skip to: the write would be truncated or shifted. Not flashing (nothing written)." ;;
		esac
		_bbb="$MT6890_SYSFS_MTD/mtd$SLOT_B_NUM/bad_blocks"
		[ -r "$_bbb" ] && say "bad_blocks: $SLOT_B_MTD = $(cat "$_bbb" 2>/dev/null) (info only)"
	else
		say "bad_blocks: unknown (sysfs attr missing) - continuing"
	fi
}

ubi_attach_gate() { # slot A must not be attached to any UBI device (read-only)
	if [ ! -d "$MT6890_SYSFS_UBI" ]; then
		say "ubi attach map: unknown (sysfs missing) - continuing"
		return 0
	fi
	_map=""
	for _uf in "$MT6890_SYSFS_UBI"/ubi[0-9]*/mtd_num; do
		[ -r "$_uf" ] || continue
		_ud="${_uf%/mtd_num}"; _ud="${_ud##*/}"
		_um="$(cat "$_uf" 2>/dev/null)"
		if [ "$_um" = "$SLOT_A_NUM" ]; then
			die "$SLOT_A_MTD (mtd$SLOT_A_NUM) is attached as $_ud; erasing it under UBI would corrupt the attach. Detach first ('ubidetach -m $SLOT_A_NUM') only if you know why it is attached - this script will not do it (nothing written)."
		fi
		_map="$_map $_ud: mtd${_um:-?};"
	done
	say "ubi attach map:${_map:- (no ubi devices attached)} - $SLOT_A_MTD (mtd$SLOT_A_NUM) not attached OK"
}

# --- fingerprint (diagnostic only) -------------------------------------------
fingerprint() { # <file>: identical output on PC and router for identical files
	[ -f "$1" ] || die "fingerprint: no such file: $1"
	have hexdump || die "fingerprint: hexdump not found"
	_fs=$(($(wc -c < "$1")))
	say "size $_fs"
	say "--- first 1 KiB ---"
	dd if="$1" bs=1024 count=1 2>/dev/null | hexdump -C
	say "--- last 1 KiB ---"
	if [ "$_fs" -le 1024 ]; then
		dd if="$1" bs=1024 count=1 2>/dev/null | hexdump -C
	elif [ $((_fs % 1024)) -eq 0 ]; then
		dd if="$1" bs=1024 skip=$((_fs / 1024 - 1)) count=1 2>/dev/null | hexdump -C
	else
		dd if="$1" bs=1 skip=$((_fs - 1024)) count=1024 2>/dev/null | hexdump -C
	fi
}

# --- common preflight for the record ----------------------------------------
need_misc() {
	[ -r "$MT6890_PROC_MTD" ] || die "cannot read $MT6890_PROC_MTD"
	mtd_num misc >/dev/null || die "no \"misc\" partition in $MT6890_PROC_MTD"
	_msz="$(mtd_size misc)"
	if [ -z "$_msz" ] || [ "$_msz" -lt $((BC_STRIDE * 3 + BC_OFF + 16)) ]; then
		die "misc partition too small (${_msz:-?} bytes)"
	fi
	MISC="$(misc_dev)" || die "cannot resolve the misc device"
	[ -r "$MISC" ] || die "cannot read misc device $MISC"
}

need_ddnand() {
	if DDN="$(ddnand_path)"; then
		say "dd-nand: $DDN"
	elif dryrun; then
		DDN=dd-nand
		log "WARNING: dd-nand not found (DRYRUN: continuing, a real run refuses)"
	else
		die "dd-nand not found (MT6890_DDNAND, PATH, /usr/sbin, /sbin) - refusing to write misc; there is no substitute"
	fi
}

# --- PHASE 0 (shared by flash and rehearse; read-only) ------------------------
phase0() { # <flash|rehearse>
	say "=== PHASE 0: preflight (read-only) ==="
	[ -r "$MT6890_PROC_MTD" ] || die "cannot read $MT6890_PROC_MTD"
	have sha256sum || die "'sha256sum' not on PATH - v2 depends on it (the stock busybox has it)"
	_na="$(mtd_num "$SLOT_A_MTD")" || die "no \"$SLOT_A_MTD\" in $MT6890_PROC_MTD"
	_nb="$(mtd_num "$SLOT_B_MTD")" || die "no \"$SLOT_B_MTD\" in $MT6890_PROC_MTD"
	if [ "$_na" != "$SLOT_A_NUM" ] || [ "$_nb" != "$SLOT_B_NUM" ]; then
		die "$SLOT_A_MTD=mtd$_na $SLOT_B_MTD=mtd$_nb; the reference layout is mtd$SLOT_A_NUM/mtd$SLOT_B_NUM - see Flash-Plan"
	fi
	ADEV="$MT6890_DEVDIR/mtd$_na"; BDEV="$MT6890_DEVDIR/mtd$_nb"
	_sa="$(mtd_size "$SLOT_A_MTD")"; _sb="$(mtd_size "$SLOT_B_MTD")"
	need_misc
	say "mtd sizes: $SLOT_A_MTD = mtd$_na ${_sa:-?} B, $SLOT_B_MTD = mtd$_nb ${_sb:-?} B, misc = $MISC $(mtd_size misc) B"
	if [ -z "$_sa" ] || [ "$_sa" -lt "$IMG_SIZE" ]; then
		die "$SLOT_A_MTD is ${_sa:-?} bytes, image needs $IMG_SIZE"
	fi
	[ -r "$ADEV" ] || die "cannot read $ADEV ($SLOT_A_MTD)"
	[ -r "$BDEV" ] || die "cannot read $BDEV ($SLOT_B_MTD)"
	need_ddnand
	if [ "$1" = flash ]; then
		select_write_tool
		dryrun || have wget || die "'wget' not found"
	fi
	bad_block_gate
	ubi_attach_gate
	read_records "$MISC" || die "misc record check failed (all 4 copies must carry magic $BC_MAGIC)"
	print_records
	decode_record "$REC0"
	records_consistent || log "WARNING: the 4 misc copies are not identical (copy 0 is used)"
	_act="$(slot_active "$REC0")" || die "cannot determine the active slot from the misc record"
	_ubi="$(cmdline_ubi_mtd)" || _ubi=""
	_boot="$(slot_booted)" || die "cannot resolve the booted slot: ubi.mtd='${_ubi:-<none>}' in $MT6890_CMDLINE is not $SLOT_A_MTD/$SLOT_B_MTD"
	case "$_ubi" in
	*[!0-9]*) say "cmdline: ubi.mtd=$_ubi -> slot $_boot" ;;
	*) say "cmdline: ubi.mtd=$_ubi -> mtd$_ubi \"$(mtd_name "$_ubi")\" -> slot $_boot" ;;
	esac
	say "active slot (misc priority): $_act"
	say "booted slot (cmdline ubi.mtd -> /proc/mtd): $_boot"
	[ "$_boot" = b ] ||
		die "this script targets the reference layout (stock on B); see Flash-Plan, swap A/B manually"
	[ "$_act" = b ] ||
		die "running B but misc already selects A (earlier attempt?) - check '$PROG status', fix with '$PROG revert <backup>'"
	_bs="$(bc_byte "$REC0" 14)"
	if [ "$_bs" != 01 ]; then
		say "WARNING: b_success=$_bs (not 01). The stock boot-done script (zmtk_boot_done) clones slot B over slot A on every stock boot while success != 01:"
		say "WARNING:  (a) any fallback to stock will overwrite 24.10 in slot A - expected and harmless (B is the source and is not changed);"
		say "WARNING:  (b) do not power-cycle the unit during the first ~2 min of a stock boot (the clone may be running);"
		say "WARNING:  (c) the Flash-Plan rollback note \"A keeps the failed image\" does not hold on this unit."
		say "(this is the normal state on most units - continuing)"
	fi
	say "PHASE 0 OK: stock runs from B and B is active; target slot A ($SLOT_A_MTD)"
}

# --- PHASE 1 (shared; writes only to MT6890_TMPDIR) ---------------------------
phase1() {
	_tgz="$MT6890_TMPDIR/stock-config-backup.tgz"
	confirm "Continue to PHASE 1 (backup to $MT6890_TMPDIR + off-device dumps)?" || die "stopped by user before PHASE 1 (nothing written)"
	say "=== PHASE 1: backup (writes only to $MT6890_TMPDIR) ==="
	BK="$MT6890_TMPDIR/flash-backup-$(date +%s)"
	[ -e "$BK" ] && BK="$BK-$$"
	mkdir "$BK" || die "cannot create $BK"
	_paths=""
	for _p in $MT6890_BACKUP_PATHS; do
		if [ -e "$_p" ]; then _paths="$_paths $_p"; else log "WARNING: $_p missing - not in the config backup"; fi
	done
	if [ -n "$_paths" ]; then
		# shellcheck disable=SC2086
		run tar czf "$_tgz" $_paths || log "WARNING: tar failed (best effort) - $_tgz may be incomplete"
	else
		log "WARNING: nothing to tar"
	fi
	printf '%s' "$RECS" > "$BK/misc-records.txt"
	cat "$MT6890_CMDLINE" > "$BK/cmdline.txt"
	cat "$MT6890_PROC_MTD" > "$BK/mtd.txt"
	date > "$BK/date.txt"
	say "$MISC" > "$BK/misc-dev.txt"
	_lines=$(($(wc -l < "$BK/misc-records.txt")))
	_good="$(awk 'length($0) == 32 && $0 !~ /[^0-9a-f]/ { n++ } END { print n + 0 }' "$BK/misc-records.txt")"
	if [ "$_lines" -ne 4 ] || [ "$_good" -ne 4 ]; then
		die "backup gate: $BK/misc-records.txt has $_lines lines / $_good valid records (want 4/4)"
	fi
	say "backup: $BK"
	ls -l "$BK"

	say "--- off-device partition dumps (mandatory) ---"
	say "on-device sha256 of the full partitions (streamed, nothing stored in $MT6890_TMPDIR):"
	_shm="$(part_sha "$MISC")"
	SHA_A="$(part_sha "$ADEV")"
	SHA_B="$(part_sha "$BDEV")"
	{
		say "$_shm  misc.bin"
		say "$SHA_A  rootfs_a.bin"
		say "$SHA_B  rootfs_b.bin"
	} > "$BK/partitions.sha256"
	sed 's/^/  /' "$BK/partitions.sha256"
	say "Run these FROM THE PC (RAM on the unit is too small to hold 2 x 64 MiB; stream over ssh):"
	say "  (stock login user is 'admin', uid 0; OpenSSH >= 8.8 needs 'HostKeyAlgorithms +ssh-rsa' for the stock"
	say "   dropbear host key - see Flash-Plan \"Prerequisites\")"
	say "  ssh <user>@<router> \"$(dump_cmd "$MISC")\" > misc.bin"
	say "  ssh <user>@<router> \"$(dump_cmd "$ADEV")\" > rootfs_a.bin"
	say "  ssh <user>@<router> \"$(dump_cmd "$BDEV")\" > rootfs_b.bin"
	say "  sha256sum misc.bin rootfs_a.bin rootfs_b.bin"
	say "nanddump may print \"ECC: N corrected bitflip(s)\" on stderr - corrected, harmless."
	say "the RUNNING slot (rootfs_b) dumps a different sha256 each time (live UBI) - that is expected; rootfs_a and misc must match the sums above exactly."
	say "PC-side misc and rootfs_a sums must equal the on-device sums above (also in $BK/partitions.sha256); rootfs_b is informational."
	say "Also copy the backup dir and config tar to the PC (OpenSSH >= 9 needs -O if the router has no sftp-server):"
	say "  scp -r <router>:$BK <router>:$_tgz <pc>/"
	if [ "$MT6890_SKIP_DUMP_GATE" = 1 ]; then
		say "WARNING: dump gate skipped by env"
	else
		confirm "Have you completed the off-device dumps of misc, rootfs_a, rootfs_b and verified the misc + rootfs_a sha256 on the PC?" ||
			die "dump gate: off-device dumps not confirmed - stopped before PHASE 2 (nothing flashed)"
	fi
	say "PHASE 1 OK"
}

# PHASE 3.x: save the original payload, write slot A's payload, read back
switch_record_to_a() {
	read_records "$MISC" || die "misc record check failed before the switch; misc untouched - the unit still boots B"
	_orig="$(say "$REC0" | cut -c17-32)"
	printf '%s\n' "$_orig" > "$BK/original-record.hex"
	[ "$(cat "$BK/original-record.hex")" = "$_orig" ] || die "cannot save $BK/original-record.hex; misc untouched"
	say "original payload (copy 0) saved: $BK/original-record.hex = $_orig"
	_new="$(payload_slot_a "$REC0")"
	say "misc $MISC: payload $_orig -> $_new"
	if ! write_payload "$MISC" "$_new"; then
		log "RECORD WRITE FAILED - do NOT reboot."
		log "restore the original record with:"
		log "  sh $0 revert $BK/original-record.hex"
		exit 1
	fi
}

# --- flash ------------------------------------------------------------------
cmd_flash() { # <url> <sha256>
	url="$1"; want_sha="$(say "$2" | sed 'y/ABCDEF/abcdef/')"
	img="$MT6890_TMPDIR/img.bin"
	dryrun && say "*** MT6890_DRYRUN=1: mtd, flash_erase, nandwrite, dd-nand, tar and wget are printed, not run ***"

	phase0 flash
	phase1

	confirm "Continue to PHASE 2 (download the image to $img)?" || die "stopped by user before PHASE 2 (nothing flashed)"
	say "=== PHASE 2: transfer (writes only to $MT6890_TMPDIR) ==="
	if dryrun; then
		say "DRYRUN: wget -O $img $url"
	else
		rm -f "$img"
		wget -O "$img" "$url" || die "wget failed"
	fi
	if [ -f "$img" ]; then
		_isz=$(($(wc -c < "$img")))
		[ "$_isz" -eq "$IMG_SIZE" ] || die "size gate: $img is $_isz bytes, want exactly $IMG_SIZE (nothing flashed)"
		say "size gate OK: $_isz"
		_got_sha="$(sha_file "$img")"
		[ "$_got_sha" = "$want_sha" ] || die "sha256 gate: got $_got_sha want $want_sha (nothing flashed)"
		say "sha256 gate OK: $_got_sha"
	elif dryrun; then
		say "DRYRUN: $img not present - size/sha256 gates skipped"
	else
		die "$img missing after wget"
	fi
	say "PHASE 2 OK"

	confirm "PHASE 3 ERASES and WRITES $SLOT_A_MTD (mtd$SLOT_A_NUM), verifies it, then switches misc to slot A. Proceed?" ||
		die "stopped by user before PHASE 3 (nothing flashed)"
	say "=== PHASE 3: flash slot A ==="
	[ "$(slot_booted)" = b ] || die "booted slot is no longer B - refusing to touch $SLOT_A_MTD"
	if [ "$WTOOL" = mtd ]; then
		say "[3.1] mtd erase $SLOT_A_MTD"
		run mtd erase "$SLOT_A_MTD"; _rc=$?
	else
		say "[3.1] flash_erase $ADEV 0 0"
		run flash_erase "$ADEV" 0 0; _rc=$?
	fi
	[ "$_rc" -eq 0 ] || die "erase of $SLOT_A_MTD failed (rc $_rc); misc untouched - the unit still boots B"
	if [ "$WTOOL" = mtd ]; then
		say "[3.2] mtd write $img $SLOT_A_MTD - 64 MiB, this takes a few minutes ..."
		run mtd write "$img" "$SLOT_A_MTD"; _rc=$?
	else
		say "[3.2] nandwrite -p $ADEV $img - 64 MiB, this takes a few minutes ..."
		run nandwrite -p "$ADEV" "$img"; _rc=$?
	fi
	[ "$_rc" -eq 0 ] || die "write of $SLOT_A_MTD failed (rc $_rc); misc untouched - the unit still boots B"
	say "[3.3] readback gate: sha256 of $SLOT_A_MTD vs image"
	if dryrun; then
		say "DRYRUN: readback gate skipped (nothing was written)"
	else
		_rb="$(slot_readback_sha "$ADEV")"
		if [ "$_rb" != "$want_sha" ]; then
			log "readback gate: $SLOT_A_MTD sha256 $_rb != image $want_sha"
			log "slot A now holds a bad image. That is harmless: the misc record was NOT touched and still selects B,"
			log "so the unit keeps booting stock B. Retry from PHASE 0: sh $0 flash $url $want_sha"
			die "readback gate failed - misc untouched"
		fi
		say "readback gate OK: $_rb"
	fi
	say "[3.4] misc record -> slot A"
	switch_record_to_a
	if dryrun; then say "PHASE 3 (DRYRUN): nothing was written"
	else say "PHASE 3 OK: $SLOT_A_MTD written + verified, all 4 misc copies select slot A"; fi

	say "=== PHASE 4: done (nothing more is written) ==="
	cat <<EOF
After the reboot (wait ~90 s), on 24.10 check (Flash-Plan 5):
  grep -o 'ubi.mtd=[^ ]*' /proc/cmdline   -> ubi.mtd=29
  mt6890-bootctl status                   -> active=a booted=a copies_consistent=yes armed=yes
  uci show network.wan                    -> proto='mtkmipc' (migration ran)
  wifi status                             -> ra0 (2.4 GHz) + rai0 (5 GHz) once enabled
  ifstatus wan                            -> cellular data call up
  ls /lib/modules/4.19.205 | wc -l        -> 136
The image ships ARMED: the preloader fallback stays active until you log in and run 'mt6890-bootctl confirm'. If you never get in, power-cycle the unit $FALLBACK_TRIES times (tries=$FALLBACK_TRIES) and it returns to stock B by itself.
Wireless ships disabled with a placeholder key: set your key, enable, then 'wifi'.

APN (Flash-Plan 6): the first install writes no config. Re-enter APN, auth,
user, password and IP type on network.wan from the stock backup
(uci set network.wan.apn=... ; uci commit network; ifup wan).

Success (Flash-Plan 7): boots from A, bootctl consistent, both Wi-Fi bands
with your SSIDs, cellular data up, 136 modules, config migrated; then run
'mt6890-bootctl confirm' (-> armed=no), reboot once more and confirm the
unit STAYS on A.

The first 24.10 -> 24.10 sysupgrade overwrites stock in slot B permanently. Keep the rootfs_b dump from PHASE 1.

Copy the backup off the unit first (/tmp does not survive a reboot):
  scp -r <router>:$BK <router>:$MT6890_TMPDIR/stock-config-backup.tgz <pc>/

EOF
	say "run \`reboot\` yourself when ready. If the unit fails to boot, the preloader falls back to stock B after the tries; \`$PROG revert /tmp/flash-backup-*/misc-records.txt\` from stock fixes a stuck record."
	say "(this run: $PROG revert $BK/misc-records.txt)"
}

# --- rehearse ---------------------------------------------------------------
cmd_rehearse() {
	dryrun && say "*** MT6890_DRYRUN=1: dd-nand and tar are printed, not run ***"
	phase0 rehearse
	phase1
	if [ "$SHA_A" != "$SHA_B" ]; then
		say "NOTE: rootfs_a sha256 ($SHA_A) != rootfs_b sha256 ($SHA_B): slot A is NOT a byte clone of B."
		say "NOTE: the rehearsal is only meaningful when slot A holds a bootable stock image; this script cannot verify that itself."
		confirm "Does slot A hold a bootable stock image (e.g. an earlier stock clone of B)?" ||
			die "rehearsal not confirmed (nothing written)"
	else
		say "rootfs_a and rootfs_b are byte-identical (sha256 $SHA_A)"
	fi
	say "NOTE: when stock boots from A with success_a != 01, its boot-done script clones A over B (the mirror of the PHASE 0 warning). With A a stock copy this is expected; keep the rootfs_b dump."
	confirm "Rehearsal: write ONLY the misc record (slot A: prio 0f, tries 03, success 00; no rootfs write). Proceed?" ||
		die "stopped by user before the record write (nothing written)"
	say "=== REHEARSAL: misc record -> slot A (rootfs untouched) ==="
	[ "$(slot_booted)" = b ] || die "booted slot is no longer B - refusing"
	switch_record_to_a
	if dryrun; then say "REHEARSAL (DRYRUN): nothing was written"; return 0; fi
	say "rehearsal armed: reboot now. Expected: the unit boots from A (stock copy). After it is up, run '$PROG status' — booted=a proves the record semantics and that LK accepts prio 0f/tries 03. Then run '$PROG revert $BK/original-record.hex' and reboot to return to B."
	say "(copy $BK off the unit before rebooting: /tmp does not survive a reboot)"
}

# --- status -----------------------------------------------------------------
cmd_status() {
	need_misc
	say "misc: $MISC"
	_ok=0
	read_records "$MISC" || _ok=1
	print_records
	if records_consistent; then say "copies_consistent=yes"; else say "copies_consistent=no"; fi
	_act="$(slot_active "$REC0")" || _act="?"
	_boot="$(slot_booted)" || _boot="?"
	say "active=$_act booted=$_boot"
	return "$_ok"
}

# --- revert -----------------------------------------------------------------
cmd_revert() { # <backup-file>
	[ -r "$1" ] || die "cannot read $1"
	_data="$(sed 's/[[:space:]]//g; /^$/d; y/ABCDEF/abcdef/' "$1")"
	_n=$(($(say "$_data" | wc -l)))
	[ -n "$_data" ] || die "$1: empty"
	if say "$_data" | grep -q '[^0-9a-f]'; then die "$1: not hex"; fi
	if [ "$_n" -eq 1 ] && [ "${#_data}" -eq 16 ]; then
		_pl="$_data"
	elif [ "$_n" -eq 4 ] && [ "$(say "$_data" | awk 'length($0) == 32 && substr($0, 1, 8) == "'"$BC_MAGIC"'" { n++ } END { print n + 0 }')" -eq 4 ]; then
		_pl="$(say "$_data" | head -n1 | cut -c17-32)"
		[ "$(say "$_data" | cut -c17-32 | sort -u | wc -l)" -eq 1 ] ||
			log "WARNING: payloads differ between the 4 backed-up copies - restoring copy 0's to all"
	else
		die "$1: want 4 lines of 32 hex chars (misc-records.txt) or 1 line of 16 hex chars (original-record.hex)"
	fi
	need_misc
	need_ddnand
	read_records "$MISC" || die "current misc record check failed (magic) - refusing to write"
	say "misc: $MISC"
	print_records
	say "target payload (+8..+15): $_pl"
	_same=1
	for _c in $BC_COPIES; do
		[ "$(bc_read "$MISC" "$_c" | cut -c17-32)" = "$_pl" ] || _same=0
	done
	if [ "$_same" -eq 1 ]; then say "all 4 copies already hold $_pl - nothing to write"; return 0; fi
	confirm "Write $_pl to all 4 misc copies?" || die "stopped by user (nothing written)"
	if ! write_payload "$MISC" "$_pl"; then
		log "REVERT FAILED - do NOT reboot; retry: sh $0 revert $1"
		exit 1
	fi
	dryrun && return 0
	say "revert OK: all 4 copies restored ($_pl), active slot now $(slot_active "$(bc_read "$MISC" 0)")"
}

case "${1:-}" in
flash)
	[ $# -eq 3 ] || usage
	case "$3" in
	*[!0-9a-fA-F]*) usage ;;
	esac
	[ "${#3}" -eq 64 ] || usage
	shift; cmd_flash "$@" ;;
rehearse) [ $# -eq 1 ] || usage; cmd_rehearse ;;
fingerprint) [ $# -eq 2 ] || usage; fingerprint "$2" ;;
status) [ $# -eq 1 ] || usage; cmd_status ;;
revert) [ $# -eq 2 ] || usage; cmd_revert "$2" ;;
*) usage ;;
esac
