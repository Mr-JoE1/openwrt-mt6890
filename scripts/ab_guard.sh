#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# ab_guard.sh - refuse a staged rootfs that contains the stock A/B "sync"
# logic. Stock /etc/init.d/zmtk_boot_done calls ab_image_sync, which clones
# the running slot over the other one (zmtk_boot_done:42,81) and would
# destroy the fallback slot. PORTING-ANALYSIS.md §6.5.
#
# Exit: 0 = clean, 1 = forbidden token found, 2 = usage/input error.

set -uo pipefail

TOKENS=(ab_image_sync zmtk_boot_done)

usage() {
	cat <<EOF
Usage: $(basename "$0") [-q] <rootfs-dir | rootfs.tar[.gz|.xz|.zst]>

Scan a staged rootfs (directory or tarball) for forbidden stock A/B tokens:
  ${TOKENS[*]}
Both file contents (binary-safe) and file names are checked.

Options:
  -q, --quiet   only print offending paths
  -h, --help    this help

Exit status: 0 clean, 1 forbidden token found, 2 usage/input error.
EOF
}

QUIET=0
TARGET=""
while [ $# -gt 0 ]; do
	case "$1" in
	-h|--help) usage; exit 0 ;;
	-q|--quiet) QUIET=1; shift ;;
	--) shift; TARGET="${1:-}"; break ;;
	-*) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
	*) [ -z "$TARGET" ] || { usage >&2; exit 2; }; TARGET="$1"; shift ;;
	esac
done
[ -n "$TARGET" ] || { usage >&2; exit 2; }

TMP=""
cleanup() { [ -z "$TMP" ] || rm -rf "$TMP"; }
trap cleanup EXIT

if [ -d "$TARGET" ]; then
	DIR="$TARGET"
elif [ -f "$TARGET" ]; then
	TMP="$(mktemp -d)"
	case "$TARGET" in
	*.tar.zst|*.tzst) zstd -dc -- "$TARGET" | tar -x -C "$TMP" -f - ;;
	*) tar -x -C "$TMP" -f "$TARGET" ;;   # tar autodetects gz/xz/bz2
	esac || { echo "ab_guard: cannot extract $TARGET" >&2; exit 2; }
	DIR="$TMP"
else
	echo "ab_guard: no such file or directory: $TARGET" >&2
	exit 2
fi

found=0
pattern="$(IFS='|'; echo "${TOKENS[*]}")"

# file contents (no symlink following; -a: binaries too)
while IFS= read -r -d '' f; do
	rel="${f#"$DIR"/}"
	hits="$(grep -a -o -E -- "$pattern" "$f" 2>/dev/null | sort -u | tr '\n' ' ')"
	echo "FORBIDDEN content [${hits% }]: /$rel"
	found=1
done < <(grep -r -l -a -Z -E -- "$pattern" "$DIR" 2>/dev/null)

# file / symlink names
while IFS= read -r -d '' f; do
	echo "FORBIDDEN name: /${f#"$DIR"/}"
	found=1
done < <(find "$DIR" \( -name '*ab_image_sync*' -o -name '*zmtk_boot_done*' \) -print0)

if [ "$found" -ne 0 ]; then
	[ "$QUIET" -eq 1 ] || echo "ab_guard: REFUSED - stock A/B sync logic present in $TARGET" >&2
	exit 1
fi
[ "$QUIET" -eq 1 ] || echo "ab_guard: OK - no ${TOKENS[*]} in $TARGET"
exit 0
