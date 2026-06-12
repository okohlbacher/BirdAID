-- SPDX-License-Identifier: MIT
-- BirdAID.lrdevplugin/src/batcher.lua (Phase 12 — WBATCH-01 slice / WBATCH-02 flushAll)
--
-- PURE module: it imports NO Lightroom SDK namespace and requires only the pure src.writeplan
-- core, so it is require-able under stock lua / lua5.1 / luajit for offline unit testing (the
-- CODEX-mandated separation invariant). It is the BL-14 incremental-write coordinator: it slices
-- the already-collected results[] (assembled OUTSIDE any catalog write gate) into batches and
-- flushes each batch through the UNCHANGED writeplan.planReport plus an INJECTED apply function,
-- threading a cumulative already-written set forward so add-only idempotency holds across batch
-- boundaries. No gate, no network, no SDK here — the only side effect is the injected applyFn.
--
-- INPUT (the same per-photo records writeplan consumes; assembled by the orchestrator/entry):
--   results = array of per-photo records, each:
--     { photoKey = <stable string id>,
--       photo    = <opaque handle | nil>,
--       response = <validated response table> | nil,   -- nil means the per-photo step errored
--       error    = <string> | nil,
--       existingNames = { [name]=true, ... } }          -- the photo's current keyword-name set
--   prefs   = an ALREADY-NORMALIZED settings table (settings.normalizedPrefs): reads
--             writeBatchSize (NUMBER, 0 = single end-of-run write) + the dryRun / threshold /
--             singleKeywordPerPhoto keys writeplan needs. The CALLER normalizes; this module
--             never requires settings (kept Lr-free + decoupled).
--   applyFn = INJECTED side-effecting writer. In production a closure calling
--             src.lr.catalog_writer.apply (ONE write gate per chunk) that RETURNS the apply
--             status string; offline a capturing spy. Signature: applyFn(plan, report) -> status
--             where status is one of 'noop'|'executed'|'queued'|'aborted'|'error'.
--
-- OUTPUT:
--   slice(results, batchSize) -> { chunk, ... }
--     DEFAULT-SAFE INVARIANT (WBATCH-01 / RESEARCH A5): batchSize nil / non-number / <1 /
--     >= #results ⇒ exactly ONE chunk that IS the original results table (byte-for-byte today's
--     single end-of-run write). A positive size < #results ⇒ ceil(#results/size) contiguous,
--     order-preserving chunks.
--   flushAll(results, prefs, applyFn) -> { applyCount, statuses, perChunkPlans }
--     One applyFn call per chunk; folds a chunk's written names forward into the cumulative
--     addedSoFar set ONLY on a committed-success status ('executed' or 'noop') AND only on a
--     non-dry-run flush (CODEX HIGH-1). A non-committed status ('error'/'aborted'/'queued') or a
--     dry-run leaves the names UNWRITTEN so a later chunk / retry re-attempts them (the add-only
--     diff makes the re-present harmless/idempotent — nothing is silently lost).
--
-- Strictly Lua 5.1 common subset: no \u{}, no //, no goto, no <close>; unpack is global.
-- This module imports no SDK and is kept clean of the SDK-import token so the negative-purity
-- grep prints only the known-pure require of the writeplan core.

local writeplan = require('src.writeplan')

local M = {}

-- COMMITTED-SUCCESS fold gate (CODEX HIGH-1): catalog_writer.apply returns one of
-- 'noop'|'executed'|'queued'|'aborted'|'error'. Fold a chunk's names forward ONLY on a real
-- committed write ('executed') or a true no-op ('noop' — nothing needed writing, already present,
-- so safe to treat as written). 'queued' is conservatively NOT-yet-committed (the deferred write
-- may not have landed); 'aborted'/'error' obviously did not commit. On any of those — and on any
-- dry-run flush — the names must STAY unwritten so a retry re-presents them.
local COMMITTED = { executed = true, noop = true }

-- ---------------------------------------------------------------------------
-- slice(results, batchSize) -> { chunk, ... }   (WBATCH-01)
-- ---------------------------------------------------------------------------
function M.slice(results, batchSize)
    local n = #results
    if type(batchSize) ~= 'number' or batchSize < 1 or batchSize >= n then
        return { results }                      -- default-safe: one batch == today's behavior
    end
    local chunks, i = {}, 1
    while i <= n do
        local chunk = {}
        for j = i, math.min(i + batchSize - 1, n) do chunk[#chunk + 1] = results[j] end
        chunks[#chunks + 1] = chunk
        i = i + batchSize
    end
    return chunks
end

-- ---------------------------------------------------------------------------
-- flushAll(results, prefs, applyFn) -> { applyCount, statuses, perChunkPlans }   (WBATCH-02)
--
-- Slices via M.slice(results, prefs.writeBatchSize) and, for each chunk:
--   1. merges addedSoFar[photoKey] (names written in PRIOR COMMITTED batches this run) into a
--      FRESH copy of that record's existingNames BEFORE calling writeplan.planReport (Option A —
--      build() stays UNCHANGED). D4 (M1): the chunk records handed to writeplan are SHALLOW CLONES
--      of the caller's records (every key copied, then existingNames overridden with the merged
--      set), so neither the record table NOR its existingNames table is mutated in place — any
--      later use of the caller's original records is uncorrupted;
--   2. calls applyFn ONCE per chunk and captures the RETURNED status string;
--   3. folds report.plan.entries[*].addKeywords forward into addedSoFar[photoKey] ONLY when the
--      status is a committed-success AND the flush is not a dry-run.
-- ---------------------------------------------------------------------------
function M.flushAll(results, prefs, applyFn)
    if type(results) ~= 'table' then results = {} end
    local batchSize = (type(prefs) == 'table') and prefs.writeBatchSize or nil

    local addedSoFar = {}                        -- [photoKey] = { [name]=true } committed so far
    local statuses = {}
    local perChunkPlans = {}
    local applyCount = 0

    for _, chunk in ipairs(M.slice(results, batchSize)) do
        -- (1) Build a FRESH per-chunk record list. When a record has prior-committed names, hand
        --     writeplan a SHALLOW CLONE of the record (every key copied) whose existingNames is the
        --     merged set — never assigning back onto the caller's record (D4 / M1: the header used
        --     to claim no mutation while reassigning rec.existingNames in place). Records with no
        --     prior set are passed through unchanged (read-only by writeplan, so safe to reuse).
        local planChunk = {}
        for ci, rec in ipairs(chunk) do
            local prior = addedSoFar[rec.photoKey]
            if prior then
                local merged = {}
                if type(rec.existingNames) == 'table' then
                    for k in pairs(rec.existingNames) do merged[k] = true end
                end
                for k in pairs(prior) do merged[k] = true end
                local clone = {}
                for k, v in pairs(rec) do clone[k] = v end
                clone.existingNames = merged
                planChunk[ci] = clone
            else
                planChunk[ci] = rec
            end
        end

        -- (2) UNCHANGED builder + the single injected side-effecting apply per chunk.
        local report = writeplan.planReport(planChunk, prefs)
        local status = applyFn(report.plan, report)
        applyCount = applyCount + 1
        statuses[#statuses + 1] = status
        perChunkPlans[#perChunkPlans + 1] = report.plan

        -- (3) Committed-success, non-dry-run fold gate (CODEX HIGH-1).
        if not report.dryRun and COMMITTED[status] then
            for _, e in ipairs(report.plan.entries) do
                local s = addedSoFar[e.photoKey]
                if s == nil then s = {}; addedSoFar[e.photoKey] = s end
                for _, name in ipairs(e.addKeywords) do s[name] = true end
            end
        end
    end

    return { applyCount = applyCount, statuses = statuses, perChunkPlans = perChunkPlans }
end

return M
