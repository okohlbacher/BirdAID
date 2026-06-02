-- SPDX-License-Identifier: MIT
-- BirdAID.lrdevplugin/src/run_state.lua (Phase 12 — RETRY-01 persisted OUTCOME shape)
--
-- PURE module: imports NO Lightroom SDK module, uses NO os.time/date/clock, NO math.random.
-- Deterministic and require-able under stock lua / lua5.1 / luajit (the CODEX-mandated separation
-- invariant). The Lr persistence (run_state_store: read/write the serialized shape to prefs/disk)
-- and the live (status, response, write-report) -> args lifting are Plan 03; this module owns only
-- the PURE OUTCOME taxonomy + the secret-free serialization SHAPE + the classifier.
--
-- SECRETS / PII: the persisted run-state carries ONLY { photoId, outcome } — NEVER a token, an AI
-- response body, a raw per-photo status, GPS coordinates, a capture date, or a file path. serialize
-- PROJECTS each record to exactly those two fields (dropping everything else), mirroring the
-- catalog_writer "NEVER a raw path / gps / date" comment discipline. There is no place here for a
-- secret to leak, by construction.
--
-- CRITICAL TERMINAL-OUTCOME MODEL (CODEX HIGH-3): a record's done-ness is its OUTCOME string, NOT a
-- `wrote==true` boolean. TERMINAL (do-not-retry): written / existing / no-bird / no-detection.
-- RETRYABLE: deferred / timed-out / errored / cancelled. An unknown / nil outcome is treated as
-- NON-terminal so a corrupt/old record is retried (safe), never silently skipped.
--
-- M.OUTCOMES                 -> { [outcome] = { terminal = <bool> } } for every known outcome
-- M.isTerminal(outcome)      -> true iff outcome is a known TERMINAL outcome (unknown/nil => false)
-- M.isRetryable(outcome)     -> true iff outcome is a known RETRYABLE outcome (unknown/nil => false)
-- M.serialize(records)       -> array of { photoId=<string>, outcome=<string> } (secret-free shape)
-- M.deserialize(serialized)  -> the same shape, defensively rebuilt (malformed dropped, nil => {})
-- M.outcomeFor(args)         -> the canonical OUTCOME string for a per-photo result/write tuple
--
-- Strictly Lua 5.1 common subset: no \u{}, no //, no goto, no <close>; unpack global.

local M = {}

-- The known OUTCOMES, each flagged terminal (do-not-retry) or retryable.
M.OUTCOMES = {
    -- TERMINAL (do not retry).
    ['written']      = { terminal = true },
    ['existing']     = { terminal = true },
    ['no-bird']      = { terminal = true },
    ['no-detection'] = { terminal = true },
    -- RETRYABLE.
    ['deferred']     = { terminal = false },
    ['timed-out']    = { terminal = false },
    ['errored']      = { terminal = false },
    ['cancelled']    = { terminal = false },
}

-- isTerminal(outcome): true iff a KNOWN terminal outcome. An unknown / nil outcome is NOT terminal
-- (so selectIncomplete retries it — a corrupt/old record is never silently treated as done).
function M.isTerminal(outcome)
    local o = M.OUTCOMES[outcome]
    return o ~= nil and o.terminal == true
end

-- isRetryable(outcome): true iff a KNOWN retryable outcome. Unknown / nil => false here (the
-- selection-side "retry the unknown" decision is isTerminal==false, kept distinct from this
-- known-retryable predicate so callers can tell "known retryable" from "unknown/missing").
function M.isRetryable(outcome)
    local o = M.OUTCOMES[outcome]
    return o ~= nil and o.terminal == false
end

-- nonEmptyString(v): v is a non-empty string.
local function nonEmptyString(v)
    return type(v) == 'string' and v ~= ''
end

-- projectRecord(r): the secret-free { photoId, outcome } projection of one record, or nil if the
-- record is malformed (photoId not a non-empty string, or outcome not a known OUTCOME). Defensive
-- on BOTH serialize (drop garbage on the way out) and deserialize (drop garbage on the way in).
local function projectRecord(r)
    if type(r) ~= 'table' then return nil end
    if not nonEmptyString(r.photoId) then return nil end
    if M.OUTCOMES[r.outcome] == nil then return nil end
    return { photoId = r.photoId, outcome = r.outcome }
end

-- serialize(records): project each record to EXACTLY { photoId, outcome } — drop every other field
-- (response / token / raw status / gps / path) and any malformed record. Returns a plain-data array.
function M.serialize(records)
    local out = {}
    if type(records) ~= 'table' then return out end
    for i = 1, #records do
        local proj = projectRecord(records[i])
        if proj ~= nil then out[#out + 1] = proj end
    end
    return out
end

-- deserialize(serialized): defensively rebuild the { photoId, outcome } shape. Non-table input
-- (nil / string / number) degrades to {} without raising; malformed records are dropped.
function M.deserialize(serialized)
    local out = {}
    if type(serialized) ~= 'table' then return out end
    for i = 1, #serialized do
        local proj = projectRecord(serialized[i])
        if proj ~= nil then out[#out + 1] = proj end
    end
    return out
end

-- outcomeFor(args): the SINGLE source of truth mapping a per-photo result/write tuple to its
-- canonical OUTCOME string. args = { status, birdPresent, detectionCount, wroteCount } — all PLAIN
-- VALUES lifted by the Plan-03 wiring from the per-photo result + write report (NO SDK objects).
--
--   'identified' + wroteCount>0                 -> 'written'      (a keyword was written this run)
--   'identified' + birdPresent==false           -> 'no-bird'      (valid response, no bird)
--   'identified' + detectionCount==0            -> 'no-detection' (valid response, empty detections)
--   'identified' + wroteCount==0 + detections>0 -> 'existing'     (already present, terminally done)
--   'deferred' / 'cancelled' / 'errored' / 'timed-out' -> the matching retryable outcome
--   any unknown / nil status                     -> nil           (treated non-terminal -> retried)
--
-- birdPresent==false takes precedence over the detection-count branches (a valid no-bird response).
function M.outcomeFor(args)
    if type(args) ~= 'table' then return nil end
    local status = args.status

    if status == 'identified' then
        local wrote = tonumber(args.wroteCount) or 0
        if wrote > 0 then return 'written' end
        if args.birdPresent == false then return 'no-bird' end
        local dets = tonumber(args.detectionCount) or 0
        if dets == 0 then return 'no-detection' end
        return 'existing'
    elseif status == 'deferred' then
        return 'deferred'
    elseif status == 'cancelled' then
        return 'cancelled'
    elseif status == 'errored' then
        return 'errored'
    elseif status == 'timed-out' then
        return 'timed-out'
    end

    -- unknown / nil status: return nil so the photo is treated as non-terminal and retried (safe).
    return nil
end

return M
