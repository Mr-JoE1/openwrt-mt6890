-- SPDX-License-Identifier: GPL-2.0-only
-- Minimal luci.util shim for the stock /sbin/wifi (open half, no vendor code).
--
-- Stock l1dat_parser.load_l1_profile() does require("luci.util") inside a
-- metatable __index (only for commented-out debug prints). The 24.10 image
-- ships no LuCI Lua runtime, so without this the require raises and
-- /sbin/wifi fails. /sbin/wifi puts '/lib/wifi/?.lua' first on package.path,
-- so this file is only seen by the wifi stack. /sbin/wifi also dofile()s every
-- *.lua under /lib/wifi; running this file there is harmless.
local M = {}
function M.serialize_data(v) return tostring(v) end
return M
