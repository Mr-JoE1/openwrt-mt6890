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
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/mt6890-apn $(1)/etc/init.d/
endef

# Boot enablement the standard OpenWrt way (the old hand-made
# etc/rc.d/S99 symlink in the ipk did not survive to the device).
# Offline (image build, $$IPKG_INSTROOT set): enable via rc.common.
# On a live device: enable only — mt6890-apn is a boot-only one-shot
# that restarts the network, so do not start it from opkg.
define Package/mt6890-mtkmipc/postinst
#!/bin/sh
if [ -n "$$IPKG_INSTROOT" ]; then
	shell="$$(command -v bash)"
	IPKG_INSTROOT="$$IPKG_INSTROOT" $${shell:-/bin/sh} "$$IPKG_INSTROOT/etc/rc.common" \
		"$$IPKG_INSTROOT/etc/init.d/mt6890-apn" enable || true
else
	/etc/init.d/mt6890-apn enable || true
fi
exit 0
endef

$(eval $(call BuildPackage,mt6890-mtkmipc))
