-- test/catalog_writer_spec.lua (Phase 4 code review #1 + #2 — apply() error visibility)
--
-- Exercises BirdAID.lrdevplugin/src/lr/catalog_writer.lua, the THIN Lr-glue writer. The file
-- lives in the src/lr/ glue tier and is the Lr-adapter (catalog:withWriteAccessDo,
-- createKeyword, photo:addKeyword), so it is NOT pure. To exercise it under the stock-lua CLI
-- suite we (a) inject a FAKE 'src.log' into package.loaded BEFORE requiring it (the real
-- src.log imports LrLogger and cannot load offline), then (b) drive apply() with a STUBBED
-- catalog + photo whose createKeyword/addKeyword we control (including raising), asserting:
--   #1  a failing addKeyword no longer reports success: status == 'error', addedCount counts
--       only the successes, and an error was LOGGED (the failure is no longer swallowed).
--   #2  an UNDEFINED withWriteAccessDo verdict ("mystery"/nil) never leaks: apply returns the
--       DEFINED 'error', not the raw value.
-- Plus regressions: empty plan -> 'noop' (gate never opened); all-success -> 'executed'.
--
-- Loaded by test/run.lua via dofile; uses the runner globals assert_eq / assert_true.
-- Strictly Lua 5.1 common subset (no \u{}, no //, no goto, no <close>; unpack global).

-- (a) Inject a fake 'src.log' BEFORE requiring catalog_writer so its top-level
--     require 'src.log' resolves to this capturing stub (no LrLogger needed offline).
local logged = { info = {}, warn = {}, error = {}, trace = {} }
local function resetLog()
    logged.info, logged.warn, logged.error, logged.trace = {}, {}, {}, {}
end
package.loaded['src.log'] = {
    event = function(level, msg, fields) (logged[level] or {})[#(logged[level] or {}) + 1] = { msg = msg, fields = fields } end,
    info  = function(msg, fields) logged.info[#logged.info + 1]   = { msg = msg, fields = fields } end,
    warn  = function(msg, fields) logged.warn[#logged.warn + 1]   = { msg = msg, fields = fields } end,
    error = function(msg, fields) logged.error[#logged.error + 1] = { msg = msg, fields = fields } end,
    trace = function(msg, fields) logged.trace[#logged.trace + 1] = { msg = msg, fields = fields } end,
    logFilePath = function() return "/dev/null" end,
}

local W = require('src.lr.catalog_writer')

assert_true(type(W) == 'table', "require 'src.lr.catalog_writer' resolves with fake src.log")
assert_true(type(W.apply) == 'function', "catalog_writer exposes apply")

-- A stub photo. addKeyword optionally RAISES (failOn[name]=true) to simulate an SDK error
-- on one keyword; otherwise it records the applied keyword name on the photo.
local function stubPhoto(failOn)
    failOn = failOn or {}
    return {
        applied = {},
        addKeyword = function(self, kw)
            if failOn[kw.name] then error("simulated addKeyword failure: " .. tostring(kw.name)) end
            self.applied[#self.applied + 1] = kw.name
            return true
        end,
        getFormattedMetadata = function(self, key) return "STUB.JPG" end,
    }
end

-- A stub catalog. createKeyword returns a tiny {name=...} keyword (returnExisting idempotent
-- is irrelevant for the stub). withWriteAccessDo just runs the body and returns `verdict`
-- (default "executed") so we can drive the defined/undefined-status paths.
local function stubCatalog(verdict, createFailOn)
    createFailOn = createFailOn or {}
    return {
        createKeyword = function(self, name, syn, inc, parent, ret)
            if createFailOn[name] then error("simulated createKeyword failure: " .. tostring(name)) end
            return { name = name }
        end,
        withWriteAccessDo = function(self, action, body)
            body()
            return verdict
        end,
    }
end

local function planFor(photo, names)
    return { entries = { { photoKey = "pk1", photo = photo, addKeywords = names } } }
end

-- =====================================================================
-- Regression: empty plan -> 'noop'; the gate is NEVER opened (no withWriteAccessDo call).
-- =====================================================================
do
    resetLog()
    local opened = false
    local cat = { withWriteAccessDo = function() opened = true; return "executed" end }
    local r = W.apply(cat, { entries = {} }, "BirdAID: write", { runId = "t" })
    assert_eq(r, 'noop', "empty plan -> noop")
    assert_eq(opened, false, "empty plan -> withWriteAccessDo NOT called")
end

-- =====================================================================
-- Regression: all keywords succeed AND verdict 'executed' -> 'executed', addedCount==planned.
-- =====================================================================
do
    resetLog()
    local photo = stubPhoto()
    local cat = stubCatalog("executed")
    local r = W.apply(cat, planFor(photo, { "Cardinal", "Robin" }), "BirdAID: write", { runId = "t" })
    assert_eq(r, 'executed', "all-success + executed -> executed")
    assert_eq(#photo.applied, 2, "both keywords applied")
    assert_eq(#logged.info, 1, "one info log on success")
    assert_eq(logged.info[1].fields.addedCount, 2, "addedCount == 2 on success")
    assert_eq(logged.info[1].fields.errorCount, 0, "errorCount == 0 on success")
end

-- =====================================================================
-- #1: a failing addKeyword must NOT report success. status=='error', addedCount counts only
--     the successes, an error is LOGGED, and the run is NOT aborted (apply returns normally).
-- =====================================================================
do
    resetLog()
    local photo = stubPhoto({ Robin = true })   -- addKeyword RAISES on "Robin"
    local cat = stubCatalog("executed")          -- SDK verdict would have been 'executed'
    local ok, r = pcall(W.apply, cat, planFor(photo, { "Cardinal", "Robin", "Jay" }),
        "BirdAID: write", { runId = "t" })
    assert_true(ok, "#1: apply does NOT raise on a per-keyword failure (run continues)")
    assert_eq(r, 'error', "#1: a swallowed addKeyword failure -> status 'error', NOT 'executed'")
    assert_eq(#photo.applied, 2, "#1: only the 2 succeeding keywords applied (Cardinal, Jay)")
    assert_eq(#logged.error, 1, "#1: the failure WAS logged (no longer swallowed)")
    assert_eq(logged.error[1].fields.addedCount, 2, "#1: log addedCount reflects only successes")
    assert_eq(logged.error[1].fields.errorCount, 1, "#1: log errorCount == 1")
    assert_true(type(logged.error[1].fields.error) == 'string', "#1: first error string captured")
    assert_eq(#logged.info, 0, "#1: NO success info log when errors occurred")
end

-- a failing createKeyword is likewise counted + downgraded to 'error'.
do
    resetLog()
    local photo = stubPhoto()
    local cat = stubCatalog("executed", { Robin = true })   -- createKeyword RAISES on "Robin"
    local r = W.apply(cat, planFor(photo, { "Cardinal", "Robin" }), "BirdAID: write", { runId = "t" })
    assert_eq(r, 'error', "#1: failing createKeyword -> status 'error'")
    assert_eq(#photo.applied, 1, "#1: only Cardinal applied (Robin's createKeyword failed)")
    assert_eq(logged.error[1].fields.errorCount, 1, "#1: createKeyword failure counted")
end

-- =====================================================================
-- #2: an UNDEFINED withWriteAccessDo verdict never leaks; apply normalizes to 'error'.
-- =====================================================================
do
    resetLog()
    local photo = stubPhoto()
    local cat = stubCatalog("mystery")   -- not in {executed,queued,aborted}
    local r = W.apply(cat, planFor(photo, { "Cardinal" }), "BirdAID: write", { runId = "t" })
    assert_eq(r, 'error', "#2: 'mystery' verdict normalized to 'error' (raw value never returned)")
    assert_true(r ~= 'mystery', "#2: raw 'mystery' string never leaked to the caller")
    assert_eq(#logged.error, 1, "#2: the undefined status was logged")
    assert_eq(logged.error[1].fields.rawResult, 'mystery', "#2: rawResult records the raw value for diagnosis")
end

-- nil verdict is likewise undefined -> 'error'.
do
    resetLog()
    local photo = stubPhoto()
    local cat = stubCatalog(nil)
    local r = W.apply(cat, planFor(photo, { "Cardinal" }), "BirdAID: write", { runId = "t" })
    assert_eq(r, 'error', "#2: nil verdict normalized to 'error'")
end

-- the DEFINED non-executed verdicts (queued / aborted) still pass through verbatim.
do
    resetLog()
    local r = W.apply(stubCatalog("queued"), planFor(stubPhoto(), { "Cardinal" }), "x", { runId = "t" })
    assert_eq(r, 'queued', "#2: defined 'queued' verdict passes through")
end
do
    resetLog()
    local r = W.apply(stubCatalog("aborted"), planFor(stubPhoto(), { "Cardinal" }), "x", { runId = "t" })
    assert_eq(r, 'aborted', "#2: defined 'aborted' verdict passes through")
end

-- =====================================================================
-- Outer-pcall path: withWriteAccessDo itself RAISING -> 'error', logged, run continues.
-- =====================================================================
do
    resetLog()
    local cat = { withWriteAccessDo = function() error("gate exploded") end }
    local ok, r = pcall(W.apply, cat, planFor(stubPhoto(), { "Cardinal" }), "x", { runId = "t" })
    assert_true(ok, "gate raise: apply does not re-raise")
    assert_eq(r, 'error', "gate raise -> 'error'")
    assert_eq(#logged.error, 1, "gate raise -> logged")
end

-- apply NEVER raises across a small battery (defensive parity with the other modules).
do
    assert_true(pcall(W.apply, stubCatalog("executed"), { entries = {} }, "x", {}), "apply never raises (empty)")
    assert_true(pcall(W.apply, stubCatalog("mystery"), planFor(stubPhoto(), { "A" }), "x", {}), "apply never raises (undefined verdict)")
end

-- =====================================================================
-- OPTION B (dependency-injected yield-safe pcall): a LIVE in-LrC re-run proved that the OUTER
-- withWriteAccessDo gate AND each INNER per-keyword createKeyword/addKeyword ALL yield inside the
-- open gate, so ALL of them route through the injected yield-safe pcall (NOT the stock C pcall,
-- which raises "Yielding is not allowed within a C or metamethod call" -> addedCount 0). This
-- locks in that EVERY SDK call that can yield is wrapped: for a 3-keyword single-photo plan where
-- all succeed the spy is invoked 1 (outer gate) + 3*2 (per keyword: createKeyword + addKeyword)
-- = 7 times. The return contract is IDENTICAL to the no-opts (4-arg) run.
-- =====================================================================
do
    resetLog()
    local spyCalls = 0
    -- The inner createKeyword/addKeyword are now CLOSURE-wrapped (run-sentinel form), so the spied
    -- target is an anonymous closure, NOT cat.createKeyword/photo.addKeyword by identity. We instead
    -- prove the inner SDK calls were actually invoked THROUGH the injected protector by instrumenting
    -- the stub catalog/photo to record that they ran: if the injected spy delegated to a real pcall
    -- that invoked the closures, createKeyword and addKeyword fire (and the closure form preserves
    -- self via colon syntax, so these stubs receive the right self).
    local sawCreate, sawAdd = false, false
    local function spy(...)            -- counts calls, delegates to the REAL global pcall
        spyCalls = spyCalls + 1
        return pcall(...)
    end
    local photo = stubPhoto()
    local realAdd = photo.addKeyword
    photo.addKeyword = function(self, kw) sawAdd = true; return realAdd(self, kw) end
    local cat = stubCatalog("executed")
    local realCreate = cat.createKeyword
    cat.createKeyword = function(self, ...) sawCreate = true; return realCreate(self, ...) end
    -- 3 keywords, single photo, all succeed:
    --   outer gate wrap         = 1 protect call
    --   per keyword (x3):
    --     createKeyword         = 1 protect call (closure form: still ONE protect call)
    --     addKeyword (success)  = 1 protect call (closure form: still ONE protect call)
    --   => 1 + 3*2 = 7 protect calls total (closure-wrapping does NOT change the count).
    local r = W.apply(cat, planFor(photo, { "Cardinal", "Robin", "Jay" }),
        "BirdAID: write", { runId = "t" }, { pcall = spy })
    assert_eq(r, 'executed', "opts.pcall: contract identical to 4-arg run (executed)")
    assert_eq(#photo.applied, 3, "opts.pcall: all keywords applied through the gate")
    assert_eq(spyCalls, 7, "opts.pcall: ALL yield-capable SDK calls routed through the injected pcall (outer gate 1 + per-keyword createKeyword/addKeyword 3*2 = 7)")
    -- Regression lock: prove the INNER per-keyword createKeyword + addKeyword were really invoked
    -- through the injected protector's closures (and with the correct self via colon syntax).
    assert_true(sawCreate, "opts.pcall: inner createKeyword was invoked THROUGH the injected protector (yield-safe, colon self)")
    assert_true(sawAdd, "opts.pcall: inner addKeyword was invoked THROUGH the injected protector (yield-safe, colon self)")
    assert_eq(#logged.info, 1, "opts.pcall: one success info log (unchanged contract)")
    assert_eq(logged.info[1].fields.addedCount, 3, "opts.pcall: addedCount == 3 (unchanged)")
end

-- A gate-raise THROUGH the injected pcall still isolates to 'error' (logged, no re-raise),
-- proving the yield-safe path preserves the error contract.
do
    resetLog()
    local spyCalls = 0
    local function spy(...)
        spyCalls = spyCalls + 1
        return pcall(...)
    end
    local cat = { withWriteAccessDo = function() error("gate exploded via injected pcall") end }
    local ok, r = pcall(W.apply, cat, planFor(stubPhoto(), { "Cardinal" }),
        "x", { runId = "t" }, { pcall = spy })
    assert_true(ok, "opts.pcall gate raise: apply does not re-raise")
    assert_eq(r, 'error', "opts.pcall gate raise -> 'error' (isolated via the injected path)")
    assert_eq(spyCalls, 1, "opts.pcall gate raise: still routed through the injected pcall once")
    assert_eq(#logged.error, 1, "opts.pcall gate raise -> logged")
end

-- opts robustness: nil / {} (no pcall key) / opts.pcall of the WRONG type all fall back to the
-- standard global pcall and behave EXACTLY like the 4-arg form (no raise, defined statuses).
do
    resetLog()
    -- opts == nil (explicit 5th arg nil) behaves like the 4-arg form.
    local r1 = W.apply(stubCatalog("executed"), planFor(stubPhoto(), { "Cardinal" }), "x", { runId = "t" }, nil)
    assert_eq(r1, 'executed', "opts=nil falls back to standard pcall (executed)")

    -- opts == {} (no pcall key).
    local r2 = W.apply(stubCatalog("executed"), planFor(stubPhoto(), { "Cardinal" }), "x", { runId = "t" }, {})
    assert_eq(r2, 'executed', "opts={} (no pcall key) falls back to standard pcall (executed)")

    -- opts.pcall wrong type (a string, not a function) -> ignored, standard pcall used.
    local r3 = W.apply(stubCatalog("executed"), planFor(stubPhoto(), { "Cardinal" }), "x", { runId = "t" },
        { pcall = "not-a-function" })
    assert_eq(r3, 'executed', "opts.pcall of the wrong type falls back to standard pcall (executed)")

    -- And a gate raise with a bogus opts.pcall still isolates to 'error' (standard pcall path).
    local cat = { withWriteAccessDo = function() error("boom") end }
    local ok, r4 = pcall(W.apply, cat, planFor(stubPhoto(), { "Cardinal" }), "x", { runId = "t" },
        { pcall = 123 })
    assert_true(ok, "opts robustness: bogus opts.pcall does not cause a re-raise")
    assert_eq(r4, 'error', "opts robustness: bogus opts.pcall + gate raise -> 'error' (standard pcall fallback)")
end

-- =====================================================================
-- DI-HARDENING (gateRan guard): a pathological injected opts.pcall that returns a FAKE success
-- `true, 'executed'` WITHOUT ever invoking its closure must NOT be trusted -- apply() forces
-- 'error' (the write gate never opened), logs a CONSTANT token-free diagnostic, and NO keyword is
-- applied (the stub catalog's createKeyword is never reached / no keyword recorded).
-- =====================================================================
local GATE_DIAG = 'write gate protector did not run the closure'
do
    resetLog()
    local createCalls = 0
    local photo = stubPhoto()
    -- A catalog whose createKeyword would record a call IF the gate body ever ran.
    local cat = {
        createKeyword = function(self, name) createCalls = createCalls + 1; return { name = name } end,
        withWriteAccessDo = function(self, action, body) body(); return "executed" end,
    }
    -- Pathological protector: returns a fake success WITHOUT calling its argument closure.
    local function liar(...) return true, 'executed' end
    local r = W.apply(cat, planFor(photo, { "Cardinal", "Robin" }), "BirdAID: write",
        { runId = "t" }, { pcall = liar })
    assert_eq(r, 'error', "gateRan: fake-success protector that skips the closure -> 'error'")
    assert_eq(createCalls, 0, "gateRan: write gate never opened -> createKeyword never called")
    assert_eq(#photo.applied, 0, "gateRan: NO keyword applied (addedCount stays 0)")
    assert_eq(#logged.error, 1, "gateRan: the skipped-closure case was logged")
    assert_eq(logged.error[1].fields.error, GATE_DIAG, "gateRan: logs the CONSTANT token-free diagnostic")
    -- The diagnostic is a fixed constant: assert it equals the constant (and carries no secret).
    assert_true(logged.error[1].fields.error == GATE_DIAG, "gateRan: diagnostic is the fixed constant (no secret)")
    assert_eq(#logged.info, 0, "gateRan: NO success info log")
end

-- Sanity: a HONEST injected pcall that DOES invoke its closure is unaffected by the gateRan guard
-- (the real LrTasks.pcall / standard pcall both call the closure -> gateRan true -> normal path).
do
    resetLog()
    local function honest(...) return pcall(...) end
    local photo = stubPhoto()
    local r = W.apply(stubCatalog("executed"), planFor(photo, { "Cardinal" }), "x",
        { runId = "t" }, { pcall = honest })
    assert_eq(r, 'executed', "gateRan: honest protector (invokes closure) -> normal 'executed' path")
    assert_eq(#photo.applied, 1, "gateRan: honest protector applies the keyword")
end

-- =====================================================================
-- DI-HARDENING (per-keyword run sentinels): a protector that HONESTLY runs the OUTER gate closure
-- but, for the INNER per-keyword calls, returns a fake `true` WITHOUT invoking the closure must NOT
-- be trusted -- apply() coerces each skipped inner call to a per-keyword failure (constant token-free
-- diagnostic) -> status 'error', addedCount==0, errorCount>0, and the stub catalog records NO applied
-- keyword. This proves a fake protector cannot report a write that never happened, even when the
-- outer gateRan guard is satisfied.
--
-- We distinguish OUTER (1 arg: a closure that opens the gate) from INNER (the per-keyword closures)
-- by call ORDER: the FIRST protect call is the outer gate -- we run it honestly; every SUBSEQUENT
-- protect call is an inner createKeyword/addKeyword -- we return a fake success WITHOUT invoking it.
local INNER_SKIP_DIAGS = {
    ['write gate protector skipped createKeyword'] = true,
    ['write gate protector skipped addKeyword'] = true,
}
do
    resetLog()
    local createCalls = 0
    local photo = stubPhoto()
    local cat = {
        createKeyword = function(self, name) createCalls = createCalls + 1; return { name = name } end,
        withWriteAccessDo = function(self, action, body) body(); return "executed" end,
    }
    local nProtect = 0
    -- First protect call = outer gate: run honestly (opens the gate, iterates entries -> reaches the
    -- inner protect calls). All subsequent protect calls = inner per-keyword: fake `true` WITHOUT
    -- invoking the closure (so the inner sentinel ranKw/ranAdd stays false -> coerced to failure).
    local function innerLiar(fn, ...)
        nProtect = nProtect + 1
        if nProtect == 1 then
            return pcall(fn, ...)   -- outer gate runs for real
        end
        return true                 -- inner call: truthy ok, closure NEVER invoked
    end
    local r = W.apply(cat, planFor(photo, { "Cardinal", "Robin" }), "BirdAID: write",
        { runId = "t" }, { pcall = innerLiar })
    assert_eq(r, 'error', "innerSkip: protector that skips the inner closures -> 'error'")
    assert_eq(createCalls, 0, "innerSkip: createKeyword never actually ran (closure was skipped)")
    assert_eq(#photo.applied, 0, "innerSkip: NO keyword applied (addedCount stays 0)")
    assert_eq(logged.error[1].fields.addedCount, 0, "innerSkip: logged addedCount == 0")
    assert_true(logged.error[1].fields.errorCount > 0, "innerSkip: errorCount > 0 (skips counted as failures)")
    assert_true(INNER_SKIP_DIAGS[logged.error[1].fields.error] == true,
        "innerSkip: the CONSTANT token-free skip diagnostic was logged")
    assert_eq(#logged.info, 0, "innerSkip: NO success info log")
end

-- =====================================================================
-- BL-15 follow-up: DUPLICATE keyword name across photos in ONE gate. Stub catalog mimics LrC
-- returning the keyword on the FIRST createKeyword for a name and nil on the 2nd+ for the SAME
-- name (the mid-transaction gotcha that broke clustered genus/family keywords). The writer's
-- per-gate cache must reuse the object so BOTH photos get the keyword, createKeyword runs once,
-- and there are NO per-keyword failures.
-- =====================================================================
do
    resetLog()
    local createCounts = {}
    local cat = {
        createKeyword = function(self, name)
            createCounts[name] = (createCounts[name] or 0) + 1
            if createCounts[name] == 1 then return { name = name } end
            return nil   -- 2nd+ call for the same NEW name in one uncommitted gate -> nil
        end,
        withWriteAccessDo = function(self, action, body) body(); return "executed" end,
    }
    local pA, pB = stubPhoto(), stubPhoto()
    local NAME = "Cardinalis sp. (uncertain)"
    local plan = { entries = {
        { photoKey = "pA", photo = pA, addKeywords = { NAME } },
        { photoKey = "pB", photo = pB, addKeywords = { NAME } },
    } }
    local r = W.apply(cat, plan, "BirdAID: write", { runId = "t" })
    assert_eq(r, 'executed', "dup-in-gate: status executed (cache reuses the keyword object)")
    assert_eq(createCounts[NAME], 1, "dup-in-gate: createKeyword called ONCE for the shared name")
    assert_eq(pA.applied[1], NAME, "dup-in-gate: photo A got the keyword")
    assert_eq(pB.applied[1], NAME, "dup-in-gate: photo B ALSO got the keyword (cache hit, no nil)")
    assert_eq(#logged.error, 0, "dup-in-gate: no per-keyword failure logged")
end

-- Clean up the injected fake so it cannot leak into another spec's require graph.
package.loaded['src.log'] = nil
