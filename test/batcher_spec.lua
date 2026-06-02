-- test/batcher_spec.lua (Phase 12 — WBATCH-01: PURE batch slicing + default-single-batch)
--
-- Exercises BirdAID.lrdevplugin/src/batcher.lua: a PURE module (no Lr, no math.random,
-- deterministic) require-able under stock lua / luajit. M.slice(results, batchSize) splits the
-- already-collected results[] into contiguous, order-preserving chunks. The DEFAULT-SAFE invariant
-- (WBATCH-01 / RESEARCH A5): batchSize nil / non-number / <1 / >= #results ⇒ exactly ONE chunk ==
-- today's single end-of-run write. (The flushAll cumulative-diff coordinator is covered by
-- test/writeplan_crossbatch_spec.lua — WBATCH-02.)
--
-- Loaded by test/run.lua via dofile; uses the runner globals assert_eq / assert_true.
-- Strictly Lua 5.1 common subset (no \u{}, no //, no goto, no <close>; unpack global).

local batcher = require('src.batcher')

assert_true(type(batcher) == 'table', "require 'src.batcher' resolves")
assert_true(type(batcher.slice) == 'function', "exposes slice")

-- A tiny results array; identity preserved by reference so we can assert order + same-table.
local function mkResults(n)
    local r = {}
    for i = 1, n do r[i] = { photoKey = "p" .. i, tag = i } end
    return r
end

-- =====================================================================
-- DEFAULT-SAFE: batchSize 0 (and nil / non-number / >= #results) ⇒ ONE chunk == the input array
-- itself (chunks[1] IS results). This is the byte-for-byte single end-of-run write invariant.
-- =====================================================================
do
    local results = mkResults(5)

    local c0 = batcher.slice(results, 0)
    assert_eq(#c0, 1, "batchSize 0 ⇒ exactly one chunk (default-safe single write)")
    assert_true(c0[1] == results, "batchSize 0 ⇒ chunk[1] IS the original results table")

    local cnil = batcher.slice(results, nil)
    assert_eq(#cnil, 1, "batchSize nil ⇒ one chunk")
    assert_true(cnil[1] == results, "batchSize nil ⇒ chunk[1] IS results")

    local cstr = batcher.slice(results, "garbage")
    assert_eq(#cstr, 1, "batchSize non-number ⇒ one chunk")
    assert_true(cstr[1] == results, "batchSize non-number ⇒ chunk[1] IS results")

    local cneg = batcher.slice(results, -3)
    assert_eq(#cneg, 1, "batchSize negative ⇒ one chunk")

    local cbig = batcher.slice(results, 5)
    assert_eq(#cbig, 1, "batchSize == #results ⇒ one chunk")
    local cbigger = batcher.slice(results, 99)
    assert_eq(#cbigger, 1, "batchSize > #results ⇒ one chunk")
end

-- =====================================================================
-- batchSize 2 over 5 records ⇒ ceil(5/2)=3 chunks with sizes {2,2,1}, order preserved, and the
-- concatenation of all chunks equals the input order.
-- =====================================================================
do
    local results = mkResults(5)
    local chunks = batcher.slice(results, 2)
    assert_eq(#chunks, 3, "batchSize 2 over 5 ⇒ 3 chunks")
    assert_eq(#chunks[1], 2, "chunk 1 size 2")
    assert_eq(#chunks[2], 2, "chunk 2 size 2")
    assert_eq(#chunks[3], 1, "chunk 3 size 1 (remainder)")

    -- Order preserved: concatenation == input order by tag.
    local seq = {}
    for _, chunk in ipairs(chunks) do
        for _, rec in ipairs(chunk) do seq[#seq + 1] = rec.tag end
    end
    assert_eq(#seq, 5, "all 5 records present across chunks")
    for i = 1, 5 do assert_eq(seq[i], i, "record order preserved at " .. i) end
end

-- =====================================================================
-- batchSize 1 over 3 records ⇒ 3 single-record chunks.
-- =====================================================================
do
    local results = mkResults(3)
    local chunks = batcher.slice(results, 1)
    assert_eq(#chunks, 3, "batchSize 1 over 3 ⇒ 3 chunks")
    assert_eq(#chunks[1], 1, "chunk 1 size 1")
    assert_eq(#chunks[2], 1, "chunk 2 size 1")
    assert_eq(#chunks[3], 1, "chunk 3 size 1")
    assert_eq(chunks[1][1].tag, 1, "chunk 1 holds record 1")
    assert_eq(chunks[3][1].tag, 3, "chunk 3 holds record 3")
end

-- =====================================================================
-- Empty results ⇒ ONE chunk (empty), never errors.
-- =====================================================================
do
    local results = {}
    local chunks = batcher.slice(results, 2)
    assert_eq(#chunks, 1, "empty results ⇒ one chunk")
    assert_eq(#chunks[1], 0, "the single chunk is empty")
    assert_true(chunks[1] == results, "empty + size>=n path returns the original (empty) table")
end
