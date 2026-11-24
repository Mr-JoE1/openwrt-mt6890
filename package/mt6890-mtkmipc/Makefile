# SPDX-License-Identifier: GPL-2.0-only
#
# netifd shell protocol "mtkmipc" for the MT6890 MIPC modem stack.
# Replaces stock /lib/netifd/proto/ql_mipc.sh (PORTING-ANALYSIS.md §6.6).

include $(TOPDIR)/rules.mk

PKG_NAME:=mt6890-mtkmipc
PKG_VERSION:=1
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0-only

include $(INCLUDE_DIR)/package.mk

define Package/mt6890-mtkmipc
  SECTION:=network/proto
  CATEGORY:=Network
  TITLE:=netifd protocol handler for MT6890 MIPC data calls (mtkmipc)
  DEPENDS:=+netifd +jshn +flock +vendor-modem-stack
  PKGARCH:=all
endef

PKG_ARCH:=all

define Package/mt6890-mtkmipc/description
  netifd shell proto "mtkmipc": activates/deactivates MIPC data calls via
  mipc_wan_cli (--data_call_act / --data_call_deact). Accepts the stock
  ql_mipc UCI options plus the renamed "pdn" (alias "vlan") and "sim".
endef

define Build/Compile
endef

define Package/mt6890-mtkmipc/install
	$(INSTALL_DIR) $(1)/lib/netifd/proto
	$(INSTALL_BIN) ./files/lib/netifd/proto/mtkmipc.sh $(1)/lib/netifd/proto/
	$(INSTALL_DIR) $(1)/lib/mt6890
	$(INSTALL_BIN) ./files/lib/mt6890/apn-wan-setup.sh $(1)/lib/mt6890/
	$(INSTALL_DIR) $(1)/etc/init.d $(1)/etc/rc.d
	$(INSTALL_BIN) ./files/etc/init.d/mt6890-apn $(1)/etc/init.d/
	$(LN) ../init.d/mt6890-apn $(1)/etc/rc.d/S99mt6890-apn
endef

$(eval $(call BuildPackage,mt6890-mtkmipc))
