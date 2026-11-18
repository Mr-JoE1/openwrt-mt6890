# SPDX-License-Identifier: GPL-2.0-only
# shellcheck shell=sh
#
# mt6890 A/B boot-control helpers - the single source of truth for slot
# state, shared by /usr/bin/mt6890-bootctl and /lib/upgrade/platform.sh.
# Sourced only (function + default definitions; no side effects).
# Lives in /lib/upgrade so stage2 copies it into the sysupgrade ramfs.
#
# Record (stock lib/upgrade/bootctrl.sh:46-55): MTD partition "misc",
# offset 2048, 16 bytes:
#   +0..3  magic 00 41 42 30 ("\0AB0")            (bootctrl.sh:178-185)
#   +8  A priority  +9  A tries  +10 A success  +11 A uptype
#   +12 B priority  +13 B tries  +14 B success  +15 B uptype
# Four copies at 256 KiB stride (bootctrl.sh:72-73, 96-97).
# Read:  dd from /dev/mtdN    (stock used nanddump, bootctrl.sh:60,84;
#                              nand-utils is not in the 24.10 image)
# Write: stock dd-nand, same 8 bytes to every copy (bootctrl.sh:92-98)
# Active slot = higher priority byte (bootctrl.sh:263-273).
# Switch to slot X = X prio 0f, X tries 03, X success 00, other prio 0e
# (stock intent: bootctrl.sh:192-241 arguments and the commented-out
# set_bootctrl calls at 209-216/244-251; see NOTES-p2 "P5" for what the
# stock shell actually wrote). uptype bytes are left untouched.
# bootok (good boot) = running slot's tries byte (+9 A / +13 B) := 00 only,
# 1 byte per dd-nand call x4 copies (stock set_bootctrl, bootctrl.sh:68-78).

MT6890_PROC_MTD="${MT6890_PROC_MTD:-/proc/mtd}"
MT6890_CMDLINE="${MT6890_CMDLINE:-/proc/cmdline}"
MT6890_DEVDIR="${MT6890_DEVDIR:-/dev}"
MT6890_DDNAND="${MT6890_DDNAND:-}"
MT6890_DRYRUN="${MT6890_DRYRUN:-0}"

MT6890_BC_OFF=2048
MT6890_BC_STRIDE=262144
MT6890_BC_COPIES="0 1 2 3"
MT6890_BC_MAGIC=00414230

mt6890_log() { echo "mt6890: $*" >&2; }

mt6890_dryrun() { [ "$MT6890_DRYRUN" = 1 ]; }

# --- /proc/mtd ------------------------------------------------------------
# mtdN: <size hex> <erasesize hex> "<name>"
mt6890_hex2dec() { printf '%d\n' "0x$1"; }
mt6890_mtd_num() {
	[ -r "$MT6890_PROC_MTD" ] || return 1
	sed -n "s/^mtd\([0-9]*\): [0-9a-fA-F]* [0-9a-fA-F]* \"$1\"\$/\1/p" "$MT6890_PROC_MTD" | head -n1 | grep .
}
mt6890_mtd_size() {
	local h
	h="$(sed -n "s/^mtd[0-9]*: \([0-9a-fA-F]*\) [0-9a-fA-F]* \"$1\"\$/\1/p" "$MT6890_PROC_MTD" 2>/dev/null | head -n1)"
	[ -n "$h" ] && mt6890_hex2dec "$h"
}
mt6890_mtd_erasesize() {
	local h
	h="$(sed -n "s/^mtd[0-9]*: [0-9a-fA-F]* \([0-9a-fA-F]*\) \"$1\"\$/\1/p" "$MT6890_PROC_MTD" 2>/dev/null | head -n1)"
	[ -n "$h" ] && mt6890_hex2dec "$h"
}
mt6890_mtd_name() { # <num>
	sed -n "s/^mtd$1: [0-9a-fA-F]* [0-9a-fA-F]* \"\(.*\)\"\$/\1/p" "$MT6890_PROC_MTD" 2>/dev/null | head -n1 | grep .
}

mt6890_misc_dev() {
	local n
	n="$(mt6890_mtd_num misc)" || { mt6890_log "no \"misc\" partition in $MT6890_PROC_MTD"; return 1; }
	echo "$MT6890_DEVDIR/mtd$n"
}

mt6890_ddnand() {
	if [ -n "$MT6890_DDNAND" ]; then echo "$MT6890_DDNAND"; return 0; fi
	command -v dd-nand 2>/dev/null && return 0
	for p in /usr/sbin/dd-nand /sbin/dd-nand; do
		[ -x "$p" ] && { echo "$p"; return 0; }
	done
	return 1
}

# --- record read ----------------------------------------------------------
mt6890_bc_read() { # <copy 0..3> -> 32 hex chars (16 bytes @2048)
	local dev off
	dev="$(mt6890_misc_dev)" || return 1
	off=$((MT6890_BC_STRIDE * $1 + MT6890_BC_OFF))
	dd if="$dev" bs=16 skip=$((off / 16)) count=1 2>/dev/null | hexdump -v -e '1/1 "%02x"'
}

mt6890_bc_byte() { # <record32> <byte index 0..15> -> 2 hex chars
	echo "$1" | cut -c$(($2 * 2 + 1))-$(($2 * 2 + 2))
}

# validate all copies; print copy 0 record on success
mt6890_bc_get() {
	local c rec rec0="" dev size
	dev="$(mt6890_misc_dev)" || return 1
	size="$(mt6890_mtd_size misc)"
	if [ -z "$size" ] || [ "$size" -lt $((MT6890_BC_STRIDE * 3 + MT6890_BC_OFF + 16)) ]; then
		mt6890_log "misc partition too small (${size:-?} bytes)"
		return 1
	fi
	for c in $MT6890_BC_COPIES; do
		rec="$(mt6890_bc_read "$c")"
		if [ "${#rec}" -ne 32 ]; then
			mt6890_log "misc copy $c: short read from $dev"
			return 1
		fi
		if [ "$(echo "$rec" | cut -c1-8)" != "$MT6890_BC_MAGIC" ]; then
			mt6890_log "misc copy $c: bad magic $(echo "$rec" | cut -c1-8) (want $MT6890_BC_MAGIC) - not an A/B record, refusing"
			return 1
		fi
		[ "$c" = 0 ] && rec0="$rec"
	done
	echo "$rec0"
}

mt6890_slot_other() { case "$1" in a) echo b ;; b) echo a ;; *) return 1 ;; esac; }

# slot that the preloader boots next (stock get_current_slot)
mt6890_slot_active() { # [record]
	local rec="${1:-}" pa pb
	[ -n "$rec" ] || rec="$(mt6890_bc_get)" || return 1
	pa=$(printf '%d' "0x$(mt6890_bc_byte "$rec" 8)")
	pb=$(printf '%d' "0x$(mt6890_bc_byte "$rec" 12)")
	if [ "$pa" -gt "$pb" ]; then echo a
	elif [ "$pb" -gt "$pa" ]; then echo b
	else mt6890_log "SAME A/B PRIORITY ($pa) in misc record"; return 1
	fi
}

# slot the running kernel was booted from: cmdline ubi.mtd=<num|name>
mt6890_slot_booted() {
	local arg v name=""
	[ -r "$MT6890_CMDLINE" ] || return 1
	for arg in $(cat "$MT6890_CMDLINE"); do
		case "$arg" in
		ubi.mtd=*)
			v="${arg#ubi.mtd=}"; v="${v%%,*}"
			case "$v" in
			*[!0-9]*) name="$v" ;;
			*) name="$(mt6890_mtd_name "$v")" ;;
			esac
			;;
		esac
	done
	case "$name" in
	rootfs_a) echo a ;;
	rootfs_b) echo b ;;
	*) return 1 ;;
	esac
}

# --- record write ---------------------------------------------------------
# new 8-byte payload (bytes +8..+15) that makes <slot> active
mt6890_bc_payload() { # <record32> <slot>
	local rec="$1" ap at as au bp bt bs bu
	ap=$(mt6890_bc_byte "$rec" 8);  at=$(mt6890_bc_byte "$rec" 9)
	as=$(mt6890_bc_byte "$rec" 10); au=$(mt6890_bc_byte "$rec" 11)
	bp=$(mt6890_bc_byte "$rec" 12); bt=$(mt6890_bc_byte "$rec" 13)
	bs=$(mt6890_bc_byte "$rec" 14); bu=$(mt6890_bc_byte "$rec" 15)
	case "$2" in
	a) ap=0f; at=03; as=00; bp=0e ;;
	b) bp=0f; bt=03; bs=00; ap=0e ;;
	*) return 1 ;;
	esac
	echo "$ap$at$as$au$bp$bt$bs$bu"
}

mt6890_hex_to_printf() { # 16 hex chars -> printf format with octal escapes
	local h="$1" out="" b
	while [ -n "$h" ]; do
		b="$(echo "$h" | cut -c1-2)"; h="$(echo "$h" | cut -c3-)"
		out="$out$(printf '\\%03o' "0x$b")"
	done
	printf '%s' "$out"   # not echo: dash's echo would interpret the escapes
}

mt6890_bc_set() { # <a|b>
	local slot="$1" rec new fmt dev ddn c off got
	case "$slot" in a|b) ;; *) mt6890_log "bad slot '$slot' (a|b)"; return 1 ;; esac
	rec="$(mt6890_bc_get)" || return 1
	dev="$(mt6890_misc_dev)" || return 1
	new="$(mt6890_bc_payload "$rec" "$slot")" || return 1
	if [ "$(echo "$rec" | cut -c17-32)" = "$new" ] && [ "$(mt6890_bc_consistent)" = yes ]; then
		mt6890_log "misc already selects slot $slot ($new) - nothing to write"
		return 0
	fi
	if mt6890_dryrun; then
		mt6890_log "DRYRUN: would write $new to $dev at +$((MT6890_BC_OFF + 8)) x4 copies (current $(echo "$rec" | cut -c17-32))"
		return 0
	fi
	ddn="$(mt6890_ddnand)" || { mt6890_log "dd-nand not found - cannot write misc (refusing; no substitute)"; return 1; }
	fmt="$(mt6890_hex_to_printf "$new")"
	mt6890_log "misc $dev: $(echo "$rec" | cut -c17-32) -> $new (slot $slot)"
	for c in $MT6890_BC_COPIES; do
		off=$((MT6890_BC_STRIDE * c + MT6890_BC_OFF + 8))
		# shellcheck disable=SC2059
		printf "$fmt" | "$ddn" of="$dev" seek="$off" bs=1 count=8 >/dev/null 2>&1
	done
	# read back every copy
	for c in $MT6890_BC_COPIES; do
		got="$(mt6890_bc_read "$c" | cut -c1-32)"
		if [ "$(echo "$got" | cut -c1-8)" != "$MT6890_BC_MAGIC" ] || [ "$(echo "$got" | cut -c17-32)" != "$new" ]; then
			mt6890_log "misc copy $c readback mismatch: got $got want ${MT6890_BC_MAGIC}........$new"
			return 1
		fi
	done
	return 0
}

# Good-boot marker: zero the tries byte of <slot> (the slot that is RUNNING)
# in every copy, one byte per dd-nand call exactly as stock set_bootctrl does
# (bootctrl.sh:71,73: bs=1 count=1, seek = 256 KiB*copy + 2048 + 9|13), the
# way the stock boot-done init script does (etc/init.d, lines 28,66:
# set_bootctrl TRY_x \\x00).
# success and prio/uptype of BOTH slots and the other slot's tries are not
# touched: stock never writes success=01 (those writes are commented out in
# that script, lines 58,98; bootctrl.sh:192-241 only ever write success=00).
mt6890_bc_bootok() { # <a|b>
	local slot="$1" idx rec dev ddn fmt c off r want b todo=no before=""
	case "$slot" in a) idx=9 ;; b) idx=13 ;; *) mt6890_log "bootok: bad slot '$slot' (a|b)"; return 1 ;; esac
	rec="$(mt6890_bc_get)" || return 1
	dev="$(mt6890_misc_dev)" || return 1
	for c in $MT6890_BC_COPIES; do
		r="$(mt6890_bc_read "$c")"
		before="$before$r
"
		[ "$(mt6890_bc_byte "$r" "$idx")" = 00 ] || todo=yes
	done
	if [ "$todo" = no ]; then
		mt6890_log "bootok: slot $slot tries already 00 in all copies - nothing to write"
		return 0
	fi
	if mt6890_dryrun; then
		mt6890_log "DRYRUN: would write 00 to $dev at +$((MT6890_BC_OFF + idx)) x4 copies (slot $slot tries, current $(mt6890_bc_byte "$rec" "$idx"))"
		return 0
	fi
	ddn="$(mt6890_ddnand)" || { mt6890_log "dd-nand not found - cannot write misc (refusing; no substitute)"; return 1; }
	fmt="$(mt6890_hex_to_printf 00)"
	mt6890_log "misc $dev: slot $slot tries -> 00"
	for c in $MT6890_BC_COPIES; do
		off=$((MT6890_BC_STRIDE * c + MT6890_BC_OFF + idx))
		# shellcheck disable=SC2059
		printf "$fmt" | "$ddn" of="$dev" seek="$off" bs=1 count=1 >/dev/null 2>&1
	done
	# read back every copy: only the tries byte may differ from before
	for c in $MT6890_BC_COPIES; do
		b="$(echo "$before" | sed -n "$((c + 1))p")"
		want="$(echo "$b" | cut -c1-$((idx * 2)))00$(echo "$b" | cut -c$((idx * 2 + 3))-)"
		r="$(mt6890_bc_read "$c")"
		if [ "$r" != "$want" ]; then
			mt6890_log "misc copy $c readback mismatch: got $r want $want"
			return 1
		fi
	done
	return 0
}

# yes if bytes 0..15 of all copies are identical
mt6890_bc_consistent() {
	local c r0 r
	r0="$(mt6890_bc_read 0)"
	for c in $MT6890_BC_COPIES; do
		r="$(mt6890_bc_read "$c")"
		[ "$r" = "$r0" ] || { echo no; return 0; }
	done
	echo yes
}
