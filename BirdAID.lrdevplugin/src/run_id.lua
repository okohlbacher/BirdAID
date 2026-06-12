-- SPDX-License-Identifier: MIT
-- BirdAID.lrdevplugin/src/run_id.lua (Wave-D D8 — single-source run-id minting)
--
-- PURE module: imports NO Lightroom SDK namespace, so it is require-able under stock lua / lua5.1 /
-- luajit for offline unit testing (the CODEX-mandated separation invariant). The ONE Lr-only input
-- newRunId needs — a fractional wall-clock — is INJECTED by the caller (the entries pass a closure
-- over LrDate.currentTime); offline the spec injects a fake clock or omits it.
--
-- WHY THIS EXISTS (D8 / H4): IdentifyBirds.lua and DeepIdentify.lua each carried a BYTE-IDENTICAL
-- newRunId + its module-scoped runIdCounter (DeepIdentify's header literally said "Copied verbatim
-- from IdentifyBirds.lua"). The id seeds the per-run scratch dir name, so its format + uniqueness is
-- load-bearing; one home prevents the two copies from drifting.
--
-- newRunId([fracClock]) -> a UNIQUE, sanitize-safe run id (ONLY [%w-_] chars so sweep.sanitizeRunId
-- accepts it; NO '.' which sanitizeRunId rejects). Combines three sources joined with '-':
--   * os.time()          -- Unix wall-clock seconds (coarse).
--   * fracClock()        -- OPTIONAL fractional seconds (LrDate.currentTime in production); the
--                           decimal point is stripped so the id stays sanitize-safe and two runs in
--                           the same second still differ. Absent/throwing/non-number -> "0".
--   * a module-scoped monotonic per-load counter -- the final disambiguator so even two calls in the
--                           SAME fractional instant get DISTINCT ids. Survives across calls within a
--                           single plugin load (module-scoped).
--
-- Strictly Lua 5.1 common subset: no \u{}, no //, no goto, no <close>.

local M = {}

-- Module-scoped monotonic per-load counter (the final disambiguator).
local runIdCounter = 0

function M.newRunId(fracClock)
    local okT, t = pcall(os.time)
    local secs = okT and t or 0

    local frac = "0"
    if type(fracClock) == 'function' then
        local okF, f = pcall(fracClock)
        if okF and type(f) == 'number' and f == f then
            local s = string.format("%.4f", f)
            frac = (s:gsub("[^%d]", ""))
            if frac == "" then frac = "0" end
        end
    end

    runIdCounter = runIdCounter + 1

    return tostring(secs) .. "-" .. frac .. "-" .. tostring(runIdCounter)
end

return M
