# SPDX-License-Identifier: GPL-2.0-only
#
# Wi-Fi glue for the stock mt_wifi.ko (MT7915 DBDC). Open half: no vendor
# bytes. The active path is the stock X28-lineage Lua stack (/sbin/wifi +
# mtkwifi.lua + lib/wifi/mt7615e.lua) shipped, locally, by vendor-mtwifi-fw;
# radios are brought up at boot by /etc/init.d/mt6890-wifi (`wifi up`) and
# configured via the .dat profiles. The netifd handler "mtwifi" below is
# installed but is not the active path (netifd `wifi` cannot drive it).
# PORTING-ANALYSIS.md §3.3 Wi-Fi row, §4 row 7.

include $(TOPDIR)/rules.mk

PKG_NAME:=mt6890-mtkwifi
PKG_VERSION:=1
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0-only

include $(INCLUDE_DIR)/package.mk

# 24.10 moved netifd-wireless.sh from netifd into wifi-scripts, which also
# ships a ucode /sbin/wifi + mac80211/nl80211 deps (unusable here, no
# cfg80211). Install the same GPL helper from the in-tree wifi-scripts source.
NETIFD_WIRELESS_SH:=$(TOPDIR)/package/network/config/wifi-scripts/files/lib/netifd/netifd-wireless.sh

define Package/mt6890-mtkwifi
  SECTION:=net
  CATEGORY:=Network
  TITLE:=netifd wireless handler for the stock MTK mt_wifi driver (mtwifi)
  DEPENDS:=+netifd +jshn +vendor-mtwifi-fw
  CONFLICTS:=wifi-scripts
  PKGARCH:=all
endef

PKG_ARCH:=all

define Package/mt6890-mtkwifi/description
  netifd wireless driver "mtwifi" (/lib/netifd/wireless/mtwifi.sh): maps UCI
  wifi-device/wifi-iface (ssid, encryption, key, channel, htmode, country,
  hidden, isolate) onto the stock .dat profiles with datconf and restarts the
  band with the stock /sbin/wifi down|up <devname>. Default /etc/config/wireless
  for ra0 (2.4G) and rai0 (5G), both disabled until a key is set.
endef

define Package/mt6890-mtkwifi/conffiles
/etc/config/wireless
endef

define Build/Compile
endef

define Package/mt6890-mtkwifi/install
	$(INSTALL_DIR) $(1)/lib/netifd/wireless
	$(INSTALL_BIN) ./files/lib/netifd/wireless/mtwifi.sh $(1)/lib/netifd/wireless/
	$(INSTALL_DATA) $(NETIFD_WIRELESS_SH) $(1)/lib/netifd/
	$(INSTALL_DIR) $(1)/lib/wifi/luci
	$(INSTALL_DATA) ./files/lib/wifi/luci/util.lua $(1)/lib/wifi/luci/
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/wireless $(1)/etc/config/
endef

$(eval $(call BuildPackage,mt6890-mtkwifi))
