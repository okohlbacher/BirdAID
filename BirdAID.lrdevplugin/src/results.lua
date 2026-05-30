-- SPDX-License-Identifier: MIT
-- BirdAID.lrdevplugin/src/results.lua (Phase 9 — BL-06/BL-07 per-photo RESULT MODEL)
--
-- PURE module: imports NO Lr* module, uses NO os.time/date/clock, NO math.random. Deterministic
-- and require-able under stock lua / lua5.1 / luajit (the CODEX-mandated separation invariant).
--
-- WHAT IT DOES: produce EXACTLY ONE per-photo result for EVERY selected photo by joining the pool's
-- anchor terminal-status map (worker_pool.run().statusByAnchorKey) with the cluster follower->anchor
-- map and the collected anchor responses (worker_pool.run().responseByAnchorKey). This is the model
-- the orchestrator (Wave 3) feeds into the results->writeplan adapter.
--
-- NOTE ON SEPARATION: results.lua is photoKey-keyed and Lr-free. The photoKey->Lr-handle binding and
-- the PER-PHOTO existingNames read for writeplan live in the ORCHESTRATOR (the adapter), NOT here.
--
-- M.build(opts) where opts = {
--     selection        = { <photoKey>, ... },                 -- every selected photo, in order
--     anchors          = { <anchorKey>, ... },                -- from cluster.group (== selection off)
--     followerToAnchor = { [followerKey]=anchorKey },         -- from cluster.group ({} when off)
--     anchorStatus     = { [anchorKey]='identified'|'fatal'|'deferred'|'cancelled' },
--     anchorResponse   = { [anchorKey]=<contract-valid response|nil> },
--   } -> { byPhoto = { [photoKey]=result }, ordered = { result, ... } } where result =
--        { photo=<photoKey>, status, response?, inheritedFrom? } per the RESULT MODEL.
--
-- JOIN RULES (anchor-failure transfer semantics):
--   ANCHOR a with anchorStatus[a]:
--     'identified' -> { status='identified', response=anchorResponse[a] }
--     'fatal'      -> { status='deferred' }   (anchor fatal => WHOLE cluster deferred)
--     'deferred'   -> { status='deferred' }   (breaker-open at dispatch OR pre-call gate)
--     'cancelled'  -> { status='cancelled' }
--     (missing)    -> { status='deferred' }   (safe; never a false identified)
--   FOLLOWER f of anchor a inherits the anchor's EFFECTIVE cluster status:
--     anchor identified -> { status='identified', response=anchorResponse[a], inheritedFrom=a }
--     anchor fatal/deferred -> { status='deferred', inheritedFrom=a }   (NEVER inherit on failure)
--     anchor cancelled -> { status='cancelled', inheritedFrom=a }
--     anchor missing   -> { status='deferred', inheritedFrom=a }        (safe)
--
-- INVARIANTS: every selection photo appears EXACTLY ONCE; only 'identified' carries a response.
--
-- Strictly Lua 5.1 common subset: no \u{}, no //, no goto, no <close>; unpack global.

local M = {}

-- effectiveStatus(rawStatus): normalize an anchor's raw pool status to its CLUSTER-level effective
-- status. 'fatal' collapses to 'deferred' (anchor failure defers the whole cluster); a missing /
-- unexpected status is 'deferred' (safe). 'identified'/'deferred'/'cancelled' pass through.
local function effectiveStatus(rawStatus)
    if rawStatus == 'identified' then return 'identified' end
    if rawStatus == 'cancelled' then return 'cancelled' end
    if rawStatus == 'deferred' then return 'deferred' end
    -- 'fatal', nil, or anything unexpected -> deferred (cluster-level defer; retried next run).
    return 'deferred'
end

function M.build(opts)
    opts = type(opts) == 'table' and opts or {}
    local selection = type(opts.selection) == 'table' and opts.selection or {}
    local followerToAnchor = type(opts.followerToAnchor) == 'table' and opts.followerToAnchor or {}
    local anchorStatus = type(opts.anchorStatus) == 'table' and opts.anchorStatus or {}
    local anchorResponse = type(opts.anchorResponse) == 'table' and opts.anchorResponse or {}

    local byPhoto = {}
    local ordered = {}

    for i = 1, #selection do
        local photoKey = selection[i]
        if photoKey ~= nil and byPhoto[photoKey] == nil then
            local anchorKey = followerToAnchor[photoKey]
            local result

            if anchorKey == nil then
                -- this photo is an ANCHOR (or a non-clustered photo): use its own status.
                local eff = effectiveStatus(anchorStatus[photoKey])
                local resp = anchorResponse[photoKey]
                -- an 'identified' anchor with a MISSING / non-table response is INVALID: degrade
                -- the whole cluster to 'deferred' (never emit identified with a nil response).
                if eff == 'identified' and type(resp) ~= 'table' then eff = 'deferred' end
                result = { photo = photoKey, status = eff }
                if eff == 'identified' then
                    result.response = resp
                end
            else
                -- this photo is a FOLLOWER: inherit the anchor's EFFECTIVE cluster status.
                local eff = effectiveStatus(anchorStatus[anchorKey])
                local resp = anchorResponse[anchorKey]
                -- same guard at the cluster level: a follower of an 'identified' anchor whose
                -- response is missing/invalid degrades to 'deferred' (no response inherited).
                if eff == 'identified' and type(resp) ~= 'table' then eff = 'deferred' end
                result = { photo = photoKey, status = eff, inheritedFrom = anchorKey }
                if eff == 'identified' then
                    result.response = resp
                end
            end

            byPhoto[photoKey] = result
            ordered[#ordered + 1] = result
        end
    end

    return { byPhoto = byPhoto, ordered = ordered }
end

return M
