-- test/cluster_similarity_spec.lua (09-01 Task 4 — PURE perceptual similarity)
--
-- Exercises BirdAID.lrdevplugin/src/cluster/similarity.lua: a PURE module (no Lr, deterministic,
-- no math.random) require-able under stock lua / luajit. Given two FIXED 8x8 (64-cell) grayscale
-- grids it decides "visually similar" -> bool via a 64-bit average-hash + Hamming distance (BL-07).
--
-- Loaded via dofile; runner globals assert_eq / assert_true. Lua 5.1 common subset.

local sim = require('src.cluster.similarity')

assert_true(type(sim) == 'table', "require 'src.cluster.similarity' resolves")
assert_true(type(sim.hash) == 'function', "exposes hash")
assert_true(type(sim.distance) == 'function', "exposes distance")
assert_true(type(sim.similar) == 'function', "exposes similar")

-- build a 64-cell grid from a generator fn(i)->value (i = 1..64).
local function grid(fn)
    local g = {}
    for i = 1, 64 do g[i] = fn(i) end
    return g
end

-- a grid where the first half is dark (0) and the second half bright (255).
local halfDark = grid(function(i) return i <= 32 and 0 or 255 end)
-- identical copy.
local halfDark2 = grid(function(i) return i <= 32 and 0 or 255 end)
-- inverted: bright first half, dark second half (every bit flips).
local inverted = grid(function(i) return i <= 32 and 255 or 0 end)

-- =====================================================================
-- Identical grids -> distance 0 -> similar at any threshold >= 0.
-- =====================================================================
do
    local ha = sim.hash(halfDark)
    local hb = sim.hash(halfDark2)
    assert_eq(sim.distance(ha, hb), 0, "identical grids -> Hamming distance 0")
    assert_eq(sim.similar(halfDark, halfDark2, 0), true, "identical similar at threshold 0")
    assert_eq(sim.similar(halfDark, halfDark2, 10), true, "identical similar at threshold 10")
end

-- =====================================================================
-- One-cell flip -> distance 1.
-- =====================================================================
do
    -- flip a single cell from the bright half to below-mean so exactly one aHash bit changes.
    local oneFlip = grid(function(i)
        if i == 64 then return 0 end           -- was 255 (above mean) -> now 0 (below mean)
        return i <= 32 and 0 or 255
    end)
    assert_eq(sim.distance(sim.hash(halfDark), sim.hash(oneFlip)), 1,
        "single below/above-mean flip -> Hamming distance 1")
end

-- =====================================================================
-- Inverted / very-different grid -> large distance (close to 64) -> not similar at small threshold.
-- =====================================================================
do
    local d = sim.distance(sim.hash(halfDark), sim.hash(inverted))
    assert_eq(d, 64, "fully inverted grid -> Hamming distance 64")
    assert_eq(sim.similar(halfDark, inverted, 10), false, "inverted not similar at threshold 10")
    assert_eq(sim.similar(halfDark, inverted, 64), true, "inverted IS similar at threshold 64 (<=)")
end

-- =====================================================================
-- Threshold boundary: == threshold is similar, threshold+1 is not.
-- =====================================================================
do
    -- build a grid with EXACTLY k flipped bits vs halfDark.
    local function withFlips(k)
        return grid(function(i)
            -- the second half (i in 33..64) is bright (above mean). flip the first k of them to 0.
            if i >= 33 and i <= 32 + k then return 0 end
            return i <= 32 and 0 or 255
        end)
    end
    local g5 = withFlips(5)
    assert_eq(sim.distance(sim.hash(halfDark), sim.hash(g5)), 5, "5 flips -> distance 5")
    assert_eq(sim.similar(halfDark, g5, 5), true, "distance == threshold is similar (<=)")
    assert_eq(sim.similar(halfDark, g5, 4), false, "distance > threshold is NOT similar")
end

-- =====================================================================
-- Guards: nil grid -> not similar; a grid that is NOT 64 cells -> not similar (SAFE no-merge).
-- =====================================================================
do
    assert_eq(sim.similar(nil, halfDark, 64), false, "nil gridA -> not similar")
    assert_eq(sim.similar(halfDark, nil, 64), false, "nil gridB -> not similar")
    local short = grid(function(i) return 0 end)
    short[64] = nil  -- now 63 cells
    assert_eq(sim.similar(halfDark, short, 64), false, "63-cell grid -> not similar (shape mismatch)")
    local long = grid(function(i) return 0 end)
    long[65] = 1     -- 65 cells
    assert_eq(sim.similar(halfDark, long, 64), false, "65-cell grid -> not similar (shape mismatch)")
end

-- =====================================================================
-- hash is deterministic + order-stable; distance always within 0..64.
-- =====================================================================
do
    local h1 = sim.hash(halfDark)
    local h2 = sim.hash(halfDark)
    assert_eq(sim.distance(h1, h2), 0, "hash is deterministic (same grid -> distance 0)")
    -- distance bounds across all pairs above.
    local d = sim.distance(sim.hash(halfDark), sim.hash(inverted))
    assert_true(d >= 0 and d <= 64, "distance within 0..64")
end
