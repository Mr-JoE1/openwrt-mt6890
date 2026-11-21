#!/bin/sh
# Host tests for mt6890-sysupgrade. POSIX sh; no root, no network.
# Flash/UBI/reboot are mocked (tests/mock/*, argv recorded in $MOCK_LOG);
# MTD partitions are sparse-ish files under a scratch /dev.
# TEST_SHELL: shell used to run the scripts under test (default dash, else sh).
# UCI: a host uci is built once from the OpenWrt uci source + host libubox
# (or set MT6890_TEST_UCI=/path/to/uci).

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PKG="$(cd "$HERE/.." && pwd)"
TOP="${OPENWRT_TOP:-$(cd "$PKG/../.." && pwd)}"
F="$PKG/files"

if [ -z "${TEST_SHELL:-}" ]; then
	command -v dash >/dev/null 2>&1 && TEST_SHELL=dash || TEST_SHELL=sh
fi

T="$(mktemp -d "${TMPDIR:-/tmp}/mt6890-sysupgrade-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT INT TERM

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); echo "  [PASS] $*"; }
bad()  { FAIL=$((FAIL + 1)); echo "  [FAIL] $*"; }
check() { # <desc> <cmd...>
	local d="$1"; shift
	if "$@"; then ok "$d"; else bad "$d"; fi
}
has()  { grep -q -- "$2" "$1"; }   # file pattern
hasnt() { ! grep -q -- "$2" "$1"; }
eq()   { [ "$1" = "$2" ] || { echo "      got '$1' want '$2'"; return 1; }; }

ES=262144
mkdir -p "$T/bin" "$T/sys" "$T/img"
for m in "$HERE"/mock/*; do cp "$m" "$T/bin/"; done
chmod +x "$T/bin/"*

export MOCK_LOG="$T/argv.log"
export MT6890_PROC_MTD="$T/proc_mtd"
export MT6890_CMDLINE="$T/cmdline"
export MT6890_SYSUBI="$T/sys"
export MT6890_INTENT="$T/intent"
export MT6890_MNT="$T/newroot"
export MT6890_LIB="$F/lib/upgrade/mt6890-bootctl.sh"
export MT6890_DDNAND="$T/bin/dd-nand"
export MT6890_ARMED_FLAG="$T/armed"
export PATH="$T/bin:$PATH"

ff() { tr '\000' '\377' < /dev/zero | head -c "$1"; }

# --- fake flash ---------------------------------------------------------
# small rootfs slots (4 MiB) for writes; check_image of the real 64 MiB
# image uses a separate /proc/mtd with the real slot size.
mkproc() { # <rootfs size hex>
	cat > "$MT6890_PROC_MTD" <<-EOF
	dev:    size   erasesize  name
	mtd0: 00080000 00040000 "preloader"
	mtd2: 00100000 00040000 "proinfo"
	mtd3: 00100000 00040000 "misc"
	mtd4: 00100000 00040000 "para"
	mtd10: 00100000 00040000 "mcf1_a"
	mtd11: 00100000 00040000 "mcf2_a"
	mtd12: 00100000 00040000 "mcf1_b"
	mtd13: 00100000 00040000 "mcf2_b"
	mtd29: $1 00040000 "rootfs_a"
	mtd42: $1 00040000 "rootfs_b"
	EOF
}

# misc record: magic + 4x00 + 8 payload bytes (hex) in 4 copies
mkmisc() { # <16 hex payload> [magic]
	local p="$1" mg="${2:-00414230}" c fmt="" h
	h="${mg}00000000$p"
	while [ -n "$h" ]; do fmt="$fmt$(printf '\\%03o' "0x$(echo "$h" | cut -c1-2)")"; h="$(echo "$h" | cut -c3-)"; done
	ff 1048576 > "$T/dev/mtd3"
	for c in 0 1 2 3; do
		# shellcheck disable=SC2059
		printf "$fmt" | dd of="$T/dev/mtd3" bs=1 seek=$((c * ES + 2048)) conv=notrunc 2>/dev/null
	done
}
misc_payload() { # [copy]
	dd if="$T/dev/mtd3" bs=1 skip=$((${1:-0} * ES + 2056)) count=8 2>/dev/null | hexdump -v -e '1/1 "%02x"'
}

reset_flash() { # <payload> <cmdline>
	rm -rf "$T/dev" "$T/sys" "$MT6890_INTENT" "$MOCK_LOG" "$T/newroot"
	mkdir -p "$T/dev" "$T/sys"
	export MT6890_DEVDIR="$T/dev"
	export MOCK_DEV="$T/dev"
	mkproc 00400000
	mkmisc "$1"
	ff 4194304 > "$T/dev/mtd29"
	ff 4194304 > "$T/dev/mtd42"
	echo "$2" > "$MT6890_CMDLINE"
	: > "$MOCK_LOG"
}

# fake factory-rootfs UBI image: PEB0+1 = EC hdr + volume names, 3 PEBs of
# data, then 0xff padding (like mt6890-pad-ff) -> 8 PEBs = 2 MiB
mkubi() { # <out> <npebs>
	local i
	: > "$1"
	for i in 0 1; do
		{ printf 'UBI#'; ff 2044; printf 'rootfs\000'; ff 1000; printf 'rootfs_data\000'; ff $((ES - 2044 - 4 - 7 - 1000 - 12)); } >> "$1"
	done
	for i in 2 3 4; do { printf 'UBI#DATA%s' "$i"; ff $((ES - 9)); } >> "$1"; done
	i=5; while [ "$i" -lt "$2" ]; do ff "$ES" >> "$1"; i=$((i + 1)); done
}
mkubi "$T/img/factory.bin" 8
cp "$T/img/factory.bin" "$T/img/rootfs.squashfs"
printf 'SIG' > "$T/img/root_ro.sig"
(cd "$T/img" && tar -czf "$T/img/stock.tar.gz" root_ro.sig rootfs.squashfs)
printf 'BOOT' > "$T/img/boot.img"
(cd "$T/img" && tar -czf "$T/img/stock-full.tar.gz" boot.img rootfs.squashfs)
mkdir -p "$T/img/raw"; printf 'hsqs-not-ubi' > "$T/img/raw/rootfs.squashfs"
(cd "$T/img/raw" && tar -czf "$T/img/stock-squashfs.tar.gz" rootfs.squashfs)
head -c 100000 /dev/urandom > "$T/img/random.bin"
{ printf 'UBI#'; ff $((ES - 4)); printf 'UBI#'; ff $((ES - 4)); } > "$T/img/ubi-badpeb.bin"
{ printf 'UBI#'; ff $((ES - 4)); ff "$ES"; } > "$T/img/ubi-nopeb1.bin"
{ printf 'UBI#'; ff 100; } > "$T/img/ubi-unaligned.bin"
mkubi "$T/img/ubi-big.bin" 20
printf 'config sysupgrade backup\n' | gzip > "$T/sysupgrade.tgz"

# run platform functions in TEST_SHELL
P() { # <env assignments ...> -- <shell code>
	$TEST_SHELL -c ". '$F/lib/upgrade/platform.sh'; $*"
}
Pq() { P "$@" >/dev/null 2>&1; }
BC() { $TEST_SHELL "$F/usr/bin/mt6890-bootctl" "$@"; }

A_ACT=0f0001000e000100   # A prio 0f, A success 01; B prio 0e
B_ACT=0e0001000f000102   # B active, B uptype 02 (must be preserved)

echo "== shell under test: $TEST_SHELL"
echo "== platform_check_image"
reset_flash "$A_ACT" ""
check "accepts factory UBI image" Pq "platform_check_image '$T/img/factory.bin'"
check "accepts stock sysupgrade tar (root_ro.sig + rootfs.squashfs[UBI])" Pq "platform_check_image '$T/img/stock.tar.gz'"
out="$(P "platform_check_image '$T/img/stock-full.tar.gz'")"; rc=$?
check "rejects stock tar with boot.img (rootfs-only platform)" [ $rc -ne 0 ]
check "  reason names boot.img" eq "$(echo "$out" | grep -c 'non-rootfs images (boot.img)')" 1
out="$(P "platform_check_image '$T/img/stock-squashfs.tar.gz'")"; rc=$?
check "rejects stock tar whose rootfs member is not UBI" [ $rc -ne 0 ]
check "  reason: not a UBI image" has /dev/stdin "not a UBI image" <<-EOF
$out
EOF
out="$(P "platform_check_image '$T/img/random.bin'")"; rc=$?
check "rejects random file" [ $rc -ne 0 ]
check "  reason: unknown format" eq "$(echo "$out" | grep -c 'unknown format')" 1
out="$(P "platform_check_image '$T/img/ubi-badpeb.bin'")"; rc=$?
check "rejects UBI without volume table names" [ $rc -ne 0 ]
check "  reason: volume table" eq "$(echo "$out" | grep -c 'lacks rootfs/rootfs_data')" 1
out="$(P "platform_check_image '$T/img/ubi-nopeb1.bin'")"; rc=$?
check "rejects UBI without EC header at PEB 1 (PEB size mismatch)" [ $rc -ne 0 ]
check "  reason: PEB size" eq "$(echo "$out" | grep -c 'PEB size mismatch')" 1
out="$(P "platform_check_image '$T/img/ubi-unaligned.bin'")"; rc=$?
check "rejects UBI not eraseblock-aligned" [ $rc -ne 0 ]
out="$(P "platform_check_image '$T/img/ubi-big.bin'")"; rc=$?
check "rejects UBI larger than the slot" [ $rc -ne 0 ]
check "  reason: size" eq "$(echo "$out" | grep -c 'rootfs slot holds 4194304')" 1
REAL="$(ls "$TOP"/bin/targets/mt6890/*/*-squashfs-factory-rootfs.bin 2>/dev/null | head -n1)"
if [ -n "$REAL" ]; then
	mkproc 04000000
	check "accepts the real built factory-rootfs.bin (64 MiB slot)" Pq "platform_check_image '$REAL'"
	mkproc 00400000
else
	echo "  [SKIP] real factory-rootfs.bin not built"
fi

echo "== slot selection (platform_pre_upgrade)"
reset_flash "$A_ACT" "console=ttyS0 root=/dev/ubiblock0_0 ubi.mtd=29"
P "platform_pre_upgrade '$T/img/factory.bin'" 2>/dev/null
check "A running (cmdline ubi.mtd=29) -> target b" eq "$(sed -n 's/^target=//p' "$MT6890_INTENT")" b
check "  part rootfs_b = mtd42" eq "$(sed -n 's/^part=//p;s/^mtd=/mtd/p' "$MT6890_INTENT" | tr '\n' ' ')" "rootfs_b mtd42 "
reset_flash "$B_ACT" "root=/dev/ubiblock0_0 ubi.mtd=42"
P "platform_pre_upgrade '$T/img/factory.bin'" 2>/dev/null
check "B running (cmdline ubi.mtd=42) -> target a (rootfs_a mtd29)" eq "$(sed -n 's/^target=//p;s/^mtd=//p' "$MT6890_INTENT" | tr '\n' ' ')" "a 29 "
reset_flash "$A_ACT" "ubi.mtd=rootfs_a"
P "platform_pre_upgrade '$T/img/factory.bin'" 2>/dev/null
check "cmdline ubi.mtd=<name> form -> target b" eq "$(sed -n 's/^target=//p' "$MT6890_INTENT")" b
reset_flash "$B_ACT" "console=ttyS0"
P "platform_pre_upgrade '$T/img/factory.bin'" 2>/dev/null
check "no ubi.mtd=, misc B active -> target a (source misc)" eq "$(sed -n 's/^target=//p;s/^source=//p' "$MT6890_INTENT" | tr '\n' ' ')" "a misc "
reset_flash "$A_ACT" "console=ttyS0"
P "platform_pre_upgrade '$T/img/factory.bin'" 2>/dev/null
check "no ubi.mtd=, misc A active -> target b" eq "$(sed -n 's/^target=//p' "$MT6890_INTENT")" b
reset_flash "$B_ACT" "ubi.mtd=29"
P "platform_pre_upgrade '$T/img/factory.bin'" 2>"$T/err"
check "misc says B but running A (fallback) -> target b, warns" eq "$(sed -n 's/^target=//p' "$MT6890_INTENT")$(grep -c WARNING "$T/err")" b1
reset_flash 0f0001000f000100 ""
P "platform_pre_upgrade '$T/img/factory.bin'" 2>/dev/null; rc=$?
check "equal priorities + no cmdline -> refused, no intent" [ $rc -ne 0 ] && [ ! -f "$MT6890_INTENT" ]
reset_flash "$A_ACT" "ubi.mtd=29"; mkmisc "$A_ACT" deadbeef
P "platform_pre_upgrade '$T/img/factory.bin'" 2>/dev/null; rc=$?
check "bad misc magic -> refused" [ $rc -ne 0 ] && [ ! -f "$MT6890_INTENT" ]

echo "== platform_do_upgrade (factory UBI, A running)"
reset_flash "$A_ACT" "ubi.mtd=29"
P "platform_pre_upgrade '$T/img/factory.bin'" 2>/dev/null
UPGRADE_BACKUP="$T/sysupgrade.tgz" P "platform_do_upgrade '$T/img/factory.bin'" >"$T/out" 2>&1; rc=$?
check "do_upgrade rc 0" [ $rc -eq 0 ] || cat "$T/out"
check "mtd erase rootfs_b" has "$MOCK_LOG" "^mtd erase rootfs_b\$"
check "mtd write - rootfs_b" has "$MOCK_LOG" "^mtd write - rootfs_b\$"
check "never touches rootfs_a" hasnt "$MOCK_LOG" "rootfs_a"
check "only the 5 used PEBs written (0xff tail skipped)" eq "$(grep -c 'eraseblocks used' "$T/out")$(grep -o '(5 of 8' "$T/out")" "1(5 of 8"
check "rootfs_b holds the image" cmp -s -n 2097152 "$T/img/factory.bin" "$T/dev/mtd42"
check "ubiattach -m 42 for verification" has "$MOCK_LOG" "^ubiattach -m 42 "
check "config backup stored in new rootfs_data" cmp -s "$T/sysupgrade.tgz" "$T/dev/fs/sysupgrade.tgz"
check "ubidetach after verify" has "$MOCK_LOG" "^ubidetach -d "
check "dd-nand called for 4 copies (seek 2056/264200/526344/788488)" eq "$(grep -c '^dd-nand of=.*/mtd3 seek=\(2056\|264200\|526344\|788488\) bs=1 count=8$' "$MOCK_LOG")" 4
check "misc write comes after the rootfs write" eq "$(grep -n '' "$MOCK_LOG" | sed -n 's/^\([0-9]*\):mtd write.*/\1/p;s/^\([0-9]*\):dd-nand.*/\1/p' | head -n2 | tr '\n' ' ' | awk '{print ($1 < $2)}')" 1
check "misc payload: A 0e, B 0f/03/00, uptypes kept" eq "$(misc_payload 0)" 0e0001000f030000
check "all 4 misc copies identical" eq "$(misc_payload 1)$(misc_payload 2)$(misc_payload 3)" 0e0001000f0300000e0001000f0300000e0001000f030000
check "intent records switched=b" has "$MT6890_INTENT" "^switched=b\$"
: > "$MOCK_LOG"
UPGRADE_BACKUP="$T/sysupgrade.tgz" P "platform_copy_config" >/dev/null 2>&1
check "copy_config afterwards is a no-op (config already saved)" eq "$(wc -l < "$MOCK_LOG" | tr -d ' ')" 0
check "do_stage2 reboot is not called by platform code" hasnt "$MOCK_LOG" "^reboot"

echo "== platform_do_upgrade (stock tar, B running)"
reset_flash "$B_ACT" "ubi.mtd=42"
P "platform_pre_upgrade '$T/img/stock.tar.gz'" 2>/dev/null
P "platform_do_upgrade '$T/img/stock.tar.gz'" >"$T/out" 2>&1; rc=$?
check "do_upgrade rc 0" [ $rc -eq 0 ] || cat "$T/out"
check "mtd erase + write rootfs_a" eq "$(grep -c '^mtd \(erase rootfs_a\|write - rootfs_a\)$' "$MOCK_LOG")" 2
check "rootfs_a holds the stock rootfs member" cmp -s -n 2097152 "$T/img/rootfs.squashfs" "$T/dev/mtd29"
check "misc payload: A 0f/03/00, B 0e, B uptype 02 kept" eq "$(misc_payload 0)" 0f0300000e000102

echo "== refusals / failure paths"
reset_flash "$A_ACT" "ubi.mtd=29"
P "platform_do_upgrade '$T/img/factory.bin'" >/dev/null 2>&1; rc=$?
check "do_upgrade without pre_upgrade intent -> refused, nothing written" [ $rc -ne 0 ] && hasnt "$MOCK_LOG" "^mtd\|^dd-nand"
reset_flash "$A_ACT" "ubi.mtd=29"
P "platform_pre_upgrade '$T/img/factory.bin'" 2>/dev/null
sed -i 's/^target=b/target=a/;s/^part=rootfs_b/part=rootfs_a/;s/^mtd=42/mtd=29/' "$MT6890_INTENT"
P "platform_do_upgrade '$T/img/factory.bin'" >/dev/null 2>&1; rc=$?
check "intent pointing at the running slot -> refused" [ $rc -ne 0 ] && hasnt "$MOCK_LOG" "^mtd"
reset_flash "$A_ACT" "ubi.mtd=29"
P "platform_pre_upgrade '$T/img/factory.bin'" 2>/dev/null
MT6890_DDNAND="$T/none" PATH="$T/bin:/usr/bin:/bin" P "MT6890_DDNAND='$T/none'; mt6890_ddnand() { return 1; }; platform_do_upgrade '$T/img/factory.bin'" >/dev/null 2>&1; rc=$?
check "dd-nand missing -> refused before any write" [ $rc -ne 0 ] && hasnt "$MOCK_LOG" "^mtd"
reset_flash "$A_ACT" "ubi.mtd=29"
P "platform_pre_upgrade '$T/img/factory.bin'" 2>/dev/null
P "ubiattach() { return 1; }; platform_do_upgrade '$T/img/factory.bin'" >/dev/null 2>&1; rc=$?
check "new slot fails UBI attach -> misc NOT switched" [ $rc -ne 0 ] && hasnt "$MOCK_LOG" "^dd-nand" && eq "$(misc_payload 0)" "$A_ACT"
reset_flash "$A_ACT" "ubi.mtd=29"
P "platform_pre_upgrade '$T/img/factory.bin'" 2>/dev/null
MOCK_DDNAND_FAIL=1 P "platform_do_upgrade '$T/img/factory.bin'" >/dev/null 2>&1; rc=$?
check "dd-nand write failure -> readback mismatch, rc != 0" [ $rc -ne 0 ]
reset_flash "$A_ACT" "ubi.mtd=29"
P "platform_pre_upgrade '$T/img/factory.bin'" 2>/dev/null
cp "$T/dev/mtd42" "$T/before42"
MT6890_DRYRUN=1 P "platform_do_upgrade '$T/img/factory.bin'" >"$T/out" 2>&1; rc=$?
check "dry run: rc 0, prints plan" [ $rc -eq 0 ] && has "$T/out" "DRYRUN: mtd erase rootfs_b" && has "$T/out" "DRYRUN: would write 0e0001000f030000"
check "dry run: no mock call, flash + misc unchanged" eq "$(wc -l < "$MOCK_LOG" | tr -d ' ')$(cmp -s "$T/before42" "$T/dev/mtd42" && echo same)$(misc_payload 0)" "0same$A_ACT"
reset_flash "$A_ACT" "ubi.mtd=29"
P "platform_pre_upgrade '$T/img/factory.bin'; platform_do_upgrade '$T/img/factory.bin'" >/dev/null 2>&1
P "platform_pre_upgrade '$T/img/factory.bin'" 2>/dev/null
check "idempotent: re-run pre_upgrade while still on A -> target b again" eq "$(sed -n 's/^target=//p' "$MT6890_INTENT")" b
: > "$MOCK_LOG"
P "platform_do_upgrade '$T/img/factory.bin'" >/dev/null 2>&1; rc=$?
check "  second do_upgrade rc 0, misc already b -> no dd-nand write" [ $rc -eq 0 ] && hasnt "$MOCK_LOG" "^dd-nand" && eq "$(misc_payload 0)" 0e0001000f030000

echo "== mt6890-bootctl"
reset_flash "$A_ACT" "ubi.mtd=29"
BC status > "$T/st"
check "status: active=a reserved=b booted=a" eq "$(grep '^active=\|^reserved=\|^booted=' "$T/st" | tr '\n' ' ')" "active=a reserved=b booted=a "
check "status: source misc mtd3 +2048" has "$T/st" "^source=misc:$T/dev/mtd3+2048\$"
check "status: copies consistent" has "$T/st" "^copies_consistent=yes\$"
BC set b >/dev/null 2>&1
check "set b -> status active=b" eq "$(BC status | sed -n 's/^active=//p')" b
check "set b -> b_tries=03 b_success=00" has /dev/stdin "b_prio=0f b_tries=03 b_success=00" <<-EOF
$(BC status)
EOF
: > "$MOCK_LOG"
BC set b >/dev/null 2>&1
check "set b again -> no write (idempotent)" hasnt "$MOCK_LOG" "^dd-nand"
BC set a >/dev/null 2>&1
check "set a -> active=a (round trip)" eq "$(BC status | sed -n 's/^active=//p')" a
out="$(BC rollback 2>/dev/null)"
check "rollback while booted from A -> next boot b" eq "$(BC status | sed -n 's/^active=//p')" b
check "  rollback prints reboot hint, does not reboot" [ -n "$(echo "$out" | grep 'reboot to apply')" ] && hasnt "$MOCK_LOG" "^reboot"
echo "ubi.mtd=42" > "$MT6890_CMDLINE"
BC rollback >/dev/null 2>&1
check "rollback while booted from B -> next boot a" eq "$(BC status | sed -n 's/^active=//p')" a
cp "$T/dev/mtd3" "$T/m3"
MT6890_DRYRUN=1 BC set b >/dev/null 2>&1
check "MT6890_DRYRUN=1 set b -> misc unchanged" cmp -s "$T/m3" "$T/dev/mtd3"
BC set c >/dev/null 2>&1; rc=$?
check "set c -> usage error" [ $rc -ne 0 ]
mkmisc "$A_ACT" ffffffff
BC status >/dev/null 2>&1; rc=$?
check "status on erased misc (no magic) -> rc != 0" [ $rc -ne 0 ]
reset_flash "$A_ACT" "ubi.mtd=29"
dd if=/dev/zero of="$T/dev/mtd3" bs=1 seek=$((2 * ES + 2056)) count=1 conv=notrunc 2>/dev/null
check "status reports inconsistent copies" has /dev/stdin "copies_consistent=no" <<-EOF
$(BC status)
EOF
BC set b >/dev/null 2>&1
check "set b repairs all copies" eq "$(misc_payload 0)$(misc_payload 2)" 0e0001000f0300000e0001000f030000

echo "== mt6890-bootctl bootok"
A_TRY=0f0300000e050100   # A active, A tries 03, B tries 05 (must survive)
B_TRY=0e0300000f050102   # B active, B tries 05, A tries 03 (must survive)
ndiff() { cmp -l "$1" "$2" 2>/dev/null | wc -l | tr -d ' '; }
reset_flash "$A_TRY" "console=ttyS0 ubi.mtd=29"
cp "$T/dev/mtd3" "$T/m3"
BC bootok >"$T/out" 2>&1; rc=$?
check "bootok from A: rc 0" [ $rc -eq 0 ] || cat "$T/out"
check "  A tries 03->00, A prio/success/uptype and all of B kept (4 copies)" eq "$(misc_payload 0)$(misc_payload 1)$(misc_payload 2)$(misc_payload 3)" 0f0000000e0501000f0000000e0501000f0000000e0501000f0000000e050100
check "  exactly 4 bytes changed in misc (one per copy)" eq "$(ndiff "$T/m3" "$T/dev/mtd3")" 4
check "  dd-nand: 1 byte x4 at A tries (seek 2057/264201/526345/788489)" eq "$(grep -c '^dd-nand of=.*/mtd3 seek=\(2057\|264201\|526345\|788489\) bs=1 count=1$' "$MOCK_LOG")$(wc -l < "$MOCK_LOG" | tr -d ' ')" 44
check "  stdout says slot a" has "$T/out" "^bootok: slot a tries=00\$"
: > "$MOCK_LOG"
BC bootok >/dev/null 2>&1; rc=$?
check "bootok again: rc 0, idempotent (no dd-nand)" [ $rc -eq 0 ] && hasnt "$MOCK_LOG" "^dd-nand"
reset_flash "$B_TRY" "root=/dev/ubiblock0_0 ubi.mtd=42"
cp "$T/dev/mtd3" "$T/m3"
BC bootok >/dev/null 2>&1; rc=$?
check "bootok from B: rc 0" [ $rc -eq 0 ]
check "  B tries 05->00, B prio/success/uptype and all of A kept (4 copies)" eq "$(misc_payload 0)$(misc_payload 1)$(misc_payload 2)$(misc_payload 3)" 0e0300000f0001020e0300000f0001020e0300000f0001020e0300000f000102
check "  exactly 4 bytes changed in misc" eq "$(ndiff "$T/m3" "$T/dev/mtd3")" 4
check "  dd-nand: 1 byte x4 at B tries (seek 2061/264205/526349/788493)" eq "$(grep -c '^dd-nand of=.*/mtd3 seek=\(2061\|264205\|526349\|788493\) bs=1 count=1$' "$MOCK_LOG")$(wc -l < "$MOCK_LOG" | tr -d ' ')" 44
reset_flash "$B_TRY" "ubi.mtd=rootfs_a"
BC bootok >/dev/null 2>&1
check "booted A while misc says B (fallback): only A's tries cleared" eq "$(misc_payload 0)" 0e0000000f050102
reset_flash "$A_TRY" "ubi.mtd=29"
dd if=/dev/zero of="$T/dev/mtd3" bs=1 seek=$((2 * ES + 2057)) count=1 conv=notrunc 2>/dev/null
dd if=/dev/zero of="$T/dev/mtd3" bs=1 seek=$((1 * ES + 2060)) count=1 conv=notrunc 2>/dev/null
BC bootok >/dev/null 2>&1; rc=$?
check "bootok with one copy already 00 and another differing: all copies repaired" [ $rc -eq 0 ] && eq "$(misc_payload 0)$(misc_payload 2)" 0f0000000e0501000f0000000e050100
check "  copy 1 (B prio was 00) keeps its own bytes, only +9 written" eq "$(misc_payload 1)" 0f00000000050100
reset_flash "$A_TRY" "console=ttyS0"
cp "$T/dev/mtd3" "$T/m3"
BC bootok >/dev/null 2>&1; rc=$?
check "running slot unknown (no ubi.mtd=) -> rc != 0, misc untouched" [ $rc -ne 0 ] && cmp -s "$T/m3" "$T/dev/mtd3" && hasnt "$MOCK_LOG" "^dd-nand"
reset_flash "$A_TRY" "ubi.mtd=29"
cp "$T/dev/mtd3" "$T/m3"
MT6890_DRYRUN=1 BC bootok >"$T/out" 2>&1; rc=$?
check "MT6890_DRYRUN=1 bootok -> rc 0, misc unchanged, no dd-nand" [ $rc -eq 0 ] && cmp -s "$T/m3" "$T/dev/mtd3" && hasnt "$MOCK_LOG" "^dd-nand" && has "$T/out" "DRYRUN: would write 00"
MOCK_DDNAND_FAIL=1 BC bootok >/dev/null 2>&1; rc=$?
check "dd-nand failure -> readback mismatch, rc != 0" [ $rc -ne 0 ]
reset_flash "$A_TRY" "ubi.mtd=29"; mkmisc "$A_TRY" deadbeef
cp "$T/dev/mtd3" "$T/m3"
BC bootok >/dev/null 2>&1; rc=$?
check "bad magic -> rc != 0, misc untouched" [ $rc -ne 0 ] && cmp -s "$T/m3" "$T/dev/mtd3" && hasnt "$MOCK_LOG" "^dd-nand"

echo "== init script mt6890-bootok"
INIT="$F/etc/init.d/mt6890-bootok"
check "init script is executable in the source tree" [ -x "$INIT" ]
check "init script has rc.common shebang + START=96 (after S95 done)" eq "$(head -n1 "$INIT")$(sed -n 's/^START=//p' "$INIT")" "#!/bin/sh /etc/rc.common96"
reset_flash "$A_TRY" "ubi.mtd=29"
# rc.common is not on the host: source the script (defs only) and call start
I() { MT6890_BOOTCTL="$F/usr/bin/mt6890-bootctl" $TEST_SHELL -c ". '$INIT'; $*"; }
I "start; wait" >/dev/null 2>&1; rc=$?
check "start (A running): rc 0, returns, tries cleared" [ $rc -eq 0 ] && eq "$(misc_payload 0)" 0f0000000e050100
check "  logged via logger tag mt6890-bootok" has "$MOCK_LOG" "bootok: slot a tries=00"
: > "$MOCK_LOG"
I "start; wait" >/dev/null 2>&1; rc=$?
check "start again: rc 0, idempotent (no dd-nand)" [ $rc -eq 0 ] && hasnt "$MOCK_LOG" "^dd-nand"
reset_flash "$B_TRY" "ubi.mtd=42"
I "start; wait" >/dev/null 2>&1
check "start (B running): only B tries cleared" eq "$(misc_payload 0)" 0e0300000f000102
reset_flash "$A_TRY" "ubi.mtd=29"
rm -f "$T/dev/mtd3"
I "start; wait" >/dev/null 2>&1; rc=$?
check "misc device node unreadable: rc 0, logged, nothing written" [ $rc -eq 0 ] && has "$MOCK_LOG" "^logger -t mt6890-bootok bootok skipped" && hasnt "$MOCK_LOG" "^dd-nand"
reset_flash "$A_TRY" "ubi.mtd=29"
grep -v '"misc"' "$MT6890_PROC_MTD" > "$T/p" && cp "$T/p" "$MT6890_PROC_MTD"
cp "$T/dev/mtd3" "$T/m3"
I "start; wait" >/dev/null 2>&1; rc=$?
check "no misc partition in /proc/mtd: rc 0, logged, nothing written" [ $rc -eq 0 ] && has "$MOCK_LOG" "^logger -t mt6890-bootok bootok skipped" && cmp -s "$T/m3" "$T/dev/mtd3"
reset_flash "$A_TRY" "ubi.mtd=29"; mkmisc "$A_TRY" ffffffff
I "start; wait" >/dev/null 2>&1; rc=$?
check "erased misc (no magic): rc 0, logged, nothing written" [ $rc -eq 0 ] && has "$MOCK_LOG" "^logger -t mt6890-bootok bootok skipped" && hasnt "$MOCK_LOG" "^dd-nand"
reset_flash "$A_TRY" "ubi.mtd=29"
rm -f "$MT6890_PROC_MTD" "$MT6890_CMDLINE"
I "start; wait" >/dev/null 2>&1; rc=$?
check "no /proc/mtd and no cmdline: rc 0, nothing written" [ $rc -eq 0 ] && hasnt "$MOCK_LOG" "^dd-nand"
reset_flash "$A_TRY" "ubi.mtd=29"
MT6890_BOOTCTL="$T/missing" $TEST_SHELL -c ". '$INIT'; start; wait" >/dev/null 2>&1; rc=$?
check "mt6890-bootctl missing: rc 0, logged" [ $rc -eq 0 ] && has "$MOCK_LOG" "not found - tries not reset"
reset_flash "$A_TRY" "ubi.mtd=29"
MOCK_DDNAND_FAIL=1 I "start; wait" >/dev/null 2>&1; rc=$?
check "dd-nand write failure: init still rc 0" [ $rc -eq 0 ]
reset_flash "$A_TRY" "ubi.mtd=29"
printf '#!/bin/sh\nsleep 3\n' > "$T/slow"; chmod +x "$T/slow"
s0=$(date +%s)
MT6890_BOOTCTL="$T/slow" $TEST_SHELL -c ". '$INIT'; start" >/dev/null 2>&1
s1=$(date +%s)
check "start returns immediately (does not block boot on a slow bootctl)" [ $((s1 - s0)) -lt 2 ]

echo "== armed first boot (MT6890_ARMED_FLAG)"
# the "start returns immediately" case above leaves a detached job (sleep 3,
# then logger -> $MOCK_LOG); let it finish so it cannot pollute argv counts
while [ "$(date +%s)" -lt $((s0 + 5)) ]; do sleep 1; done
check "package ships files/etc/mt6890-armed (empty)" [ -f "$F/etc/mt6890-armed" ] && [ ! -s "$F/etc/mt6890-armed" ]
check "Makefile installs /etc/mt6890-armed" grep -q '^	$(INSTALL_DATA) ./files/etc/mt6890-armed $(1)/etc/$' "$PKG/Makefile"
check "uci-defaults never removes the armed flag" hasnt "$F/etc/uci-defaults/95-mt6890-uci-migrate" "mt6890-armed"
reset_flash "$A_TRY" "ubi.mtd=29"; : > "$MT6890_ARMED_FLAG"
cp "$T/dev/mtd3" "$T/m3"
I "start; wait" >/dev/null 2>&1; rc=$?
check "start with flag present (A running, tries 03): rc 0, misc unchanged, no dd-nand" [ $rc -eq 0 ] && cmp -s "$T/m3" "$T/dev/mtd3" && hasnt "$MOCK_LOG" "^dd-nand"
check "  logger line says armed, tries NOT reset" has "$MOCK_LOG" "^logger -t mt6890-bootok armed: tries NOT reset (run 'mt6890-bootctl confirm'"
check "  flag still present after boot" [ -e "$MT6890_ARMED_FLAG" ]
reset_flash "$A_TRY" "ubi.mtd=29"; rm -f "$MT6890_ARMED_FLAG"
I "start; wait" >/dev/null 2>&1; rc=$?
check "start with flag absent: tries cleared as before, no armed log" [ $rc -eq 0 ] && eq "$(misc_payload 0)" 0f0000000e050100 && hasnt "$MOCK_LOG" "armed"
reset_flash "$A_TRY" "console=ttyS0 ubi.mtd=29"; : > "$MT6890_ARMED_FLAG"
cp "$T/dev/mtd3" "$T/m3"
BC confirm >"$T/out" 2>"$T/err"; rc=$?
check "confirm (flag present, A running): rc 0" [ $rc -eq 0 ] || cat "$T/out" "$T/err"
check "  A tries 03->00 only, B tries 05 kept (4 copies)" eq "$(misc_payload 0)$(misc_payload 1)$(misc_payload 2)$(misc_payload 3)" 0f0000000e0501000f0000000e0501000f0000000e0501000f0000000e050100
check "  exactly 4 bytes changed in misc" eq "$(ndiff "$T/m3" "$T/dev/mtd3")" 4
check "  dd-nand: 1 byte x4 at 2057/264201/526345/788489, nothing else" eq "$(grep -c '^dd-nand of=.*/mtd3 seek=\(2057\|264201\|526345\|788489\) bs=1 count=1$' "$MOCK_LOG")$(wc -l < "$MOCK_LOG" | tr -d ' ')" 44
check "  flag file removed" [ ! -e "$MT6890_ARMED_FLAG" ]
check "  stdout: confirmed: slot a tries=00" has "$T/out" "^confirmed: slot a tries=00, fallback disarmed\$"
reset_flash "$A_TRY" "ubi.mtd=29"; : > "$MT6890_ARMED_FLAG"
MOCK_DDNAND_FAIL=1 BC confirm >/dev/null 2>&1; rc=$?
check "confirm with dd-nand failing: rc != 0, flag still present" [ $rc -ne 0 ] && [ -e "$MT6890_ARMED_FLAG" ]
reset_flash "$A_TRY" "console=ttyS0"; : > "$MT6890_ARMED_FLAG"
cp "$T/dev/mtd3" "$T/m3"
BC confirm >/dev/null 2>&1; rc=$?
check "confirm with running slot unknown: rc != 0, flag kept, misc untouched" [ $rc -ne 0 ] && [ -e "$MT6890_ARMED_FLAG" ] && cmp -s "$T/m3" "$T/dev/mtd3" && hasnt "$MOCK_LOG" "^dd-nand"
reset_flash "$A_TRY" "ubi.mtd=29"; : > "$MT6890_ARMED_FLAG"
cp "$T/dev/mtd3" "$T/m3"
MT6890_DRYRUN=1 BC confirm >/dev/null 2>&1; rc=$?
check "MT6890_DRYRUN=1 confirm: rc 0, misc unchanged, flag kept" [ $rc -eq 0 ] && cmp -s "$T/m3" "$T/dev/mtd3" && [ -e "$MT6890_ARMED_FLAG" ]
reset_flash "$A_TRY" "ubi.mtd=29"; rm -f "$MT6890_ARMED_FLAG"
check "status without flag: armed=no" has /dev/stdin "^armed=no\$" <<-EOF
$(BC status)
EOF
out="$(BC arm 2>&1)"; rc=$?
check "arm creates the flag, rc 0, prints hint" [ $rc -eq 0 ] && [ -e "$MT6890_ARMED_FLAG" ] && eq "$out" "armed: next boots will not reset tries until 'confirm'"
BC arm >/dev/null 2>&1; rc=$?
check "arm again: idempotent rc 0, flag present, no misc write" [ $rc -eq 0 ] && [ -e "$MT6890_ARMED_FLAG" ] && hasnt "$MOCK_LOG" "^dd-nand"
check "status after arm: armed=yes" has /dev/stdin "^armed=yes\$" <<-EOF
$(BC status)
EOF
BC confirm >/dev/null 2>&1
check "status after confirm: armed=no" has /dev/stdin "^armed=no\$" <<-EOF
$(BC status)
EOF

echo "== UCI migration (95-mt6890-uci-migrate)"
UCI_BIN="${MT6890_TEST_UCI:-}"
if [ -z "$UCI_BIN" ]; then
	S="$(ls -d "$TOP"/build_dir/target-*/uci-*/ 2>/dev/null | head -n1)"
	H="$TOP/staging_dir/host"
	if [ -n "$S" ] && [ -f "$H/lib/libubox.a" ] && command -v gcc >/dev/null 2>&1; then
		gcc -O1 -w -I"$H/include" -I"$S" -o "$T/uci" "$S/cli.c" "$S/libuci.c" "$S/file.c" \
			"$S/util.c" "$S/delta.c" "$S/parse.c" "$S/blob.c" "$H/lib/libubox.a" 2>"$T/uci.err" && UCI_BIN="$T/uci"
	fi
	[ -n "$UCI_BIN" ] || UCI_BIN="$(command -v uci 2>/dev/null)"
fi
if [ -z "$UCI_BIN" ]; then
	bad "no host uci (set MT6890_TEST_UCI)"
else
	C="$T/etc/config"; R="$T/rom/etc/config"
	mkdir -p "$C" "$R"
	# vendor UI profile package name: single source of truth is the migration script
	PP="$(sed -n 's/^drop_\([A-Za-z0-9_]*\)() {.*/\1/p' "$F/etc/uci-defaults/95-mt6890-uci-migrate")"
	: > "$C/network"; : > "$C/$PP"
	# stock-shaped network + vendor UI profile fixture (structure of a stock
	# 19.07 UCI dump; carrier values replaced by placeholders)
	"$UCI_BIN" -c "$C" batch >/dev/null 2>&1 <<-EOF
	set network.loopback=interface
	set network.loopback.ifname='lo'
	set network.loopback.proto='static'
	set network.loopback.ipaddr='127.0.0.1'
	set network.loopback.netmask='255.0.0.0'
	set network.lan=interface
	set network.lan.type='bridge'
	set network.lan.ifname='eth0.1 eth0.2'
	set network.lan.proto='static'
	set network.lan.ipaddr='192.168.1.1'
	set network.lan.netmask='255.255.255.0'
	set network.lan.ip6assign='60'
	set network.wan=interface
	set network.wan.proto='ql_mipc'
	set network.wan.ifname='ccmni'
	set network.wan.mode='AUTO'
	set network.wan.pppoe_username='user'
	set network.wan.pppoe_password='pass'
	set network.wan.apn='apn1.example'
	set network.wan.plmn='00101'
	set network.wan2=interface
	set network.wan2.proto='ql_mipc'
	set network.wan2.ifname='ccmni'
	set network.wan2.apn='apn2.example'
	set network.wan2.iaapn='ia.apn2.example'
	set network.wan2.iptype='3'
	set network.wan2.vlan='2'
	set network.wan2.static_route1='198.51.100.10'
	set network.wan2.static_route2='198.51.100.11'
	set network.wan2.auto_conf='0'
	set network.clatd=interface
	set network.clatd.proto='464xlat'
	set network.clatd.tunlink='wan'
	set $PP.system=$PP
	set $PP.mobile=profile
	set $PP.wireless=profile
	set $PP.login=true
	set $PP.traffic=daemon
	set $PP.apnDefault=apnDefault
	set $PP.wps=pbc
	set $PP.parentalControl=profile
	set $PP.openVPN=vpn
	EOF
	"$UCI_BIN" -c "$C" commit
	cat > "$C/wireless" <<-'EOF'
	config wifi-iface
		option device 'ra0'
		option instance '1'
	EOF
	cp "$PKG/../mt6890-mtkwifi/files/etc/config/wireless" "$R/wireless"
	export MT6890_UCI="$UCI_BIN" MT6890_UCI_CONF="$C" MT6890_ROM_CONF="$R" MIGRATE_LOG="$T/migrate.log"
	G() { "$UCI_BIN" -c "$C" -q get "$1"; }
	check "fixture: stock wan proto ql_mipc, apn set" eq "$(G network.wan.proto) $(G network.wan.apn)" "ql_mipc apn1.example"
	$TEST_SHELL "$F/etc/uci-defaults/95-mt6890-uci-migrate"; rc=$?
	check "migration exits 0" [ $rc -eq 0 ]
	check "wan: proto ql_mipc -> mtkmipc" eq "$(G network.wan.proto)" mtkmipc
	check "wan: APN preserved" eq "$(G network.wan.apn)" apn1.example
	check "wan: plmn preserved" eq "$(G network.wan.plmn)" 00101
	check "wan: ifname ccmni and mode AUTO dropped" eq "$(G network.wan.ifname)|$(G network.wan.mode)" "|"
	check "wan2: proto mtkmipc, vlan 2 -> pdn 2" eq "$(G network.wan2.proto) $(G network.wan2.pdn) [$(G network.wan2.vlan)]" "mtkmipc 2 []"
	check "wan2: apn/iaapn/iptype/auto_conf preserved" eq "$(G network.wan2.apn) $(G network.wan2.iaapn) $(G network.wan2.iptype) $(G network.wan2.auto_conf)" "apn2.example ia.apn2.example 3 0"
	check "lan / clatd untouched" eq "$(G network.lan.proto) $(G network.clatd.proto)" "static 464xlat"
	check "vendor UI profile package dropped" [ ! -f "$C/$PP" ]
	check "log names dropped profile sections" has "$T/migrate.log" "$PP: dropped package.*apnDefault(apnDefault)"
	check "log notes unknown wan options (pppoe_*, static_route*)" has "$T/migrate.log" "network.wan2: option 'static_route1' is not used"
	check "stock wireless replaced by mt6890-mtkwifi default" cmp -s "$R/wireless" "$C/wireless"
	check "stock wireless kept aside" [ -f "$C/wireless.stock-migrated" ]
	cp "$C/network" "$T/net1"; cp "$T/migrate.log" "$T/log1"
	$TEST_SHELL "$F/etc/uci-defaults/95-mt6890-uci-migrate"
	check "second run: network unchanged (idempotent)" cmp -s "$T/net1" "$C/network"
	check "second run: wireless (mtwifi) kept" cmp -s "$R/wireless" "$C/wireless"
	echo "  --- migration log:"; sed 's/^/      /' "$T/log1"
fi

echo "== syntax"
for s in "$F/lib/upgrade/platform.sh" "$F/lib/upgrade/mt6890-bootctl.sh" "$F/usr/bin/mt6890-bootctl" "$F/etc/uci-defaults/95-mt6890-uci-migrate" "$F/etc/init.d/mt6890-bootok"; do
	check "$TEST_SHELL -n ${s#"$F"/}" $TEST_SHELL -n "$s"
done
if command -v shellcheck >/dev/null 2>&1; then
	check "shellcheck -s sh (errors only)" shellcheck -s sh -S error "$F/lib/upgrade/platform.sh" "$F/lib/upgrade/mt6890-bootctl.sh" "$F/usr/bin/mt6890-bootctl" "$F/etc/uci-defaults/95-mt6890-uci-migrate" "$F/etc/init.d/mt6890-bootok"
fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
