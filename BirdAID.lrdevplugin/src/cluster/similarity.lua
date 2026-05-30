-- SPDX-License-Identifier: MIT
-- BirdAID.lrdevplugin/src/cluster/similarity.lua (Phase 9 — BL-07 perceptual similarity)
--
-- PURE module: imports NO Lr* module, uses NO os.time/date/clock, NO math.random. Deterministic
-- and require-able under stock lua / lua5.1 / luajit (the CODEX-mandated separation invariant).
--
-- WHAT IT DOES (BL-07): given two FIXED 8x8 (64-cell) grayscale grids — the output of
-- jpeg_thumb.dcLumaGrid (Task 5) — decide "visually similar" -> bool via an AVERAGE-HASH (aHash):
-- each of the 64 cells is compared to the grid mean -> 1 bit, and two hashes are compared by
-- Hamming distance (the count of differing bits, an integer 0..64). This is the sim() predicate
-- injected into cluster.group.
--
-- HASH REPRESENTATION: a flat ARRAY of 64 zero/one integers (NOT a packed 64-bit integer), which
-- keeps the arithmetic strictly Lua-5.1-safe (no 64-bit integer literals, no bit ops). aHash bit i
-- = (cell[i] > mean) and 1 or 0.
--
-- INTERFACE:
--   M.hash(grid)                    -> a 64-element {0/1,...} array, or nil for a malformed grid.
--   M.distance(hashA, hashB)        -> Hamming distance integer 0..64 (or 64 for any malformed pair,
--                                      the SAFE "maximally different" direction).
--   M.similar(gridA, gridB, threshold) -> bool ( distance(hash A, hash B) <= threshold ). GUARD:
--                                      if either grid is nil or NOT exactly 64 cells, return FALSE
--                                      (the SAFE direction: NOT similar -> do NOT merge -> identify
--                                      independently). threshold is the clusterSimilarityThreshold
--                                      integer 0..64 (default 10); lower = stricter (fewer merges).
--
-- Strictly Lua 5.1 common subset: no \u{}, no //, no goto, no <close>; unpack global.

local M = {}

-- isGrid64(g): true ONLY when g is a table whose keys are EXACTLY 1..64 with numeric values
-- (no gaps, no extra keys). #t is unreliable for sparse tables, so count via pairs then verify.
local function isGrid64(g)
    if type(g) ~= 'table' then return false end
    local count = 0
    for k, v in pairs(g) do
        if type(k) ~= 'number' or k % 1 ~= 0 or k < 1 or k > 64 then return false end
        if type(v) ~= 'number' then return false end
        count = count + 1
    end
    if count ~= 64 then return false end
    for i = 1, 64 do
        if g[i] == nil then return false end
    end
    return true
end

-- M.hash(grid) -> a 64-element 0/1 array (aHash), or nil for a malformed grid.
function M.hash(grid)
    if not isGrid64(grid) then return nil end
    local sum = 0
    for i = 1, 64 do sum = sum + grid[i] end
    local mean = sum / 64
    local bits = {}
    for i = 1, 64 do
        bits[i] = (grid[i] > mean) and 1 or 0
    end
    return bits
end

-- isHash64: a 64-element 0/1 array.
local function isHash64(h)
    if type(h) ~= 'table' then return false end
    for i = 1, 64 do
        local v = h[i]
        if v ~= 0 and v ~= 1 then return false end
    end
    return true
end

-- M.distance(hashA, hashB) -> Hamming distance 0..64. A malformed pair returns 64 (maximally
-- different — the SAFE direction so similar() never accidentally merges on a bad hash).
function M.distance(hashA, hashB)
    if not (isHash64(hashA) and isHash64(hashB)) then return 64 end
    local d = 0
    for i = 1, 64 do
        if hashA[i] ~= hashB[i] then d = d + 1 end
    end
    return d
end

-- M.similar(gridA, gridB, threshold) -> bool. nil / not-64-cells -> false (safe no-merge).
function M.similar(gridA, gridB, threshold)
    if not (isGrid64(gridA) and isGrid64(gridB)) then return false end
    local t = tonumber(threshold)
    if type(t) ~= 'number' or t ~= t then return false end  -- NaN/non-number threshold -> no merge.
    return M.distance(M.hash(gridA), M.hash(gridB)) <= t
end

return M
