-- test/cluster_group_spec.lua (09-01 Task 3 — PURE cluster grouping)
--
-- Exercises BirdAID.lrdevplugin/src/cluster/group.lua: a PURE module (no Lr, deterministic,
-- no math.random) require-able under stock lua / luajit. Partitions an ORDERED list of frames
-- into clusters and emits anchors + a follower->anchor map (BL-07).
--
-- A frame joins the PREVIOUS frame's cluster iff:
--   ( both timeEpoch finite AND (cur-prev) < maxGapSeconds )
--     OR ( useStacks AND both stackId present AND equal )
--   AND ( sim == nil OR sim(prevKey,curKey) == true )
-- The anchor is the FIRST frame of each cluster. nil-time frames are NEVER time-clustered.
--
-- Loaded via dofile; runner globals assert_eq / assert_true. Lua 5.1 common subset.

local group = require('src.cluster.group')

assert_true(type(group) == 'table', "require 'src.cluster.group' resolves")
assert_true(type(group.group) == 'function', "group exposes group()")

-- helper: count keys in a table.
local function count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- =====================================================================
-- Empty / non-table input -> empty result (never raises).
-- =====================================================================
do
    local r = group.group(nil, { maxGapSeconds = 1 })
    assert_true(type(r) == 'table', "nil frames -> a result table")
    assert_eq(#r.anchors, 0, "nil frames -> no anchors")
    assert_eq(count(r.followerToAnchor), 0, "nil frames -> no followers")

    local r2 = group.group({}, { maxGapSeconds = 1 })
    assert_eq(#r2.anchors, 0, "empty frames -> no anchors")
end

-- =====================================================================
-- A single frame -> one anchor, no followers.
-- =====================================================================
do
    local r = group.group({ { key = 'a', timeEpoch = 10, selIndex = 1 } }, { maxGapSeconds = 1 })
    assert_eq(#r.anchors, 1, "single frame -> one anchor")
    assert_eq(r.anchors[1], 'a', "the lone frame is the anchor")
    assert_eq(count(r.followerToAnchor), 0, "single frame -> no followers")
end

-- =====================================================================
-- Pure time-gap clustering: gap < T merges, gap >= T splits.
-- =====================================================================
do
    local frames = {
        { key = 'a', timeEpoch = 0.0, selIndex = 1 },
        { key = 'b', timeEpoch = 0.5, selIndex = 2 },   -- gap 0.5 < 1 -> merges into a
        { key = 'c', timeEpoch = 5.0, selIndex = 3 },   -- gap 4.5 >= 1 -> new anchor
        { key = 'd', timeEpoch = 5.4, selIndex = 4 },   -- gap 0.4 < 1 -> merges into c
    }
    local r = group.group(frames, { maxGapSeconds = 1.0 })
    assert_eq(#r.anchors, 2, "two clusters: {a,b} and {c,d}")
    assert_eq(r.anchors[1], 'a', "first anchor is a")
    assert_eq(r.anchors[2], 'c', "second anchor is c")
    assert_eq(r.followerToAnchor['b'], 'a', "b follows a")
    assert_eq(r.followerToAnchor['d'], 'c', "d follows c")
    assert_eq(r.followerToAnchor['a'], nil, "a is an anchor (not a follower)")
    assert_eq(r.followerToAnchor['c'], nil, "c is an anchor (not a follower)")
end

-- =====================================================================
-- Gap EQUAL to T splits (strict <).
-- =====================================================================
do
    local frames = {
        { key = 'a', timeEpoch = 0, selIndex = 1 },
        { key = 'b', timeEpoch = 1, selIndex = 2 },  -- gap == 1.0, not < 1.0 -> new anchor
    }
    local r = group.group(frames, { maxGapSeconds = 1.0 })
    assert_eq(#r.anchors, 2, "gap exactly == T is NOT merged (strict <)")
end

-- =====================================================================
-- Stack-only clustering with NIL times (useStacks=true).
-- =====================================================================
do
    local frames = {
        { key = 'a', timeEpoch = nil, stackId = 'S1', selIndex = 1 },
        { key = 'b', timeEpoch = nil, stackId = 'S1', selIndex = 2 },  -- same stack -> merges
        { key = 'c', timeEpoch = nil, stackId = 'S2', selIndex = 3 },  -- diff stack -> new anchor
        { key = 'd', timeEpoch = nil, stackId = nil,  selIndex = 4 },  -- no stack, no time -> new anchor
    }
    local r = group.group(frames, { maxGapSeconds = 1.0, useStacks = true })
    assert_eq(#r.anchors, 3, "{a,b}, {c}, {d}")
    assert_eq(r.followerToAnchor['b'], 'a', "b follows a (same stack)")
    assert_eq(r.followerToAnchor['c'], nil, "c is an anchor (different stack)")
    assert_eq(r.followerToAnchor['d'], nil, "d is an anchor (no stack, nil time)")
end

-- =====================================================================
-- useStacks=false disables the stack branch.
-- =====================================================================
do
    local frames = {
        { key = 'a', timeEpoch = nil, stackId = 'S1', selIndex = 1 },
        { key = 'b', timeEpoch = nil, stackId = 'S1', selIndex = 2 },
    }
    local r = group.group(frames, { maxGapSeconds = 1.0, useStacks = false })
    assert_eq(#r.anchors, 2, "useStacks=false: same-stack nil-time frames do NOT merge")
end

-- =====================================================================
-- The AND-sim gate: a within-window frame with sim=false starts a NEW cluster.
-- =====================================================================
do
    local frames = {
        { key = 'a', timeEpoch = 0.0, selIndex = 1 },
        { key = 'b', timeEpoch = 0.2, selIndex = 2 },  -- time-adjacent BUT sim says different
    }
    local simFalse = function(_, _) return false end
    local r = group.group(frames, { maxGapSeconds = 1.0, sim = simFalse })
    assert_eq(#r.anchors, 2, "sim=false breaks the cluster even within the time window")
    assert_eq(r.followerToAnchor['b'], nil, "b is its own anchor when sim says not-similar")
end

do
    -- sim=true within window merges.
    local frames = {
        { key = 'a', timeEpoch = 0.0, selIndex = 1 },
        { key = 'b', timeEpoch = 0.2, selIndex = 2 },
    }
    local simTrue = function(_, _) return true end
    local r = group.group(frames, { maxGapSeconds = 1.0, sim = simTrue })
    assert_eq(#r.anchors, 1, "sim=true + time-adjacent -> merged")
    assert_eq(r.followerToAnchor['b'], 'a', "b follows a")
end

-- =====================================================================
-- sim receives (prevKey, curKey) and is only consulted within a gap/stack window.
-- =====================================================================
do
    local seen = {}
    local frames = {
        { key = 'a', timeEpoch = 0.0, selIndex = 1 },
        { key = 'b', timeEpoch = 0.2, selIndex = 2 },  -- in window -> sim consulted
        { key = 'c', timeEpoch = 9.0, selIndex = 3 },  -- out of window -> sim NOT consulted
    }
    local sim = function(prev, cur)
        seen[#seen + 1] = prev .. '->' .. cur
        return true
    end
    group.group(frames, { maxGapSeconds = 1.0, sim = sim })
    assert_eq(#seen, 1, "sim consulted ONLY for the in-window pair")
    assert_eq(seen[1], 'a->b', "sim called with (prevKey, curKey)")
end

-- =====================================================================
-- nil-time frame is NEVER time-clustered (only stack-clustered when applicable).
-- =====================================================================
do
    local frames = {
        { key = 'a', timeEpoch = 0.0, stackId = nil, selIndex = 1 },
        { key = 'b', timeEpoch = nil, stackId = nil, selIndex = 2 },  -- nil time, no stack -> new anchor
        { key = 'c', timeEpoch = 0.1, stackId = nil, selIndex = 3 },  -- prev (b) has nil time -> new anchor
    }
    local r = group.group(frames, { maxGapSeconds = 1.0, useStacks = true })
    assert_eq(#r.anchors, 3, "nil-time frames break the time branch on both sides")
end

-- =====================================================================
-- Anchor is ALWAYS the first frame of the cluster; followerToAnchor maps every non-anchor.
-- =====================================================================
do
    local frames = {
        { key = 'a', timeEpoch = 0.0, selIndex = 1 },
        { key = 'b', timeEpoch = 0.1, selIndex = 2 },
        { key = 'c', timeEpoch = 0.2, selIndex = 3 },
    }
    local r = group.group(frames, { maxGapSeconds = 1.0 })
    assert_eq(#r.anchors, 1, "one cluster of three")
    assert_eq(r.anchors[1], 'a', "anchor is the FIRST frame")
    assert_eq(r.followerToAnchor['b'], 'a', "b -> a")
    assert_eq(r.followerToAnchor['c'], 'a', "c -> a")
end

-- =====================================================================
-- nil sim is treated as "always similar" (time/stack-only clustering).
-- =====================================================================
do
    local frames = {
        { key = 'a', timeEpoch = 0.0, selIndex = 1 },
        { key = 'b', timeEpoch = 0.1, selIndex = 2 },
    }
    local r = group.group(frames, { maxGapSeconds = 1.0 })  -- no sim
    assert_eq(#r.anchors, 1, "nil sim = always similar -> merged on time alone")
end

-- =====================================================================
-- Determinism: repeated runs produce identical anchors + map.
-- =====================================================================
do
    local frames = {
        { key = 'a', timeEpoch = 0.0, selIndex = 1 },
        { key = 'b', timeEpoch = 0.3, selIndex = 2 },
        { key = 'c', timeEpoch = 2.0, selIndex = 3 },
    }
    local r1 = group.group(frames, { maxGapSeconds = 1.0 })
    local r2 = group.group(frames, { maxGapSeconds = 1.0 })
    assert_eq(r1.anchors[1], r2.anchors[1], "deterministic anchor 1")
    assert_eq(r1.anchors[2], r2.anchors[2], "deterministic anchor 2")
    assert_eq(r1.followerToAnchor['b'], r2.followerToAnchor['b'], "deterministic follower map")
end
