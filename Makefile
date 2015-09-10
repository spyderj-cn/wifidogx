#
# Copyright (C) Spyderj
#

include $(TOPDIR)/rules.mk

PKG_NAME:=wifidogx
PKG_VERSION:=1.0.0

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)
PKG_BUILD_DEPENDS:=+lua/host

include $(INCLUDE_DIR)/package.mk

define Package/wifidogx
  SUBMENU:=Captive Portals
  SECTION:=net
  CATEGORY:=Network
  DEPENDS:=+iptables-mod-extra +iptables-mod-ipopt +kmod-ipt-nat +iptables-mod-nat-extra +lask +lua
  TITLE:=A wireless captive portal solution
endef

define Package/wifidogx/description
	The Wifidogx project is a complete and embeddable captive
	portal solution for wireless community groups or individuals
	who wish to open a free Hotspot while still preventing abuse
	of their Internet connection.
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	cp -r ./* $(PKG_BUILD_DIR)/
endef

define Build/Compile 
	#nothing to do 
endef

define Package/wifidogx/install
	$(INSTALL_DIR) $(1)/usr/lib/lua/wifidogx
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_DIR) $(1)/etc/wifidogx-www
	$(INSTALL_DIR) $(1)/etc/init.d
	
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/etc/init.d/wifidogx $(1)/etc/init.d/wifidogx
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/luasrc/wifidogx.lua $(1)/usr/bin/wifidogx
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/luasrc/wdxctl.lua $(1)/usr/bin/wdxctl
	
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/etc/wifidogx-www/* $(1)/etc/wifidogx-www
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/etc/wifidogx.conf $(1)/etc/wifidogx.conf
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/luasrc/fw_ipset.lua $(1)/usr/lib/lua/wifidogx/fw_ipset.lua
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/luasrc/fw_iptables.lua $(1)/usr/lib/lua/wifidogx/fw_iptables.lua
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/luasrc/conf.lua $(1)/usr/lib/lua/wifidogx/conf.lua
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/luasrc/auth.lua $(1)/usr/lib/lua/wifidogx/auth.lua
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/luasrc/http.lua $(1)/usr/lib/lua/wifidogx/http.lua
endef

$(eval $(call BuildPackage,wifidogx))
