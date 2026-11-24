# Lessons from porting OpenWrt 24.10 to a vendor-kernel 5G CPE

This page records how the DWR-2000M A3 port was done and what it taught, in the order it happened. It is meant
for anyone facing a similar device: a modern SoC, a heavily patched vendor kernel, an old vendor OpenWrt, and
no source for half of it.

| Phase | Outcome |
|---|---|
| P0: capture | Read-only dumps: boot image, rootfs UBI, module tarball, kernel config, preloader/LK, UCI, later a live FDT and a full rootfs tar |
| P1: analysis | Kernel provenance, 136-module table, DTB, config delta, precedent study, target design, risk register, 22 open questions |
| P2: target + build | `target/linux/mt6890` with a no-op kernel, sha256-pinned vendor import, a green full build, an artefact verifier |
| P3: cellular | `proto mtkmipc`, 51 mocked tests |
| P4: Wi-Fi | `mtwifi` netifd wireless handler over the stock stack, 72 mocked tests |
| P5: A/B | `platform.sh` + `mt6890-bootctl` + UCI migration (89 tests), then `mt6890-bootok` (+31 → 120) |
| Flash plan | Written and reviewed; on-device flash pending |

---

## 1. Verify where every capture came from

The first device-tree dump turned out to come from a phone, not the router. Model, compatible and `/chosen` were all
those of a handset SoC. It looked plausible at a glance (MediaTek, arm64, thousands of nodes), and it would have
sent the whole hardware analysis in the wrong direction. A second capture labelled as one bootloader was in fact
ARM Trusted Firmware from the neighbouring partition.

**An early FDT capture came from a phone, not the router. Always verify DTB provenance.** Check, for every capture
and before using it:

* the DT `model` and top-level `compatible` against the board (here `mediatek,evb6890v1_64_cpe_nand`, `mediatek,mt6890`);
* the image header name (`lk` vs `atf`) and the size against `/proc/mtd`;
* the file type (`file(1)` said "UBI image" for what was labelled a squashfs).

The router's real static DTB was inside the Android boot image at a fixed offset behind a 64-byte MTK DTB-table
header, and a live `/sys/firmware/fdt` captured afterwards confirmed it. The live tree also shows what the bootloader
changes at boot (the `/memory` size, `mblock` reservations, `/chosen` additions), which the static tree can't show.

## 2. Don't rebuild what you can't rebuild: the no-op kernel

The vendor modules import about two dozen symbols that exist only in the vendor vmlinux (HNAT/PPE hooks, CCCI modem
API, conninfra, EMI-MPU), and `MODVERSIONS=y` CRC-checks every import. The modem data path is built into that kernel
and has no mainline counterpart. Rebuilding the kernel would mean either recreating the vendor tree exactly or
porting the modem stack to mainline. Both are far larger than the userspace port.

So the target keeps the kernel and builds everything else:

* `KERNEL_PATCHVER:=6.6` exists only so the 24.10 toolchain, `linux-headers` and `.vermagic` machinery work.
* `Kernel/CompileModules` and `Kernel/CompileImage` are redefined in the target `Makefile` (after `include target.mk`,
  before `BuildTarget`). They only touch the files later steps expect (`modules.builtin*`, an empty `vmlinux`), so no
  vmlinux is ever compiled. Prepare/Configure stay at their defaults; the 6.6 source tarball is still unpacked.
* `CONFIG_STRIP_KERNEL_EXPORTS` must stay off: its rule runs `make vmlinux`.
* The device recipe sets `KERNEL :=`, `KERNEL_INITRAMFS :=` and `KERNEL_IN_UBI :=` empty. One generic line in
  `include/image.mk` still insisted that `<dev>-kernel.bin` exists. The fix applies that check only when the device
  defines a `KERNEL`:

  ```diff
  -	[ -f $$(word 1,$$^) -a -f $$(word 2,$$^) ]
  +	[ $$(if $$(KERNEL),-f $$(word 1,$$^) -a )-f $$(word 2,$$^) ]
  ```

* The stock `pad-to` pads with `0x00`, which is wrong for NAND. A small `mt6890-pad-ff` build step pads with `0xff`.
* The stock `sysupgrade-tar` always passes a kernel, so a custom recipe produces `sysupgrade-<dev>/{CONTROL,root,root.sha256}`.

Savings: no kernel compile, no kernel debugging, no risk of a self-built kernel that doesn't boot. The boot chain on
the device stays byte-identical to stock, and the image is a single rootfs.

Kernel gaps then become userspace choices: fw3 + `iptables-legacy` (no `NF_TABLES`), swconfig (no DSA), no
`procd-ujail`/`procd-seccomp` (no namespaces/seccomp), and a custom Wi-Fi handler (no cfg80211).

## 3. Staged delegation of long builds

The work was split into small, separately specified stages: setup without `make`, vendor import without `make`, a
single package compile, the image recipe, artefact verification, then one feature package per stage. Each stage had:

* a written spec with explicit "do not" bounds (no network, no commit, no `make world` unless the stage was a build);
* an appended notes section recording deviations from the spec and *why*. For example, the spec asked for
  `PCI_SUPPORT:=y`, but `target-metadata.pl` reads only `FEATURES`, so `pci pcie` went into `FEATURES` instead;
* an **independent re-run** of the stage's tests or verifier before it was accepted.

Long builds ran as their own stage with logs on disk, so a failure (a `checklibs` miss, the `image.mk` guard) became the
next small, well-defined stage instead of a sprawling debug session. Notes also recorded every side effect of a
diagnostic step, such as `make defconfig` silently dropping a package, and how it was undone.

## 4. Find the vendor library closure with `ldd` and `checklibs`

Vendor userspace on a 19.07 base needs libraries 24.10 doesn't ship, or ships under a different SONAME or ABI. Two
tools find the closure:

* `readelf -d` / `ldd` on each vendor ELF lists `NEEDED`;
* OpenWrt's own `checklibs` step refuses any package whose ELFs need a library no selected package provides. That's
  a free, exact closure checker.

It took three rounds of import → build → read the `checklibs` error: 8 libraries, then 3 more, then 1 more, then
`libasound.so.2`. That last one comes from 24.10's `alsa-lib`, which is only selectable when the target has
`AUDIO_SUPPORT`, which `FEATURES += pci` selects. Other findings:

* `libjson-c.so.2`, the 19.07 `libubox`/`libuci` and an old `libubus.so.20210603` ship as compat libraries. A distinct
  SONAME coexists with 24.10's.
* The first rootfs extraction was partial (131 entries, no `sbin/`), so "missing" libraries were really missing *from the
  copy*. A full tar of the live rootfs settled it. Absent means absent from the copy until proven otherwise.
* Each import is sha256-pinned; re-runs refuse if a source changed. Every re-pin was diffed and accepted only as
  pure additions.
* Package stripping (`rstrip`) rewrote vendor ELFs. Vendor packages set `RSTRIP:=:`.

## 5. Take the UBI geometry from the device, not from a similar device

The X28 (same SoC, same SDK family) documents PEB 262,144 / VID 4096 / LEB 253,952, and the stock rootfs image
confirmed exactly that. Its volume table, however, differs from X28's (105/135 PEB vs 124/116), and so do its mtd numbers
(`rootfs_a` = mtd29, `user_data` = mtd48 vs X28's 50). Parsing the actual image gave the facts:

* EC header `UBI#` at 0 and VID header `UBI!` at 4096, **big-endian**, with header CRCs;
* data at 8192, so LEB = PEB − 8192;
* volume names live in the layout volume (`0x7fffefff`), not in volume 0;
* squashfs `bytes_used` is a u64 at `0x28`.

The bootloader confirms the slot model. LK and the preloader carry `bootslot=a/b` and `[QL_AB] slot:%d,tries_remaining:%d`
strings, and the DTB bootargs name `ubi.mtd=` while LK picks the slot. `scripts/verify-image.py` re-parses every header of
the built image independently of the tools that produced it. Partitions are always addressed **by name** from
`/proc/mtd`: one partition-number slip (`ubi.mtd=28` in the static DTB vs `rootfs_a` = 29) would hit the signature
partition.

## 6. Reverse-engineer the modem protocol from the stock netifd proto

There is no MIPC kernel module. The modem transport is the built-in CCCI driver exposing `/dev/ttyCMIPC*`, and the
vendor `mipc_wan_cli` wraps MIPC messages (`libmipc_msg.so`) and Quectel AT helpers (`libql_at.so`) behind a JSON CLI.
The contract came from reading the stock `ql_mipc.sh` line by line:

* verbs and argument order: `--nw_radio_state_get 0`, `--check_ia …`, `--show_sim_status`, `--check_nw_status`,
  `--data_call_deact_apn`, `--data_call_act '<json>'`, `--data_call_deact <cid>`, `--apn_provision_by_sim`;
* activation JSON keys (`apn ip_type roaming_type auth_type username password bearer_bitmask mtu mode`) and the reply
  keys (`result cid ifname v4_* v6_* clatd odu_*`);
* the semantics of the misleadingly named `vlan` option: a **PDN index**, not 802.1Q;
* the stock defaults (`bearer_bitmask 0xfffdffff`, ia* inheriting from the non-ia values, retry 2).

A mock `mipc_wan_cli` returning canned JSON, plus OpenWrt's real `netifd-proto.sh` and `jshn`, then lets the proto be
tested exactly the way netifd calls it, without a modem.

## 7. CID-tracked teardown

A cellular proto that tears down "by APN" or by killing helpers will eventually drop the wrong bearer, for example a
secondary PDN on another interface that happens to share the APN. `mtkmipc` records the CID returned by
`--data_call_act` in a per-interface state file. Teardown deactivates **only that CID**, and with no state file it
makes **no** modem call. All `mipc_wan_cli` calls are serialised under one `flock`, because the modem handles one
request at a time. The tests assert that tearing down `wan` leaves `wan2`'s CID untouched.

## 8. The tries counter and the boot record

The A/B record in `misc` is 16 bytes at offset 2048, stored in four copies 256 KiB apart: magic, then per slot
priority / tries / success / uptype. Three things mattered:

* **Read the stock code by running it.** Running the stock `bootctrl.sh` functions under dash and bash with stubbed I/O
  showed that `$10`..`$16` are parsed as `${1}0`..`${1}6`. The stock switch writes B's priority as `0x10` and works only
  because `0x10 > 0x0e`. The port writes the documented intent, never the accident.
* **Switch last, verify first.** Write the inactive slot, `ubiattach` it and require both volumes, store the config in the new
  slot, and only then write the record (target `0f`/tries `03`, other `0e`), reading back every copy.
* **`bootok` resets tries, never sets success.** After a good boot, `mt6890-bootok` zeroes only the running slot's tries
  byte (one byte per copy, idempotent, in the background, always exit 0). Leaving `success` alone keeps the
  preloader's fallback armed. Tests assert that exactly four bytes of `misc` change.

A build guard (`ab_guard.sh`) refuses any rootfs containing the stock slot-cloning logic. It is strict enough to flag
a *comment* that named the stock script. The comment changed; the guard did not.

## 9. Test without the hardware, and say so

243 mocked tests cover the three packages. They run the real shell code under dash/bash/busybox ash, with stubs for
`mipc_wan_cli`, `datconf`, `/sbin/wifi`, `dd-nand`, `mtd`, `ubiattach` and a plain file standing in for `misc`. They
catch logic errors, argument-order mistakes and unsafe write sequences. They don't prove that the preloader honours
`tries = 00`, that LK accepts the new rootfs, or that the stock Lua binary runs on 24.10 musl. Those are listed as
unverified in the [Porting Analysis](Porting-Analysis#10-unverified) and the [Flash Plan](Flash-Plan#known-unknowns),
and every one of them fails closed to the untouched stock slot.

## 10. Keep the open half open and the vendor half local

The repository contains only original work: target, packages, scripts, docs. Vendor modules, firmware and binaries
are imported locally from each user's own device dump with pinned hashes and never committed. This keeps the project
publishable and makes every build reproducible against a known stock firmware.
