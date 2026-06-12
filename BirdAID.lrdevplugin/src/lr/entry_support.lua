-- SPDX-License-Identifier: MIT
-- BirdAID.lrdevplugin/src/lr/entry_support.lua (Wave-D D8 — shared entry-point scaffold)
--
-- THIN Lr-GLUE adapter. This file lives in the src/lr/ glue tier and is one of the few modules that
-- MAY touch the Lightroom SDK indirectly (it calls injected Lr-backed closures: a progress scope's
-- isCanceled, a metadata reader, LrTasks.pcall, catalogWriter.apply). It is NOT a pure module and is
-- intentionally EXCLUDED from the negative-purity grep. It is loaded only by an entry point AFTER
-- birdaid_bootstrap.lua has installed the require shim.
--
-- WHY THIS EXISTS (D8 / H4): IdentifyBirds.lua and DeepIdentify.lua carried VERBATIM (or near-
-- verbatim) copies of the same per-run scaffold helpers. DeepIdentify even labelled them
-- "Copied verbatim". Drift between two hand-maintained copies of the cancel/name/flush glue is a
-- hazard, so the truly-shared helpers (identical semantics in both) live here and both entries
-- require them. Anything that DIFFERS semantically (the per-photo pipelines, the deep export loop)
-- deliberately stays in each entry.
--
-- PUBLIC SURFACE:
--   * M.cancelled(progress) -> bool. Guarded read of progress:isCanceled(); a missing/throwing
--       scope never crashes the run (degrades to false = not cancelled).
--   * M.photoName(photo, metadataReader) -> string. Best-effort formatted file name for human
--       context; never raises, never PII-leaks (the metadata reader is INJECTED so this stays
--       decoupled from the entry's own module-scoped reader).
--   * M.flushWrite(opts) -> writeResult. The batched single-write fold both entries share. Builds
--       the per-chunk applyFn (catalogWriter.apply with a PARAMETERIZED Undo actionName — the only
--       thing that differed between the two entries: " (deep)" suffix), runs batcher.flushAll, and
--       folds the chunk statuses into the authoritative summary writeResult ('error' if ANY chunk
--       errored, else the last committed status). NO gallery/flush logic enters the gate (CLAUDE.md
--       HARD CONSTRAINT — the ONLY thing inside the encapsulated catalog_writer gate is apply).
--
-- Strictly Lua 5.1 common subset: no \u{}, no //, no goto, no <close>.

local M = {}

-- cancelled(progress) -> bool, guarded so a missing/throwing isCanceled never crashes the run.
function M.cancelled(progress)
    local ok, c = pcall(function() return progress:isCanceled() end)
    return (ok and c) or false
end

-- photoName(photo, metadataReader) -> string. Best-effort formatted file name; never raises,
-- never PII-leaks. metadataReader is injected (each entry owns its own require of it).
function M.photoName(photo, metadataReader)
    local ok, name = pcall(function() return metadataReader.formattedFileName(photo) end)
    return (ok and name) or "(unknown file)"
end

-- flushWrite(opts) -> writeResult. opts = {
--   catalogWriter = <src.lr.catalog_writer>,   -- the encapsulated single-gate writer.
--   catalog       = <LrCatalog>,
--   batcher       = <src.batcher>,             -- pure cumulative-diff flush coordinator.
--   results       = <array of per-photo records>,
--   prefs         = <normalized prefs>,        -- reads writeBatchSize.
--   runId         = <string>,
--   actionName    = <string>,                  -- Undo step label (the ONLY per-entry difference).
--   pcall         = <LrTasks.pcall>,           -- yield-safe outer gate wrap.
-- }
-- Mirrors the byte-identical fold both entries had: applyFn reproduces the shipped catalogWriter.apply
-- 5-arg signature per chunk and RETURNS its status string so flushAll gates the cross-batch fold on a
-- committed success; the summary writeResult is 'error' if ANY chunk errored, else the last committed
-- status (single-chunk runs are byte-identical to the prior inline code).
function M.flushWrite(opts)
    local catalogWriter = opts.catalogWriter
    local catalog       = opts.catalog
    local batcher       = opts.batcher
    local results       = opts.results
    local prefs         = opts.prefs
    local runId         = opts.runId
    local actionName    = opts.actionName
    local lrPcall       = opts.pcall

    local function applyFn(plan, _chunkReport)
        return catalogWriter.apply(
            catalog,
            plan,
            actionName,
            { runId = runId },
            { pcall = lrPcall }   -- yield-safe outer gate wrap (the gate yields internally)
        )
    end

    local flush = batcher.flushAll(results, prefs, applyFn)

    -- Authoritative writeResult for the summary: 'error' if ANY chunk errored, else the last
    -- committed status (executed/noop). A single-chunk run is byte-identical to the inline code.
    local writeResult = 'noop'
    local statuses = (type(flush) == 'table' and type(flush.statuses) == 'table') and flush.statuses or {}
    for si = 1, #statuses do
        local s = statuses[si]
        if s == 'error' then return 'error' end
        writeResult = s
    end
    return writeResult
end

return M
