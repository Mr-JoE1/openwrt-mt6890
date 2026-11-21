# SPDX-License-Identifier: GPL-2.0-only
#
# MT6890 A/B sysupgrade hooks, boot-slot control and stock->24.10 UCI
# migration (docs/NOTES-p2.md "P5").
#
# Runtime tools used: mtd (erase/write, stock mechanism), ubi-utils
# (ubiattach/ubidetach for post-write verification), dd-nand from
# vendor-modem-stack (stock misc writer). sysupgrade itself is part of
# base-files in 24.10 (no separate package).

include $(TOPDIR)/rules.mk

PKG_NAME:=mt6890-sysupgrade
PKG_VERSION:=1
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0-only

include $(INCLUDE_DIR)/package.mk

define Package/mt6890-sysupgrade
  SECTION:=base
  CATEGORY:=Base system
  TITLE:=MT6890 A/B sysupgrade platform hooks + mt6890-bootctl
  DEPENDS:=+mtd +ubi-utils +vendor-modem-stack
  PKGARCH:=all
endef

PKG_ARCH:=all

define Package/mt6890-sysupgrade/description
  lib/upgrade/platform.sh for the MT6890 A/B layout: writes the inactive
  rootfs_a/rootfs_b slot (raw mtd write of the UBI image, as stock), stores
  the config backup in the new slot's rootfs_data and switches the misc
  boot record last. mt6890-bootctl: status / set <a|b> / rollback /
  bootok / confirm / arm. Ships /etc/mt6890-armed: the boot-time tries
  reset stays suppressed until 'mt6890-bootctl confirm'.
  uci-defaults migration of stock ql_mipc/stoneoim config.
endef

define Build/Compile
endef

define Package/mt6890-sysupgrade/install
	$(INSTALL_DIR) $(1)/lib/upgrade $(1)/usr/bin $(1)/etc/uci-defaults $(1)/etc/init.d
	$(INSTALL_DATA) ./files/lib/upgrade/platform.sh $(1)/lib/upgrade/
	$(INSTALL_DATA) ./files/lib/upgrade/mt6890-bootctl.sh $(1)/lib/upgrade/
	$(INSTALL_BIN) ./files/usr/bin/mt6890-bootctl $(1)/usr/bin/
	$(INSTALL_BIN) ./files/etc/uci-defaults/95-mt6890-uci-migrate $(1)/etc/uci-defaults/
	$(INSTALL_BIN) ./files/etc/init.d/mt6890-bootok $(1)/etc/init.d/
	$(INSTALL_DATA) ./files/etc/mt6890-armed $(1)/etc/
endef

$(eval $(call BuildPackage,mt6890-sysupgrade))
