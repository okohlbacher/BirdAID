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
-- After the deterministic (timeEpoch ASC, selIndex ASC) sort, finite-time frames are grouped
-- among themselves and nil-time frames sort LAST and can never join the time branch. With
-- a(0.0), c(0.1), and a nil-time b: a & c are within the window and merge ({a,c}); b sorts last
-- as its own anchor. So two clusters total, and b is NEVER a time-follower.
-- =====================================================================
do
    local frames = {
        { key = 'a', timeEpoch = 0.0, stackId = nil, selIndex = 1 },
        { key = 'b', timeEpoch = nil, stackId = nil, selIndex = 2 },  -- nil time, no stack -> own anchor (sorts last)
        { key = 'c', timeEpoch = 0.1, stackId = nil, selIndex = 3 },  -- merges with a after sort
    }
    local r = group.group(frames, { maxGapSeconds = 1.0, useStacks = true })
    assert_eq(#r.anchors, 2, "nil-time frame sorts last as its own anchor; finite-time a,c merge")
    assert_eq(r.anchors[1], 'a', "first anchor is a (earliest finite time)")
    assert_eq(r.followerToAnchor['c'], 'a', "c merges with a (time-adjacent after sort)")
    assert_eq(r.followerToAnchor['b'], nil, "nil-time b is its own anchor, never a time-follower")
end

-- =====================================================================
-- A nil-time frame with NO stack genuinely never time-clusters: two nil-time frames stay separate.
-- =====================================================================
do
    local frames = {
        { key = 'a', timeEpoch = nil, stackId = nil, selIndex = 1 },
        { key = 'b', timeEpoch = nil, stackId = nil, selIndex = 2 },
    }
    local r = group.group(frames, { maxGapSeconds = 1.0, useStacks = true })
    assert_eq(#r.anchors, 2, "two nil-time, no-stack frames never merge (time branch needs finite times)")
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
-- B2: UNSORTED input is grouped IDENTICALLY to the same frames sorted by (timeEpoch, selIndex).
-- group.build sorts internally, so shuffling the input must not change the partition.
-- =====================================================================
do
    local sorted = {
        { key = 'a', timeEpoch = 0.0, selIndex = 1 },
        { key = 'b', timeEpoch = 0.3, selIndex = 2 },  -- merges with a
        { key = 'c', timeEpoch = 5.0, selIndex = 3 },  -- new anchor
        { key = 'd', timeEpoch = 5.2, selIndex = 4 },  -- merges with c
    }
    local shuffled = {
        { key = 'd', timeEpoch = 5.2, selIndex = 4 },
        { key = 'a', timeEpoch = 0.0, selIndex = 1 },
        { key = 'c', timeEpoch = 5.0, selIndex = 3 },
        { key = 'b', timeEpoch = 0.3, selIndex = 2 },
    }
    local rs = group.group(sorted,   { maxGapSeconds = 1.0 })
    local ru = group.group(shuffled, { maxGapSeconds = 1.0 })
    assert_eq(#rs.anchors, 2, "sorted input -> 2 clusters")
    assert_eq(#ru.anchors, 2, "shuffled input -> SAME 2 clusters")
    assert_eq(ru.anchors[1], rs.anchors[1], "same first anchor regardless of input order (a)")
    assert_eq(ru.anchors[2], rs.anchors[2], "same second anchor regardless of input order (c)")
    assert_eq(ru.followerToAnchor['b'], 'a', "b -> a after internal sort (was out of order)")
    assert_eq(ru.followerToAnchor['d'], 'c', "d -> c after internal sort (was out of order)")
end

-- =====================================================================
-- B2: a NEGATIVE time delta NEVER merges. Even if a caller passes an earlier frame after a later
-- one (and we defeat the sort by giving them equal selIndex won't help) -- the internal sort puts
-- the earlier-time frame first, and the lower-bound (delta >= 0) guard means no earlier frame ever
-- folds into a later anchor. Construct a pair where, pre-sort, cur is BEFORE prev in time.
-- =====================================================================
do
    -- input order: later-time first, earlier-time second (an "unsorted" descending pair).
    local frames = {
        { key = 'late',  timeEpoch = 10.0, selIndex = 1 },
        { key = 'early', timeEpoch = 0.0,  selIndex = 2 },  -- 10s before -> never adjacent
    }
    local r = group.group(frames, { maxGapSeconds = 1.0 })
    -- after sort: early(0.0) then late(10.0); gap 10 >= 1 -> two anchors. A negative delta is never
    -- even evaluated (sort fixes order) AND would be rejected by delta>=0 if it were.
    assert_eq(#r.anchors, 2, "descending-time input never merges into a single cluster")
    assert_eq(r.anchors[1], 'early', "earliest-time frame is the first anchor after sort")
    assert_eq(r.followerToAnchor['late'], nil, "the later frame never merges backward")
end

-- =====================================================================
-- B2: EQUAL timeEpoch ties break by selIndex ASC (deterministic, total ordering).
-- =====================================================================
do
    -- three frames at the SAME instant, given out of selIndex order; the window is wide so all merge,
    -- and the FIRST anchor must be the lowest-selIndex frame after the tie-break sort.
    local frames = {
        { key = 'z', timeEpoch = 100.0, selIndex = 3 },
        { key = 'x', timeEpoch = 100.0, selIndex = 1 },
        { key = 'y', timeEpoch = 100.0, selIndex = 2 },
    }
    local r = group.group(frames, { maxGapSeconds = 1.0 })
    assert_eq(#r.anchors, 1, "equal-time frames within the window merge into one cluster")
    assert_eq(r.anchors[1], 'x', "the lowest-selIndex frame (x) is the anchor after the tie-break")
    assert_eq(r.followerToAnchor['y'], 'x', "y follows x")
    assert_eq(r.followerToAnchor['z'], 'x', "z follows x")
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
