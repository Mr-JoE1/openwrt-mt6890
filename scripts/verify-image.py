#!/usr/bin/env python3
"""Offline verification of the built mt6890 image artifacts (TASK-p2h).

stdlib only.  Read-only on openwrt/; scratch output goes to build/verify-*.

Checks:
  1. UBI geometry (EC/VID headers, volume table, LEB size, PEB count)
  2. squashfs reconstruction from volume 0, unsquashfs, module sha256, file
     presence, ab_guard.sh
  3. sysupgrade tar layout + CONTROL
  4. git cleanliness (openwrt/ and this repo)

NOTE on format: the real UBI on-disk format is big-endian with magics
b'UBI#' (EC, offset 0) and b'UBI!' (VID, at vid_hdr_offset).  Volume names
are stored in the layout-volume volume table (vol_id 0x7fffefff), not in
vol_id 0 data blocks.  This script parses the real format.
"""
import hashlib
import os
import shutil
import struct
import subprocess
import sys
import zlib

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TMP = os.path.join(
    REPO, "openwrt/build_dir/target-aarch64_cortex-a55_musl/linux-mt6890_vk419/tmp")
PFX = "openwrt-mt6890-vk419-dlink_dwr-2000m-a3-squashfs-"
FACTORY = os.path.join(TMP, PFX + "factory-rootfs.bin")
SYSUP = os.path.join(TMP, PFX + "sysupgrade.tar")
BUILD = os.path.join(REPO, "build")
SQ_FILE = os.path.join(BUILD, "verify-rootfs.squashfs")
ROOT_DIR = os.path.join(BUILD, "verify-rootfs")
SYSUP_DIR = os.path.join(BUILD, "verify-sysupgrade")
MOD_SRC = os.path.join(BUILD, "modules-extracted/modules/4.19.205")
MOD_DST = os.path.join(ROOT_DIR, "lib/modules/4.19.205")

PEB = 262144
IMG_SIZE = 64 * 1024 * 1024
LAYOUT_VOL = 0x7FFFEFFF
EXPECT_MODULES = 136
EXPECT_FILES = [
    "etc/inittab", "etc/board.d/01_leds", "etc/board.d/02_network",
    "etc/init.d/mt6890-links", "etc/uci-defaults/90-mt6890-defaults",
    "lib/firmware/mt7915_patch_e2_hdr.bin", "usr/lib/libubox.so",
    "usr/lib/libuci.so", "usr/bin/mipc_wan_cli", "usr/lib/libasound.so.2",
]

issues = []


def out(s=""):
    print(s, flush=True)


def check(ok, msg):
    out(("  [PASS] " if ok else "  [FAIL] ") + msg)
    if not ok:
        issues.append(msg)
    return ok


def ubi_crc(data):
    # UBI crc32: crc32_le with init 0xffffffff and no final xor
    return (zlib.crc32(data) ^ 0xFFFFFFFF) & 0xFFFFFFFF


def run(cmd, **kw):
    return subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          universal_newlines=True, **kw)


# --------------------------------------------------------------------------
def check_ubi():
    out("== 1. UBI geometry ==")
    if not check(os.path.isfile(FACTORY), "factory image exists: " + FACTORY):
        return None
    img = open(FACTORY, "rb").read()
    check(len(img) == IMG_SIZE, "image size %d == %d (64 MiB)" % (len(img), IMG_SIZE))
    npeb = len(img) // PEB
    check(npeb == 256 and len(img) % PEB == 0, "PEB count %d == 256" % npeb)

    valid = blank = ec_only = bad = 0
    vol_pebs = {}            # vol_id -> [(lnum, peb_index, data_off, data_size)]
    leb_sizes = set()
    vid_offs = set()
    data_offs = set()
    for i in range(npeb):
        p = i * PEB
        ec = img[p:p + 64]
        if ec[:4] != b"UBI#":
            if img[p:p + PEB] == b"\xff" * PEB:
                blank += 1
            else:
                bad += 1
            continue
        _, ver, _, _, vid_off, data_off = struct.unpack(">4sB3sQII", ec[:24])
        crc_ok = ubi_crc(ec[:60]) == struct.unpack(">I", ec[60:64])[0]
        if not crc_ok:
            bad += 1
            continue
        valid += 1
        vid_offs.add(vid_off)
        data_offs.add(data_off)
        leb_sizes.add(PEB - data_off)
        vh = img[p + vid_off:p + vid_off + 64]
        if vh[:4] != b"UBI!":
            ec_only += 1          # erased/free PEB: EC header only
            continue
        if ubi_crc(vh[:60]) != struct.unpack(">I", vh[60:64])[0]:
            bad += 1
            continue
        vol_type, _, _, vol_id, lnum = struct.unpack(">BBBII", vh[5:16])
        data_size = struct.unpack(">I", vh[20:24])[0]
        vol_pebs.setdefault(vol_id, []).append(
            (lnum, i, p + data_off, data_size, vol_type))

    out("  valid EC PEBs: %d (with VID: %d, free/EC-only: %d), blank(0xff): %d, corrupt: %d"
        % (valid, valid - ec_only, ec_only, blank, bad))
    check(bad == 0, "no corrupt PEBs")
    check(valid + blank == 256, "valid(%d) + blank(%d) == 256 PEBs" % (valid, blank))
    out("  vid_hdr_offset: %s, data_offset: %s"
        % (sorted(vid_offs), sorted(data_offs)))
    check(leb_sizes == {253952},
          "LEB size %s == 253952 (262144 - 4096 EC - 4096 VID)" % sorted(leb_sizes))
    out("  distinct volume IDs seen: %s"
        % ", ".join(hex(v) if v >= 0x7FFFEFFF else str(v) for v in sorted(vol_pebs)))
    for v in sorted(vol_pebs):
        out("    vol_id %s: %d PEBs (lnum 0..%d)"
            % (hex(v) if v >= 0x7FFFEFFF else v, len(vol_pebs[v]),
               max(x[0] for x in vol_pebs[v])))

    # volume table from layout volume (use the first copy that parses)
    vols = {}
    for lnum, pi, doff, dsz, _ in sorted(vol_pebs.get(LAYOUT_VOL, [])):
        data = img[doff:doff + PEB]
        for idx in range(128):
            r = data[idx * 172:(idx + 1) * 172]
            if len(r) < 172 or r[:4] == b"\0\0\0\0" and r[14:16] == b"\0\0":
                continue
            if ubi_crc(r[:168]) != struct.unpack(">I", r[168:172])[0]:
                continue
            reserved, align, pad, vtype, upd, nlen = struct.unpack(">IIIBBH", r[:16])
            if nlen == 0:
                continue
            vols[idx] = dict(name=r[16:16 + nlen].decode("ascii", "replace"),
                             reserved=reserved, type=vtype, upd=upd, align=align)
        if vols:
            break
    out("  volume table:")
    for idx, v in sorted(vols.items()):
        out("    vol %d: name=%r type=%s reserved_pebs=%d upd_marker=%d"
            % (idx, v["name"], {1: "dynamic", 2: "static"}.get(v["type"], v["type"]),
               v["reserved"], v["upd"]))
    check(vols.get(0, {}).get("name") == "rootfs", "volume 0 name == 'rootfs'")
    check(vols.get(1, {}).get("name") == "rootfs_data", "volume 1 name == 'rootfs_data'")
    check(vols.get(0, {}).get("type") == 1, "volume 0 is dynamic")
    check(vols.get(1, {}).get("type") == 1, "volume 1 is dynamic")
    out("  note: rootfs_data (UBIFS) has %d data PEBs in the image; it is created/"
        "formatted on first boot" % len(vol_pebs.get(1, [])))
    return img, vol_pebs


# --------------------------------------------------------------------------
def check_squashfs(img, vol_pebs):
    out("")
    out("== 2. Squashfs extraction + module hashes ==")
    pebs = sorted(vol_pebs.get(0, []))
    if not check(bool(pebs), "volume 0 has data PEBs (%d)" % len(pebs)):
        return
    check([x[0] for x in pebs] == list(range(len(pebs))),
          "volume 0 LEBs contiguous 0..%d" % (len(pebs) - 1))
    first = img[pebs[0][2]:pebs[0][2] + 0x30]
    if not check(first[:4] == b"hsqs", "squashfs magic 'hsqs' at first vol-0 LEB"):
        return
    used = struct.unpack("<Q", first[0x28:0x30])[0]
    # squashfs 4.0: bytes_used is u64 at 0x28; the task's u32@0x2C would be its high half
    out("  squashfs bytes_used = %d (u64 @0x28; u32 @0x2C would be %d)"
        % (used, struct.unpack("<I", first[0x2C:0x30])[0]))
    buf = bytearray()
    for lnum, pi, doff, dsz, _ in pebs:
        buf += img[doff:doff + (PEB - (doff - pi * PEB))]
        if len(buf) >= used:
            break
    check(len(buf) >= used, "reconstructed %d bytes >= bytes_used %d" % (len(buf), used))
    # keep the full LEB-padded tail trimmed to bytes_used
    os.makedirs(BUILD, exist_ok=True)
    with open(SQ_FILE, "wb") as fh:
        fh.write(bytes(buf[:used]))
    out("  wrote %s (%d bytes)" % (os.path.relpath(SQ_FILE, REPO), used))

    if os.path.isdir(ROOT_DIR):
        shutil.rmtree(ROOT_DIR)
    r = run(["unsquashfs", "-f", "-d", ROOT_DIR, SQ_FILE])
    tail = r.stdout.strip().splitlines()[-3:]
    out("  unsquashfs rc=%d: %s" % (r.returncode, " | ".join(tail)))
    # Non-root: device nodes (dev/console) cannot be created -> rc 2.  Accept
    # that single, benign class of error; anything else is a failure.
    errs = [l for l in r.stdout.splitlines()
            if l.startswith(("create_inode:", "write_file:", "FATAL", "failed", "Failed"))]
    benign = [l for l in errs if "character device" in l or "block device" in l]
    if r.returncode != 0 and benign:
        out("  note: ignoring %d device-node error(s) (not superuser): %s"
            % (len(benign), "; ".join(l.split(",")[0] for l in benign)))
    if not check(r.returncode == 0 or (errs and len(errs) == len(benign)),
                 "unsquashfs succeeded (device-node errors tolerated)"):
        return

    # modules
    names = sorted(n for n in os.listdir(MOD_SRC) if n.endswith(".ko"))
    check(len(names) == EXPECT_MODULES,
          "%d .ko in %s (expected %d)" % (len(names), os.path.relpath(MOD_SRC, REPO), EXPECT_MODULES))
    match = 0
    bad = []
    for n in names:
        dst = os.path.join(MOD_DST, n)
        try:
            a = hashlib.sha256(open(os.path.join(MOD_SRC, n), "rb").read()).hexdigest()
            b = hashlib.sha256(open(dst, "rb").read()).hexdigest()
        except OSError as e:
            bad.append("%s (%s)" % (n, e.strerror))
            continue
        if a == b:
            match += 1
        else:
            bad.append("%s (sha mismatch)" % n)
    out("  modules sha256 match: %d/%d" % (match, len(names)))
    for b in bad:
        out("    BAD: " + b)
    check(match == EXPECT_MODULES and not bad, "all %d modules match" % EXPECT_MODULES)

    # presence
    out("  required files:")
    for rel in EXPECT_FILES:
        p = os.path.join(ROOT_DIR, rel)
        ok = os.path.lexists(p)
        extra = ""
        if ok and os.path.islink(p):
            extra = " -> " + os.readlink(p)
        elif ok:
            extra = " (%d B)" % os.path.getsize(p)
        check(ok, rel + extra)

    # ab_guard
    out("  ab_guard.sh:")
    r = run(["bash", os.path.join(REPO, "scripts/ab_guard.sh"), ROOT_DIR])
    for line in r.stdout.strip().splitlines()[:20]:
        out("    " + line)
    check(r.returncode == 0, "ab_guard.sh rc=%d on extracted rootfs" % r.returncode)


# --------------------------------------------------------------------------
def check_sysupgrade():
    out("")
    out("== 3. sysupgrade tar ==")
    if not check(os.path.isfile(SYSUP), "sysupgrade tar exists (%d B)"
                 % (os.path.getsize(SYSUP) if os.path.isfile(SYSUP) else -1)):
        return
    r = run(["tar", "tf", SYSUP])
    names = r.stdout.splitlines()
    check(r.returncode == 0, "tar t rc=0 (%d entries)" % len(names))
    d = "sysupgrade-dlink_dwr-2000m-a3"
    out("  top-level entries: %s" % sorted({n.split("/")[0] + ("/" if "/" in n else "")
                                            for n in names}))
    out("  entries:")
    for n in names:
        out("    " + n)
    check(d + "/CONTROL" in names, d + "/CONTROL present")
    check(any(n == d + "/root" or n.startswith(d + "/root") for n in names),
          d + "/root present")
    if os.path.isdir(SYSUP_DIR):
        shutil.rmtree(SYSUP_DIR)
    os.makedirs(SYSUP_DIR)
    r = run(["tar", "-xf", SYSUP, "-C", SYSUP_DIR, d + "/CONTROL"])
    if not check(r.returncode == 0, "extracted CONTROL to build/verify-sysupgrade/"):
        return
    ctl = open(os.path.join(SYSUP_DIR, d, "CONTROL"), errors="replace").read()
    out("  CONTROL (%d B):" % len(ctl))
    pv = [l for l in ctl.splitlines() if l.startswith(("Package", "Version"))]
    for l in (pv or ctl.splitlines()[:10]):
        out("    " + l)
    if not pv:
        out("    (no Package/Version lines)")


# --------------------------------------------------------------------------
def check_git():
    out("")
    out("== 4. Git cleanliness ==")
    r = run(["git", "-C", os.path.join(REPO, "openwrt"), "status", "--porcelain"])
    out("  git -C openwrt status --porcelain (rc=%d):" % r.returncode)
    lines = r.stdout.splitlines()
    for l in lines or ["(empty)"]:
        out("    " + l)
    check(r.returncode == 0, "git -C openwrt status ok")
    unt = [l for l in lines if l.startswith("??")]
    out("  untracked in openwrt/: %d (reported verbatim above; judged as build state)" % len(unt))

    r = run(["git", "-C", os.path.join(REPO, "openwrt"), "status", "--porcelain", "--ignored"])
    v = [l for l in r.stdout.splitlines() if "vendor" in l]
    out("  git -C openwrt status --porcelain --ignored | grep vendor:")
    for l in v or ["(none)"]:
        out("    " + l)
    check(any(l.startswith("!!") and "package/vendor" in l for l in v),
          "package/vendor is ignored (!!)")
    check(not any(l.startswith("??") and "vendor" in l for l in v),
          "no untracked vendor paths")

    r = run(["git", "-C", REPO, "status", "--porcelain"])
    out("  git status --porcelain (this repo):")
    for l in r.stdout.splitlines() or ["(empty)"]:
        out("    " + l)


# --------------------------------------------------------------------------
def main():
    res = check_ubi()
    if res:
        check_squashfs(*res)
    check_sysupgrade()
    check_git()
    out("")
    if issues:
        out("RESULT: FAIL (%d issues)" % len(issues))
        for i in issues:
            out("  - " + i)
        return 1
    out("RESULT: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
