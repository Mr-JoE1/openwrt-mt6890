# SPDX-License-Identifier: GPL-2.0-only

SUBTARGET:=vk419
BOARDNAME:=Vendor 4.19 kernel

define Target/Description
	MT6890 CPEs running the stock vendor 4.19.205 kernel (boot_a/boot_b are
	not rebuilt). Userspace is OpenWrt; kernel modules are the stock .ko set
	repackaged from the owner's own backup (package/vendor/).
endef
