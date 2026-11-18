# SPDX-License-Identifier: GPL-2.0-only
#
# MediaTek MT6890 (T750) CPE target, vendor-kernel (4.19.205) subtarget.
#
# The kernel is NOT built from this tree for shipping: boot_a/boot_b stay
# stock (PORTING-ANALYSIS.md §6.1/§6.2). KERNEL_PATCHVER only exists so the
# 24.10 toolchain/headers machinery has a version to work with. Modules come
# from package/vendor/vendor-kernel-4.19.205 (local-only, see
# scripts/import-stock.sh in the project repo).

include $(TOPDIR)/rules.mk

ARCH:=aarch64
BOARD:=mt6890
BOARDNAME:=MediaTek MT6890 (T750)
# Cortex-A55 = ARMv8.2-A + NEON (stock: aarch64_cortex-a55_neon-vfpv4).
# include/target.mk only knows generic/cortex-a53 for aarch64, so the CFLAGS
# for this CPU_TYPE must be provided before target.mk is included.
CPU_TYPE:=cortex-a55
CPU_CFLAGS_cortex-a55:=-mcpu=cortex-a55
SUBTARGETS:=vk419
# pci/pcie: hardware has PCIe (MT7531 switch 14c3:4d75, MT7915 14c3:7915).
# 'pci' -> PCI_SUPPORT, which selects AUDIO_SUPPORT (target/Config.in); alsa-lib
# depends on AUDIO_SUPPORT. (Bare PCI_SUPPORT:=y variables are not read by
# target-metadata.pl; only FEATURES is.)
FEATURES:=squashfs nand ubifs pci pcie

KERNEL_PATCHVER:=6.6

include $(INCLUDE_DIR)/target.mk

# Stock kernel lacks NF_TABLES, CFG80211, NAMESPACES, SECCOMP, NET_DSA
# (evidence/kernel.config:995,1365,145,419,1203) -> fw3 + iptables-legacy,
# swconfig, no ujail/seccomp, no nl80211 wifi stack, no mainline mt7915e.
DEFAULT_PACKAGES += \
	firewall iptables-legacy ip6tables-legacy swconfig \
	-firewall4 -nftables -kmod-nft-offload \
	-procd-ujail -procd-seccomp \
	-wpad-basic-mbedtls -iw -kmod-mt7915e

# ---------------------------------------------------------------------------
# No-op kernel experiment (PORTING-ANALYSIS.md §6.2 step 1).
#
# include/kernel-build.mk (pulled in by target.mk when TARGET_BUILD=1)
# defines Kernel/CompileModules and Kernel/CompileImage with plain `define`,
# so redefining them here, after target.mk and before BuildTarget is
# evaluated, overrides them for this target only.
#
#  * Kernel/Prepare + Kernel/Configure stay default: they unpack/configure
#    the 6.6 tree, which produces .vermagic (needed by include/kernel.mk) and
#    user_headers. No compiler run on the kernel itself.
#  * Kernel/CompileModules: default runs `make all modules` (= full vmlinux
#    build). Replaced by creating the empty modules.builtin{,.modinfo} files
#    that package/kernel/linux installs, so that package does not fail.
#  * Kernel/CompileImage: default runs `make Image` + objcopy. Replaced by an
#    empty placeholder $(LINUX_KERNEL) (= $(KDIR)/vmlinux) so that image.mk's
#    $(KDIR)/$(KERNEL_NAME) prerequisite exists; the device recipe has
#    KERNEL := (empty), so nothing from it reaches any image.
#
# CONFIG_STRIP_KERNEL_EXPORTS must stay unset (its symtab.h rule runs
# `make vmlinux`). TO VALIDATE in P2b: full `make` succeeds with these.
# ---------------------------------------------------------------------------
define Kernel/CompileModules
	mkdir -p $(LINUX_DIR)
	touch $(LINUX_DIR)/modules.builtin $(LINUX_DIR)/modules.builtin.modinfo
	@echo "mt6890: vendor kernel target - 6.6 modules/vmlinux build skipped"
endef

define Kernel/CompileImage
	mkdir -p $(KERNEL_BUILD_DIR)
	rm -f $(LINUX_KERNEL)
	touch $(LINUX_KERNEL)
	@echo "mt6890: vendor kernel target - 6.6 kernel image build skipped"
endef

$(eval $(call BuildTarget))
