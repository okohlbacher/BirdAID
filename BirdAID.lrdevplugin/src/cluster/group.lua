-- SPDX-License-Identifier: MIT
-- BirdAID.lrdevplugin/src/cluster/group.lua (Phase 9 — BL-07 burst/stack clustering)
--
-- PURE module: imports NO Lr* module, uses NO os.time/date/clock, NO math.random. Deterministic
-- and require-able under stock lua / lua5.1 / luajit for offline unit testing (the CODEX-mandated
-- separation invariant). Keeping the visual-similarity predicate INJECTED (opts.sim) makes
-- grouping pure and independent of any JPEG decode.
--
-- WHAT IT DOES (BL-07): partition an ORDERED list of frames into clusters; ONE anchor per cluster
-- hits the provider and its keywords transfer to near-duplicate followers (the transfer/result
-- join lives in results.lua). group emits the anchors (in input order) and a follower->anchor map.
--
-- ORDERING + TIE-BREAK: the CALLER must sort frames before calling and group assumes that order.
-- The orchestrator's sort key is (timeEpoch ASC) with a deterministic tie-break by selIndex ASC
-- for EQUAL timeEpoch. A frame with a NIL (or non-finite) timeEpoch is NOT time-clustered (it can
-- only stack-cluster); nil-time frames keep their selIndex order and never join via the time branch.
--
-- A frame joins the PREVIOUS frame's cluster iff:
--   ( time-adjacent: BOTH timeEpoch finite numbers AND (cur.timeEpoch - prev.timeEpoch) < maxGapSeconds )
--     OR ( useStacks AND both stackId present AND equal )
--   AND ( sim == nil OR sim(prev.key, cur.key) == true ).
-- Otherwise it STARTS A NEW cluster (becomes a new anchor). The anchor is the FIRST frame of each
-- cluster (a sharpness-proxy anchor choice is explicitly DEFERRED — first-of-cluster for now).
--
-- M.group(frames, opts) where
--   frames = ordered array of { key=<stable id>, timeEpoch=<number|nil>, stackId=<string|number|nil>,
--            selIndex=<integer original selection index> }
--   opts   = { maxGapSeconds=<number>, useStacks=<bool>, sim=function(prevKey,curKey)->bool }
--   -> { anchors = { <key>, ... }, followerToAnchor = { [followerKey]=anchorKey } }
--
-- NEVER raises on malformed input. Strictly Lua 5.1 common subset (no //, no goto, no <close>).

local M = {}

local INF = 1 / 0
local function finite(x)
    return type(x) == 'number' and x == x and x ~= INF and x ~= -INF
end

function M.group(frames, opts)
    local anchors = {}
    local followerToAnchor = {}

    if type(frames) ~= 'table' then
        return { anchors = anchors, followerToAnchor = followerToAnchor }
    end

    opts = type(opts) == 'table' and opts or {}
    local maxGap = finite(opts.maxGapSeconds) and opts.maxGapSeconds or 0
    local useStacks = opts.useStacks
    local sim = opts.sim   -- function(prevKey,curKey)->bool, or nil = "always similar"

    -- DETERMINISTIC SORT (robustness against unsorted input): order by (timeEpoch ASC, selIndex ASC).
    -- Frames with a NIL / non-finite timeEpoch sort AFTER all finite-time frames and are ordered
    -- among themselves by selIndex; they can NEVER be time-adjacent (the time branch already requires
    -- BOTH endpoints finite). selIndex ties / nil-selIndex fall back to the original input index so
    -- the comparator is total and stable. We sort a copy of the valid frames (table + non-nil key).
    local sorted = {}
    for i = 1, #frames do
        local cur = frames[i]
        if type(cur) == 'table' and cur.key ~= nil then
            sorted[#sorted + 1] = { frame = cur, origIndex = i }
        end
    end
    local function selOr(f)
        return finite(f.selIndex) and f.selIndex or nil
    end
    table.sort(sorted, function(ea, eb)
        local a, bb = ea.frame, eb.frame
        local ta, tb = finite(a.timeEpoch), finite(bb.timeEpoch)
        if ta ~= tb then
            -- finite time sorts before nil/non-finite time.
            return ta
        end
        if ta and tb and a.timeEpoch ~= bb.timeEpoch then
            return a.timeEpoch < bb.timeEpoch
        end
        -- equal (or both-nil) time: break by selIndex ASC (nil selIndex sorts last among ties).
        local sa, sb = selOr(a), selOr(bb)
        if sa ~= nil and sb ~= nil and sa ~= sb then
            return sa < sb
        end
        if (sa ~= nil) ~= (sb ~= nil) then
            return sa ~= nil   -- a frame WITH selIndex sorts before one without.
        end
        -- fully tied: fall back to original input order for a stable, total comparator.
        return ea.origIndex < eb.origIndex
    end)

    local prev = nil       -- the previous frame table
    local anchorKey = nil  -- the current cluster's anchor key

    for i = 1, #sorted do
        local cur = sorted[i].frame
        do
            if prev == nil then
                -- First frame: always a new anchor.
                anchors[#anchors + 1] = cur.key
                anchorKey = cur.key
            else
                -- time-adjacent only when BOTH timeEpochs are finite numbers (nil-time never merges)
                -- AND the delta is in [0, maxGap): a NEGATIVE delta (cur before prev) NEVER merges,
                -- so even pathologically unsorted input cannot fold an earlier frame into a later
                -- anchor. After the deterministic sort above the delta is normally >= 0; the explicit
                -- lower bound is belt-and-suspenders robustness.
                local timeAdjacent = false
                if finite(prev.timeEpoch) and finite(cur.timeEpoch) then
                    local delta = cur.timeEpoch - prev.timeEpoch
                    timeAdjacent = (delta >= 0) and (delta < maxGap)
                end

                -- stack-same only when useStacks AND both stackId present AND equal.
                local stackSame = false
                if useStacks and prev.stackId ~= nil and cur.stackId ~= nil
                    and prev.stackId == cur.stackId then
                    stackSame = true
                end

                local window = timeAdjacent or stackSame
                -- sim is consulted ONLY within a gap/stack window (and only if provided).
                local similar = true
                if window and sim ~= nil then
                    similar = sim(prev.key, cur.key) == true
                end

                if window and similar then
                    followerToAnchor[cur.key] = anchorKey   -- joins the current cluster.
                else
                    anchors[#anchors + 1] = cur.key          -- starts a new cluster.
                    anchorKey = cur.key
                end
            end
            prev = cur
        end
    end

    return { anchors = anchors, followerToAnchor = followerToAnchor }
end

return M
