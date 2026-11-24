# Porting Analysis: D-Link DWR-2000M A3 (MediaTek MT6890)

Reverse-engineering analysis behind the OpenWrt 24.10 port. It covers kernel provenance, the stock module set, the
device tree, the kernel-config delta against a 24.10 userspace, the comparable ZLT X28 design, and the resulting
target design, then the A/B boot record, MIPC protocol and UCI migration findings from implementation, followed by
the risk register and the list of claims still unverified.

**Method.** Every device claim was derived offline from read-only captures of one unit: the stock `boot_a` image
(Android v2: kernel + DTB), the stock rootfs UBI image, the `/lib/modules/4.19.205` tarball, `/proc/config.gz`
(`kernel.config` below), the live `/sys/firmware/fdt`, preloader and LK images, a full stock UCI dump and a tar of
the full stock rootfs. Line numbers such as `kernel.config:995` refer to those captures. Nothing in this analysis was
written to the device. Claims that rest on another device's documentation, or on reasoning without a capture, are
marked UNVERIFIED and collected in §10.

**Reading guide.** §1–§4 describe the hardware and the stock firmware. §5 summarises the ZLT X28 precedent. §6 is
the design that was built. §7 and §8 record what implementation found about the boot record, the modem protocol and
the configuration. §9 is the risk register and §10 the open questions.

---

## 0. Capture provenance (read first)

Four problems with the initial captures were found during analysis. They shaped the method, so they are listed first.

1. **One early FDT capture was not from this router.** A device-tree dump in the first evidence set came from a
   phone, not the router: its model, compatible and `/chosen` properties belong to a handset SoC. The router's real
   static DTB is the one embedded in `boot_a.img` (model `MediaTek evb6890v1_64_cpe_nand`, compatible
   `mediatek,evb6890v1_64_cpe_nand`, `mediatek,mt6890`). A live `/sys/firmware/fdt` was then captured read-only
   from the router (153,521 B), and it confirms the same model and compatible (§3). **Lesson: always verify DTB
   provenance** (model, compatible, and a node unique to the board) before using a tree for hardware decisions.
2. **The `lk_b` capture is not an LK image.** Its MTK image header is named `atf` (ARM Trusted Firmware
   `v1.6(debug)`, built Nov 1 2024), and it is 1 MiB against `lk_a`'s 2 MiB. It was most likely read from the adjacent
   `tee_*` partition. `lk_a.img` is a genuine LK (`lk` header, `lk_main_dtb`, `bootslot=a/b`).
3. **The rootfs capture is a UBI image, not raw squashfs.** It holds volume 0 `rootfs` (squashfs) and volume 1
   `rootfs_data` (UBIFS). See §3.4.
4. **Module count: a metadata file says 74, the tarball holds 136 `.ko`.** All 136 are byte-identical to
   `/lib/modules/4.19.205/*.ko` inside the stock rootfs, so the tarball is the full set and "74" is most likely a
   loaded-module (`lsmod`) count (U1).

---

## 1. Kernel provenance

### 1.1 Identity

| Field | Value | Source |
|---|---|---|
| `uname -a` | `Linux MobileRouter 4.19.205 #0 SMP Fri Nov 1 12:40:04 UTC 2024 aarch64` | device |
| `/proc/version` | `Linux version 4.19.205 (…) (gcc version 7.5.0 (OpenWrt GCC 7.5.0 r0-7bdb3f5e), GNU ld (GNU Binutils) 2.31.1) #0 SMP Fri Nov 1 12:40:04 UTC 2024` | device; identical banner in the gunzipped Image from `boot_a.img` |
| Build host | a 12-hex-digit container hostname, i.e. a Docker buildbot | `/proc/version` |
| Toolchain | OpenWrt GCC 7.5.0, binutils 2.31.1, musl (`target-aarch64_cortex-a55+neon-vfpv4_musl`) | banner; module debug paths |
| OpenWrt revision | `r0-7bdb3f5e`, 19.07-SNAPSHOT, `DISTRIB_TARGET='mt6890/evb6890v1_64_cpe_nand'` | `/etc/openwrt_release` |
| Vendor SDK tree | `…/fe_platform_rg500l_t750_vtrunk/openwrt/build_dir/target-aarch64_cortex-a55+neon-vfpv4_musl/linux-mt6890_evb6890v1_64_cpe_nand/…` | `strings` of mt_wifi, conninfra, gps_drv, warp, hw_nat, cryptodev, btmtk_uart, mapfilter `.ko`; also in `preloader.img` |
| Vermagic | `4.19.205 SMP mod_unload modversions aarch64`: one value across all 136 modules | `modinfo -F vermagic` |
| `module_layout` CRC | `0x37269833`: the same in mt_wifi, hw_nat, wifi_md_coex, act_connmark | parsed `__versions` |
| `CONFIG_LOCALVERSION` | `""` (`LOCALVERSION_AUTO=y`, no SCM suffix) | kernel.config:23-24 |
| `CONFIG_MODVERSIONS` | `y`; no `MODULE_SIG*` | kernel.config:650 |
| Kernel image | Android boot v2, page 2048, kernel gzip 9,045,539 B @ `0x40080000`, tags `0x42f00000`, no ramdisk, cmdline `bootopt=64S3,32N2,64N2`; Image 31,123,464 B, `text_offset 0x80000` | header parse of `boot_a.img` |
| Built-in cmdline | `console=tty0 console=ttyMT3,921600n1 root=/dev/ram vmalloc=496M slub_max_order=0 slub_debug=O` + `CMDLINE_FROM_BOOTLOADER=y` | kernel.config:460-461 |
| DTB bootargs (static) | `console=tty0 console=ttyS0,921600n1 root=/dev/ubiblock0_0 rootfstype=squashfs ubi.mtd=28 init=/etc/preinit loglevel=8 androidboot.selinux=permissive androidboot.hardware=mt6890 initcall_debug=1` | `/chosen/bootargs` of the `boot_a` DTB |
| Rootfs build date | squashfs `mkfs_time` 1729678592 = 2024-10-23 (module tar mtimes match) | UBI vol 0 superblock |

**Who built it.** The SDK name `fe_platform_rg500l_t750` is the key. **RG500L** is a Quectel 5G module family and
**T750** is MediaTek's brand name for MT6890. Quectel fingerprints are everywhere: `CONFIG_QUECTEL_*` / `CONFIG_QL_*`
(kernel.config:1444,1511,2400,2403,5305,5307), DT nodes `ql,quectel-power`, `quectel,spi-mtk-slave`,
`quectel-phys-scan`, the netifd proto `ql_mipc`, USB VID `0x2c7c` (Quectel) in the stock UCI, and preloader `[QL_AB]`
strings. A vendor UI profile package (a UCI package of the same name plus the buildbot path) is the ODM's UI layer
on top of the Quectel RG500L SDK. **This is the same Quectel RG500L/T750 SDK family as the ZLT X28** (§5).

### 1.2 Implications for an OpenWrt 24.10 target

* **The kernel can't be rebuilt from OpenWrt 24.10 sources.** The vendor modules resolve symbols that exist only in
  this vmlinux. Comparing every module's undefined symbols against what all 136 modules export via
  `__ksymtab_strings` leaves: `ppe_dev_register_hook`, `ppe_hook_{rx,tx}_{eth,ext,modem,rndis,wifi}`,
  `ra_sw_nat_hook_{rx,tx}`, `ppe_del_entry_by_mac`, `ppe_get_dev_stats`, `ppe_virt_foe_base_tmp`,
  `medmcu_hnat_info_host_base_virt` (HNAT glue, `CONFIG_HW_NAT=y`), `mtk_ccci_{open,close}_port`,
  `mtk_ccci_{read,write}_data` (CCCI, used by `wifi_md_coex` and `btmtk_uart`), `clk_buf_ctrl`,
  `wmt_export_platform_bridge_register` (conninfra) and `mtk_emimpu_*` (gps_drv). `strings` of the Image confirms
  `__ksymtab_mtk_ccci_open_port` and `ppe_dev_register_hook`. With `MODVERSIONS=y` each import is CRC-checked
  (e.g. `ppe_dev_register_hook` `0xe1bfa376`, `ra_sw_nat_hook_rx` `0x898a5d02`).
* **The kernel stays a frozen binary artefact.** `boot_a`/`boot_b` are left as shipped and the OpenWrt build never
  produces a kernel. The target `Makefile` still declares a `KERNEL_PATCHVER` (OpenWrt requires one), but the kernel
  build becomes a no-op and the image recipe has no kernel member (§6.2).
* **Official 24.10 `kmod-*` packages won't load.** Their vermagic and CRCs differ, and 24.10 targets kernel 6.6. The
  136 stock `.ko` (plus about 41 built-ins) ship through a `kernel` meta-package pinned to `4.19.205` with `kmod-*`
  stubs.
* **Not the X28's kernel build.** X28 documents `4.19.205 (release@vm-mtk5g-96) … Fri Dec 22 12:10:12 UTC 2023`,
  toolchain `r0-f6109fc5`. Ours is `… Nov 1 2024`, `r0-7bdb3f5e`. Same version string, different build, so kmods
  built for X28 must not be assumed to load.
* **The userspace ABI is musl / aarch64 cortex-a55.** The vendor `mipc_wan_cli` was linked against
  `libjson-c.so.2` and `libql_at.so` while 24.10 ships `libjson-c.so.5`, so a small set of 19.07 compat libraries
  ships alongside (§8.3).

---

## 2. Module inventory

**Counts.** 136 `.ko` in the stock tarball; 136 table rows. The flat `modules/4.19.205/` directory has no
`modules.dep` / `modules.alias` and no symlinks.

**Method, per row.** `modinfo -F {license,intree,depends,vermagic}`, `stat -c %s`, `sha256sum` (12-hex prefix), and
membership in the stock `/etc/modules.d/*`. Separately, `strings | grep vermagic` on every module: **all 136 carry
`vermagic=4.19.205 SMP mod_unload modversions aarch64`** (last column). The 12-hex prefixes are the pins that
`scripts/import-stock.sh` enforces.

**Classification rules**

* **BLOB**: `license: Proprietary`. Only `mt_wifi.ko` (13,672,672 B, not stripped).
* **MTK vendor out-of-tree**: `intree` absent and MediaTek origin (author / description / build path): `mtk_warp`,
  `mtk_warp_proxy`, `hw_nat` ("Mediatek Hardware NAT"), `mapfilter`, `wifi_md_coex`, `conninfra`, `gps_drv`,
  `btmtk_uart` ("Mediatek Bluetooth Driver", `7.0.20120401:turnkey`). Their license tags say GPL / Dual BSD/GPL, but
  no source accompanies the firmware, so for packaging they are treated like blobs (R13).
* **Open, out-of-tree OpenWrt package**: `cryptodev` (cryptodev-linux 1.10) and `nat46`.
* **Open, OpenWrt hack-patch**: `nf_conntrack_rtcache` (`intree: Y`).
* **Open, mainline-style**: `intree: Y`, upstream 4.19 sources.

Summary: 1 blob, 8 MTK out-of-tree, 2 OSS out-of-tree, 1 OpenWrt hack, 124 mainline-style. By family: netfilter 98,
other net 18, tc/qos 9, lib/crypto 7, sound/bt 4. Total size 21,842,208 B.

There are **no MIPC / CCCI / CCMNI modules.** The modem stack is built into vmlinux (`CONFIG_MTK_ECCCI_DRIVER=y`,
`CONFIG_MTK_NET_CCMNI=y`, kernel.config:1805-1815). The Image contains `ttyCMIPC0`…`ttyCMIPC14` and about 195 `ccmni`
strings. The MIPC userspace (`mipc_wan_cli`, `libmipc_msg.so`) opens `/dev/ttyCMIPC*`.

**Stock autoload vs. presence.** The stock `/etc/modules.d` names 177 modules. 41 of them have no `.ko` because they
are built in (e.g. `swconfig`, `tun`, `ext4`, `l2tp_core`, `sch_fq_codel`, `libphy`, `crc32c_generic`, `ppp_mppe`).
Only `bluetooth.ko` ships without being autoloaded directly (`btmtk_uart` pulls it in).

**Load order to reproduce** (from `depends`): `wifi_md_coex` → `mt_wifi` → `mtk_warp` → `mtk_warp_proxy`;
`conninfra` → `gps_drv`; `bluetooth` → `btmtk_uart`; `hw_nat` standalone (needs the vmlinux PPE hooks). Stock files:
`etc/modules.d/{wifi_md_coex,mt_wifi,60-warp,mtk_warp_proxy,70-hw_nat,30-conninfra,50-gps_drv,btmtk_uart,mapfilter}`.

### 2.1 Module table

| # | module | class | license | intree | depends | size (B) | sha256[:12] | stock autoload | family | vermagic (strings) |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | `act_connmark` | open, mainline-style (in-tree 4.19) | GPL | Y | nf_conntrack | 13,488 | `834ac873f602` | Y | tc/qos | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 2 | `act_skbedit` | open, mainline-style (in-tree 4.19) | GPL | Y | - | 14,480 | `892fb11afe7b` | Y | tc/qos | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 3 | `af_alg` | open, mainline-style (in-tree 4.19) | GPL | Y | - | 33,328 | `7a4fb230c1ca` | Y | lib/crypto | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 4 | `algif_hash` | open, mainline-style (in-tree 4.19) | GPL | Y | af_alg | 17,576 | `7ea0755e0989` | Y | lib/crypto | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 5 | `algif_skcipher` | open, mainline-style (in-tree 4.19) | GPL | Y | af_alg | 15,192 | `3a543168abbe` | Y | lib/crypto | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 6 | `bluetooth` | open, mainline-style (in-tree 4.19) | GPL | Y | - | 924,576 | `038ac1d3b998` | N | sound/bt | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 7 | `br_netfilter` | open, mainline-style (in-tree 4.19) | GPL | Y | - | 30,096 | `dca3ae257573` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 8 | `btmtk_uart` | MTK vendor out-of-tree (GPL/dual-tagged, source not published) | GPL | N | bluetooth | 244,672 | `b4f5e2ec399c` | Y | net | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 9 | `cls_basic` | open, mainline-style (in-tree 4.19) | GPL | Y | - | 14,928 | `be0bc8271d15` | Y | tc/qos | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 10 | `cls_matchall` | open, mainline-style (in-tree 4.19) | GPL v2 | Y | - | 13,760 | `83a2689849cd` | Y | tc/qos | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 11 | `cls_route` | open, mainline-style (in-tree 4.19) | GPL | Y | - | 16,984 | `f6df92aee19c` | Y | tc/qos | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 12 | `cls_tcindex` | open, mainline-style (in-tree 4.19) | GPL | Y | - | 23,904 | `01427fd97189` | Y | tc/qos | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 13 | `conninfra` | MTK vendor out-of-tree (GPL/dual-tagged, source not published) | GPL | N | - | 553,776 | `996ab95f1b79` | Y | net | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 14 | `crc-ccitt` | open, mainline-style (in-tree 4.19) | GPL | Y | - | 5,656 | `d57587bfba52` | Y | lib/crypto | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 15 | `cryptodev` | open, out-of-tree (OpenWrt package) | GPL | N | - | 87,256 | `6548ee994c16` | Y | net | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 16 | `ebt_802_3` | open, mainline-style (in-tree 4.19) | GPL | Y | x_tables | 5,120 | `1299835c9dd6` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 17 | `ebt_among` | open, mainline-style (in-tree 4.19) | GPL | Y | x_tables | 8,240 | `d40672f3d00f` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 18 | `ebt_arp` | open, mainline-style (in-tree 4.19) | GPL | Y | x_tables | 6,048 | `05a7ef070ac6` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 19 | `ebt_arpreply` | open, mainline-style (in-tree 4.19) | GPL | Y | x_tables | 5,816 | `c004286545ff` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 20 | `ebt_dnat` | open, mainline-style (in-tree 4.19) | GPL | Y | x_tables | 5,720 | `0218f3e95b90` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 21 | `ebt_ip` | open, mainline-style (in-tree 4.19) | GPL | Y | x_tables | 5,912 | `25da8608b349` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 22 | `ebt_ip6` | open, mainline-style (in-tree 4.19) | GPL | Y | x_tables | 6,408 | `4e11ebe2556d` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 23 | `ebt_limit` | open, mainline-style (in-tree 4.19) | GPL | Y | x_tables | 7,224 | `21678c6cb197` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 24 | `ebt_log` | open, mainline-style (in-tree 4.19) | GPL | Y | x_tables | 9,616 | `51183475b6f0` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 25 | `ebt_mark` | open, mainline-style (in-tree 4.19) | GPL | Y | x_tables | 8,688 | `6705fba687c7` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 26 | `ebt_mark_m` | open, mainline-style (in-tree 4.19) | GPL | Y | x_tables | 10,712 | `07faadd4c9dd` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 27 | `ebt_nflog` | open, mainline-style (in-tree 4.19) | GPL | Y | x_tables | 5,328 | `9d07c67f50bc` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 28 | `ebt_pkttype` | open, mainline-style (in-tree 4.19) | GPL | Y | x_tables | 4,928 | `0d8e8bca00c2` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 29 | `ebt_redirect` | open, mainline-style (in-tree 4.19) | GPL | Y | x_tables | 5,656 | `e4f62b45f86d` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 30 | `ebt_snat` | open, mainline-style (in-tree 4.19) | GPL | Y | x_tables | 5,624 | `b9ad60cdf9f6` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 31 | `ebt_stp` | open, mainline-style (in-tree 4.19) | GPL | Y | x_tables | 6,872 | `916e817d42f3` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 32 | `ebt_vlan` | open, mainline-style (in-tree 4.19) | GPL | Y | x_tables | 9,224 | `603898258717` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 33 | `ebtable_broute` | open, mainline-style (in-tree 4.19) | GPL | Y | ebtables | 6,728 | `a77848f530fe` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 34 | `ebtable_filter` | open, mainline-style (in-tree 4.19) | GPL | Y | ebtables | 6,672 | `41d845e45a5f` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 35 | `ebtable_nat` | open, mainline-style (in-tree 4.19) | GPL | Y | ebtables | 6,672 | `03fdcb44dd61` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 36 | `ebtables` | open, mainline-style (in-tree 4.19) | GPL | Y | x_tables | 63,632 | `6257598ada71` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 37 | `gps_drv` | MTK vendor out-of-tree (GPL/dual-tagged, source not published) | GPL | N | conninfra | 669,760 | `6222368c8773` | Y | net | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 38 | `hw_nat` | MTK vendor out-of-tree (GPL/dual-tagged, source not published) | Dual BSD/GPL | N | - | 643,976 | `1afc66ce70a8` | Y | net | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 39 | `ifb` | open, mainline-style (in-tree 4.19) | GPL | Y | - | 14,848 | `517a6a6a5c6b` | Y | tc/qos | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 40 | `ip6_gre` | open, mainline-style (in-tree 4.19) | GPL | Y | - | 52,408 | `1fb35d15f0bb` | Y | net | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 41 | `ip6_tables` | open, mainline-style (in-tree 4.19) | GPL | Y | x_tables | 43,952 | `b5a9885c0fd7` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 42 | `ip6t_REJECT` | open, mainline-style (in-tree 4.19) | GPL | Y | x_tables,nf_reject_ipv6 | 6,632 | `0bd2894b955c` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 43 | `ip6table_filter` | open, mainline-style (in-tree 4.19) | GPL | Y | x_tables,ip6_tables | 7,832 | `19d54eebcbb5` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 44 | `ip6table_mangle` | open, mainline-style (in-tree 4.19) | GPL | Y | x_tables,ip6_tables | 7,512 | `afd6d1c50ddb` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 45 | `ip_gre` | open, mainline-style (in-tree 4.19) | GPL | Y | - | 42,440 | `5dadf47546d2` | Y | net | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 46 | `ip_set` | open, mainline-style (in-tree 4.19) | GPL | Y | nfnetlink | 75,648 | `897ff7ad4879` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 47 | `ip_set_bitmap_ip` | open, mainline-style (in-tree 4.19) | GPL | Y | ip_set | 20,704 | `c37cb4a724ba` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 48 | `ip_set_bitmap_ipmac` | open, mainline-style (in-tree 4.19) | GPL | Y | ip_set | 19,088 | `0b6f18dde8b3` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 49 | `ip_set_bitmap_port` | open, mainline-style (in-tree 4.19) | GPL | Y | ip_set | 17,880 | `3023f4c8db47` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 50 | `ip_set_hash_ip` | open, mainline-style (in-tree 4.19) | GPL | Y | ip_set | 53,472 | `b32514277f84` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 51 | `ip_set_hash_ipmark` | open, mainline-style (in-tree 4.19) | GPL | Y | ip_set | 53,464 | `0dc3847414f2` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 52 | `ip_set_hash_ipport` | open, mainline-style (in-tree 4.19) | GPL | Y | ip_set | 54,368 | `63cb12a28fd3` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 53 | `ip_set_hash_ipportip` | open, mainline-style (in-tree 4.19) | GPL | Y | ip_set | 55,280 | `dca2a14debc1` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 54 | `ip_set_hash_ipportnet` | open, mainline-style (in-tree 4.19) | GPL | Y | ip_set | 60,880 | `eb189d3e6b27` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 55 | `ip_set_hash_mac` | open, mainline-style (in-tree 4.19) | GPL | Y | ip_set | 32,856 | `8048076c5711` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 56 | `ip_set_hash_net` | open, mainline-style (in-tree 4.19) | GPL | Y | ip_set | 57,696 | `125d6bce03a1` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 57 | `ip_set_hash_netiface` | open, mainline-style (in-tree 4.19) | GPL | Y | ip_set | 60,144 | `d24043f1a3d2` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 58 | `ip_set_hash_netnet` | open, mainline-style (in-tree 4.19) | GPL | Y | ip_set | 60,288 | `00d05389ef9c` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 59 | `ip_set_hash_netport` | open, mainline-style (in-tree 4.19) | GPL | Y | ip_set | 59,576 | `2cf33e17fafb` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 60 | `ip_set_hash_netportnet` | open, mainline-style (in-tree 4.19) | GPL | Y | ip_set | 61,608 | `e6047782793c` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 61 | `ip_set_list_set` | open, mainline-style (in-tree 4.19) | GPL | Y | ip_set | 19,792 | `ff06c95a57b6` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 62 | `ip_tables` | open, mainline-style (in-tree 4.19) | GPL | Y | x_tables | 44,600 | `7c2de0723f11` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 63 | `ipt_ECN` | open, mainline-style (in-tree 4.19) | GPL | Y | x_tables | 6,704 | `a1dc844f207d` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 64 | `ipt_MASQUERADE` | open, mainline-style (in-tree 4.19) | GPL | Y | nf_nat_ipv4,x_tables,nf_conntrack | 8,032 | `6c498e346ebb` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 65 | `ipt_REJECT` | open, mainline-style (in-tree 4.19) | GPL | Y | x_tables,nf_reject_ipv4 | 6,568 | `ac7a836232ac` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 66 | `iptable_filter` | open, mainline-style (in-tree 4.19) | GPL | Y | x_tables,ip_tables | 7,800 | `cf1ac1e8ab8a` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 67 | `iptable_mangle` | open, mainline-style (in-tree 4.19) | GPL | Y | x_tables,ip_tables | 7,448 | `5ef2bb6e7ae6` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 68 | `iptable_nat` | open, mainline-style (in-tree 4.19) | GPL | Y | nf_nat_ipv4,ip_tables | 7,224 | `bf521c611fab` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 69 | `iptable_raw` | open, mainline-style (in-tree 4.19) | GPL | Y | x_tables,ip_tables | 9,072 | `630bf386af13` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 70 | `l2tp_eth` | open, mainline-style (in-tree 4.19) | GPL | Y | - | 16,776 | `72bec2b770e3` | Y | net | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 71 | `l2tp_ip` | open, mainline-style (in-tree 4.19) | GPL | Y | - | 30,304 | `1dfc9eb6237e` | Y | net | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 72 | `l2tp_ip6` | open, mainline-style (in-tree 4.19) | GPL | Y | l2tp_ip | 30,472 | `2da0d68c195b` | Y | net | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 73 | `mapfilter` | MTK vendor out-of-tree (GPL/dual-tagged, source not published) | Dual BSD/GPL | N | - | 92,032 | `d6bd9544ea1f` | Y | net | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 74 | `mt_wifi` | **BLOB** (MTK proprietary, binary-only) | Proprietary | N | wifi_md_coex | 13,672,672 | `cff751c51c2f` | Y | net | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 75 | `mtk_warp` | MTK vendor out-of-tree (GPL/dual-tagged, source not published) | GPL | N | - | 2,108,352 | `465639084594` | Y | net | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 76 | `mtk_warp_proxy` | MTK vendor out-of-tree (GPL/dual-tagged, source not published) | GPL | N | mt_wifi,mtk_warp | 29,376 | `26e325b0aaea` | Y | net | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 77 | `nat46` | open, out-of-tree (OpenWrt package) | GPL | N | - | 53,776 | `45741dc53422` | Y | net | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 78 | `nf_conncount` | open, mainline-style (in-tree 4.19) | GPL | Y | nf_conntrack | 23,080 | `d8e550bd220d` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 79 | `nf_conntrack` | open, mainline-style (in-tree 4.19) | GPL | Y | nf_defrag_ipv6,nf_defrag_ipv4 | 257,560 | `86d86bd2168f` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 80 | `nf_conntrack_ftp` | open, mainline-style (in-tree 4.19) | GPL | Y | nf_conntrack | 28,016 | `d1eeba8ed559` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 81 | `nf_conntrack_netlink` | open, mainline-style (in-tree 4.19) | GPL | Y | nfnetlink,nf_conntrack | 66,360 | `098c6b714301` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 82 | `nf_conntrack_rtcache` | open, OpenWrt hack-patch (mainline-style) | GPL | Y | nf_conntrack | 17,248 | `a26d93897705` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 83 | `nf_defrag_ipv4` | open, mainline-style (in-tree 4.19) | GPL | Y | - | 7,408 | `4fdb213a8375` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 84 | `nf_defrag_ipv6` | open, mainline-style (in-tree 4.19) | GPL | Y | - | 27,240 | `53aa062ed6e2` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 85 | `nf_log_common` | open, mainline-style (in-tree 4.19) | GPL | Y | - | 12,456 | `81d69b8c8ba0` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 86 | `nf_log_ipv4` | open, mainline-style (in-tree 4.19) | GPL | Y | nf_log_common | 14,008 | `b10d70810d74` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 87 | `nf_log_ipv6` | open, mainline-style (in-tree 4.19) | GPL | Y | nf_log_common | 14,224 | `17a459631e69` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 88 | `nf_nat` | open, mainline-style (in-tree 4.19) | GPL | Y | nf_conntrack | 49,920 | `f803f429aa32` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 89 | `nf_nat_ftp` | open, mainline-style (in-tree 4.19) | GPL | Y | nf_conntrack_ftp,nf_nat,nf_conntrack | 10,504 | `f5a330361e8f` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 90 | `nf_nat_ipv4` | open, mainline-style (in-tree 4.19) | GPL | Y | nf_nat,nf_conntrack | 21,760 | `895f0a5d9e0e` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 91 | `nf_reject_ipv4` | open, mainline-style (in-tree 4.19) | GPL | Y | - | 8,144 | `c6a59f7dc233` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 92 | `nf_reject_ipv6` | open, mainline-style (in-tree 4.19) | GPL | Y | - | 12,472 | `6cdc1d204df5` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 93 | `nfnetlink` | open, mainline-style (in-tree 4.19) | GPL | Y | - | 18,128 | `be406f608a3c` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 94 | `ppp_async` | open, mainline-style (in-tree 4.19) | GPL | Y | crc-ccitt | 30,904 | `3b64d55e06a7` | Y | net | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 95 | `pppoe` | open, mainline-style (in-tree 4.19) | GPL | Y | - | 35,608 | `9bd8f368dc32` | Y | net | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 96 | `sch_hfsc` | open, mainline-style (in-tree 4.19) | GPL | Y | - | 32,096 | `c66ddd550fb9` | Y | tc/qos | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 97 | `sch_tbf` | open, mainline-style (in-tree 4.19) | GPL | Y | - | 18,064 | `00e3c4756aa7` | Y | tc/qos | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 98 | `snd-compress` | open, mainline-style (in-tree 4.19) | GPL v2 | Y | - | 36,056 | `86d4025a305d` | Y | sound/bt | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 99 | `snd-mixer-oss` | open, mainline-style (in-tree 4.19) | GPL | Y | - | 42,840 | `ee5f474e0191` | Y | sound/bt | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 100 | `snd-pcm-oss` | open, mainline-style (in-tree 4.19) | GPL | Y | snd-mixer-oss | 85,312 | `3bfc0e9e3abf` | Y | sound/bt | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 101 | `ts_bm` | open, mainline-style (in-tree 4.19) | GPL | Y | - | 6,112 | `52cb93290c83` | Y | lib/crypto | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 102 | `ts_fsm` | open, mainline-style (in-tree 4.19) | GPL | Y | - | 7,160 | `69329dbdaaf0` | Y | lib/crypto | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 103 | `ts_kmp` | open, mainline-style (in-tree 4.19) | GPL | Y | - | 5,920 | `a017b885e464` | Y | lib/crypto | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 104 | `wifi_md_coex` | MTK vendor out-of-tree (GPL/dual-tagged, source not published) | Dual BSD/GPL | N | - | 32,288 | `a6c834a02118` | Y | net | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 105 | `x_tables` | open, mainline-style (in-tree 4.19) | GPL | Y | - | 62,088 | `096b5f1bf088` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 106 | `xt_CLASSIFY` | open, mainline-style (in-tree 4.19) | GPL | Y | x_tables | 5,040 | `05690fae0093` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 107 | `xt_CT` | open, mainline-style (in-tree 4.19) | GPL | Y | x_tables,nf_conntrack | 14,120 | `7734727f11e0` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 108 | `xt_DSCP` | open, mainline-style (in-tree 4.19) | GPL | Y | x_tables | 6,920 | `0b762870283a` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 109 | `xt_HL` | open, mainline-style (in-tree 4.19) | GPL | Y | x_tables | 6,232 | `773fdd330a16` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 110 | `xt_LOG` | open, mainline-style (in-tree 4.19) | GPL | Y | x_tables | 7,656 | `c6c6ada6335d` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 111 | `xt_REDIRECT` | open, mainline-style (in-tree 4.19) | GPL | Y | x_tables,nf_nat,nf_conntrack | 7,976 | `fef657a85300` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 112 | `xt_TCPMSS` | open, mainline-style (in-tree 4.19) | GPL | Y | x_tables | 11,624 | `d67fe235f787` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 113 | `xt_bpf` | open, mainline-style (in-tree 4.19) | GPL | Y | x_tables | 8,008 | `7f474e8c87b4` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 114 | `xt_comment` | open, mainline-style (in-tree 4.19) | GPL | Y | x_tables | 4,792 | `48102b9998af` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 115 | `xt_connbytes` | open, mainline-style (in-tree 4.19) | GPL | Y | x_tables,nf_conntrack | 7,720 | `8e6984bbaf8f` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 116 | `xt_connlimit` | open, mainline-style (in-tree 4.19) | GPL | Y | x_tables,nf_conntrack,nf_conncount | 6,560 | `1f9bca4d267b` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 117 | `xt_connmark` | open, mainline-style (in-tree 4.19) | GPL | Y | x_tables,nf_conntrack | 9,328 | `08e1eaa95b0c` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 118 | `xt_conntrack` | open, mainline-style (in-tree 4.19) | GPL | Y | x_tables,nf_conntrack | 8,592 | `12c6ab2d146f` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 119 | `xt_dscp` | open, mainline-style (in-tree 4.19) | GPL | Y | x_tables | 6,032 | `a5cdca6df4ae` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 120 | `xt_ecn` | open, mainline-style (in-tree 4.19) | GPL | Y | x_tables | 7,312 | `1ea5185ac5ae` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 121 | `xt_helper` | open, mainline-style (in-tree 4.19) | GPL | Y | x_tables,nf_conntrack | 6,640 | `34ed97fc4220` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 122 | `xt_hl` | open, mainline-style (in-tree 4.19) | GPL | Y | x_tables | 5,560 | `8c520e6ed5db` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 123 | `xt_length` | open, mainline-style (in-tree 4.19) | GPL | Y | x_tables | 5,280 | `f06e61a69655` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 124 | `xt_limit` | open, mainline-style (in-tree 4.19) | GPL | Y | x_tables | 8,608 | `22210faadc3e` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 125 | `xt_mac` | open, mainline-style (in-tree 4.19) | GPL | Y | x_tables | 4,920 | `d1511c8a48da` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 126 | `xt_mark` | open, mainline-style (in-tree 4.19) | GPL | Y | x_tables | 5,624 | `2e1fd51e0f8b` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 127 | `xt_multiport` | open, mainline-style (in-tree 4.19) | GPL | Y | x_tables | 8,248 | `a563b8a96f6e` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 128 | `xt_nat` | open, mainline-style (in-tree 4.19) | GPL | Y | x_tables,nf_conntrack,nf_nat | 11,496 | `fde2d9803036` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 129 | `xt_recent` | open, mainline-style (in-tree 4.19) | GPL | Y | x_tables | 26,800 | `ce66fa2e1b7d` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 130 | `xt_set` | open, mainline-style (in-tree 4.19) | GPL | Y | x_tables,ip_set | 20,920 | `868d67608e8b` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 131 | `xt_state` | open, mainline-style (in-tree 4.19) | GPL | Y | x_tables,nf_conntrack | 6,272 | `1bf3014ef1e1` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 132 | `xt_statistic` | open, mainline-style (in-tree 4.19) | GPL | Y | x_tables | 6,408 | `ffe0f16eb646` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 133 | `xt_string` | open, mainline-style (in-tree 4.19) | GPL | Y | x_tables | 5,712 | `13fbc605cecc` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 134 | `xt_tcpmss` | open, mainline-style (in-tree 4.19) | GPL | Y | x_tables | 5,880 | `ed7d69da9785` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 135 | `xt_tcpudp` | open, mainline-style (in-tree 4.19) | GPL | Y | x_tables | 10,144 | `de4e5042f84a` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |
| 136 | `xt_time` | open, mainline-style (in-tree 4.19) | GPL | Y | x_tables | 8,984 | `651fac419d19` | Y | netfilter | `vermagic=4.19.205 SMP mod_unload modversions aarch64` |

---

## 3. Device tree and memory

**Source.** The static tree is extracted from `boot_a.img`. The boot image's DTB section at `0x8a1000` starts with
a 64-byte MTK/Android DTB-table header (magic `d7 b7 ab 1e`), and the FDT itself is at `0x8a1040` (X28 documents
the same structure at `0x89a000`/`0x89a040`):

```sh
python3 - <<'EOF'
import struct; f=open('boot_a.img','rb').read(); o=0x8a1040
open('dtb-from-boot_a.dtb','wb').write(f[o:o+struct.unpack('>I',f[o+4:o+8])[0]])
EOF
```

**Provenance check.** The live `/sys/firmware/fdt` captured read-only from the running router (153,521 B, 407
`compatible` properties) has the same model (`MediaTek evb6890v1_64_cpe_nand`) and compatible
(`mediatek,evb6890v1_64_cpe_nand`, `mediatek,mt6890`) as the `boot_a` DTB. It also carries the edits LK makes at
boot: a rewritten `/memory` (`reg` = `0x4000_0000` + `0x4000_0000`, i.e. 1 GiB) with an `mblock_info` blob, and
`/chosen` additions (`rootfs,*`, `atag,*`, `mblock-*` reserved regions). All statements below use the
router's own tree. The phone tree mentioned in §0 was discarded.

### 3.1 Every `compatible` string

The static router DTB has 387 `compatible` properties with 310 distinct strings:

<details><summary>310 distinct compatible strings (387 properties); ×N = number of nodes</summary>

`Mediatek,simcards` · `arm,armv8-pmuv3` · `arm,armv8-timer` · `arm,cortex-a55` ×4 · `arm,dsu-pmu` · `arm,gic-v3` · `arm,psci-0.2` · `ethernet-phy-id0022.1640` · `ethernet-phy-id0243.0d90` · `ethernet-phy-ieee802.3-c45` · `fixed-clock` ×7 · `focaltech,fts` · `goodix,gt1151` · `gpio-keys` · `gpio-leds` · `hynitron,hyn_ts` · `inside-secure,safexcel-eip97` · `mediatek,dsi_te-eint` · `mediatek,mrdump_ext_rst-eint` · `mediatek,mt6873-uart-dma,mediatek,mt6577-uart-dma` · `mediatek,aes_top0` · `mediatek,alsps` · `mediatek,amms` · `mediatek,ap2woccif` · `mediatek,ap_ccif0` · `mediatek,ap_ccif1` · `mediatek,ap_ccif2` · `mediatek,ap_ccif3` · `mediatek,ap_ccif4` · `mediatek,ap_ccif5` · `mediatek,apmixed` · `mediatek,apxgpt` · `mediatek,atf_logger` · `mediatek,audio_sram` · `mediatek,barometer` · `mediatek,bcrm_ao_peri` · `mediatek,bcrm_fmem` · `mediatek,bcrm_fmem_ao` · `mediatek,bcrm_infra` · `mediatek,bcrm_peri` · `mediatek,bcrm_peri2` · `mediatek,bcrm_peri_ao` · `mediatek,bcrm_peri_ao2` · `mediatek,bcrm_peri_par_ao` · `mediatek,buck_boost` · `mediatek,bus_dbg-v2` · `mediatek,cap_touch` · `mediatek,chipid` · `mediatek,cldma_sys_ap` · `mediatek,clk-bring-up` · `mediatek,clock_buffer` · `mediatek,cmdq-test` · `mediatek,colgin-sgmiisys_0,syscon` · `mediatek,colgin-sgmiisys_1,syscon` · `mediatek,colgin-sgmiisys_phy_0,syscon` · `mediatek,colgin-sgmiisys_phy_1,syscon` · `mediatek,connac2-gps` · `mediatek,cpupm-sysram` · `mediatek,cq_dma` · `mediatek,dbg_tracker` · `mediatek,dbg_tracker2` · `mediatek,dbgtop` · `mediatek,debug_ao_fmem` · `mediatek,debug_ao_peri` ×2 · `mediatek,debug_ao_peri2` · `mediatek,debug_ao_peri_par` · `mediatek,devapc_ao_fmem` · `mediatek,devapc_ao_infra` · `mediatek,devapc_ao_mm` · `mediatek,devapc_ao_peri` · `mediatek,devapc_ao_peri2` · `mediatek,devapc_ao_peri_par` · `mediatek,devapc_peri` · `mediatek,devapc_peri2` · `mediatek,devinfo` · `mediatek,dfd` · `mediatek,direct_charger_1` · `mediatek,disp_aal0` · `mediatek,disp_ccorr0` · `mediatek,disp_color0` · `mediatek,disp_dither0` · `mediatek,disp_gamma0` · `mediatek,disp_mutex0` · `mediatek,disp_ovl0` · `mediatek,disp_pwm0,mediatek,mt6890-disp-pwm` · `mediatek,disp_rdma0` · `mediatek,disp_wdma0` · `mediatek,dispsys` · `mediatek,dpmaif` · `mediatek,dpmaif_ao` · `mediatek,dramc_ch0_top0` · `mediatek,dramc_ch0_top1` · `mediatek,dramc_ch0_top2` · `mediatek,dramc_ch0_top3` · `mediatek,dramc_ch0_top4` · `mediatek,dramc_ch0_top5` · `mediatek,dramc_ch0_top6` · `mediatek,dramc_ch1_rsv0` · `mediatek,dramc_ch1_rsv1` · `mediatek,dramc_ch1_top0` · `mediatek,dramc_ch1_top1` · `mediatek,dramc_ch1_top2` · `mediatek,dramc_ch1_top3` · `mediatek,dramc_ch1_top4` · `mediatek,dramc_ch1_top5` · `mediatek,dramc_ch1_top6` · `mediatek,dramc_ch2_top0` · `mediatek,dramc_ch2_top1` · `mediatek,dramc_ch2_top2` · `mediatek,dramc_ch2_top3` · `mediatek,dramc_ch2_top4` · `mediatek,dramc_ch2_top5` · `mediatek,dramc_ch2_top6` · `mediatek,dramc_ch3_top0` · `mediatek,dramc_ch3_top1` · `mediatek,dramc_ch3_top2` · `mediatek,dramc_ch3_top3` · `mediatek,dramc_ch3_top4` · `mediatek,dramc_ch3_top5` · `mediatek,dramc_ch3_top6` · `mediatek,dsi0` · `mediatek,dvfsrc-helper` · `mediatek,dvfsrc-met` · `mediatek,dxcc_sec` · `mediatek,eth-mac` ×2 · `mediatek,evb6890v1_64_cpe_nand,mediatek,mt6890` · `mediatek,extcon-usb` · `mediatek,fpga-u3phy` · `mediatek,g3d_config` · `mediatek,g3d_dvfs` · `mediatek,g3d_testbench` · `mediatek,generic-tphy-v2` · `mediatek,gpio` · `mediatek,gpio_usage_mapping` · `mediatek,gps-reserve-memory` · `mediatek,gpufreq` · `mediatek,gsensor` · `mediatek,i2c` ×6 · `mediatek,i2c_common` · `mediatek,i2c_lcd_bias` · `mediatek,idle-state` ×3 · `mediatek,infra_device_mpu` ×2 · `mediatek,infra_dpmaif` · `mediatek,infra_mbist` · `mediatek,infracfg` · `mediatek,infracfg_ao,syscon,simple-mfd` · `mediatek,infracfg_ao_mem` · `mediatek,infracfg_mem` · `mediatek,iocfg_tl` · `mediatek,kp` · `mediatek,leakage` · `mediatek,leopard-ethsys,syscon,simple-mfd` ×2 · `mediatek,lpm-sysram` · `mediatek,mailbox-gce` · `mediatek,mali,arm,mali-midgard,arm,mali-bifrost` · `mediatek,mbist_ao` · `mediatek,mcupm` · `mediatek,mcupm-dvfsp` · `mediatek,mcusys-ctrl` · `mediatek,md-cooler-mutt_cc` · `mediatek,md-cooler-scg-off` · `mediatek,md-cooler-tx-pwr` · `mediatek,md-cooler-ul-control` · `mediatek,md-rf` · `mediatek,md1_sim1_hot_plug_eint-eint` · `mediatek,md1_sim2_hot_plug_eint-eint` · `mediatek,md2md_md2_ccif0` · `mediatek,md_ccif0` · `mediatek,md_ccif1` · `mediatek,md_ccif2` · `mediatek,md_ccif3` · `mediatek,md_ccif4` ×2 · `mediatek,md_ccif5` · `mediatek,mddriver` · `mediatek,mdp_rdma0` · `mediatek,mdp_rsz0` · `mediatek,mdp_tdshp0` · `mediatek,mdp_wrot0` · `mediatek,medmcu` · `mediatek,mipi_tx0` · `mediatek,mm_vpu_m0_sub_common` ×2 · `mediatek,mm_vpu_m1_sub_common` ×5 · `mediatek,mmsys_config` · `mediatek,modem_temp_share` · `mediatek,msensor` · `mediatek,mt-pmic` · `mediatek,mt2735-gmac` · `mediatek,mt6297-md-cooler-mutt` · `mediatek,mt6315,mtk,spmi-pmic` · `mediatek,mt6315_5-regulator` · `mediatek,mt6330` · `mediatek,mt6330-efuse` · `mediatek,mt6330-keys` · `mediatek,mt6330-pmic-temp` ×4 · `mediatek,mt6330-regulator` · `mediatek,mt6330-rtc` · `mediatek,mt6330-spmi_p` · `mediatek,mt6330_leds` · `mediatek,mt63xx-ot-debug` · `mediatek,mt6765-auxadc` · `mediatek,mt6765-spi` ×4 · `mediatek,mt6765-spi-slave,mediatek,mt8512-spi-slave` · `mediatek,mt67xx-rng` · `mediatek,mt6873-uart,mediatek,mt6577-uart` ×3 · `mediatek,mt6880-board-ntc` ×4 · `mediatek,mt6880-consys` · `mediatek,mt6880-dcm` · `mediatek,mt6880-devapc` · `mediatek,mt6880-dramc,mediatek,common-dramc` · `mediatek,mt6880-emicen,mediatek,common-emicen` · `mediatek,mt6880-emichn,mediatek,common-emichn` · `mediatek,mt6880-emiisu,mediatek,common-emiisu` · `mediatek,mt6880-emimpu,mediatek,common-emimpu` · `mediatek,mt6880-fhctl` · `mediatek,mt6880-lvts` · `mediatek,mt6880-m4u` · `mediatek,mt6880-m4u-debug` · `mediatek,mt6880-mhccif` · `mediatek,mt6880-mmc` ×2 · `mediatek,mt6880-mt6359-sound` · `mediatek,mt6880-nfc` · `mediatek,mt6880-pcie` ×4 · `mediatek,mt6880-pcie-ep` · `mediatek,mt6880-pcie-phy` ×4 · `mediatek,mt6880-pinctrl` · `mediatek,mt6880-pmif-m,syscon` · `mediatek,mt6880-pmif-p` · `mediatek,mt6880-pwm` · `mediatek,mt6880-smi-common` ×2 · `mediatek,mt6880-smi-larb` · `mediatek,mt6880-sound` · `mediatek,mt6880-trm` · `mediatek,mt6880-wdt,mediatek,mt6589-wdt,syscon,simple-mfd` · `mediatek,mt6890-apmixedsys,syscon` · `mediatek,mt6890-audsys,syscon` · `mediatek,mt6890-dbgsys_dem,syscon` · `mediatek,mt6890-dbi0` · `mediatek,mt6890-dvfsrc` · `mediatek,mt6890-eth,syscon` · `mediatek,mt6890-gce,syscon` · `mediatek,mt6890-imp_iic_wrap_e,syscon` · `mediatek,mt6890-infracfg_ao,syscon` · `mediatek,mt6890-mfgsys,syscon` · `mediatek,mt6890-mmsys_config,syscon` · `mediatek,mt6890-pericfg,syscon` · `mediatek,mt6890-scpsys,syscon` · `mediatek,mt6890-topckgen,syscon` · `mediatek,mt753x` · `mediatek,mt753x-port` ×2 · `mediatek,mtk-lpm` · `mediatek,mtk-xhci` · `mediatek,mtu3` · `mediatek,nli_arb` · `mediatek,pcie-mirror` · `mediatek,pericfg` · `mediatek,pmic-auxadc,mediatek,mt6330-auxadc` · `mediatek,pmic_clock_buffer` · `mediatek,pwm-leds` · `mediatek,pwrmcu` · `mediatek,reserve-memory-mcupm_share` · `mediatek,reserve-memory-medmcu_share` · `mediatek,reserve-memory-sspm_share` · `mediatek,reserved` ×15 · `mediatek,scpsys-bring-up` ×4 · `mediatek,security_ao` · `mediatek,sej` · `mediatek,sgmii-bring-up` ×4 · `mediatek,sgmii0` · `mediatek,sgmii1` · `mediatek,slave_charger` · `mediatek,sleep,syscon` · `mediatek,sleep_sram` · `mediatek,spmtwam` · `mediatek,sramrom` · `mediatek,srclken` · `mediatek,sspm` · `mediatek,sys_cirq` · `mediatek,sys_cirq1` · `mediatek,sys_cirq2` · `mediatek,sys_timer,mediatek,mt6765-timer` · `mediatek,tinsys` · `mediatek,topckgen,syscon` · `mediatek,topckgen_ao` · `mediatek,topmisc` · `mediatek,touch` · `mediatek,trng` · `mediatek,typec_switch` · `mediatek,usb_type_c` · `mediatek,wed` · `mediatek,wed-wdma` · `mediatek,wed2` · `mediatek,wocpu0_emi` · `mediatek,wocpu0_msg` · `mediatek,wocpu1_emi` · `mediatek,wocpu1_msg` · `mediatek,wocpu_boot` · `mediatek,wocpu_data` · `mediatek,wocpu_dlm` · `mediatek,wocpu_sysram` · `operating-points-v2` ×2 · `ql,quectel-power` · `quectel,spi-mtk-slave` · `quectel-phys-scan` · `regulator-fixed` ×9 · `richtek,rt9467` · `silabs,proslic_spi` · `simple-bus` ×2 · `snps,dwmac-mdio` · `syscon-reboot-mode` · `ti,syscon-reset` ×2

</details>

The tree is a reference-board **EVB** tree (`evb6890v1_64_cpe_nand`) with phone leftovers that do nothing on a CPE:
display (`disp_*`, `dsi0`, `mipi_tx0`, LCM names in `/chosen`), I²C1 sensors (`barometer@76`, `msensor@0c`,
`gsensor@6a`, `alsps@60`), chargers (`rt9467`, `slave_charger`, `direct_charger_1`), touch controllers
(`goodix,gt1151`, `focaltech,fts`, `hynitron,hyn_ts`), GPU (`mali`), audio (`mt6880-mt6359-sound`) and NFC. A clean
board DTS would drop them. Since the stock boot image is kept, this port does not ship a DTS at all.

### 3.2 Memory layout

| Node | Value (`#address-cells = #size-cells = 2`) | Note |
|---|---|---|
| `/memory@40000000` | base `0x4000_0000`, size `0x1e80_0000` (488 MiB) | static |
| `/memory` (second node) | static: base `0x4000_0000`, size `0x3e60_5000` (~998 MiB); **live: size `0x4000_0000` (1 GiB)** | rewritten by LK, live FDT adds `mblock_info` |
| `/reserved-memory/wocpu0_emi@50000000` | `0x5000_0000` + 512 KiB, no-map | WED/WO CPU (Wi-Fi offload) |
| `/reserved-memory/wocpu1_emi@50040000` | `0x5008_0000` + 512 KiB (node name disagrees with its `reg`) | WO CPU 1 |
| `/reserved-memory/wocpu_data@50100000` | `0x5010_0000` + 1.5 MiB | WO data |
| `/reserved-memory/wocpu0_msg@50280000` | `0x5028_0000` + 1.5 MiB | WO mailbox |
| `/reserved-memory/wocpu1_msg@50400000` | `0x5040_0000` + 1.5 MiB | WO mailbox |
| dynamic pools | `gps-reserve-memory` 0x60000, `mcupm_share` 0x210000, `medmcu_share` 0x328700, `sspm_share` 0x210000 | placed by the kernel |
| modem / mblock | not in the static tree | LK adds `mblock-*` reservations, including the modem's |

Usable RAM after the modem and WO carve-outs is well below 1 GiB (a figure of ~643 MB has been reported but not
measured, U3). Kernel side: `CONFIG_ARM64_VA_BITS=39`, 4 KiB pages, built-in `vmalloc=496M`
(kernel.config:239,389,460).

### 3.3 Subsystems: nodes, vendor drivers, and what a mainline 6.x kernel would need

This section shows why the port keeps the vendor kernel. The "vendor driver" column comes from kernel.config. The
"mainline 6.x" column is an assessment against upstream as of roughly v6.6–6.12; no mainline tree was grepped, so
it is UNVERIFIED (U4). Platform-wide gaps (clocks, power, pinctrl, PMIC) affect every row and are listed first.

**Common to every subsystem (MT6890 SoC base).** Nodes: `mediatek,mt6890-topckgen`, `mt6890-apmixedsys`,
`mt6890-infracfg_ao`, `mt6890-pericfg`, `mt6890-scpsys`, `mt6880-pinctrl` (`/pinctrl@10005000`),
`mt6880-pmif-m`/`-p` (SPMI), `mediatek,mt6330` PMIC (regulators, rtc, keys, leds, auxadc, efuse), `mt6315` buck,
`mt6890-dvfsrc`, `mt6880-devapc`, `mt6880-emi*`/`dramc`, `mailbox-gce` (CMDQ), `mcupm`/`sspm`/`medmcu`. Mainline has
**none** of the MT6890/MT6880 **clock driver**, **pinctrl** (vendor `PINCTRL_MT6880=y`), **scpsys power-domain data**
or **MT6330 PMIC MFD/regulator** drivers. MT6315 (`mediatek,mt6315-regulator`) and the SPMI PMIF framework (only
`mt6873`/`mt8195` data) exist upstream. Generic parts that should work with the right compatibles: GICv3, the arch
timer, PSCI 0.2, 8250_mtk UART (`mediatek,mt6577-uart` fallback present), the watchdog (`mediatek,mt6589-wdt`
fallback present), `mt6577_auxadc`, and `inside-secure,safexcel-eip97`.

| Subsystem | Router DT nodes (status) | Vendor driver (kernel.config) | What a mainline 6.x kernel would need |
|---|---|---|---|
| **NAND / MTD** | `/nfi@11005000` `mediatek,mt6880-nfc` **okay**; pins `pinctrl/nandcdefault`. **No partition node** in the DT | `MTD_NANDX_V2=y` (MTK "nandx"), `MTD_PMT_PARTS=y` (MTK PMT table), `QL_MTD_ERASE_COUNT=y`; `MTD_NAND_MTK` **not set** (1565) | (a) NFI/ECC: mainline `mtk_nand.c` + `mtk_ecc.c` only match `mt2701/mt2712/mt7622-nfc`; `mt6880-nfc` would need new SoC data and register validation, and might not be compatible at all. (b) **PMT partition parser**: absent upstream, so either write a `mtdparts` parser or freeze the 49 partitions as `fixed-partitions` in the DTS (offsets come from `/proc/mtd`; the stock firmware has only names, `etc/setup_link.sh`). (c) Bad-block/BMT compatibility with the vendor layout: high risk of corrupting `misc`/`nvdata`. Raw vs SPI-NAND is UNVERIFIED. |
| **Wi-Fi** | `/wed@15010000` `mediatek,wed` (`wed_num=2`, `pci_slot_map=<0 1>`), `/wed2@15011000`, `/wdma@15102800` `wed-wdma`, `/ap2woccif@151A9000`, `/wocpu@15180000`, `/wocpu_dlm`, `/wocpu_boot`, `/wo@15195000` (ethsys-like syscon), 5 WO reserved-memory regions. **The MT7915 itself has no node** (a PCIe endpoint) | `mt_wifi.ko` (**proprietary**, WEXT/ioctl, `CFG80211` not set), `mtk_warp*.ko` (WED/WO), `wifi_md_coex.ko`; fw `WIFI_RAM_CODE_MT7915.bin`, `7915_WACPU_RAM_CODE_release.bin`, `mt7915_rom_patch_e1/e2` (strings), `/lib/firmware/mt7915_patch_e2_hdr.bin`; l1profile `INDEX0=MT7915D` DBDC, `ra0`/`rai0` | **`mt76`/`mt7915e`** already drives MT7915 over PCIe (mac80211/nl80211) with linux-firmware `mediatek/mt7915_{wm,wa,rom_patch}.bin`. Needs: (a) working PCIe (row below); (b) the EEPROM/calibration image as `nvmem`/`mediatek,mtd-eeprom` (vendor keeps `e2p`, 0x20000 B, in `INDEX0_EEPROM_size`; X28 puts it in `nvcfg`); (c) WED offload: mainline `mtk_wed` supports only `mt7622/mt7986/mt7988-wed`, so `mediatek,wed`/`wed2` and the WO CPU on MT6890 would need porting. Without WED, Wi-Fi works with CPU forwarding only. `wifi_md_coex` (modem↔Wi-Fi coexistence over CCCI) has no upstream counterpart. |
| **Cellular / modem** | `/mddriver` `mediatek,mddriver` (`mdhif_type=2`, `cldma_capability=2`, power-domain), `/dpmaif@10014000` `mediatek,dpmaif`, `/dpmaif_ao`, `/infra_dpmaif`, `/cldma_sys_ap`, `/ap_ccif0..5`, `/md_ccif0..5`, `/md2md_md2_ccif0`, `/mhccif@10024000` (**disabled**), `/modem_temp_share`, `/spmi/md1_sim{1,2}_hot_plug_eint` **okay**, `/simcards` (`usim0`, `usim1`), `md-cooler-*`, `md-rf`, `mt6297-md-cooler-mutt` | **Built-in:** `MTK_CCCI_DEVICES`, `MTK_ECCCI_DRIVER`, `ECCCI_CCIF`, `ECCCI_C2K`, `MTK_NET_CCMNI`, `MTK_HSAPIF_DRIVER`, `MTK_MD1_SUPPORT=24`, `ECCCI_PLATFORM="mt6890"` (1805-1815). Userspace: `ccci_fsd`, `ccci_mdinit`, `nvram_daemon`, `ql_ril_service`, `ql_netd`, `mipc_submonitor`, `atcid`, `mtk_netagent`, `mipc_wan_cli`/`libmipc_msg.so` → `/dev/ttyCMIPC*`; netdevs `ccmni0..` | **No upstream equivalent.** Mainline `drivers/net/wwan/t7xx` targets MediaTek T700 as an external **PCIe** modem (CLDMA + DPMAIF over PCIe), not the on-die MD1 on MT6890 (CCIF + DPMAIF via EMI). A port would need: an ECCCI core (CCIF mailbox, shared-memory layout, MD boot handshake), DPMAIF data path → WWAN netdevs, CLDMA control path, the MIPC/AT tty ports, EMI-MPU protection (`mtk_emimpu_*`), MD power and SPM control, modem image loading (`md1img`, `md1dsp`, currently LK + `ccci_mdinit`), and the MD thermal/cooling interfaces. **This is the single biggest blocker for a mainline kernel.** |
| **Ethernet + switch** | `/ethernet@15100000` `mediatek,mt6890-eth` **okay**: `mac@0` `2500base-x` fixed-link 2500 (to the switch), `mac@1` `sgmii` fixed-link 1000 with `mdio-bus/eth-phy@1` (`ql,gpio-names=eth_cable_det`, `phy_reset-gpios`); `/sgmiisys@10060000`/`@10070000` `mediatek,colgin-sgmiisys_0/1`; `/sgmiiphy@11ED0000`/`@11EE0000`; `/ethsys@15000000` `leopard-ethsys`; `/gsw@0` `mediatek,mt753x` **okay** (`portmap="llllw"`, reset-gpio, irq; `port@5`/`port@6` sgmii 2500); `/quectel-phys@0` `quectel-phys-scan`; `/ethernet@11021000` `mediatek,mt2735-gmac` (stmmac) status `"disable"`, with mdio PHYs `id0243.0d90`@5, `ieee802.3-c45`@7, `id0022.1640`@4 | `NET_MEDIATEK_SOC=y` (vendor `mtk_eth_soc`), `MT753X_GSW=y` (vendor swconfig GSW, `NET_DSA` **not set**, 1203), `HW_NAT=y` + `hw_nat.ko`, `swconfig` built-in; stock UCI `switch0` VLANs 1-4 with port 5 tagged | (a) `mtk_eth_soc`: mainline knows mt7621/7622/7623/7629/7981/7986/7988 but has no `mt6890-eth` SoC data (NETSYS version, register map, QDMA/PDMA layout all unverified). (b) SGMII: mainline `pcs-mtk-lynxi` + `mediatek,mt7986-sgmiisys`-style bindings, which would need `colgin` data. (c) **Switch: mainline DSA `mt7530` supports MT7531** over MDIO (`mediatek,mt7531`). That is the most portable piece, but stock UCI/VLAN semantics move from swconfig to DSA/bridge-VLAN. (d) HNAT/PPE: mainline flow offload (`mtk_ppe`) exists only for supported NETSYS versions. (e) The stmmac `mt2735-gmac` is disabled here; mainline `dwmac-mediatek` has no mt2735 data. PHY ID `0x00221640` = Micrel/Microchip KSZ9131 family (supported); `0x02430d90` unknown; the probable RTL8221B on mac@1 (from `ql_wan_lan_auto_adapt_8221_disable` in UCI) is UNVERIFIED. |
| **PCIe** | `/pcie@11280000`, `/pcie@11288000`, `/pcie@11290000`, `/pcie@11298000`, all `mediatek,mt6880-pcie` **okay**, each with `legacy-interrupt-controller`, `phy-names=pcie-phy`, power-domain; `/phy0..3` `mediatek,mt6880-pcie-phy`; `/pcie_ep@11280000` `mt6880-pcie-ep` **disabled**; `/pcie_mirror@10201000`; pinctrl `pcie0..3-default` | `PCIE_MEDIATEK_GEN3=y` (338), `PCIE_MEDIATEK` not set, `PHY_MTK_PCIE=y` | Mainline `pcie-mediatek-gen3.c` (mt8192/mt8195/mt8188/mt7986 fallback) is the right family: add `mediatek,mt6880-pcie` (or a gen3 fallback compatible) plus SoC quirks. `phy-mtk-pcie.c` (`mt8195-pcie-phy`) needs mt6880 efuse/lane data. Clocks and power domains are blocked by the missing clock and scpsys drivers. Which of the 4 ports carries the MT7915 is UNVERIFIED (`pci_slot_map=<0 1>` hints at slots 0/1; l1profile `INDEX0_pcie_slot=0000`). |
| **I²C** | `/i2c0..5@11c4x000` `mediatek,i2c` (+ `/i2c_common`); children are mostly EVB phone parts. Useful for a CPE: `i2c3/usb_type_c@4e` (X28: fusb304) | vendor `mediatek,i2c` driver; `I2C_MT65XX` **not set** (2786) | Mainline `i2c-mt65xx` binds SoC-specific compatibles (`mt6577/mt8173/mt8183/mt8192-i2c`…). `mediatek,i2c` is not one of them, so new compatible data is needed (a v3 controller is likely; UNVERIFIED). There is probably no CPE-critical consumer apart from the Type-C controller. |
| **Thermal** | `/lvts@1100b000` `mediatek,mt6880-lvts` (nvmem `e_data1`, resets); `/thermal-ntc1..4` `mt6880-board-ntc`; `/thermal_risk_monitor` `mt6880-trm`; `/thermal-zones/{soc_max,cpu_little0-3,gpu0/1,dramc,mmsys,md_5g,md_4g,md_3g,soc_dram_ntc,nrpa_ntc,ltepa_ntc,rf_ntc,pmic,pmic_vcore,pmic_vproc,pmic_vgpu,md_rf,conn_gps}`; `mt6330-pmic-temp` ×4; `md-cooler-*` | `MTK_THERMAL=y`, `MTK_PMIC_THERMAL`, `MTK_MD_THERMAL*`, `MTK_THERMAL_IPI/TRM`, gov step_wise + power_allocator | Mainline `lvts_thermal.c` covers mt7988/mt8188/mt8192/mt8195, **not mt6880**, so LVTS needs new SoC data and calibration layout. Board NTCs could use `generic-adc-thermal` on `mt6577_auxadc`. The modem zones (`md_5g`…) rely on CCCI/IPI, which doesn't exist upstream. Without these, the 5G PA would run with **no thermal throttling**. |
| **USB** | `/usb@11201000` `mediatek,mtu3` (`dr_mode=otg`, super-speed, `usb-role-switch`, `ql,gpio-names=usb_iddig`), `/usb@11201000/xhci0@11200000` `mediatek,mtk-xhci`, `/usb-phy@11e30000` `mediatek,generic-tphy-v2` (`usb2-phy0`, `usb3-phy0` okay), `/usb-phy` `fpga-u3phy` disabled, `/typec_switch`, `/extcon_usb` | `USB_MTU3` dual role, `USB_XHCI_MTK`, `PHY_MTK_TPHY`, gadget RNDIS/ACM/MSC/FFS built-in; X28 found its stock modem stack (`atcid`) needs an ACM gadget | **Closest to mainline:** `mtu3` and `xhci-mtk` both accept the generic `mediatek,mtu3` / `mediatek,mtk-xhci` fallbacks, and `phy-mtk-tphy` supports `mediatek,generic-tphy-v2`. What's left: clocks/power domains (same base gap) and the vendor `mediatek,clk-mgr`/`force-vbus` properties. |

Other board nodes (relevant to userspace integration, not driver porting):

* **Buttons** `/gpio-keys`: `button0` "RESTORE_KEY" (`linux,code=6`, GPIO 6), `button1` "WPS_KEY" (`linux,code=7`,
  GPIO 7, debounce 10 ms). Codes 6/7 are not `KEY_RESTART` (0x198) / `KEY_WPS_BUTTON` (0x211), so OpenWrt's
  `/etc/rc.button` mapping needs a remap or hotplug shim (U16).
* **LEDs** `/gpio_leds` (`led9501:red:sim`, `led9502:red:cellular-stat`, `led9504:red:cellular-data`,
  `led9505:red:cellular-rat`, `led9506:red:cellular-ims`, `led9507/8/9 nr-rssi` RGB, `led9510/11/12 lte-rssi` RGB,
  `led9513/14/15 power` RGB) and the PMIC `mt6330-led` Isink1-3 (`led9515/16/17 wifi-led` RGB; the labels duplicate
  `led9515`). The `01_leds` board script only defines LEDs that actually appear in `/sys/class/leds` (U15).
* **Quectel glue**: `ql,quectel-power@0` (`dtr_wake` GPIO), `spi0/spidev_user@0` `quectel,spi-mtk-slave`,
  `quectel-phys-scan`. Left to the vendor kernel.

### 3.4 Stock rootfs UBI geometry

| Property | Value |
|---|---|
| PEB size | 262,144 B (256 KiB) |
| EC header | offset 0, magic `UBI#` (big-endian) |
| VID header | offset 4096, magic `UBI!` |
| Data offset | 8192 |
| LEB size | **253,952 B** (262,144 − 4096 − 4096) |
| Slot size | 256 PEB = 64 MiB (`rootfs_a` mtd29, `rootfs_b` mtd42) |
| Stock volume table (layout volume `0x7fffefff`) | vol 0 `rootfs` 105 reserved PEB (squashfs v4, xz, 4631 inodes, built 2024-10-23); vol 1 `rootfs_data` 135 PEB (UBIFS magic `0x06101831`) |
| Fastmap | not enabled (`MTD_UBI_FASTMAP` not set) |

The port's image reuses this geometry exactly. Its volumes are both dynamic: `rootfs` sized to the squashfs
(27 PEB in the final build) and `rootfs_data` with autoresize, formatted by fstools on first boot.

---

## 4. Kernel config delta

Targeted greps of `kernel.config` (line numbers shown) against what an **OpenWrt 24.10 userspace** assumes
(fw4/nftables, procd-ujail, mac80211 tooling, wpad, etc.).

| # | CONFIG (line) | Vendor value | 24.10 expects | Port implication |
|---|---|---|---|---|
| 1 | `NF_TABLES` (995) | **not set** | `=y/m` (fw4 + nftables are the default firewall) | **Drop `firewall4`/`nftables`/`kmod-nft-*`; use `firewall` (fw3) + `iptables-legacy`/`ip6tables-legacy`.** fw3 still exists in the 24.10 feeds. LuCI `luci-app-firewall` works with fw3 (X28 does this on 23.05). **Confirmed for 24.10 by this build.** |
| 2 | `NETFILTER_XTABLES` (996), `IP_NF_IPTABLES` (1115), `IP6_NF_IPTABLES` (1144), `NF_CONNTRACK` (961), `NF_NAT` (988) | `=m` | — | All present as stock `.ko` (§2). fw3 needs `ipt_MASQUERADE`, `xt_conntrack`, `xt_state`, `nf_reject_*`, all present. Missing: `ip6table_raw`, `xt_hashlimit`, `xt_iprange` (1057 not set), `xt_owner` (1066 not set), `xt_socket`/`TPROXY` (1028/1076 not set), `xt_cgroup`. |
| 3 | `NF_NAT_IPV6` (1143), `IP6_NF_NAT` (1162) | **not set** | optional | No IPv6 NAT/masquerade. Fine for a routed /64, but fw3 `masq6` will fail. |
| 4 | `NF_FLOW_TABLE` / `NETFILTER_XT_TARGET_FLOWOFFLOAD` | absent | used by fw4/fw3 `flow_offloading` | No software flow offload. Hardware offload goes only through the vendor `hw_nat` (PPE hooks in vmlinux). Leave fw3 `flow_offloading` off. |
| 5 | `NAMESPACES` (145) | **not set** | procd-ujail, seccomp-jailed services | **Remove `procd-ujail`, `procd-seccomp`** (X28: jailed dnsmasq/sysntpd exited at start otherwise). |
| 6 | `SECCOMP` (419) | **not set** | `procd-seccomp`, `ujail` | As above. |
| 7 | `CFG80211` (1365) / `MAC80211` | **not set** | `wpad`, `hostapd`, `iw`, `iwinfo` nl80211 | **No nl80211.** Drop `wpad-*`/`hostapd`/`iw`. Wi-Fi uses a custom netifd wireless handler for `mt_wifi` (`mtwifi`, §8.4) over the stock `.dat` profiles. |
| 8 | `WLAN_VENDOR_MEDIATEK` (2431) | `y`, with every `MTK_COMBO_*_WIFI` not set (1842) | — | Only the out-of-tree `mt_wifi.ko` (MT7915 PCIe) provides Wi-Fi. |
| 9 | `MTD` (1454), `MTD_PMT_PARTS` (1489), `MTD_NANDX_V2` (1510), `MTD_NAND_MTK` (1565) | `y`, `y`, `y`, not set | OpenWrt nand.sh assumes named mtd partitions | Partition names come from PMT (seen in `/proc/mtd`, linked by `etc/setup_link.sh`). `fstools`/sysupgrade must use names, never numbers. |
| 10 | `MTD_UBI` (1573), `MTD_UBI_BLOCK` (1578), `MTD_UBI_FASTMAP` (1576), `MTD_UBI_BEB_LIMIT` (1575) | `y`, `y`, not set, `3` | `ubiblock` root + UBIFS overlay (standard `nand.sh` layout) | Root is `ubiblock0_0` squashfs and the overlay is the `rootfs_data` UBIFS. **This matches OpenWrt's standard UBI layout**, so `fstools`/`mount_root` works unchanged. No fastmap, so attach time scales with partition size. |
| 11 | `SQUASHFS` (5448) / `SQUASHFS_XZ` (5458) / `SQUASHFS_ZLIB` (5455) / `SQUASHFS_LZ4`/`ZSTD` (5456/5459) | `y`/`y`/`y`/not set | 24.10 mksquashfs default xz | OK. Don't enable zstd squashfs. |
| 12 | `UBIFS_FS` (5439) LZO+ZLIB, `UBIFS_FS_ADVANCED_COMPR` (5440) not set; `OVERLAY_FS` (5355); `JFFS2_FS` (5430) | `y` | overlayfs + UBIFS | OK. `mkfs.ubifs` must use `-x lzo` or `zlib`, **not zstd**. |
| 13 | `DEVTMPFS` (1406), `UEVENT_HELPER` (1404) | not set / `y` | procd mounts `tmpfs` on `/dev` and creates nodes via hotplug | Works on stock 19.07 procd. **UNVERIFIED on hardware** with 24.10 procd (it still handles no-devtmpfs, but the `/dev/tty*`/`ttyCMIPC*` node creation timing needs a test). |
| 14 | `FHANDLE` (171), `TMPFS_XATTR` (5401), `TMPFS_POSIX_ACL` (5400) | not set | — | No `open_by_handle_at`. Some 24.10 userspace (e.g. `ubox` logd, `mount_root` xattr on tmpfs) may warn. Low impact. |
| 15 | `CRYPTO_USER_API`/`_HASH`/`_SKCIPHER` (5734-5736) | `=m` (`af_alg`, `algif_*`) | used by some 24.10 tools | OK as stock modules. `cryptodev.ko` is also there. |
| 16 | `CRYPTO_CHACHA20` (5707), `CRYPTO_POLY1305` (5675), `CRYPTO_CHACHA20POLY1305` (5636), `WIREGUARD` (2171) | not set | `kmod-wireguard` | No in-kernel WireGuard. X28 builds `wireguard-linux-compat` against an SDK tree and loads it without CRC checks: **out of scope until we have a matching SDK** (§9). |
| 17 | `CRYPTO_DEV_SAFEXCEL` (5756) | `y` (EIP-97, DT `inside-secure,safexcel-eip97`) | — | HW AES/SHA available to IPsec/OpenSSL (devcrypto); optional. |
| 18 | `MTK_ECCCI_DRIVER`, `MTK_NET_CCMNI`, `MTK_ECCCI_CCIF`, `MTK_ECCCI_C2K`, `MTK_HSAPIF_DRIVER`, `MTK_MD1_SUPPORT=24` (1805-1815) | `y` | — | Modem transport is in vmlinux. **There is no `CONFIG_*MIPC*` symbol.** MIPC is a userspace protocol over CCCI tty ports `/dev/ttyCMIPC0..14` (Image strings, `mipc_wan_cli` strings). The netifd proto just shells out to `mipc_wan_cli`. |
| 19 | `HW_NAT` (1392) | `y` + `hw_nat.ko` | — | PPE hooks in vmlinux, `hw_nat.ko` from stock. `mt_wifi` and `mtk_warp` link against `ra_sw_nat_hook_*`. |
| 20 | `NET_DSA` (1203) / `MT753X_GSW` (2402) / swconfig (stock `modules.d/41-swconfig`, built-in) | not set / `y` / `y` | 24.10 assumes DSA for new targets but still has `swconfig` | **Use `swconfig`** (built into vmlinux; stock UCI `network.eth0=switch`). Board.json must use `"switch"` (swconfig) syntax, not DSA ports. |
| 21 | `BRIDGE_VLAN_FILTERING` (1201), `VLAN_8021Q` (1204) | `y` | 24.10 netifd bridge-vlan | OK for `br-lan` on `eth0.N`. |
| 22 | `USB_*`: `USB_XHCI_MTK` (4119), `USB_MTU3` (4168) dual-role, `USB_CONFIGFS_*` RNDIS/ACM/FFS (4249-4271), `USB_STORAGE` (4145) | `y` | — | The USB gadget is in vmlinux. The modem tools (`atcid`) want an ACM gadget (X28). USB-host storage works. `USB_NET_*` host drivers were not seen (the grep found no `USB_NET_` `=y`/`m`), so no USB tethering dongles. |
| 23 | `TUN` (2184), `PPP` (2407), `L2TP` (1191), `IPV6_TUNNEL` (934), `IPV6_SIT` (933) not set | `y`/`y`/`y`/`y`/n | — | OpenVPN, PPPoE, L2TP, DS-Lite OK. **No 6in4/6rd.** The `464xlat` proto (stock `clatd`) relies on `nat46.ko` (present). |
| 24 | `IKCONFIG_PROC` (106) | `y` | — | `/proc/config.gz` is on the device, so the live config can be diffed against the capture (read-only). |

Also noted: `CONFIG_MODVERSIONS=y` (650), `RANDOMIZE_BASE=y` (454), `STACKPROTECTOR=y` (606), no `KEXEC` (422) (so no
kexec-based recovery), `PSTORE_RAM=y`/`PSTORE_CONSOLE=y` (5470-5483) (oops logs survive a reboot in `/sys/fs/pstore`;
useful for first-boot debugging), `NET_SCH_CAKE` not set (1243) (so no SQM cake; use `fq_codel`/`htb`, both built in or stock).

149 config symbols are `=m`. 136 `.ko` ship. The 13+ missing ones include `MACVLAN`, `VETH`, `VXLAN`, `TAP`, `MACVTAP`,
`BT_HIDP`, `BT_HCIUART`, `BLK_DEV_NBD`, `SPI_SPIDEV`, `HID`, `LCD_CLASS_DEVICE`, `MTK_MET_PLF` and the `SND_SEQ*` set.
They were built but are **not in the stock rootfs**, so the port cannot provide them either. This matters for container-style
packages, which need `veth`.

---

## 5. Precedent: the ZLT X28

The ZLT X28 is another MT6890 CPE with a public OpenWrt project and published design documents (README,
native-cellular, status, build, boot-flow, sysupgrade-design and recovery documents, plus an OpenWrt forum thread).
Everything in this section is X28's own claim about X28. Where our captures agree, that is said explicitly. Their
implementation tooling is not public, so this port re-implements from the published design (clean room).

### 5.1 Same platform, different build

| | ZLT X28 (their docs) | DWR-2000M A3 (our captures) |
|---|---|---|
| SoC / Wi-Fi / switch | MT6890, MT7915 DBDC, MT7531 | MT6890 (`mediatek,mt6890`), MT7915 (mt_wifi strings, l1profile `MT7915D`), `mediatek,mt753x` GSW (MT7531 family) |
| Modem module | Quectel RG500L-EU, USB `2c7c:7003` | SDK `fe_platform_rg500l_t750`; UCI `usb.vid=0x2c7c`, `usb.pid=0x7003`: same |
| Kernel | `4.19.205 (release@vm-mtk5g-96) … Fri Dec 22 2023`, `r0-f6109fc5`, 146 modules | `4.19.205 … Fri Nov 1 2024`, `r0-7bdb3f5e`, **136** modules: **different build** |
| MTD layout | 51 partitions, `user_data` = mtd50, `rootfs_b` = mtd42 | 49 partitions (mtd0..mtd48), `user_data` = **mtd48**, `rootfs_b` = mtd42, `rootfs_a` = mtd29, `misc` = mtd3: **X28's mtd numbers must not be reused** |
| A/B record | `misc` @0x800 `00 41 42 30`, 4 copies at 0x40000 stride | stock `bootctrl.sh`: `BOOTCTRL_OFFSET=2048`, magic `0x00414230`, 3 extra copies at `256*1024*i`: same scheme |
| UBI geometry | PEB 262144, min I/O 4096, VID 4096, LEB 253952; rootfs 124 LEB, rootfs_data 116 LEB | same PEB/VID/LEB; stock vtbl `rootfs` 105, `rootfs_data` 135, 256 PEB = 64 MiB: **different volume sizes** |
| Stock netifd proto | vendor `mipc` | `ql_mipc.sh` (884 lines, Quectel) + `mipc.sh` (576, MTK) |

### 5.2 How X28 integrates the vendor kernel

X28 adds no `target/linux/` directory and never builds or modifies the kernel:

1. **Open half, built in CI**: the official OpenWrt 23.05.5 ImageBuilder for `armsr/armv8` (SHA-256 pinned)
   assembles a rootfs with `-firewall4 -nftables -kmod-nft-offload +firewall +iptables-legacy +ip6tables-legacy`
   plus LuCI. The armsr 5.15 kernel and kmods are discarded.
2. **Vendor half, local only**, from the user's own backup, never committed or uploaded:
   * a staging step keeps the modern core and **replaces all module/autoload files and kernel/kmod package records
     with the stock 4.19.205 ones**, adds ten vendor binaries with their ELF library closure (keeping four 19.07
     compat libraries), imports **no stock init scripts** and deletes every `lib/upgrade/*` and the stock boot-done script;
   * a first-boot policy step (switch VLAN table, `br-lan`, dropbear, stock `swconfig` binary, removal of
     `procd-ujail`, a console getty);
   * an **A/B guard** that walks every boot-reachable script and refuses the build on `ab_image_sync`, the stock
     boot-done script, `bootctrl`, `mtd … write`, `nandwrite`, `ubiformat`, `ubiupdatevol`, `sysupgrade` and
     `of=/dev/{mtd,ubi,block}`, with narrow reviewed exceptions;
   * a UBI packager (squashfs xz 256 KiB blocks, a fresh empty UBIFS, the unit's exact volume reservations, padded
     to 64 MiB) with an independent parser that re-checks every EC/VID header and both layout copies;
   * a flasher that writes **only `rootfs_a`** over the MediaTek download agent.
3. **`boot_a`/`boot_b` are left as they are.** "Vendor-kernel bundling" is simply "don't touch the boot partition and
   put the matching stock `.ko` set in the new rootfs".
4. **Kernel-compatible package feed**: a `kernel` package at `1:4.19.205-x28` (epoch, so it outranks 5.15) plus 180
   empty `kmod-*` stubs for modules the vendor kernel already has.

### 5.3 X28's MIPC protocol design

* The **transport is the vendor CLI**: the proto shells out to the ABI-compatible vendor `mipc_wan_cli`. Our stock
  rootfs has the same CLI (`usr/bin/mipc_wan_cli`, linking `libmipc_msg.so`, `libql_at.so`, `libjson-c.so.2`) and the
  stock protos use the verbs `--data_call_act <json>`, `--data_call_deact[_apn]`, `--check_ia`, `--check_nw_status`,
  `--show_sim_status`, `--get_imei`, `--apn_provision_by_sim`, `--nw_radio_state_set/get` and `--at_cmd`.
* **Lifecycle rules**: setup is refused while the vendor `wan_mgr` runs; operations are serialised; the proto **brings
  the returned `ccmniN` up itself** (the kernel leaves it down after `data_call_act`); it records the CID and
  **teardown deactivates only that CID**, never by APN, never by killing processes.
* **IPv6**: the modem's link-local address is kept and the kernel autoconfigures from the RA; the /64 is delegated to
  the LAN. `mtk_netagent` is **not started** because it forces `CFUN 0/4`.
* **Modem bring-up** before network: `/dev/mtd/<name>` links, `nvram_daemon`, `ccci_fsd`, `ccci_mdinit`,
  `ql_ril_service`, `ql_netd`, `mipc_submonitor`, `atcid` (plus a one-ACM USB gadget), then `AT+CFUN=1`. Our stock
  rootfs has the same init chain (`S001nvram_daemon`, `S002ccci_fsd`, `S003ccci_mdinit`, `S22mtk_netagent`,
  `S85ql_ril_service`, `S85ql_netd.init`, `S96atcid`, `S99mipc_submonitor.init`, `S99mipc_wan.init`).

### 5.4 X28's A/B design

* **Boot control**: `misc` @0x800, magic `\0AB0`, four copies. The preloader picks the higher priority, adds one *try*
  per boot, and at a threshold (decoded as **6**, never observed) gives the other slot priority. The stock boot-done
  script resets tries but also **clones the running slot onto the other** via `ab_image_sync` when the slot isn't
  marked successful. Our stock rootfs has the identical script (146 lines; `ab_image_sync "_b"` at line 42,
  `"_a"` at line 81).
* **Boot-OK writer** (START=96): after the LAN and SSH are up, write 0 to the running slot's tries byte (A 2057,
  B 2061) in each copy with stock `dd-nand`; copy 0x800 last; read back; **never set the success byte**, so the
  preloader's fallback stays armed.
* **Sysupgrade**: target = the slot not booted; format and verify the target first; only then write `misc` (target
  priority up, tries 0, success untouched, four copies, read back); reboot.
* **Rootfs signature**: LK verifies `rootfs_sig_*` certificates (`ROOTFS_SIG_VFY`). On X28 no consumer checking the
  rootfs **content** was found, so a modified rootfs boots with the stock signature. On a verification *error* LK
  halts with no A/B fallback. Our `lk_a.img` has the same `ROOTFS_SIG_VFY Success/Fail` strings, but it is a
  different build (U10).

### 5.5 Recovery path

* No recovery slot. Recovery means **MediaTek preloader USB download mode** (`0e8d:2000` about 1.1 s after power-on)
  with `mtkclient` and a T750 download agent; the DA bundled with mtkclient refuses reads on this SoC family. **The DA
  cannot write `misc`**, so a bad A/B record can only be fixed from a running Linux.
* **UART**: a 3-hole 1.8 V footprint, 921600 8N1, needs a level shifter. Our DTB bootargs also say
  `console=ttyS0,921600n1`.
* `nvdata`, `protect1/2`, `nvram`, `user_data` and the active rootfs change at runtime. Restoring them from an old
  backup **rolls back modem NV / calibration**.
* The first native→native sysupgrade overwrites the stock slot, so **stock fallback exists only until the first
  upgrade**.

**Takeaways adopted:** keep the boot partitions untouched; ship the stock `.ko` set plus a `kernel`/kmod-stub record;
import no stock init scripts that write flash; write a new MIPC proto over `mipc_wan_cli`; reset the tries byte after
a good boot; write the inactive slot first and switch `misc` last.

---

## 6. Target design (as built)

### 6.1 Design decisions

| Decision | Choice | Why |
|---|---|---|
| Kernel | **Not built, not flashed.** `boot_a`/`boot_b` stay stock | §1.2: vmlinux-only symbols + MODVERSIONS |
| What gets written | Only the inactive `rootfs_{a,b}` (64 MiB UBI) and the `misc` boot record | §3.4, §7 |
| Root layout | UBI vol 0 `rootfs` = squashfs-xz (`/dev/ubiblock0_0`), vol 1 `rootfs_data` = UBIFS overlay | stock vtbl + bootargs `root=/dev/ubiblock0_0 rootfstype=squashfs` |
| Firewall | `firewall` (fw3) + `iptables-legacy` | `NF_TABLES` not set (kernel.config:995) |
| Switch | swconfig `switch0` | `NET_DSA` not set, `MT753X_GSW=y` (1203, 2402) |
| Wi-Fi | stock `mt_wifi` + stock Lua stack, driven by a new netifd wireless handler `mtwifi` | `CFG80211` not set (1365) |
| Jail / seccomp | `-procd-ujail -procd-seccomp` | `NAMESPACES`/`SECCOMP` not set (145, 419) |
| Modules | stock 136 `.ko` + `kernel` meta-package `4.19.205` + `kmod-*` stubs for the ~41 built-ins | §2 |
| Names | target **`mt6890`**, subtarget **`vk419`** ("vendor kernel 4.19"), device **`dlink_dwr-2000m-a3`** | leaves `mt6890` open for a future mainline subtarget |

### 6.2 Vendor-kernel bundling in a source-tree target

OpenWrt has no "prebuilt kernel" target type. X28 avoids the question by using the ImageBuilder. This port uses a
**source-tree target that doesn't ship its kernel**, so `make menuconfig` / `make` work as for any target:

1. `target/linux/mt6890/Makefile` declares `KERNEL_PATCHVER:=6.6` only so the 24.10 toolchain and `linux-headers`
   build, plus `CPU_TYPE:=cortex-a55`, `FEATURES:=squashfs nand ubifs pci pcie` and a minimal `config-6.6`. A
   `Kernel/CompileImage` override leaves an empty placeholder; no 6.6 kernel is installed or packaged.
   `DEFAULT_PACKAGES` adds `firewall iptables-legacy ip6tables-legacy swconfig` and removes `firewall4 nftables
   kmod-nft-offload procd-ujail procd-seccomp wpad-basic-mbedtls iw kmod-mt7915e`.
2. Four **local-only** packages under `package/vendor/` (git-ignored), filled by `scripts/import-stock.sh` from the
   user's own dump, every source sha256-pinned:
   * `vendor-kernel-4.19.205`: the 136 modules (pinned against the 12-hex prefixes in §2.1) and `/etc/modules.d`
     autoload lists in stock order; `Provides: kernel (=4.19.205)` plus `kmod-*` stubs for the built-ins.
   * `vendor-mtwifi-fw`: MT7915 firmware and EEPROM images, `l1profile.dat` and `.dat` templates, the stock Lua Wi-Fi
     stack (`/sbin/wifi`, `mtkwifi.lua`, `l1dat_parser.lua`, `datconf`, stock `lua` binary).
   * `vendor-modem-stack`: `ccci_fsd`, `ccci_mdinit`, `nvram_daemon`, `ql_ril_service`, `ql_netd`, `mipc_submonitor`,
     `atcid`, `mipc_wan_cli`, `dd-nand`, their libraries (§8.3) and the APN database, **with their stock init
     scripts stripped**.
   * `vendor-compat-libs`: 19.07 SONAMEs the vendor ELFs need that 24.10 lacks (`libjson-c.so.2`, the 19.07
     `libubox`/`libuci`, …).
3. Image recipe: `Device/dlink_dwr-2000m-a3` with `KERNEL :=`, `KERNEL_INITRAMFS :=`, `KERNEL_IN_UBI :=` empty,
   `BLOCKSIZE 256k`, `PAGESIZE 4096`, `VID_HDR_OFFSET 4096`, `IMAGE_SIZE 64m`:
   * `factory-rootfs.bin`: `append-ubi` (vol0 `rootfs` squashfs, vol1 `rootfs_data` autoresize) padded with `0xff`
     to exactly 67,108,864 B.
   * `sysupgrade.tar`: `sysupgrade-dlink_dwr-2000m-a3/{CONTROL,root,root.sha256}`, the standard OpenWrt NAND tar
     without a `kernel` member.
4. Only the open half is published: target, packages, scripts. Building an image requires your own stock dump.

### 6.3 Directory tree (as published)

```
target/linux/mt6890/
├── Makefile                 BOARD mt6890, cortex-a55, SUBTARGETS vk419, KERNEL_PATCHVER 6.6 (headers only)
├── config-6.6               minimal, never shipped
├── vk419/target.mk          "Vendor 4.19 kernel"
├── image/Makefile           Device/dlink_dwr-2000m-a3: rootfs-only UBI + sysupgrade.tar
└── base-files/etc/
    ├── board.d/01_leds      LEDs that exist in /sys/class/leds
    ├── board.d/02_network   switch0 VLANs, lan, wan = mtkmipc
    ├── inittab              rcS + ttyS0 askfirst console
    ├── init.d/mt6890-links  /dev/mtd/<name> links from /proc/mtd (replaces the stock number-based script)
    └── uci-defaults/90-mt6890-defaults   hostname / timezone defaults
package/
├── mt6890-mtkmipc/          /lib/netifd/proto/mtkmipc.sh + tests (51)
├── mt6890-mtkwifi/          /lib/netifd/wireless/mtwifi.sh, default wireless config, luci.util shim + tests (72)
└── mt6890-sysupgrade/       /lib/upgrade/{platform.sh,mt6890-bootctl.sh}, /usr/bin/mt6890-bootctl,
                             /etc/init.d/mt6890-bootok, /etc/uci-defaults/95-mt6890-uci-migrate + tests (120)
scripts/
├── import-stock.sh          sha256-pinned import of the stock modules and vendor files
├── verify-image.py          offline artefact verifier
└── ab_guard.sh              refuses a rootfs containing the stock slot-cloning logic
```

### 6.4 Network (`base-files/etc/board.d/02_network`)

From stock UCI and the DTB (`gsw@0 portmap "llllw"`, ports 5/6 SGMII):

```sh
ucidef_add_switch "switch0" \
    "0:lan:1" "1:lan:2" "2:lan:3" "3:lan:4" "5t@eth0"
ucidef_set_interface_lan "eth0.1 eth0.2"          # stock: network.lan.ifname='eth0.1 eth0.2'
ucidef_set_interface "wan"  protocol "mtkmipc"    # cellular (stock wan = ql_mipc on ccmni)
```

Stock UCI puts each LAN port in its own VLAN (1→port 0 … 4→port 3, CPU port 5 tagged) and bridges only
`eth0.1 eth0.2`. The stock `99-default_network` claims `wan eth1 / lan eth0`, where `eth1` = `mac@1` (SGMII +
external PHY with `eth_cable_det`). Physical port labels, the role of `eth1` and whether port 4 (`w` in `llllw`) is
wired are UNVERIFIED (U7).

---

## 7. A/B boot control

### 7.1 The `misc` boot record

| Field | Value |
|---|---|
| Partition | `misc` (mtd3), located by **name** from `/proc/mtd` |
| Offset | 2048 (`0x800`) |
| Magic | `00 41 42 30` (`\0AB0`, `0x00414230`) at +0 |
| Slot A | +8 priority, +9 tries, +10 success, +11 uptype |
| Slot B | +12 priority, +13 tries, +14 success, +15 uptype |
| Copies | 4, at `256 KiB × i` (seek 2048, 264192, 526336, 788480) |
| Stock read | `nanddump --skip-bad-blocks-to-start -l 2064` + hexdump (`bootctrl.sh:57-66`) |
| Stock write | `echo -n -e '\x..' \| dd-nand of=misc seek=N bs=1 count=K` on every copy (`bootctrl.sh:68-105`) |
| Active slot | the higher priority byte; equal priorities are an error (`bootctrl.sh:263-273`) |
| Switch (stock intent) | target prio `0f`, tries `03`, success `00`; other prio `0e` (`bootctrl.sh:187-261`) |

### 7.2 Stock sysupgrade, step by step

| What | Stock behaviour | Ref (stock `lib/upgrade/`) |
|---|---|---|
| check_image | gzip magic `1f8b` only | platform.sh:205-216 |
| A/B detect | misc magic @2048 == 0x00414230 | bootctrl.sh:178-185 |
| target | the other slot (`_a` running → `*_b`) | bootctrl.sh:380-435 |
| rootfs write | `mtd erase rootfs_b`, then the squashfs member streamed into `mtd write - rootfs_b` | platform.sh:97-101 |
| rest of slot | `clone_non_update_images`: nanddump other slot → mtd write | bootctrl.sh:351-372 |
| switch | change_slot_info (prio/tries/success as in 7.1) | bootctrl.sh:187-261 |
| after | `mtd erase boot_para` | platform.sh:198 |
| config | backup tgz → `/data` (UBIFS on `user_data`) | platform.sh:222-245 |

**A latent stock bug.** `set_bootctrl_string` reads positional parameters `$10`..`$16`. POSIX shells and busybox ash
parse unbraced `$10` as `${1}0`, so arguments 5–8 (all the B-slot bytes) are garbage. Running the real stock
functions under dash and bash with stubbed I/O gives:

* pre-flash with A running, record `0f0001000e000100` → writes `0f0001020e020100` (B tries := 02, not just A uptype)
* switch to B, record `0f0001020e000100` → writes **`0e000100 10000100`** (B priority = `0x10` from "1"+"0")
* switch to A, record `0e0001000f000102` → writes `0f030000 10000102`

B's priority ends up `0x10` in both directions, so stock switching works by accident (`0x10 > 0x0e`). The port
writes the **documented intent** (the argument list plus the commented-out `set_bootctrl` calls), never `0x10`.

### 7.3 The port's sysupgrade (`mt6890-sysupgrade`)

| 24.10 hook | Caller | Implementation |
|---|---|---|
| `platform_check_image` | `validate_firmware_image` | accepts the factory UBI image (EC/VID magics, 256 PEB geometry, `rootfs` + `rootfs_data`) or a rootfs-only tar; rejects tars with other members |
| `platform_pre_upgrade` | `stage2` (real root) | slot selection, writes an intent file |
| `platform_do_upgrade` | `do_stage2` (ramfs) | write → verify → store config → **switch `misc` last** |
| `platform_copy_config` | `do_stage2` | no-op if already stored (idempotent) |

`RAMFS_COPY_BIN` adds `/usr/sbin/dd-nand` (its libraries come along through `ldd`). 24.10 has no
`platform_post_upgrade`; that work happens at the end of `do_upgrade`.

Deliberate deltas from stock:

* **Slot detection** prefers the *running* slot from `/proc/cmdline` `ubi.mtd=<num|name>` mapped through
  `/proc/mtd` (mtd29 → A, mtd42 → B). It falls back to the `misc` priority only when the cmdline is unusable. If the
  two disagree (pending switch or fallback), the target is the slot that is *not running*, and a warning is logged.
* **Rootfs write** is the stock mechanism: `mtd erase` + `mtd write` of the UBI image. The `0xff` tail of the padded
  image isn't rewritten.
* **Verify before switching**: `ubiattach` of the target must succeed and show `rootfs` + `rootfs_data`. Otherwise
  `misc` is not touched.
* **misc I/O**: read with `dd` from `/dev/mtdN`, all four magics required; written with stock `dd-nand` (8 bytes per
  copy), each copy read back. No write if the record already selects the target.
* **Not done**: no boot/lk/tee/modem writes, no clone of non-updated partitions, no `boot_para` erase.
* **Config** goes into the *new* slot's `rootfs_data/sysupgrade.tgz` (restored by preinit), written before the
  switch. The old slot keeps its own configuration.
* **Dry run**: `MT6890_DRYRUN=1` prints the full plan without writing anything.

`mt6890-bootctl`: `status` (`active=`, `booted=`, `copies_consistent=`), `set a|b`, `rollback` (select the slot that
is not running), `bootok`.

### 7.4 Tries counter and `mt6890-bootok`

The stock boot-done script clears tries with single-byte writes and has its `success=01` writes commented out. The
X28 analysis agrees that success is never written. The port follows that convention:

* `/etc/init.d/mt6890-bootok` (START=96, after `done`) runs `mt6890-bootctl bootok` **in the background** and always
  exits 0, so a hung flash write can't block boot.
* It writes one byte (`00`) per copy at the running slot's tries offset: A at 2057, 264201, 526345, 788489; B at 2061,
  264205, 526349, 788493. Every other byte is left alone: the tests assert that exactly four bytes of `misc` change.
* The running slot must be proven from the cmdline; there is no fallback to the "active" slot. If misc is missing,
  unreadable, erased, or the slot is unknown, it logs `bootok skipped (rc=N)` and writes nothing.
* Idempotent: if all four copies already hold `00`, nothing is written, so the steady state has zero flash wear.
* `success` is never set, so the preloader's fallback stays armed for the next upgrade.

### 7.5 The A/B guard

The stock boot-done script and `bootctrl.sh` contain `ab_image_sync`, which clones the running slot over the other
one. If any of it survives into the 24.10 rootfs, an upgrade could be overwritten by the old slot.
`scripts/ab_guard.sh` scans the staged rootfs and fails the build if the cloning tokens appear anywhere in file
content. It runs inside `verify-image.py`. It once caught a *comment* in the port's own scripts that named the stock
script. The comment was reworded and the guard left strict.

---

## 8. Modem (MIPC), Wi-Fi and configuration

### 8.1 MIPC protocol findings

The vendor's only data-call path is the stock netifd proto `ql_mipc.sh`. The MTK helper `mtk_wan_mipc.sh` only runs
`--apn_provision_by_sim` and writes UCI. The `mipc_wan_cli` contract, reconstructed from `ql_mipc.sh`:

| Step | Invocation | Notes (stock line refs) |
|---|---|---|
| radio state | `--nw_radio_state_get 0` | must print `Get SW radio state:MIPC_NW_RADIO_STATE_ON` (l.345) |
| attach APN | `--check_ia <iaapn> <rattype> <iaiptype> <iaroamingtype> "<user>" "<pass>" <auth> <iabearer_bitmask>` | l.362 |
| SIM | `--show_sim_status` | `COMPLETE_READY` / `SIM_PIN` / `SIM_PUK` (l.382-410) |
| network | `--check_nw_status` | l.414 |
| primary PDN only | `--data_call_deact_apn "<apn>"` first | l.416-419 |
| activate | `--data_call_act '<json>'` with keys `apn ip_type roaming_type auth_type username password bearer_bitmask mtu mode` | l.422-436 |
| reply | JSON `result` (0 = ok) then `cid ifname v4_addr v4_mask v4_gw v4_dns1/2 v4_mtu v6_addr v6_prefix v6_gw v6_dns1/2 v6_mtu clatd odu_addr odu_dhcp_offset` | l.437-476 |
| teardown | `--data_call_deact <cid>` (cid from the interface's netifd data) | l.618-645 |
| auto APN | `--apn_provision_by_sim` → JSON `apn auth_type user password protocol iaapn rattype plmn` | `mtk_wan_mipc.sh` l.5-15 |

Stock defaults: retry 2, roamingtype/iptype 3, rattype 0, mode 1, mtu 1500, auto_conf 1, bearer_bitmask
`0xfffdffff`; ia* inherit the non-ia values. `vlan > 0` means a **secondary PDN index, not an 802.1Q VLAN**. Stock
then takes `/var/lock/ql_mipc.lock` and disables auto APN provisioning. The transport underneath is the AT/MIPC
channel on `/dev/ttyCMIPC*` exposed by the built-in CCCI driver. `mipc_wan_cli` wraps the MIPC messages
(`libmipc_msg.so`) and the Quectel AT helper (`libql_at.so`) and speaks JSON at the CLI boundary.

### 8.2 `proto mtkmipc` design

* Name `mtkmipc`, so a stock `ql_mipc`/`mipc` config can never half-activate it. Options: the stock superset plus
  `pdn` (accepts stock `vlan`) and `sim` (1|2|3, validated and recorded; SIM switching is a modem-level setting).
* **Every** `mipc_wan_cli` call runs under `flock -w 120` on `/var/run/mtkmipc.lock`: one modem call at a time
  across all interfaces. Stock locked only secondary PDNs.
* **CID-tracked teardown**: after a successful `--data_call_act`, a state file `/tmp/mtkmipc-<iface>.state` records
  cid, ifname, pdn, sim, apn and addresses. Teardown deactivates **only that CID** and removes the file. With no state
  file, teardown makes no modem call. Another interface's PDN is never touched.
* Setup notifies netifd with the returned `ccmniN` device, addresses, routes and DNS. Bridge mode (`mode 2`) uses
  address-external. `retry` = number of activation attempts, 3 s apart.
* Stock side effects intentionally dropped: META-mode checks, firewall `mtu_fix` UCI writes, automatic clatd
  interface creation, policy routing, the ULA `ra_default` hack.
* Status: `mtkmipc.sh mtkmipc status <iface>` prints `cid/ifname/pdn/sim/state`.
* **Dual SIM = one active SIM.** The stock design powers one USIM at a time. Its two WAN interfaces are two PDN
  profiles: `wan` is the primary PDN, and `wan2` is a secondary PDN (`vlan '2'`) with its own carrier APN (redacted)
  and static routes. The port maps them to `pdn 0` / `pdn 2` on the selected SIM.

Tests: 51 mocked cases covering dump, setup argv, status, `vlan`→`pdn` alias, teardown of only the saved CID,
failure/retry, SIM PIN, invalid SIM, auto APN and lock usage. They run against OpenWrt's own `netifd-proto.sh`
and `jshn`.

### 8.3 Vendor library closure (checklibs)

OpenWrt's `checklibs` step refuses a package whose ELFs need a library no package provides. Iterating
`readelf -d` / `ldd` over the vendor ELFs gave the modem-stack closure, in rounds:

* round 0: `libccci.so`, `libfile_op.so`, `libmtk_audio_mixer_ctrl.so`, `libnvram.so`, `libql_mipc.so`,
  `libql_qlog.so`, `libquectel_atcmd.so`, `libubus.so.20210603`
* round 1: `libgnsshal.so`, `libql_comtools.so`, `libqlslic.so`
* round 2: `libaudio-ctrl-service-interface.so`
* then `libasound.so.2`. 24.10's `alsa-lib` provides it, but only when `AUDIO_SUPPORT` is set, which the target gets
  through `FEATURES += pci pcie`. Bare `PCI_SUPPORT:=y` variables are ignored by `target-metadata.pl`.
* `dd-nand` needs `libnandapi.so` and the 19.07 `libubox.so`.

Each re-pin was diffed against the previous manifest and contained pure additions only.

### 8.4 Wi-Fi: the `mtwifi` handler

* 24.10's netifd calls every `/lib/netifd/wireless/*.sh` with `dump` and then `<drv> setup|teardown <dev> <json>`
  from `/etc/config/wireless`. The handler `mtwifi.sh` validates the options, writes them into that radio's stock
  `.dat` with the stock `datconf -f <dat> set K V`, runs the stock `/sbin/wifi down/up <devname>`, then
  `wireless_add_vif` + `wireless_set_up`.
* devname = `INDEX.mainidx.subidx` from `l1profile.dat`: `MT7915D.1.1` = `ra0`, `MT7915D.1.2` = `rai0`. The band
  comes from the `.dat` `WirelessMode` (16 → 2g, 17 → 5g).
* The handler ships the GPL `netifd-wireless.sh` helper and `CONFLICTS:=wifi-scripts`, because 24.10's
  `wifi-scripts` pulls in an nl80211 `/sbin/wifi` that collides with the stock one.

| UCI | `.dat` key |
|---|---|
| iface `ssid` (BSS j) | `SSIDj` |
| iface `key` | `WPAPSKj` (8–63 chars or 64 hex) |
| iface `encryption` none/psk2/psk-mixed/sae/sae-mixed/owe | `AuthMode` OPEN/WPA2PSK/WPAPSKWPA2PSK/WPA3PSK/WPA2PSKWPA3PSK/OWE; `EncrypType` NONE/AES/TKIPAES |
| iface `hidden` / `isolate` | `HideSSID` / `NoForwarding` (token j) |
| number of AP ifaces | `BssidNum` (vif 1 = `ra0`/`rai0`, then `ra1`, `rai1`, …) |
| device `channel` N / auto | `Channel`=N, `AutoChannelSelect`=0 / `Channel`=0, `AutoChannelSelect`=3 |
| device `htmode` HT20/HT40/VHT80/VHT160 | `HT_BW`/`VHT_BW` 0/0, 1/0, 1/1, 1/2 |
| device `country` | `CountryCode` |
| device `band` | checked against the `.dat` band, never written |

Rejected with nothing applied: band mismatch, out-of-band channel (2g 1–14, 5g 36–177), VHT on 2g, bad PSK, WEP/EAP,
missing netdev. The default config has `ra0` (2g, ch 6, HT40) and `rai0` (5g, ch 36, VHT80) with SSIDs `DWR-2000M` /
`DWR-2000M-5G` and a placeholder key. **Both ship `disabled '1'`**, so the placeholder never goes on air. Stock keeps
the real SSIDs and keys in the `.dat` files, not in UCI. Tests: 72 mocked cases.

The stock Lua stack's only LuCI dependency is `luci.util` inside `l1dat_parser`'s metatable. A two-function shim at
`/lib/wifi/luci/util.lua` satisfies it without installing LuCI Lua. The stock Lua 5.1 binary links
`liblua.so.5.1.5`, which 24.10's `liblua` provides at that SONAME.

### 8.5 UCI migration (stock 19.07 → 24.10): `95-mt6890-uci-migrate`

| Stock | 24.10 | Action |
|---|---|---|
| `network.wan` / `wan2` `proto ql_mipc` | `proto mtkmipc` | rewritten |
| `vlan` (`wan2='2'`) | `pdn` | renamed (PDN index, not 802.1Q) |
| apn, auth, username, password, iptype, roamingtype, iaapn, iaiptype, iaroamingtype, rattype, plmn, mtu, auto_conf, retry, bearer_bitmask, iabearer_bitmask | same | kept unchanged (carrier APN (redacted) values preserved) |
| `ifname 'ccmni'` | — | dropped (the device comes from the modem) |
| `mode 'AUTO'` | — | dropped (mtkmipc: 1 = route, 2 = bridge; default 1); 1/2 kept |
| `pppoe_username/password` (wan), `static_route1/2` (wan2) | — | kept and logged as unused |
| `network.lan` bridge/ifname, switch VLANs, `clatd` 464xlat, loopback, globals | — | untouched (base-files converts `lan`) |
| vendor UI profile package (sections system, mobile, wireless, login, traffic, apnDefault, wps, parentalControl, openVPN) | — | package file removed, sections logged |
| `wireless` (three anonymous stock wifi-ifaces, no wifi-device) | mt6890-mtkwifi default | stock file kept as `wireless.stock-migrated` |
| firewall `@include /etc/firewall.user`, zones/rules | same schema | logged / untouched |
| aee, collectd, ddns, easycwmp, led_ctrld, luci_statistics, mdlog, netagent, omcproxy, openvpn*, qos, scd, sim, speech_property, usb, vnstat, vpnbypass | no 24.10 consumer | untouched, inert |

It runs once, after preinit restores a config backup, and it is idempotent. The log goes to
`/etc/mt6890-uci-migrate.log` and syslog tag `mt6890-migrate`. Note: the stock Lua Wi-Fi stack still reads two
`enable_2g/5g` options from the vendor UI profile package and defaults them to on when it's missing, so removing the
package is safe.

---

## 9. Risk register

Likelihood (L) and impact (I) on a 1–3 scale. "Brick" = the device no longer boots Linux and can only be recovered over
preloader download mode. "Status" reflects the implementation.

| ID | Risk | L | I | Evidence | Mitigation |
|---|---|---|---|---|---|
| R1 | **Stock `zmtk_boot_done` clones the running slot over the other** (`ab_image_sync`). If any stock init path survives into our image, or if stock boots once after we flash slot B, our slot is overwritten (or worse, a half-booting image overwrites good stock). | 2 | 3 | `etc/init.d/zmtk_boot_done:42,81`; `lib/upgrade/bootctrl.sh:275-292,325-349` | Import **no** stock init scripts. Add a build guard that fails on `ab_image_sync`, `zmtk_boot_done`, `bootctrl.sh`, `mtd write`, `nandwrite`, `of=/dev/mtd*`. While stock is still installed on the other slot, its own `zmtk_boot_done` can clone over our slot whenever stock boots without its success flag set. Flash only when the stock slot is marked successful, and don't let the device fall back to stock unattended. **Status:** implemented (`ab_guard.sh`, no stock init imported). |
| R2 | **A/B boot counter exhaustion**: the preloader adds a try per boot; if nothing resets it, at N tries it flips slots (X28 decoded 6, never observed). If the other slot is also native and broken, the device loops. | 2 | 3 | preloader strings `[QL_AB] slot:%d,tries_remaining:%d`, `ab_retry`, `ab_boot_success`; X28 STATUS/BOOT-FLOW | `mt6890-bootok` resets only the running slot's tries, only after LAN+SSH are up, never sets the success byte (keeps fallback). Keep stock on the other slot until native has survived ≥ N reboots. **Verify N for our preloader** (different build, `preloader.img` sha256 `0564fad8…`) via UART before relying on it. **Status:** `mt6890-bootok` implemented (§7.4); threshold still U9. |
| R3 | **`misc` corruption**: a torn write across 4 copies; the DA cannot write `misc` (X28), so recovery is only possible from a running Linux. | 1 | 3 | bootctrl.sh `set_bootctrl` writes 4 copies via `dd-nand`; X28 RECOVERY | Byte-level writes with read-back; write copy@0x800 last; verify all 4 magics before *and* after; never write priority and tries in the same step as flashing; keep a `nanddump` of `misc` in the backup set. **Status:** implemented in `mt6890-bootctl` (§7.3). |
| R4 | **Rootfs signature enforcement differs from X28.** If our LK (a different build from X28's) hashes the rootfs, or a later consumer of `/chosen rootfs,hashvallist` does, then a custom rootfs → LK assert + halt (`cpsid i` spin, no fallback per X28 decode). | 2 | 3 | `lk_a.img` strings `ROOTFS_SIG_VFY Success/Fail: %x`, `ql_raw_data_module.c`; X28 BOOT-FLOW | Before the first native flash: UART-capture a stock boot (expect `ROOTFS_SIG_VFY Success`); grep our Image for `hashvallist`/`rootfs,pubk`/`rootfs,sigval` consumers (offline); first native boot only on the **inactive** slot with the DA recovery path proven by a read-back of the same partition beforehand. |
| R5 | **Wrong partition numbers**: X28 uses mtd numbers for its unit (51 parts, `user_data`=50). Ours has 49 (`user_data`=48, `rootfs_a`=29). The DTB bootargs say `ubi.mtd=28` while `setup_link.sh` maps `rootfs_a`=mtd29. A write by number would hit `rootfs_sig_a`. | 2 | 3 | `etc/setup_link.sh`; DTB `/chosen/bootargs`; X28 RECOVERY partition table | Resolve every partition by **name** from `/proc/mtd` at runtime; refuse if the name→size map differs from a pinned table captured read-only beforehand. Treat `ubi.mtd=28` as the static DTB default that LK overwrites (X28 saw `ubi.mtd=42` on B); confirm with `/proc/cmdline`. **Status:** all partition access is by name. |
| R6 | **Wrong evidence used for hardware decisions**: an early FDT capture that came from a phone, and an `lk_b` capture that is actually ATF. | 3 | 2 | §0 | §3 uses the router's own DTB (boot_a, confirmed by the live FDT). Re-capture the live FDT, `/proc/mtd`, `/proc/cmdline`, the real `lk_b`, `tee_a/b` and `misc` read-only before relying on them. **Status:** resolved (live FDT captured, §0/§3). |
| R7 | **Kernel module/ABI mismatch**: installing a 24.10 `kmod-*` (vermagic 6.6) or an X28-built kmod (different 4.19.205 build) → load failure, or with forced loading, an oops. | 2 | 2 | §1.2 CRCs; X28 STATUS ("loads with no symbol version check") | The `kernel` meta-package pinned to `4.19.205`, plus stubs; no official kmod feed; never `insmod -f`. WireGuard/TPROXY stay out of scope until we have a matching kernel tree (GPL request to D-Link/Quectel for 4.19.205 source). |
| R8 | **Userspace ABI mismatch for vendor binaries** (19.07 musl/libs vs 24.10): `mipc_wan_cli` needs `libjson-c.so.2`, `libql_at.so`, `libdtmf_detect.so`, `libasound.so.2`, `libuci.so`, `libubox.so`. `libubox`/`libuci` ABI changed between 19.07 and 24.10 (same SONAME, different structs). | 3 | 3 (no WAN) | `readelf -d stock rootfs usr/bin/mipc_wan_cli` | Ship vendor compat copies of `libjson-c.so.2` (and, if needed, the 19.07 `libubox`/`libuci` under a `LD_LIBRARY_PATH` / rpath wrapper for vendor ELFs only). Do a musl `ld.so --list` closure check at build time (X28 pattern). Test `mipc_wan_cli --get_imei` as the first smoke test. **Status:** closure resolved at build time (§8.3); runtime ABI still U18. |
| R9 | **First-boot failures (no brick, but no access)**: (a) the 24.10 procd without devtmpfs creates `/dev` nodes late, so `ttyCMIPC*`/`ccci` are missing and the modem never starts; (b) ujail/seccomp services exit (dnsmasq, ntpd); (c) fw4 is pulled in and fails, so there's no firewall/NAT; (d) netifd can't drive the `switch0` table, so LAN is dead; (e) Wi-Fi handler absent, so no Wi-Fi; (f) the UBIFS overlay won't mount (compressor mismatch, `UBIFS_FS_ADVANCED_COMPR` not set). | 2 | 2 | kernel.config 145/419/995/1406/5440; X28 BUILD #122/#86 | A UART console (`ttyS0::askfirst`), pstore-ram enabled (5470-5483); an image-time manifest check (no fw4/nftables/ujail, swconfig present, `ubifs -x lzo`); the LAN must come up with a static IP before modem or Wi-Fi start; Wi-Fi/modem started after `mt6890-bootok`; modem start runs in the background so it can't block boot. |
| R10 | **Dual-SIM config migration**: stock `wan`/`wan2` + `sim.sim_switch` semantics are inferred from scripts. A wrong mapping could select the wrong SIM/APN, or set `vlan=2` as an 802.1Q VLAN. | 2 | 2 | uci-full.txt `network.wan*`, `sim.sim_switch.defaultsim='1'`; `usr/bin/switch_sim.sh` | Migrate to explicit `pdn`/`sim` options and keep stock names as aliases; the first release supports a single active SIM with an optional secondary PDN; keep a dry-run mode for `95-mt6890-uci-migrate` that prints the diff; mocked tests for both SIMs. |
| R11 | **`mtk_netagent` forces the radio off** (`CFUN 0/4`) if started in the wrong order (X28). | 2 | 2 | X28 NATIVE-CELLULAR; our rc.d `S22mtk_netagent` | Don't start it (X28). If IPv6 RA or modem-reset handling is later needed, reverse-engineer the order on a spare unit. |
| R12 | **Modem NV / calibration loss**: `nvdata`, `protect1/2`, `nvram`, `nvcfg` change at runtime. Restoring an old backup or erasing them → no IMEI, no RF calibration, no Wi-Fi e2p. | 1 | 3 | X28 RECOVERY (DIFF partitions) | Sysupgrade and the flasher are restricted to `rootfs_{a,b}` and, via `mt6890-bootctl`, `misc`. A hard allowlist in code; never write NV partitions; back up all 49 partitions read-only first. |
| R13 | **Blob licensing / redistribution**: `mt_wifi.ko` is `Proprietary`; the 8 MTK out-of-tree modules are GPL/dual-tagged without source in hand; the vendor userspace (`ql_*`, `mipc_*`, `ccci_*`) has unknown terms; firmware files (`WIFI_RAM_CODE_MT7915*.bin`) are MTK-licensed. Publishing images would redistribute them. | 3 | 2 (legal) | `modinfo` license column §2 | Publish no binary images; publish source (target, packages, scripts) plus a provenance table (file → sha256 → stock path → license tag); users assemble from their own dump (X28's original model). Send a GPL source request to D-Link for the 4.19.205 kernel and the GPL-tagged modules (`hw_nat`, `mtk_warp`, `conninfra`, `gps_drv`, `btmtk_uart`, `wifi_md_coex`, `mapfilter`). |
| R14 | **Thermal**: on a mainline or reduced kernel there's no MD/PA throttling; on the vendor kernel, thermal management depends on the vendor userspace (`thermal_manager`? UNVERIFIED) not being dropped. | 1 | 2 | DTB thermal-zones `md_5g`, `nrpa_ntc`, `ltepa_ntc`; `MTK_MD_THERMAL*` | Keep the vendor kernel thermal drivers (built-in). List vendor thermal daemons in the stock rc.d and decide whether to keep them. Log `/sys/class/thermal/*/temp` in the first-boot soak. |
| R15 | **Wi-Fi offload memory**: WED/WO reserves about 6.5 MiB and X28 notes `WHNAT` uses ~65 MiB per radio; the 24.10 userspace is bigger than 19.07. OOM is possible on ~643 MB usable RAM. | 1 | 2 | DTB reserved-memory; X28 BUILD (#597) | Expose a `whnat` option in the Wi-Fi handler; run a soak test that records `MemAvailable` (X28 #213 saw slow decline). |
| R16 | **Upgrade replaces stock fallback**: the first native→native sysupgrade overwrites the stock slot. | 3 | 1 | X28 sysupgrade-design | Document it; the flash plan requires a verified 49-partition backup before the first install. |

**What could fail on the very first boot (ordered):** (1) LK `ROOTFS_SIG_VFY` on the modified rootfs (R4); (2) the
kernel finds `ubiblock0_0` but the mount fails (squashfs compression or block size); (3) procd `/dev` and console
without devtmpfs (R9a); (4) `mount_root` with the UBIFS overlay (R9f); (5) switch/LAN (R9d), reachable at `192.168.1.1`
by default; (6) tries reset (`mt6890-bootok`); (7) module autoload order (`wifi_md_coex` before `mt_wifi`; `hw_nat`
hooks are in vmlinux, so the order relative to `mt_wifi`/`mtk_warp` is unverified); (8) the modem stack and
`mipc_wan_cli` ABI (R8); (9) Wi-Fi.

---

## 10. Unverified

Claims made or depended on without grounding in a capture of this unit, or grounded only in X28's documentation.
Each check listed is read-only.

| # | Claim | Where used | Grounding available | How to verify |
|---|---|---|---|---|
| U1 | The meta.txt "74" is a loaded-module (`lsmod`) count | §2, defects | none (meta.txt prints a bare number) | `lsmod \| wc -l` vs `ls /lib/modules/4.19.205/*.ko \| wc -l` on the router |
| U2 | The `lk_b` capture was read from the wrong partition (probably `tee_*`) | defects, R6 | its header is `atf`; the source of the capture is unknown | re-dump `lk_b` by name from `/dev/mtd/lk_b`; compare sizes with `/proc/mtd` |
| U3 | Usable RAM after carve-outs (~643 MB reported) | §3.2 | live FDT shows a 1 GiB `/memory` reg; ~643 MB usable is a reported figure | `free -m` on the device |
| U4 | Every "mainline 6.x would need" statement in §3.3 (absence of `mt6880-nfc`, mt6890 clk/pinctrl/eth/lvts/i2c data; t7xx not applicable; `mtu3`/`xhci-mtk`/`tphy` generic fallbacks bind) | §3.3 | upstream knowledge, no tree grepped | grep a Linux 6.6/6.12 checkout for each compatible in §3.1 |
| U5 | Raw NAND (not SPI-NAND) and the exact NAND part | §3.3 NAND row | `mediatek,mt6880-nfc` + `NANDX_V2` only; X28 docs give 4096/64/256 KiB geometry for X28 | `dmesg \| grep -i nand`, `/sys/class/mtd/mtd0/{writesize,oobsize,erasesize}` |
| U6 | Which PCIe port carries the MT7915; whether 1 or 2 Wi-Fi chips are fitted | §3.3 PCIe/Wi-Fi | `pci_slot_map=<0 1>`, l1profile `INDEX0_pcie_slot=0000` | `lspci` / `/sys/bus/pci/devices` |
| U7 | Switch is an MT7531AE; physical port labels; role of `eth1`/`mac@1`; port 4 (`w` in `llllw`) wiring; PHY `0x02430d90` identity; an RTL8221B on mac@1 | §3.3, §6.4 | DTB, stock UCI, the product listing, UCI key `ql_wan_lan_auto_adapt_8221_disable` | `swconfig dev switch0 show`, `ip -d link`, `cat /sys/class/net/*/phydev/phy_id` (read-only) |
| U8 | `/proc/cmdline` contains `bootslot=a\|b` and LK rewrites `ubi.mtd` per slot | §7.3, R5 | X28 observation; our LK has the `bootslot=a`/`bootslot=b` strings | `cat /proc/cmdline` |
| U9 | Our preloader flips slots at 6 tries; the current `misc` record values | R2, §7.4 | X28 decode; our stock scripts' offsets | UART boot log (`[QL_AB] ...tries_remaining`), read-only `nanddump -l 2064 /dev/mtd/misc` |
| U10 | LK on our build does not enforce rootfs **content** (only `rootfs_sig` certs) | R4, §5.4 | X28 offline analysis of *their* LK | UART log + offline Ghidra of `lk_a.img`; offline grep of our Image for `hashvallist` consumers |
| U11 | `wan` and `wan2` are two PDNs on one modem/SIM; never dual-active SIMs | §8.2, R10 | stock `ql_mipc.sh` (`vlan` = PDN index, flock), `switch_sim.sh` (single-SIM select) | `ifstatus wan`, `ifstatus wan2`, `ip -br link \| grep ccmni` on the live router |
| U12 | Product-listing claims about the secondary WAN carrier, "ccmni0-20", "radios ra0/rai0/ra1" | §8.2 | UCI shows only a carrier APN (redacted) and IA-APN; three `wifi-iface` stubs `ra0/rai0/ra1`; l1profile lists only `ra0;rai0` | `ip -br link`, `iwconfig` |
| U13 | 24.10 procd works without `DEVTMPFS` at runtime | §4 #13 | fw3 + `iptables-legacy` build fine on 24.10 (confirmed); runtime `/dev` behaviour untested | first boot over UART |
| U14 | ~~The `KERNEL_PATCHVER` / no-op-kernel trick lets `make` build a target without shipping its kernel~~ | §6.2 | **Resolved:** full build green, rootfs-only image produced | — |
| U15 | `/sys/class/leds` exposes the `gpio_leds` labels on our build (vs X28's vendor char device `tz_gpio_leds`) | §3.3, 01_leds | DTB `gpio-leds` node | `ls /sys/class/leds`, `ls /dev \| grep -i gpio` |
| U16 | Keys reach userspace as `linux,code` 6/7 via `gpio-keys` (vs a vendor device) | §3.3 | DTB | `cat /proc/bus/input/devices` |
| U17 | Thermal is fully in-kernel (no vendor thermal daemon needed) | R14 | kernel.config only | inspect stock `etc/rc.d` for thermal daemons (offline, `rootfs_a.img`) |
| U18 | 19.07 `libubox`/`libuci` ABI is incompatible with 24.10 for the vendor ELFs | R8 | general OpenWrt history | load test in a chroot/qemu-aarch64 of `mipc_wan_cli --help` against the 24.10 libs (offline) |
| U19 | The vendor UI profile package is the ODM UI layer; the ODM identity behind D-Link's A3 | §1.1 | UCI package name + buildbot path | none required for the port |
| U20 | Redistribution terms for the GPL-tagged MTK modules and the vendor userspace | R13 | `modinfo` license tags only | D-Link GPL request |
| U21 | MT7915 firmware file names and paths loaded at runtime | §6.2 | all firmware/EEPROM files from the full stock rootfs are imported | `dmesg \| grep -i firmware` on first boot |
| U22 | X28-specific facts quoted in §5 (51 partitions, tries limit 6, DA behaviour, WHNAT 65 MiB) apply to the DWR-2000M | §5, §9 | X28 docs only | per row above; the DA behaviour needs a read-only DL-mode test on a **spare** unit |

---

## Appendix A: reproduction commands (offline, on your own captures)

```sh
# modules
mkdir -p build/modules-extracted && tar xzf evidence/modules-4.19.205.tgz -C build/modules-extracted
find build/modules-extracted -name '*.ko' | wc -l                      # 136
for f in build/modules-extracted/modules/4.19.205/*.ko; do strings "$f" | grep -m1 '^vermagic='; done | sort | uniq -c
for f in build/modules-extracted/modules/4.19.205/*.ko; do printf '%s %s %s\n' "${f##*/}" "$(modinfo -F license "$f")" "$(modinfo -F intree "$f")"; done
# vendor-module imports not exported by any module (=> vmlinux-only)
cd build/modules-extracted/modules/4.19.205
for f in *.ko; do readelf -p __ksymtab_strings "$f" 2>/dev/null | awk '/\]/{print $3}'; done | sort -u > /tmp/exp
nm -u mt_wifi.ko hw_nat.ko wifi_md_coex.ko conninfra.ko gps_drv.ko btmtk_uart.ko | awk '/ U /{print $2}' | sort -u | comm -23 - /tmp/exp
# kernel.config greps
grep -nE '^(# )?CONFIG_(NF_TABLES|CFG80211|NAMESPACES|SECCOMP|DEVTMPFS|NET_DSA|MT753X_GSW|MTD_PMT_PARTS|MTD_NANDX_V2|MTD_UBI|MTK_ECCCI_DRIVER|MTK_NET_CCMNI|HW_NAT|MODVERSIONS)[= ]' evidence/kernel.config
# rootfs UBI -> squashfs (vol 0) and image checks
python3 scripts/verify-image.py
```
