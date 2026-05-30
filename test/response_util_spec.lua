-- test/response_util_spec.lua (Plan 07-01 — shared response helpers, extracted from openai_response)
--
-- Exercises BirdAID.lrdevplugin/src/providers/response_util.lua: a PURE module (requires only the
-- pure src.json / src.contract / src.lib.dkjson), require-able under stock lua / luajit. These
-- helpers (normalizeNulls / salvage / repairOnce / finalize / degrade) were FACTORED OUT of
-- openai_response.lua in 07-01 (CODEX MUST-FIX 2) so both wave-2 providers (claude/gemini) can
-- depend on them via this wave-1 plan with no inter-wave-2 file race. Behavior is preserved;
-- openai_response_spec staying green is the regression backstop.
--
-- Loaded by test/run.lua via dofile; uses the runner globals assert_eq / assert_true.
-- Strictly Lua 5.1 common subset (no \u{}, no //, no goto, no <close>; unpack global).

local ru       = require('src.providers.response_util')
local contract = require('src.contract')
local dkjson   = require('src.lib.dkjson')

assert_true(type(ru) == 'table', "require 'src.providers.response_util' resolves")
assert_true(type(ru.normalizeNulls) == 'function', "exposes normalizeNulls")
assert_true(type(ru.salvage) == 'function', "exposes salvage")
assert_true(type(ru.repairOnce) == 'function', "exposes repairOnce")
assert_true(type(ru.finalize) == 'function', "exposes finalize")
assert_true(type(ru.degrade) == 'function', "exposes degrade")

-- isDegrade(r): the EXACT degrade shape {bird_present=false, detections={}}.
local function isDegrade(r)
    return type(r) == 'table'
        and r.bird_present == false
        and type(r.detections) == 'table'
        and #r.detections == 0
end

-- =====================================================================
-- degrade(): a fresh valid no-bird shape each call (no shared mutable constant).
-- =====================================================================
do
    local a = ru.degrade()
    local b = ru.degrade()
    assert_true(isDegrade(a), "degrade() is the no-bird shape")
    assert_true(contract.validateResponse(a), "degrade() validates")
    assert_true(a ~= b, "degrade() returns a fresh table each call")
end

-- =====================================================================
-- normalizeNulls: drops the dkjson NULL sentinel anywhere (top + nested).
-- =====================================================================
do
    local NULL = dkjson.null
    local t = { confidence = NULL, detections = { { confidence = NULL, keep = 1 } } }
    local out = ru.normalizeNulls(t)
    assert_eq(out.confidence, nil, "top-level NULL dropped to nil")
    assert_eq(out.detections[1].confidence, nil, "nested NULL dropped to nil")
    assert_eq(out.detections[1].keep, 1, "non-null sibling preserved")
    -- a plain non-table value passes through.
    assert_eq(ru.normalizeNulls(5), 5, "non-table passes through")
    assert_eq(ru.normalizeNulls(NULL), nil, "bare NULL -> nil")
end

-- =====================================================================
-- salvage: strips fences/prose, re-decodes to a table.
-- =====================================================================
do
    local fenced = "```json\n{\"bird_present\":false,\"detections\":[]}\n```"
    local ok, val = ru.salvage(fenced)
    assert_true(ok, "salvage recovers a fence-wrapped object")
    assert_true(type(val) == 'table' and val.bird_present == false, "salvage yields the decoded table")

    local prose = "Here is the result: {\"bird_present\":true,\"detections\":[]} thanks!"
    local pok, pval = ru.salvage(prose)
    assert_true(pok, "salvage trims surrounding prose")
    assert_eq(pval.bird_present, true, "salvage prose: decoded value correct")

    assert_eq((ru.salvage("no json here")), false, "salvage on non-JSON -> false")
    assert_eq((ru.salvage(42)), false, "salvage on non-string -> false")
end

-- =====================================================================
-- repairOnce: drops a contradictory non-empty detections array when bird_present==false.
-- =====================================================================
do
    local r = ru.repairOnce({ bird_present = false, detections = { { x = 1 } } }, 'some-err')
    assert_eq(r.bird_present, false, "repairOnce keeps bird_present false")
    assert_eq(#r.detections, 0, "repairOnce drops contradictory detections")
    -- non-table passes through unchanged.
    assert_eq(ru.repairOnce("x"), "x", "repairOnce non-table passes through")
end

-- =====================================================================
-- finalize: validate-or-(repair-once)-or-degrade. Always returns a contract-valid table.
-- =====================================================================
do
    -- a known-good shape validates and is returned (not degraded).
    local good = {
        bird_present = true,
        detections = { {
            bbox = { 0.1, 0.1, 0.2, 0.2 },
            common_name = 'Northern Cardinal',
            scientific_name = 'Cardinalis cardinalis',
            identified_rank = 'species',
            rank_name = 'Northern Cardinal',
            alternatives = {},
        } },
    }
    local fg = ru.finalize(good)
    assert_eq(fg.bird_present, true, "finalize keeps a valid bird_present")
    assert_eq(fg.detections[1].common_name, 'Northern Cardinal', "finalize preserves the detection")
    assert_true(contract.validateResponse(fg), "finalize output validates")

    -- a known-bad (contradictory) shape -> repaired/degraded to the valid no-bird shape.
    local bad = { bird_present = false, detections = { { common_name = 'x' } } }
    local fb = ru.finalize(bad)
    assert_eq(fb.bird_present, false, "finalize repairs contradictory shape to no-bird")
    assert_eq(#fb.detections, 0, "finalize drops contradictory detections")
    assert_true(contract.validateResponse(fb), "finalize repaired output validates")

    -- a non-table -> degrade.
    assert_true(isDegrade(ru.finalize(nil)), "finalize(nil) -> degrade")
    assert_true(isDegrade(ru.finalize("nope")), "finalize(string) -> degrade")
end
