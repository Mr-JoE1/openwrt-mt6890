# SPDX-License-Identifier: GPL-2.0-only
#
# DWR-2000M A3 LuCI footer credit: overrides the bootstrap theme's ucode
# footer template. Must be a device package (DEVICE_PACKAGES, listed after
# luci): base-files is installed before the theme, so an override there
# would be clobbered by luci-theme-bootstrap.

include $(TOPDIR)/rules.mk

PKG_NAME:=mt6890-luci-footer
PKG_VERSION:=1
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0-only

include $(INCLUDE_DIR)/package.mk

define Package/mt6890-luci-footer
  SECTION:=luci
  CATEGORY:=LuCI
  TITLE:=DWR-2000M A3 LuCI footer credit
  DEPENDS:=+luci-theme-bootstrap
  PKGARCH:=all
endef

PKG_ARCH:=all

define Package/mt6890-luci-footer/description
  DWR-2000M A3 LuCI footer credit (device package)
endef

define Build/Compile
endef

define Package/mt6890-luci-footer/install
	$(INSTALL_DIR) $(1)/usr/share/ucode/luci/template/themes/bootstrap
	$(INSTALL_DATA) ./files/usr/share/ucode/template/themes/bootstrap/footer.ut \
		$(1)/usr/share/ucode/luci/template/themes/bootstrap/
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/etc/uci-defaults/96-mt6890-luci-redirect $(1)/etc/uci-defaults/
endef

$(eval $(call BuildPackage,mt6890-luci-footer))
