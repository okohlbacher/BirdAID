-- SPDX-License-Identifier: MIT
-- BirdAID.lrdevplugin/src/lr/stack_reader.lua (Phase 9 — BL-07 stack-membership read)
--
-- THIN Lr-GLUE adapter. This file lives in the src/lr/ glue tier and MAY touch the Lightroom SDK
-- (it calls photo:getRawMetadata). It is NOT a pure module and is intentionally EXCLUDED from the
-- negative-purity grep gate (which scopes only the pure src/ modules). It is loaded only by an
-- entry point AFTER birdaid_bootstrap.lua has installed the require shim. It mirrors the guarded
-- rawField pattern in src/lr/metadata_reader.lua (each getRawMetadata read under pcall, NEVER
-- raises).
--
-- WHAT IT PROVIDES (BL-07 clustering pre-pass):
--   * M.stackId(photo)         -> a STABLE stack identifier string | nil. A nil id disables the
--                                 stack branch of cluster.group for that photo (the SAFE default:
--                                 it falls back to time-gap-only clustering, or none).
--   * M.captureTimeEpoch(photo)-> a number (seconds, Cocoa epoch) | nil — the time signal the
--                                 cluster pre-pass sorts/groups by. Guarded; nil disables the time
--                                 branch for that photo (per cluster.group's nil-time semantics).
--   * M.probe(photo)           -> { keysWithValues = { <key>, ... }, ... } — a DEBUG probe that
--                                 records WHICH candidate keys returned a value. The orchestrator
--                                 logs this (token-free) so the live in-LrC pass (Task 12) reveals
--                                 the REAL key shapes.
--
-- *** LIVE-UNVERIFIED ASSUMPTION (A-STACK) ***
-- The EXACT raw-metadata keys for stack membership are NOT confirmed against a real LrC catalog.
-- We read CANDIDATE keys in priority order and combine into ONE stable id. If the live Task-12
-- pass shows these keys are wrong/empty, the observed keys (from M.probe via the DEBUG log) MUST
-- be folded back into CANDIDATE_KEYS below. The candidate set (from the LrC SDK docs / research):
--   'topOfStackInFolderContainingPhoto' — the photo at the top of this photo's stack. Its identity
--      (a stable per-photo handle/string) makes the BEST stack id: every member of one stack shares
--      the same top-of-stack, so they hash to the same id and cluster together.
--   'stackInFolderMembers'              — the array of member photos. The FIRST member's identity is
--      a fallback stable id (also shared across the stack).
--   'stackPositionInFolder'             — this photo's 1-based position in its stack (a number). NOT
--      a stable cross-photo id on its own, but presence (>0 / non-nil) signals membership.
--   'isInStackInFolder'                 — a boolean membership flag (may not exist on all SDK builds).
-- A nil from EVERY candidate -> nil stackId (no stack clustering for the photo — safe).
--
-- LOGGING / PII: this file does not create its own LrLogger; if it ever logs it MUST use the single
-- require 'src.log' sink. It logs only token-free, NON-PII data — the NAMES of the candidate keys
-- that returned a value (never the value, never the path/gps/date). The orchestrator owns the
-- actual log call (passing a loggable formatted filename + runId); this module returns the probe
-- data so the call site stays the single logging owner.
--
-- Strictly Lua 5.1 common subset: no \u{}, no //, no goto, no <close>; unpack global. MUST run
-- inside an LrTasks task (getRawMetadata is an SDK call); the caller owns the task + per-photo
-- LrTasks.pcall isolation.

local M = {}

-- Candidate stack-membership keys, in PRIORITY order. The first key that yields a usable stable id
-- wins. ADJUST THIS LIST after the Task-12 live observation if the assumed keys are wrong (see the
-- header). The order matters: a shared top-of-stack identity is the strongest id.
local CANDIDATE_KEYS = {
    'topOfStackInFolderContainingPhoto',
    'stackInFolderMembers',
    'stackPositionInFolder',
    'isInStackInFolder',
}

-- rawField(photo, key) -> the value of photo:getRawMetadata(key), or nil if the accessor is missing
-- OR THROWS. Mirrors metadata_reader.rawField: a single throwing accessor (an SDK that errors on an
-- unknown key for a given file) must NOT abort the read — each candidate is read independently under
-- pcall and a failure yields nil for that key only.
local function rawField(photo, key)
    local ok, value = pcall(function() return photo:getRawMetadata(key) end)
    if ok then return value end
    return nil
end

-- valueIsPresent(v) -> bool. A "present" raw value is one we can derive signal from: a non-empty
-- string/number, a boolean true, or a non-empty table (e.g. stackInFolderMembers). nil / false /
-- empty string / empty table count as ABSENT.
local function valueIsPresent(v)
    local t = type(v)
    if t == 'string' then return v ~= '' end
    if t == 'number' then return v == v end            -- a finite-ish number (NaN -> absent)
    if t == 'boolean' then return v == true end
    if t == 'table' then return next(v) ~= nil end     -- non-empty table
    if t == 'userdata' then return true end            -- an SDK photo handle (top-of-stack) is present
    return false
end

-- stableIdFrom(key, value) -> a STABLE string id derived from one candidate's raw value, or nil if
-- this value cannot yield a stable cross-photo id (e.g. a position number / a bare boolean — those
-- signal membership but are NOT a stack-unique id). Stack members must map to the SAME id.
local function stableIdFrom(key, value)
    if key == 'topOfStackInFolderContainingPhoto' then
        -- The top-of-stack photo handle; tostring() is a stable per-photo key (same as the photoKey
        -- convention used elsewhere). Every member shares the same top -> same id.
        return 'top:' .. tostring(value)
    elseif key == 'stackInFolderMembers' then
        -- The member array; the FIRST member's identity is shared across the whole stack.
        if type(value) == 'table' and value[1] ~= nil then
            return 'members:' .. tostring(value[1])
        end
        return nil
    end
    -- stackPositionInFolder / isInStackInFolder only PROVE membership; they are not a stable
    -- stack-unique id on their own, so they do not produce an id here (they feed the probe instead).
    return nil
end

-- probe(photo) -> { keysWithValues = { <key>, ... } }. Reads EVERY candidate key (guarded) and
-- records which ones returned a present value. PII-free (only key NAMES, never values). The
-- orchestrator logs this so the Task-12 live pass reveals the real key shapes.
function M.probe(photo)
    local keysWithValues = {}
    if type(photo) ~= 'userdata' and type(photo) ~= 'table' then
        return { keysWithValues = keysWithValues }
    end
    for i = 1, #CANDIDATE_KEYS do
        local key = CANDIDATE_KEYS[i]
        local v = rawField(photo, key)
        if valueIsPresent(v) then
            keysWithValues[#keysWithValues + 1] = key
        end
    end
    return { keysWithValues = keysWithValues }
end

-- stackId(photo) -> a stable id string | nil. Reads candidate keys in priority order; the FIRST
-- one that yields a stable id wins. nil on any/all failures (no stack clustering for the photo —
-- the safe default). Never raises.
function M.stackId(photo)
    if type(photo) ~= 'userdata' and type(photo) ~= 'table' then
        return nil
    end
    for i = 1, #CANDIDATE_KEYS do
        local key = CANDIDATE_KEYS[i]
        local v = rawField(photo, key)
        if valueIsPresent(v) then
            local id = stableIdFrom(key, v)
            if id ~= nil then
                return id
            end
        end
    end
    return nil
end

-- captureTimeEpoch(photo) -> number (Cocoa-epoch seconds) | nil. The time signal the cluster
-- pre-pass sorts + time-gaps by. Reads dateTimeOriginal with the same fallback chain as
-- metadata_reader (Original -> Digitized -> dateTime), each guarded. Returns a finite number or
-- nil; a nil disables the time branch of cluster.group for that photo (per its nil-time semantics).
function M.captureTimeEpoch(photo)
    if type(photo) ~= 'userdata' and type(photo) ~= 'table' then
        return nil
    end
    local v = rawField(photo, 'dateTimeOriginal')
          or rawField(photo, 'dateTimeDigitized')
          or rawField(photo, 'dateTime')
    if type(v) == 'number' and v == v then          -- finite-ish (NaN-guarded) number
        return v
    end
    return nil
end

return M
