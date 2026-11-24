# Flash Plan: DWR-2000M A3, stock 4.19 → OpenWrt 24.10 (vk419)

The procedure for the first install of the 24.10 image on a unit running stock firmware. It writes **only** the
idle A/B rootfs slot and the `misc` boot record. Every write is gated on a read-back of the previous step.

> **Status:** prepared, not yet executed on hardware. Steps and expected values below come from the stock scripts,
> the image build and 243 mocked tests. The three hardware-only unknowns are listed under [Known unknowns](#known-unknowns).

## The artefact

| | |
|---|---|
| File | `openwrt-mt6890-vk419-dlink_dwr-2000m-a3-squashfs-factory-rootfs.bin` |
| Size | 67,108,864 B (64 MiB, `0xff`-padded) |
| Format | UBI, PEB 262,144 / VID header 4096 / data 8192 / LEB 253,952, 256 PEB |
| Volumes | `rootfs` (dynamic; squashfs-xz, OpenWrt 24.10.8 userspace + 136 stock 4.19.205 modules) · `rootfs_data` (dynamic, autoresize; UBIFS formatted on first boot) |
| Reference build sha256 | `065c67d72bcd380aa7d3828feb10dd80c6b62ad364138aa7c9807d84f1022e35` |
| Verified by | `scripts/verify-image.py`: EC/VID header CRCs, volume table, squashfs extraction, 136/136 module hashes, A/B guard |

Your own build will have a different sha256 (timestamps, your stock inputs). Record yours and verify that exact value.

## Why it's safe

* **The running stock slot is never touched.** On the reference unit stock runs from slot **B** (`rootfs_b`, mtd42;
  `/proc/cmdline` shows `ubi.mtd=42`). 24.10 goes to the idle slot **A** (`rootfs_a`, mtd29). Always confirm which slot is
  running first; if your unit runs from A, swap every A/B in this plan.
* **Nothing else changes**: boot_a/boot_b kernels (4.19.205), preloader, LK, TEE, modem firmware, NV and calibration
  partitions, `user_data`.
* **The boot record is switched last**, through the stock `dd-nand` mechanism (imported from the stock rootfs and
  sha256-pinned), and every one of its four copies is read back.
* **Automatic fallback**: the new slot gets `tries = 03`. If it fails to boot, the preloader's tries counter
  returns the unit to the untouched stock slot.
* **The image ships ARMED** (`/etc/mt6890-armed`): the boot-time good-boot marker is suppressed, so a 24.10 that boots
  but is unreachable (wrong LAN ports, Wi-Fi disabled) does **not** disarm the fallback. Only `mt6890-bootctl confirm`,
  run by someone who reached the device, clears the tries. Until then every power cycle counts towards the fallback.
* **Every rootfs write is read back**: the flash script compares the sha256 of slot A read from NAND with the image
  before the record is switched. `mtd write` returning 0 is not trusted.
* **Recoverable from any running Linux**: a wrong record can be fixed with `mt6890-bootctl set <slot>` (24.10) or the
  equivalent raw `dd-nand` write (stock). This matters because the preloader download agent can't write `misc`.

## Known unknowns

Verified on the reference unit (read-only captures from a stock DWR-2000M A3, see Lessons):

| Question | Finding | Evidence |
|---|---|---|
| Record layout | byte-exact as decoded: `00414230 ffffffff 0e 00 01 01 0f 00 01 01` (B active, both `success=01`, `tries=00`), 4 identical copies | `dd` of `misc` @2048 + 256 KiB × n |
| Preloader reads it the same way | `[QL_AB] metadata.slots[0].priority:14, slots[1].priority:15` | persistent boot log in `expdb` (mtd5) |
| Secure boot | **enforced**: `sboot_state = 0x1`, `img_auth_required = 1` for every image LK loads (preloader, LK, TEE, boot, …). None of those are written by this port. | `expdb` |
| Does LK verify the rootfs *content*? | **No.** LK verifies the `rootfs_sig_*` certificate chain (`ROOTFS_SIG_VFY Success`) and passes the signed 32-byte hash to the kernel as `/chosen/rootfs,hashvallist`. The stock 4.19.205 kernel (decompressed from `boot_a`) contains **no** consumer of `hashvallist`/`rootfs,sigval`/`rootfs,pubk`; `kernel.config` has no `DM_VERITY`/`IMA`. Nothing in stock userspace reads it either. The flash never touches `rootfs_sig_a`, so the certificate check keeps passing. | `strings` of `lk_a.img`, the decompressed kernel `Image`, `/proc/device-tree/chosen`, `rootfs_sig_a/b` dumps (identical `cert1` headers) |
| Bad blocks | 0 on every partition, erasesize `0x40000` = the image's PEB | `/sys/class/mtd/*/bad_blocks` |
| Kernel images | `boot_a == boot_b`, identical to the kernel image the port was built against | sha256 of the `boot_a`/`boot_b` dumps |
| Stock tools | `mtd`, `flash_erase`/`nandwrite`/`nanddump`, `dd-nand`, `sha256sum`, TLS-capable `wget` (uclient-fetch + libssl) | `command -v` on stock |

Still unobserved (hardware-only, fail closed):

| Unknown | Why it's believed fine | If wrong |
|---|---|---|
| Does LK rewrite `ubi.mtd=` to 29 for slot A? | LK carries `bootslot=a/b` strings; B already boots with `ubi.mtd=42`; the `expdb` log shows earlier boots with A at priority 15 | slot A doesn't mount root → tries exhausted → B |
| Preloader tries threshold | X28 decodes 6; we write 3 | fallback happens sooner or later, but it happens |
| Stock slot A content | On the reference unit `rootfs_a` ≠ `rootfs_b` (different sha256); A may be an older stock build. The `rehearse` step (below) proves whether A boots before any custom image is written. | rehearsal falls back to B after the tries; `revert` the record from stock |

On units where the record shows `b_success != 01`, the stock boot-done script (`zmtk_boot_done`) clones slot B over
slot A on every stock boot. The flash script prints a warning in that case: a fallback to stock will then overwrite
24.10 in A (harmless), and "A keeps the failed image" below does not hold.

## Prerequisites

* A flashing PC on the router's LAN (Linux or WSL — the dumps are streamed over `ssh` into files; avoid PowerShell
  redirects for binary data), SSH access to the stock firmware.
* **Stock SSH facts (reference unit)**: the login user is `admin` (uid 0, full root), **not** `root`. The stock dropbear
  offers only an `ssh-rsa` host key, which OpenSSH ≥ 8.8 refuses ("no matching host key type found. Their offer:
  ssh-rsa"). Working `~/.ssh/config` on the PC:

  ```
  Host dwr
      HostName <router-ip>
      User admin
      HostKeyAlgorithms +ssh-rsa
      PubkeyAcceptedAlgorithms +ssh-rsa
  ```

  `nanddump` may print `ECC: N corrected bitflip(s) at offset 0x...` on stderr on aging NAND: corrected, harmless, not
  an error. Dumping the **running** slot (`rootfs_b`) gives a different sha256 on every read (live UBI: `rootfs_data`
  writes, wear-levelling, scrubbing) — expected; the idle `rootfs_a` and `misc` dump identically every time and must
  match the on-device sums exactly.
* The image on the flashing PC with its sha256 recorded. The flash script takes the sha256 as a **mandatory argument**
  and checks it on the unit, then again on the NAND readback.
* **Mandatory before any write — full off-device dumps**, streamed from the PC (RAM on the unit is too small):
  `misc`, `rootfs_a`, `rootfs_b`, `rootfs_sig_a/b`, `boot_a/b` via `ssh admin@<router> "nanddump -q /dev/mtdN" > file`,
  sha256 compared with the on-device sums the script prints. They are the only recovery for anything this plan did not
  foresee. The script stops at a gate until you confirm they exist.
* **Required for the first flashes of a new unit batch**: UART at 1.8 V, 921600 8N1, to watch the first boot. Once the
  fallback has been *observed* on your hardware revision it can be downgraded to recommended.
* Run the **dress rehearsal first** (`dwr2000m-flash.sh rehearse`): with both slots still stock, only the record is
  switched to A; reboot; `status` must show `booted=a`; `revert`; reboot. Ten minutes, zero risk, and it turns the
  preloader fallback from a decoded assumption into something you have seen.

## Steps

### 1. Back up (writes only to `/tmp` and the flashing PC)

```sh
# on the router (stock)
tar czf /tmp/stock-config-backup.tgz /etc /data
dd if=/dev/mtd3 bs=1 skip=2048 count=16 2>/dev/null | od -A d -t x1 > /tmp/misc-record-before.txt
for o in 264192 526336 788480; do dd if=/dev/mtd3 bs=1 skip=$o count=16 2>/dev/null | od -A d -t x1; done >> /tmp/misc-record-before.txt
{ cat /proc/cmdline; cat /proc/mtd; } > /tmp/pre-flash-state.txt
```

Copy all three files to the flashing PC (`scp`). Confirm in `/proc/cmdline` which slot is running (`ubi.mtd=42` = B),
and that all four `misc` copies start with `00 41 42 30`.

### 2. Transfer the image

Serve the file from the flashing PC over HTTP and `wget` it into the router's `/tmp` (64 MiB of RAM-backed storage).
The stock firmware has no `sha256sum`, so the integrity gate is:

* size is exactly 67,108,864 B, **and**
* `hexdump -C` of the first and last 1 KiB match the hexdumps taken on the flashing PC.

### 3. Flash slot A

```sh
mtd erase rootfs_a
mtd write /tmp/img.bin rootfs_a          # 64 MiB, a few minutes
```

Then write the boot record for slot A: priority `0f`, tries `03`, success `00` for A, B's priority set to `0e`,
every other byte unchanged. Use the exact `dd-nand` invocation of the stock `bootctrl.sh` (8 bytes at seek 2056 plus the
three copies at +256 KiB/+512 KiB/+768 KiB). Don't run the stock helper functions themselves: they contain a
positional-parameter bug that corrupts the B bytes (see [Porting Analysis §7.2](Porting-Analysis#72-stock-sysupgrade-step-by-step)).
Read back all four copies and byte-compare them with the intended record. **Do not reboot unless all four match.**

### 4. Reboot

`reboot`, then wait about 90 s.

### 5. Verify the new root

| Check | Expected |
|---|---|
| `grep -o 'ubi.mtd=[^ ]*' /proc/cmdline` | `ubi.mtd=29` |
| `mt6890-bootctl status` | `active=a booted=a copies_consistent=yes armed=yes` |
| `uci show network.wan` | `proto='mtkmipc'` (the migration ran) |
| `wifi status` | `ra0` (2.4 GHz) and `rai0` (5 GHz) once enabled; default SSIDs `DWR-2000M` / `DWR-2000M-5G` |
| `ifstatus wan` | cellular data call up (mtkmipc via the stock `mipc_wan_cli`) |
| `ls /lib/modules/4.19.205 \| wc -l` | `136` |
| `logread \| grep mt6890-bootok` | `armed: tries NOT reset (run 'mt6890-bootctl confirm' ...)` |

The default wireless config ships disabled with a placeholder key. Set your own key and enable the radios before
`wifi`. Keep a wired or still-associated client until the new SSIDs are confirmed.

### 6. Re-apply the cellular settings

The first install from stock writes no config. Re-enter the APN, auth, user, password and IP type from the backed-up
stock config on `network.wan` (`uci set network.wan.apn=…` etc.), then `uci commit network; ifup wan`. Alternatively,
restore a stock `/etc/config/network` and copy `95-mt6890-uci-migrate` back into `/etc/uci-defaults/` before a reboot
so the migration converts it.

### 7. Success criteria (all must hold)

Boots from A; bootctl consistent; both Wi-Fi bands up with your SSIDs; cellular data up; 136 modules; config migrated.
**Only then** run `mt6890-bootctl confirm` (tries → 00, `armed=no`), reboot once more and confirm the unit **stays** on A.
If you never reach the device: power-cycle it three times and the preloader returns it to stock B by itself.

## Rollback

| Situation | Action |
|---|---|
| A doesn't boot, or boots but is unreachable | Power-cycle until the preloader falls back to B (tries = 3; the image is armed, so an unreachable boot still counts as a failed try). A keeps the failed image for inspection unless `b_success != 01` on your unit (then stock re-clones B over A). |
| A boots but is unusable | From 24.10: `mt6890-bootctl set b && reboot` (or `mt6890-bootctl rollback`). |
| Back on stock B, record still selects A | `sh dwr2000m-flash.sh revert <backup>/original-record.hex` (stock `dd-nand`, all 4 copies, read back), then reboot. |
| Config needed on stock again | Restore `/tmp/stock-config-backup.tgz` (stock `/etc` + `/data`); the original `misc` bytes are in `<backup>/misc-records.txt`. |
| LK halts on slot A (not expected, see the verified table) | Hard brick without a MediaTek DA tool. This is what the mandatory `rootfs_a` / `rootfs_sig_a` dumps are for. |

Note: once 24.10 runs from A, the next `sysupgrade` targets the *other* slot, which is stock B. Stock fallback exists
only until that first 24.10 → 24.10 upgrade. Keep a full partition backup before doing it.

## Later upgrades (24.10 → 24.10)

```sh
sysupgrade -v /tmp/openwrt-mt6890-vk419-dlink_dwr-2000m-a3-squashfs-sysupgrade.tar
# or a dry run that prints the plan and writes nothing:
MT6890_DRYRUN=1 sh -c '. /lib/upgrade/platform.sh; platform_pre_upgrade IMG; platform_do_upgrade IMG'
```

`platform.sh` picks the slot that is not running, erases and writes it, verifies with `ubiattach` (both volumes must be
present), stores the config backup in the new slot's `rootfs_data`, and only then switches `misc`. Manual equivalent
(A running): `mtd erase rootfs_b; mtd write IMG rootfs_b; mt6890-bootctl set b; reboot`.

## What does NOT change

Stock slot B, boot_a/boot_b kernels (4.19.205), preloader, LK, TEE, modem firmware and all modem/NV partitions,
`user_data`. Only `rootfs_a` and the `misc` A/B record are written.
