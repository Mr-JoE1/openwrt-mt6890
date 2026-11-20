#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# shellcheck shell=sh
#
# dwr2000m-flash.sh - first install of the 64 MiB UBI OpenWrt 24.10 image on
# a D-Link DWR-2000M A3 that still runs the stock firmware. It is the
# executable form of the wiki page "Flash-Plan" (public/wiki/Flash-Plan.md):
# back up, fetch the image into /tmp, gate it on size (+ sha256 or the
# first/last 1 KiB fingerprint), erase and write the idle slot A (rootfs_a,
# mtd29) and finally switch the misc A/B record to slot A with the stock
# dd-nand. Runs on the stock busybox ash (POSIX sh, no bashisms). The misc
# record logic mirrors openwrt/package/mt6890-sysupgrade/files/lib/upgrade/
# mt6890-bootctl.sh, which is the single source of truth for its semantics.
#
# Safety invariants:
#  * never writes the running slot: only the reference layout (stock booted
#    AND active on B = rootfs_b/mtd42) is accepted, rechecked right before
#    the erase; the only rootfs target is rootfs_a
#  * the misc record is switched last, only after erase + write returned 0
#  * every record write is read back (all 4 copies, magic + 8-byte payload);
#    any mismatch exits nonzero and prints the revert command
#  * never reboots the unit; no write happens before its gate has passed
#
# Usage:
#   dwr2000m-flash.sh flash <image-url> [expected-sha256]
#   dwr2000m-flash.sh fingerprint <file>
#   dwr2000m-flash.sh status
#   dwr2000m-flash.sh revert <backup-file>
#
# Environment (test hooks, mirroring the package): MT6890_PROC_MTD,
# MT6890_CMDLINE, MT6890_DEVDIR, MT6890_MISC_DEV (misc device, highest
# precedence), MT6890_DDNAND, MT6890_DRYRUN=1 (print mtd/dd-nand/tar/wget
# instead of running them), MT6890_TMPDIR (default /tmp),
# MT6890_BACKUP_PATHS (default "/etc /data").
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

# misc A/B record (mt6890-bootctl.sh)
BC_OFF=2048          # record offset in each copy
BC_SEEK0=2056        # BC_OFF + 8: start of the 8-byte payload (+8..+15)
BC_STRIDE=262144     # 256 KiB between copies
BC_COPIES="0 1 2 3"
BC_MAGIC=00414230    # "\0AB0"

IMG_SIZE=67108864    # 64 MiB UBI image
SLOT_A_MTD=rootfs_a; SLOT_A_NUM=29
SLOT_B_MTD=rootfs_b; SLOT_B_NUM=42

PROG="${0##*/}"
DDN=""
MISC=""
RECS=""
REC0=""

say() { printf '%s\n' "$*"; }
log() { printf '%s: %s\n' "$PROG" "$*" >&2; }
die() { printf '%s: ABORT: %s\n' "$PROG" "$*" >&2; exit 1; }
dryrun() { [ "$MT6890_DRYRUN" = 1 ]; }

usage() {
	cat <<EOF
Usage: $PROG <command> [args]

  flash <image-url> [expected-sha256]
        first install of the 64 MiB UBI image into the idle slot A from
        stock (stock must run from B); interactive, gated, never reboots
  fingerprint <file>
        size + hexdump -C of the first/last 1 KiB (run on the serving PC;
        flash prints the same for /tmp/img.bin so the two can be diffed)
  status
        dump all 4 misc records, active slot, booted slot (read-only)
  revert <backup-file>
        write the original 8-byte payload back to all 4 misc copies;
        <backup-file> = misc-records.txt (4 x 32 hex) or original-record.hex
        (16 hex = 8 bytes)

Only flash and revert write. See the wiki page Flash-Plan.
EOF
	exit 2
}

confirm() { # <question>
	printf '%s [y/N] ' "$1"
	read -r ans || ans=""
	case "$ans" in y|Y|yes|YES) return 0 ;; esac
	return 1
}

run() { # mtd/wget/tar wrapper honouring MT6890_DRYRUN
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
	if command -v hexdump >/dev/null 2>&1; then
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

slot_booted() { # ubi.mtd=<num|name> in cmdline, resolved to a name via /proc/mtd
	[ -r "$MT6890_CMDLINE" ] || return 1
	_name=""
	_cl="$(cat "$MT6890_CMDLINE")"
	for _arg in $_cl; do
		case "$_arg" in
		ubi.mtd=*)
			_v="${_arg#ubi.mtd=}"; _v="${_v%%,*}"
			case "$_v" in
			*[!0-9]*) _name="$_v" ;;
			*) _name="$(mtd_name "$_v")" ;;
			esac
			;;
		esac
	done
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

# --- fingerprint ------------------------------------------------------------
fingerprint() { # <file>: identical output on PC and router for identical files
	[ -f "$1" ] || die "fingerprint: no such file: $1"
	command -v hexdump >/dev/null 2>&1 || die "fingerprint: hexdump not found"
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

# --- flash ------------------------------------------------------------------
cmd_flash() { # <url> [sha256]
	url="$1"; want_sha="$(say "${2:-}" | sed 'y/ABCDEF/abcdef/')"
	img="$MT6890_TMPDIR/img.bin"
	tgz="$MT6890_TMPDIR/stock-config-backup.tgz"
	dryrun && say "*** MT6890_DRYRUN=1: mtd, dd-nand, tar and wget are printed, not run ***"

	say "=== PHASE 0: preflight (read-only) ==="
	[ -r "$MT6890_PROC_MTD" ] || die "cannot read $MT6890_PROC_MTD"
	_na="$(mtd_num "$SLOT_A_MTD")" || die "no \"$SLOT_A_MTD\" in $MT6890_PROC_MTD"
	_nb="$(mtd_num "$SLOT_B_MTD")" || die "no \"$SLOT_B_MTD\" in $MT6890_PROC_MTD"
	if [ "$_na" != "$SLOT_A_NUM" ] || [ "$_nb" != "$SLOT_B_NUM" ]; then
		die "$SLOT_A_MTD=mtd$_na $SLOT_B_MTD=mtd$_nb; the reference layout is mtd$SLOT_A_NUM/mtd$SLOT_B_NUM - see Flash-Plan"
	fi
	_sa="$(mtd_size "$SLOT_A_MTD")"
	if [ -z "$_sa" ] || [ "$_sa" -lt "$IMG_SIZE" ]; then
		die "$SLOT_A_MTD is ${_sa:-?} bytes, image needs $IMG_SIZE"
	fi
	say "$SLOT_A_MTD = mtd$_na ($_sa bytes), $SLOT_B_MTD = mtd$_nb"
	need_misc
	say "misc: $MISC"
	need_ddnand
	if ! dryrun; then
		for _t in mtd wget; do
			command -v "$_t" >/dev/null 2>&1 || die "'$_t' not found"
		done
	fi
	read_records "$MISC" || die "misc record check failed (all 4 copies must carry magic $BC_MAGIC)"
	print_records
	records_consistent || log "WARNING: the 4 misc copies are not identical (copy 0 is used)"
	_act="$(slot_active "$REC0")" || die "cannot determine the active slot from the misc record"
	_boot="$(slot_booted)" || die "cannot resolve the booted slot: no ubi.mtd=$SLOT_A_MTD/$SLOT_B_MTD in $MT6890_CMDLINE"
	say "active slot (misc priority): $_act"
	say "booted slot (cmdline ubi.mtd -> /proc/mtd): $_boot"
	[ "$_boot" = b ] ||
		die "this script targets the reference layout (stock on B); see Flash-Plan, swap A/B manually"
	[ "$_act" = b ] ||
		die "running B but misc already selects A (earlier attempt?) - check '$PROG status', fix with '$PROG revert <backup>'"
	say "PHASE 0 OK: stock runs from B and B is active; target slot A ($SLOT_A_MTD)"

	confirm "Continue to PHASE 1 (backup to $MT6890_TMPDIR)?" || die "stopped by user before PHASE 1 (nothing written)"
	say "=== PHASE 1: backup (writes only to $MT6890_TMPDIR) ==="
	bk="$MT6890_TMPDIR/flash-backup-$(date +%s)"
	[ -e "$bk" ] && bk="$bk-$$"
	mkdir "$bk" || die "cannot create $bk"
	_paths=""
	for _p in $MT6890_BACKUP_PATHS; do
		if [ -e "$_p" ]; then _paths="$_paths $_p"; else log "WARNING: $_p missing - not in the config backup"; fi
	done
	if [ -n "$_paths" ]; then
		# shellcheck disable=SC2086
		run tar czf "$tgz" $_paths || log "WARNING: tar failed (best effort) - $tgz may be incomplete"
	else
		log "WARNING: nothing to tar"
	fi
	printf '%s' "$RECS" > "$bk/misc-records.txt"
	cat "$MT6890_CMDLINE" > "$bk/cmdline.txt"
	cat "$MT6890_PROC_MTD" > "$bk/mtd.txt"
	date > "$bk/date.txt"
	say "$MISC" > "$bk/misc-dev.txt"
	_lines=$(($(wc -l < "$bk/misc-records.txt")))
	_good="$(awk 'length($0) == 32 && $0 !~ /[^0-9a-f]/ { n++ } END { print n + 0 }' "$bk/misc-records.txt")"
	if [ "$_lines" -ne 4 ] || [ "$_good" -ne 4 ]; then
		die "backup gate: $bk/misc-records.txt has $_lines lines / $_good valid records (want 4/4)"
	fi
	say "backup: $bk"
	ls -l "$bk"
	say "copy it to the flashing PC now (run on the PC; OpenSSH >= 9 needs -O if the router has no sftp-server):"
	say "  scp -r <router>:$MT6890_TMPDIR/flash-backup-* <router>:$tgz <pc>/"
	say "PHASE 1 OK"

	confirm "Continue to PHASE 2 (download the image to $img)?" || die "stopped by user before PHASE 2 (nothing flashed)"
	say "=== PHASE 2: transfer (writes only to $MT6890_TMPDIR) ==="
	say "note: the stock firmware has no sha256sum - without it the gate is size + first/last 1 KiB fingerprint"
	if dryrun; then
		say "DRYRUN: wget -O $img $url"
	else
		rm -f "$img"
		wget -O "$img" "$url" || die "wget failed"
	fi
	if [ -f "$img" ]; then
		_isz=$(($(wc -c < "$img")))
		[ "$_isz" -eq "$IMG_SIZE" ] || die "size gate: $img is $_isz bytes, want exactly $IMG_SIZE"
		say "size gate OK: $_isz"
		if [ -n "$want_sha" ] && command -v sha256sum >/dev/null 2>&1; then
			_got_sha="$(sha256sum "$img" | cut -d' ' -f1)"
			[ "$_got_sha" = "$want_sha" ] || die "sha256 gate: got $_got_sha want $want_sha"
			say "sha256 gate OK: $_got_sha"
		else
			[ -n "$want_sha" ] && say "sha256 given but sha256sum is not available here - using the fingerprint gate"
			say "fingerprint of $img (diff against '$PROG fingerprint <image>' on the PC):"
			fingerprint "$img"
			confirm "Is this fingerprint byte-for-byte identical to the PC-side one?" ||
				die "fingerprint gate not confirmed (nothing flashed)"
		fi
	elif dryrun; then
		say "DRYRUN: $img not present - size/sha256 gates skipped"
	else
		die "$img missing after wget"
	fi
	say "PHASE 2 OK"

	confirm "PHASE 3 ERASES and WRITES $SLOT_A_MTD (mtd$SLOT_A_NUM), then switches misc to slot A. Proceed?" ||
		die "stopped by user before PHASE 3 (nothing flashed)"
	say "=== PHASE 3: flash slot A ==="
	[ "$(slot_booted)" = b ] || die "booted slot is no longer B - refusing to touch $SLOT_A_MTD"
	say "[3.1] mtd erase $SLOT_A_MTD"
	run mtd erase "$SLOT_A_MTD"; _rc=$?
	[ "$_rc" -eq 0 ] || die "mtd erase $SLOT_A_MTD failed (rc $_rc); misc untouched - the unit still boots B"
	say "[3.2] mtd write $img $SLOT_A_MTD - 64 MiB, this takes a few minutes ..."
	run mtd write "$img" "$SLOT_A_MTD"; _rc=$?
	[ "$_rc" -eq 0 ] || die "mtd write failed (rc $_rc); misc untouched - the unit still boots B"
	say "[3.3] misc record -> slot A"
	read_records "$MISC" || die "misc record check failed before the switch; misc untouched - the unit still boots B"
	_orig="$(say "$REC0" | cut -c17-32)"
	printf '%s\n' "$_orig" > "$bk/original-record.hex"
	[ "$(cat "$bk/original-record.hex")" = "$_orig" ] || die "cannot save $bk/original-record.hex; misc untouched"
	say "original payload (copy 0) saved: $bk/original-record.hex = $_orig"
	_new="$(payload_slot_a "$REC0")"
	say "misc $MISC: payload $_orig -> $_new"
	if ! write_payload "$MISC" "$_new"; then
		log "RECORD WRITE FAILED - do NOT reboot."
		log "restore the original record with:"
		log "  sh $0 revert $bk/original-record.hex"
		exit 1
	fi
	if dryrun; then say "PHASE 3 (DRYRUN): nothing was written"
	else say "PHASE 3 OK: $SLOT_A_MTD written, all 4 misc copies select slot A"; fi

	say "=== PHASE 4: done (nothing more is written) ==="
	cat <<EOF
After the reboot (wait ~90 s), on 24.10 check (Flash-Plan 5):
  grep -o 'ubi.mtd=[^ ]*' /proc/cmdline   -> ubi.mtd=29
  mt6890-bootctl status                   -> active=a booted=a copies_consistent=yes
  uci show network.wan                    -> proto='mtkmipc' (migration ran)
  wifi status                             -> ra0 (2.4 GHz) + rai0 (5 GHz) once enabled
  ifstatus wan                            -> cellular data call up
  ls /lib/modules/4.19.205 | wc -l        -> 136
  logread | grep mt6890-bootok            -> tries reset for slot A
Wireless ships disabled with a placeholder key: set your key, enable, then 'wifi'.

APN (Flash-Plan 6): the first install writes no config. Re-enter APN, auth,
user, password and IP type on network.wan from the stock backup
(uci set network.wan.apn=... ; uci commit network; ifup wan).

Success (Flash-Plan 7): boots from A, bootctl consistent, both Wi-Fi bands
with your SSIDs, cellular data up, 136 modules, config migrated, bootok
logged; reboot once more and confirm the unit STAYS on A.

Copy the backup off the unit first (/tmp does not survive a reboot):
  scp -r <router>:$bk <router>:$tgz <pc>/

EOF
	say "run \`reboot\` yourself when ready. If the unit fails to boot, the preloader falls back to stock B after the tries; \`$PROG revert /tmp/flash-backup-*/misc-records.txt\` from stock fixes a stuck record."
	say "(this run: $PROG revert $bk/misc-records.txt)"
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
flash) { [ $# -eq 2 ] || [ $# -eq 3 ]; } || usage; shift; cmd_flash "$@" ;;
fingerprint) [ $# -eq 2 ] || usage; fingerprint "$2" ;;
status) [ $# -eq 1 ] || usage; cmd_status ;;
revert) [ $# -eq 2 ] || usage; cmd_revert "$2" ;;
*) usage ;;
esac
