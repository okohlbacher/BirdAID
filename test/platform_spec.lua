-- test/platform_spec.lua (Phase 8 — HARD-01 platform-capability fail-clear)
--
-- Exercises BirdAID.lrdevplugin/src/platform.lua: a PURE module (imports NO Lr*),
-- require-able under stock lua / luajit. It maps an OS token (derived in the LrC
-- entry/glue from the MAC_ENV/WIN_ENV globals) to a capability table. The fail-clear
-- rule (SPEC §2): crop-for-ID is macOS-only in v1; any non-'macos' token (incl.
-- unknown/nil) DISABLES crop with a clear, non-nil reason string so a broken cmd.exe
-- crop command is never built off-macOS.
--
-- Loaded by test/run.lua via dofile; uses the runner's global assert_eq / assert_true.
-- Strictly Lua 5.1 common subset.

local platform = require('src.platform')

-- (1) macOS: crop enabled, no reason needed.
local mac = platform.capabilities('macos')
assert_true(mac.crop_supported, "macos supports crop")
assert_eq(mac.crop_reason, nil, "macos has no crop_reason (nil)")
assert_eq(mac.os, 'macos', "macos echoes the os token")

-- (2) windows: crop disabled with a clear, non-nil reason string.
local win = platform.capabilities('windows')
assert_eq(win.crop_supported, false, "windows fails clear: crop disabled")
assert_true(win.crop_reason ~= nil, "windows has a non-nil crop_reason")
assert_true(type(win.crop_reason) == 'string', "windows crop_reason is a string")
assert_true(#win.crop_reason > 0, "windows crop_reason is a non-empty string")
assert_eq(win.os, 'windows', "windows echoes the os token")

-- (3) unknown token: fail closed (crop disabled) with a reason.
local unk = platform.capabilities('unknown')
assert_eq(unk.crop_supported, false, "unknown token fails closed: crop disabled")
assert_true(unk.crop_reason ~= nil, "unknown token has a non-nil crop_reason")
assert_eq(unk.os, 'unknown', "unknown echoes the os token")

-- (4) nil token: fail closed (crop disabled) with a reason; os echoes nil.
local none = platform.capabilities(nil)
assert_eq(none.crop_supported, false, "nil token fails closed: crop disabled")
assert_true(none.crop_reason ~= nil, "nil token has a non-nil crop_reason")
assert_eq(none.os, nil, "nil token echoes nil os")

-- (5) an arbitrary non-macos token also fails closed (only 'macos' opens crop).
local lin = platform.capabilities('linux')
assert_eq(lin.crop_supported, false, "arbitrary non-macos token fails closed")
assert_true(lin.crop_reason ~= nil, "arbitrary non-macos token has a reason")
assert_eq(lin.os, 'linux', "arbitrary token is echoed verbatim")
