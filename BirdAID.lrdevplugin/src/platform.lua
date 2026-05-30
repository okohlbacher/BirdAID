-- SPDX-License-Identifier: MIT
-- BirdAID.lrdevplugin/src/platform.lua (Phase 8 — HARD-01 platform-capability helper)
--
-- PURE OS-token -> capabilities mapping. Imports NO Lr* module, performs NO os.*
-- probes, so it is require-able under stock lua / lua5.1 / luajit for offline unit
-- testing and the negative-purity grep gate stays green.
--
-- The LrC runtime exposes MAC_ENV / WIN_ENV globals; the ENTRY/GLUE (Plan 08-03)
-- reads those, derives an OS token ('macos' | 'windows' | 'unknown'), and hands the
-- token to M.capabilities below. Keeping that derivation OUT of this module is
-- deliberate: the globals only exist inside Lightroom, but the OS-token -> capability
-- DECISION is a pure function and therefore CLI-testable.
--
-- Fail-clear rule (SPEC §2): crop-for-ID needs an external image tool invoked via
-- LrTasks.execute, whose command quoting is POSIX-only in v1; cmd.exe (Windows) would
-- silently mangle it. So crop is enabled ONLY on a 'macos' token and DISABLED (fail
-- closed) for every other token — including unknown / nil — with a clear, non-nil
-- reason string the entry surfaces in the log + run summary.
--
-- Strictly Lua 5.1 common subset.

local M = {}

-- A clear, user-surfaceable reason explaining why crop is off on non-macOS.
local CROP_REASON = "crop-for-ID is only supported on macOS in this version"

-- capabilities(osToken) -> { os, crop_supported, crop_reason }
--   os             : the token echoed verbatim (incl. nil)
--   crop_supported : true ONLY when osToken == 'macos'; false otherwise (fail closed)
--   crop_reason    : nil on macOS; a non-nil clear string for every non-macos token
function M.capabilities(osToken)
    local mac = (osToken == 'macos')
    -- NOTE: do NOT use `mac and nil or CROP_REASON` -- the `a and nil or b` idiom is
    -- the Lua ternary trap (the nil middle is falsy, so it ALWAYS yields b). Use an
    -- explicit branch so macOS gets a nil reason and non-macos gets the string.
    local reason
    if not mac then
        reason = CROP_REASON
    end
    return {
        os             = osToken,
        crop_supported = mac,
        crop_reason    = reason,
    }
end

return M
