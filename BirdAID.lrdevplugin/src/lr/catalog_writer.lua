-- SPDX-License-Identifier: MIT
-- BirdAID.lrdevplugin/src/lr/catalog_writer.lua (WR-01 mechanics / WR-02 live / WR-03 add-only)
--
-- THIN Lr-GLUE adapter. This file lives in the src/lr/ glue tier and is one of the few
-- modules ALLOWED to touch the Lightroom SDK (catalog:withWriteAccessDo, catalog:createKeyword,
-- photo:addKeyword, photo:getRawMetadata). It is NOT a pure module and is intentionally
-- EXCLUDED from the negative-purity grep gate (which scopes only the pure src/ modules). It is
-- loaded only by a live in-Lightroom entry point (the real per-photo pipeline) AFTER
-- birdaid_bootstrap.lua has installed the require shim.
--
-- It does EXACTLY two things, and nothing else:
--   1. M.readExistingNames(photo) -> { [name]=true }  (a READ; call OUTSIDE the write gate)
--      Reads the photo's directly-applied keyword names so the pure writeplan diff can be
--      add-only. Defensive: never raises (a throwing accessor yields an empty/partial set).
--   2. M.apply(catalog, plan, actionName, fields, opts) -> 'noop'|'executed'|'queued'|'aborted'|'error'
--      Applies a pre-computed ADD-ONLY plan inside EXACTLY ONE catalog:withWriteAccessDo gate.
--
-- YIELD-SAFE pcall (opts.pcall): catalog:withWriteAccessDo YIELDS internally to acquire write
-- access AND -- as a LIVE in-LrC re-run proved (the inner calls were wrongly assumed synchronous)
-- -- so do catalog:createKeyword and photo:addKeyword INSIDE the open gate. In Lua 5.1 you cannot
-- yield across a standard `pcall` C-frame, so wrapping ANY of these in the stock C pcall makes the
-- SDK's can-yield guard fail: the outer wrap surfaces "must be called from within an LrTask", and
-- the inner per-keyword wraps surface "Yielding is not allowed within a C or metamethod call" (so
-- every keyword errors -> addedCount 0). apply() therefore accepts an optional
-- `opts = { pcall = <yield-safe pcall> }`; live callers pass `opts.pcall = LrTasks.pcall`. This
-- mirrors the proven src/lr/http.lua `deps.pcall` convention (where the yielding LrHttp.post is
-- wrapped in LrTasks.pcall). The SAME resolved `protect` wraps BOTH the OUTER gate AND the INNER
-- per-keyword createKeyword/addKeyword calls -- ALL of them can yield inside a live LrTask. When
-- `opts` (or opts.pcall) is absent or not a function, apply falls back to the standard global
-- `pcall`, which is still correct for the offline stock-lua suite (no `import`/LrTasks; the stubbed
-- catalog/createKeyword/addKeyword do NOT yield).
--
-- DI-RUN-SENTINELS: the OUTER gate closure (gateRan) AND each INNER per-keyword createKeyword /
-- addKeyword closure (ranKw / ranAdd) set a run-sentinel as their FIRST statement, so a fake
-- protector that returns a truthy ok WITHOUT invoking the closure can NEVER report a write that did
-- not happen -- a skipped inner call is coerced to a per-keyword failure (constant, token-free
-- diagnostic), and a skipped outer gate is coerced to the DEFINED 'error' status. Real protectors
-- (LrTasks.pcall / global pcall) always invoke, so all sentinels are always true and behavior is
-- byte-for-byte unchanged on the live and offline paths.
--
-- ADD-ONLY BY CONSTRUCTION (WR-03): the writer ONLY ever calls createKeyword(returnExisting)
-- + photo:addKeyword. It NEVER removes, renames, or replaces a keyword, and the module does
-- not even contain the capability tokens to do so (so the WR-03 source grep stays clean and is
-- not inflated by prose in these comments).
--
-- ONE TIGHT GATE (WR-01): the whole plan is applied inside a single gate so the user gets one
-- clean Undo step. NO network / provider / preview / require / log call happens inside the gate
-- closure -- all collection (identify, preview, metadata.shape, the pure writeplan build) is
-- done by the caller OUTSIDE the gate, and all logging happens AFTER the gate returns. An empty
-- plan SKIPS the gate entirely (no spurious Undo step). The gate body is pcall-wrapped and each
-- per-keyword call is guarded so a mid-batch SDK exception is isolated: it is caught, logged
-- with error=tostring(err) and subject context, returns a DEFINED 'error' status, and the run
-- is NOT aborted (per-run isolation, matching the project's "errors must speak" convention).
--
-- LOGGING / PII: routes the write result through the single require 'src.log' sink (NEVER a new
-- LrLogger). It logs only structured fields (runId / photoCount / addCount / writeResult, plus a
-- best-effort FORMATTED filename as a subject) -- NEVER a raw path / gps / date; redaction at the
-- sink is the backstop.
--
-- Strictly Lua 5.1 common subset. MUST run inside an LrTasks task (the SDK calls require it);
-- the caller (entry / pipeline) owns the task.

local log = require 'src.log'

local M = {}

-- ---------------------------------------------------------------------------
-- readExistingNames(photo) -> { [name]=true }
-- Reads the photo's directly-applied keyword names for the add-only diff. Defensive: a nil
-- photo, a throwing getRawMetadata, or a throwing kw:getName() yields an empty (or partial)
-- set rather than raising. Call this OUTSIDE the write gate (it is a read).
-- ---------------------------------------------------------------------------
function M.readExistingNames(photo)
    local set = {}
    if type(photo) ~= 'userdata' and type(photo) ~= 'table' then
        return set
    end
    local ok, kws = pcall(function() return photo:getRawMetadata('keywords') end)
    if ok and type(kws) == 'table' then
        for _, kw in ipairs(kws) do
            local okn, name = pcall(function() return kw:getName() end)
            if okn and type(name) == 'string' and name ~= '' then
                set[name] = true
            end
        end
    end
    return set
end

-- A safe, loggable subject for a plan entry (NEVER the raw path). Best-effort: never raises.
-- Returns nil if no photo / the SDK call fails (the caller simply omits the field).
local function safeFileName(photo)
    if type(photo) ~= 'userdata' and type(photo) ~= 'table' then
        return nil
    end
    local name
    pcall(function() name = photo:getFormattedMetadata('fileName') end)
    if type(name) == 'string' and name ~= '' then return name end
    return nil
end

-- shallowCopy(t) -> a new table with t's top-level pairs (used to build the base log fields
-- without mutating the caller's `fields` table). Pure Lua 5.1.
local function shallowCopy(t)
    local out = {}
    if type(t) == 'table' then
        for k, v in pairs(t) do out[k] = v end
    end
    return out
end

-- DEFINED-STATUS allow-list: the only raw withWriteAccessDo verdicts we trust verbatim.
-- Any OTHER raw return (a stray string, a number, nil, true/false, ...) is treated as
-- unexpected: it is LOGGED and mapped to the DEFINED 'error' status (CODEX MUST-FIX #2).
local DEFINED_RESULTS = { executed = true, queued = true, aborted = true }

-- ---------------------------------------------------------------------------
-- apply(catalog, plan, actionName, fields, opts) -> 'noop'|'executed'|'queued'|'aborted'|'error'
--
--   catalog    = the active LrCatalog.
--   plan       = { entries = { { photoKey, photo, addKeywords = { <name>, ... } }, ... } }
--                (from src.writeplan.build / planReport; only non-empty entries appear.)
--   actionName = the Undo label (REQUIRED -- the caller passes an explicit, descriptive
--                label so the Undo step names the call site; we do NOT default it).
--   fields     = a base log-fields table (e.g. { runId = ... }); copied, never mutated.
--   opts       = OPTIONAL { pcall = <yield-safe pcall> }. The yield-safe pcall (live callers
--                pass LrTasks.pcall) wraps the OUTER withWriteAccessDo gate AND each INNER
--                per-keyword createKeyword/addKeyword -- a live LrC re-run proved ALL of these
--                yield inside the gate, so all are routed through the injected protector. Absent /
--                opts.pcall not a function -> falls back to the standard global pcall (offline-safe;
--                the stub catalog never yields).
--
-- Return semantics (LOCKED, one for every path) -- the FULL mapping:
--   'noop'     -> the plan had no entry with a non-empty addKeywords; the gate was NEVER
--                 opened (WR-02). No Undo step.
--   'executed' -> withWriteAccessDo returned the DEFINED "executed" verdict AND every
--                 per-keyword createKeyword/addKeyword succeeded (errorCount == 0).
--   'queued'   -> withWriteAccessDo returned the DEFINED "queued" verdict (write deferred)
--                 AND errorCount == 0.
--   'aborted'  -> withWriteAccessDo returned the DEFINED "aborted" verdict AND
--                 errorCount == 0.
--   'error'    -> ANY of:
--                   (a) the gate body / withWriteAccessDo RAISED (outer pcall caught it); OR
--                   (b) one or more per-keyword createKeyword/addKeyword calls FAILED inside
--                       the gate (errorCount > 0), even if the SDK verdict was "executed"
--                       (CODEX MUST-FIX #1: a swallowed addKeyword failure must NOT report
--                       success); OR
--                   (c) withWriteAccessDo returned an UNEXPECTED raw value outside
--                       {executed,queued,aborted} (CODEX MUST-FIX #2: never leak the raw
--                       value -- log it and return the DEFINED 'error').
--                 In every 'error' case the FIRST error string + subject context is logged
--                 and the run is NOT aborted (per-run isolation) so the caller can surface it.
-- ---------------------------------------------------------------------------
function M.apply(catalog, plan, actionName, fields, opts)
    local entries = (type(plan) == 'table' and type(plan.entries) == 'table') and plan.entries or {}

    -- Resolve the yield-safe protector ONCE: the injected yield-safe pcall (LrTasks.pcall) when
    -- one is supplied, else the standard global pcall. Used for BOTH the single withWriteAccessDo
    -- wrap below AND each inner per-keyword createKeyword/addKeyword -- a live LrC re-run proved
    -- those inner calls ALSO yield inside the open gate, so they must be yield-safe-wrapped too.
    local protect = (type(opts) == 'table' and type(opts.pcall) == 'function') and opts.pcall or pcall

    -- Compute addCount (total planned additions) + entryCount (entries with a non-empty
    -- addKeywords) up front, so addCount is logged on BOTH the noop and the write paths. Also
    -- gather per-entry subject context (photoKey + a formatted filename) OUTSIDE the closure so
    -- a thrown error can be logged with context without re-entering the gate.
    local addCount = 0
    local entryCount = 0
    local subjects = {}   -- parallel to the non-empty entries, for error context
    for _, entry in ipairs(entries) do
        local names = (type(entry) == 'table' and type(entry.addKeywords) == 'table') and entry.addKeywords or {}
        if #names > 0 then
            entryCount = entryCount + 1
            addCount = addCount + #names
            subjects[#subjects + 1] = {
                photoKey = entry.photoKey,
                file     = safeFileName(entry.photo),
            }
        end
    end

    local baseFields = shallowCopy(fields)
    baseFields.photoCount = entryCount
    baseFields.addCount = addCount

    -- Empty plan: NEVER open a gate (no spurious Undo step, WR-02). addCount logs as 0 here --
    -- the count is reported on the noop path too.
    if entryCount == 0 then
        baseFields.writeResult = 'noop'
        log.info("write skipped: empty plan", baseFields)
        return 'noop'
    end

    -- Per-keyword bookkeeping accumulated INSIDE the gate (CODEX MUST-FIX #1). The inner
    -- pcalls used to silently swallow createKeyword/addKeyword failures, so a failing
    -- addKeyword still yielded 'executed' + addCount==planned. We now COUNT successes and
    -- failures and capture the FIRST error string + its subject so we can (a) downgrade the
    -- status to 'error' and (b) log honest counts AFTER the gate. These locals are captured by
    -- the closure (no log/require call inside the gate -- still WR-01-clean).
    local addedCount = 0
    local errorCount = 0
    local firstError = nil
    local firstErrSubject = nil
    -- DIAGNOSTIC (BL-15 follow-up): capture the actual REJECTED keyword names so we can see exactly
    -- which character/pattern createKeyword refuses. Keyword names are bird names, NOT secrets, but
    -- they are %q-quoted so any invisible/odd byte (control char, stray quote) is visible in the log.
    -- Capped to keep the line bounded; redaction sink still applies as a backstop.
    local failedNames = {}
    local function noteFailed(name)
        if #failedNames < 15 then
            failedNames[#failedNames + 1] = string.format('%q', tostring(name))
        end
    end

    -- DI-HARDENING: prove the protected closure actually RAN before trusting a success verdict.
    -- A pathological injected opts.pcall could return `true, <verdict>` WITHOUT ever invoking its
    -- closure (the write gate never opens), which would otherwise be mis-reported as success. The
    -- closure sets gateRan=true as its FIRST statement, so gateRan is true iff the protector really
    -- called it. The real path (LrTasks.pcall and standard pcall both invoke the closure) sets it
    -- true, so the existing logic below is byte-for-byte unchanged for that path.
    local gateRan = false

    -- ONE tight gate. The closure does ONLY createKeyword + addKeyword (each guarded) plus
    -- pure-Lua counter bookkeeping; no require / network / preview / log call inside (log
    -- AFTER the gate returns).
    local okGate, result = protect(function()
        gateRan = true
        return catalog:withWriteAccessDo(actionName, function()
            local entryIdx = 0
            -- DUPLICATE-IN-GATE CACHE: a clustered burst applies the SAME new keyword name to many
            -- photos, so createKeyword runs N times for one name in a SINGLE gate. LrC's
            -- createKeyword(returnExisting=true) returns nil on the 2nd+ call for a name created
            -- earlier in the SAME uncommitted transaction (the catalog index isn't live mid-gate).
            -- Cache the keyword OBJECT by name and reuse it; addKeyword still runs per photo, so
            -- createKeyword executes exactly once per UNIQUE name. (Bug found live: clustered
            -- genus/family keywords failed on every repeat.)
            local kwByName = {}
            for _, entry in ipairs(entries) do
                local names = (type(entry) == 'table' and type(entry.addKeywords) == 'table') and entry.addKeywords or {}
                local photo = entry.photo
                if #names > 0 then
                    entryIdx = entryIdx + 1
                end
                for _, name in ipairs(names) do
                    -- Per-keyword guard via the SAME yield-safe `protect`: createKeyword and
                    -- addKeyword YIELD inside the live gate (proven by an in-LrC re-run), so they
                    -- MUST route through the injected yield-safe pcall, not the stock C pcall
                    -- (which would raise "Yielding is not allowed within a C or metamethod call").
                    -- A throwing call on one keyword does NOT abort the gate, and it is no longer
                    -- SILENT -- we record the failure + first error string so the result/log reflect it.
                    --
                    -- DI-HARDENING (per-keyword run sentinel): each inner call is CLOSURE-form with a
                    -- per-call sentinel (ranKw / ranAdd) set as the FIRST statement inside the closure,
                    -- so a fake protector that returns a truthy ok WITHOUT invoking the closure cannot
                    -- report a write that never happened. When that occurs we coerce ok->false with a
                    -- CONSTANT token-free diagnostic, funnelling into the EXISTING per-keyword failure
                    -- branch (errorCount++, firstError) -- no new code path, and for a real protector
                    -- (LrTasks.pcall / global pcall always invoke) ranKw/ranAdd are always true so the
                    -- guard is dead and behavior is byte-for-byte unchanged. COLON syntax inside the
                    -- closure keeps `self` correct; createKeyword args (name,nil,true,nil,true) and the
                    -- returnExisting=true semantics are preserved.
                    local okKw, kw
                    local cachedKw = kwByName[name]
                    if cachedKw ~= nil then
                        -- Same name already created earlier in THIS gate: reuse the object (avoids the
                        -- mid-transaction createKeyword-returns-nil gotcha for duplicates).
                        okKw, kw = true, cachedKw
                    else
                        local ranKw = false
                        okKw, kw = protect(function() ranKw = true; return catalog:createKeyword(name, nil, true, nil, true) end)
                        if okKw and not ranKw then
                            okKw = false
                            kw = 'write gate protector skipped createKeyword'
                        end
                        if okKw and kw then kwByName[name] = kw end
                    end
                    if okKw and kw then
                        local ranAdd = false
                        local okAdd, addErr = protect(function() ranAdd = true; return photo:addKeyword(kw) end)
                        if okAdd and not ranAdd then
                            okAdd = false
                            addErr = 'write gate protector skipped addKeyword'
                        end
                        if okAdd then
                            addedCount = addedCount + 1
                        else
                            errorCount = errorCount + 1
                            noteFailed(name)
                            if firstError == nil then
                                firstError = tostring(addErr)
                                firstErrSubject = subjects[entryIdx]
                            end
                        end
                    else
                        errorCount = errorCount + 1
                        noteFailed(name)
                        if firstError == nil then
                            -- okKw==false => kw holds the error; okKw==true but kw nil/false
                            -- => createKeyword returned no keyword.
                            firstError = okKw and 'createKeyword returned no keyword'
                                or tostring(kw)
                            firstErrSubject = subjects[entryIdx]
                        end
                    end
                end
            end
        end)
    end)

    if not okGate then
        -- The gate body / withWriteAccessDo raised. Isolate it: log the ACTUAL error string
        -- with the base fields + a first-subject hint, and return 'error' WITHOUT re-raising
        -- (the caller's run continues -- per-run isolation).
        local errFields = baseFields
        errFields.writeResult = 'error'
        errFields.addedCount = addedCount
        errFields.errorCount = errorCount
        errFields.error = tostring(result)
        local first = subjects[1]
        if first then
            errFields.photoKey = first.photoKey
            errFields.file = first.file
        end
        log.error("write failed (isolated; run continues)", errFields)
        return 'error'
    end

    -- DI-HARDENING: okGate is truthy but the closure never ran -- a pathological injected
    -- opts.pcall returned a fake success WITHOUT invoking its argument, so the write gate never
    -- opened. Never trust that verdict: force the DEFINED 'error' status with a CONSTANT,
    -- token-free diagnostic (we deliberately do NOT log the value returned by opts.pcall).
    if not gateRan then
        baseFields.writeResult = 'error'
        baseFields.error = 'write gate protector did not run the closure'
        log.error("write gate protector did not run the closure", baseFields)
        return 'error'
    end

    -- Gate returned. Record honest counts for BOTH the success and the per-keyword-failure
    -- paths (CODEX MUST-FIX #1: log planned addCount + actual addedCount + errorCount +
    -- firstError -- no secret/path).
    baseFields.addedCount = addedCount
    baseFields.errorCount = errorCount

    -- (b) One or more per-keyword calls failed inside the gate: the SDK verdict is irrelevant
    -- -- a swallowed failure must NOT be reported as success. Status is forced to 'error'.
    if errorCount > 0 then
        baseFields.writeResult = 'error'
        baseFields.rawResult = tostring(result)
        baseFields.error = tostring(firstError)
        -- DIAGNOSTIC (BL-15 follow-up): the %q-quoted names (capped) that FAILED to write -- either
        -- createKeyword refused them OR addKeyword raised -- so we can see exactly which name/pattern
        -- is involved.
        baseFields.failedNames = table.concat(failedNames, ' | ')
        local s = firstErrSubject or subjects[1]
        if s then
            baseFields.photoKey = s.photoKey
            baseFields.file = s.file
        end
        log.error("write completed with per-keyword failures (run continues)", baseFields)
        return 'error'
    end

    -- (c) withWriteAccessDo returned an UNEXPECTED value outside {executed,queued,aborted}.
    -- Never leak the raw value to the caller: log it and return the DEFINED 'error'.
    if not (type(result) == 'string' and DEFINED_RESULTS[result]) then
        baseFields.writeResult = 'error'
        baseFields.rawResult = tostring(result)
        log.error("write returned an undefined status (normalized to error)", baseFields)
        return 'error'
    end

    -- Normal path: every keyword applied AND the verdict is defined. Log and return the SDK's
    -- verdict (executed/queued/aborted). A non-executed result is a real outcome the caller
    -- surfaces (RESEARCH Pitfall 2).
    baseFields.writeResult = result
    log.info("write applied", baseFields)
    return result
end

return M
