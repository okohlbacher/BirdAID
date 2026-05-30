-- SPDX-License-Identifier: MIT
-- tools/build_manifest.lua (Phase 8 — HARD-03 build-exclusion decision, testable half)
--
-- PURE Lua module. Imports NO Lr* module and performs NO filesystem I/O -- it only
-- DECIDES, given a repo-relative path, whether that path is DEV-ONLY (must be excluded
-- from the shipped .lrplugin) or a SHIPPED source. The actual tree copy/exclude is the
-- shell build script in 08-04 (CODEX #8); this rule is factored out so the include/
-- exclude policy is unit-testable from the repo root without a tree walk.
--
-- DEV-ONLY (excluded) =
--   * any leaf matching `Debug*.lua` (leaf PREFIX 'Debug' + suffix '.lua') -- matches
--     ALL Debug entry points however many exist (no hardcoded count);
--   * any path with a segment under an excluded directory: .planning/, .git/, test/,
--     tools/  (a stray `BirdAID.lrdevplugin/test/...` is therefore excluded too);
--   * repo cruft: a leaf of CLAUDE.md or .DS_Store, anywhere.
--
-- SHIPPED (NOT dev-only) = the real plugin sources: Info.lua, IdentifyBirds.lua,
-- PluginInfoProvider.lua, birdaid_bootstrap.lua, and everything under src/ (incl.
-- src/lr/*, src/providers/*, src/cluster/*, src/viz/*, src/net/*, src/crop/sweep.lua, src/lib/dkjson).
--
-- Strictly Lua 5.1 common subset.

local M = {}

-- Directory segments that are dev-only wherever they appear in a path.
local EXCLUDED_DIRS = {
    [".planning"] = true,
    [".git"]      = true,
    ["test"]      = true,
    ["tools"]     = true,
}

-- Leaf filenames that are dev-only wherever they appear.
local EXCLUDED_LEAVES = {
    ["CLAUDE.md"]  = true,
    [".DS_Store"]  = true,
}

-- Split a path on '/' into its segments (handles a single bare leaf too).
local function segments(relPath)
    local segs = {}
    for seg in relPath:gmatch("[^/]+") do
        segs[#segs + 1] = seg
    end
    return segs
end

-- isExcludedDir(relPath) -> true if ANY path segment is an excluded directory name.
function M.isExcludedDir(relPath)
    if type(relPath) ~= "string" then return false end
    for _, seg in ipairs(segments(relPath)) do
        if EXCLUDED_DIRS[seg] then
            return true
        end
    end
    return false
end

-- isDevOnly(relPath) -> true if the path must be excluded from the shipped package.
function M.isDevOnly(relPath)
    if type(relPath) ~= "string" then return false end

    -- (a) Any excluded directory segment anywhere in the path.
    if M.isExcludedDir(relPath) then
        return true
    end

    local segs = segments(relPath)
    local leaf = segs[#segs] or relPath

    -- (b) Cruft leaves anywhere.
    if EXCLUDED_LEAVES[leaf] then
        return true
    end

    -- (c) Debug entry points: leaf PREFIX 'Debug' + suffix '.lua' (not a substring,
    --     so src/NotDebugThing.lua still ships). No hardcoded Debug count.
    if leaf:match("^Debug.*%.lua$") then
        return true
    end

    return false
end

return M
