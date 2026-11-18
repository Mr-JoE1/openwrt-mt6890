# SPDX-License-Identifier: GPL-2.0-only
#
# MT6890 vendor-kernel images: rootfs-only. boot_a/boot_b (stock 4.19.205
# kernel + DTB) are never produced or written (PORTING-ANALYSIS.md §6.2-3).

include $(TOPDIR)/rules.mk
include $(INCLUDE_DIR)/image.mk

# Pad the current image to $(1) bytes with 0xff (erased-NAND value).
# Build/pad-to uses dd conv=sync, which pads with 0x00 - wrong for NAND/UBI.
define Build/mt6890-pad-ff
	size=$$(stat -c%s $@); \
	if [ $$size -gt $$(($(1))) ]; then \
		echo "WARNING: $@ is $$size bytes, larger than $(1)" >&2; \
		rm -f $@; exit 1; \
	fi; \
	[ $$size -eq $$(($(1))) ] || \
		tr '\000' '\377' < /dev/zero | \
		dd bs=$$(($(1) - size)) count=1 iflag=fullblock 2>/dev/null >> $@
endef

# Wrap the current image ($@ = UBI image of both volumes) into the standard
# OpenWrt nand sysupgrade tar layout WITHOUT a kernel member:
#   sysupgrade-<board>/CONTROL, sysupgrade-<board>/root, root.sha256
# platform.sh (P5) ubiformats the inactive rootfs_{a,b} mtd with "root".
define Build/mt6890-sysupgrade-tar
	rm -rf $@.d
	mkdir -p $@.d/sysupgrade-$(DEVICE_NAME)
	echo "BOARD=$(DEVICE_NAME)" > $@.d/sysupgrade-$(DEVICE_NAME)/CONTROL
	cp $@ $@.d/sysupgrade-$(DEVICE_NAME)/root
	( cd $@.d/sysupgrade-$(DEVICE_NAME) && \
		$(MKHASH) sha256 root > root.sha256 )
	$(TAR) -C $@.d --sort=name --owner=0 --group=0 --numeric-owner \
		$(if $(SOURCE_DATE_EPOCH),--mtime="@$(SOURCE_DATE_EPOCH)") \
		-cf $@ sysupgrade-$(DEVICE_NAME)
	rm -rf $@.d
endef

define Device/Default
  PROFILES := Default $$(DEVICE_NAME)
  FILESYSTEMS := squashfs
  # No kernel member anywhere: the stock boot_{a,b} image is kept.
  # KERNEL_NAME stays "vmlinux": $(KDIR)/vmlinux is the empty placeholder
  # created by the target Makefile's Kernel/CompileImage override.
  KERNEL :=
  KERNEL_INITRAMFS :=
  KERNEL_IN_UBI :=
  DEVICE_DTS :=
endef

define Device/dlink_dwr-2000m-a3
  DEVICE_VENDOR := D-Link
  DEVICE_MODEL := dwr-2000m
  DEVICE_VARIANT := a3
  # Stock DTB compatible is the MTK EVB one (evidence: boot_a.img DTB);
  # /tmp/sysinfo/board_name will report it.
  SUPPORTED_DEVICES := dlink,dwr-2000m-a3 mediatek,evb6890v1_64_cpe_nand
  # Stock UBI geometry (rootfs_a.img): PEB 256 KiB, min-I/O 4096,
  # VID hdr @4096 -> LEB 253952; rootfs_{a,b} mtd = 64 MiB.
  BLOCKSIZE := 256k
  PAGESIZE := 4096
  VID_HDR_OFFSET := 4096
  UBINIZE_OPTS := -E 5
  IMAGE_SIZE := 64m
  # append-ubi (scripts/ubinize-image.sh) emits vol0 "rootfs" (squashfs,
  # dynamic) + vol1 "rootfs_data" (dynamic, autoresize, formatted UBIFS by
  # fstools on first boot).
  IMAGES := factory-rootfs.bin sysupgrade.tar
  IMAGE/factory-rootfs.bin := append-ubi | check-size $$$$(IMAGE_SIZE) | \
	mt6890-pad-ff 67108864
  IMAGE/sysupgrade.tar := append-ubi | check-size $$$$(IMAGE_SIZE) | \
	mt6890-sysupgrade-tar
  DEVICE_PACKAGES := vendor-kernel-4.19.205 vendor-mtwifi-fw \
	vendor-modem-stack vendor-compat-libs alsa-lib mt6890-mtkmipc \
	mt6890-mtkwifi mt6890-sysupgrade
endef
TARGET_DEVICES += dlink_dwr-2000m-a3

$(eval $(call BuildImage))
