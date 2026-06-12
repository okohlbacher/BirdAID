-- test/writeplan_spec.lua (Phase 4 — Cross-photo write-plan builder: WR-01/WR-02/WR-04/SUM-01)
--
-- Exercises BirdAID.lrdevplugin/src/writeplan.lua: a PURE module (requires only src.keyword),
-- require-able under stock lua / luajit. It consumes per-photo COLLECTED responses (assembled
-- OUTSIDE any catalog write gate) plus each photo's existing keyword-name set, runs every
-- detection through keyword.decide + keyword.render, dedupes within a photo, applies the
-- add-only diff vs existing names (idempotency), honors singleKeywordPerPhoto, and aggregates
-- the SUM-01 summary. build() returns plain data and NEVER branches on dryRun; planReport()
-- is the dry-run orchestration helper that flags report.dryRun for the caller.
--
-- LOCKED semantics asserted here:
--   * "found" = the photo had >=1 DETECTION (NOT the bird_present flag): bird_present=true with
--     an empty detections array => found=0, skipped=1.
--   * "identified"/"uncertain" counted from the DEDUPED kept set (identical strings count ONCE).
--   * add-only diff: addKeywords = deduped desired names MINUS existing names; empty diff => no entry.
--   * singleKeywordPerPhoto=true: keep the single best by rank (species>genus>family) then higher
--     decision.confidence (NOT raw det.confidence).
--   * duplicate photoKey ACCUMULATES into a single entry / single perPhoto (merge+dedupe, sum counts).
--
-- Loaded by test/run.lua via dofile; uses the runner globals assert_eq / assert_true.
-- Strictly Lua 5.1 common subset (no \u{}, no //, no goto, no <close>; unpack global).

local W = require('src.writeplan')
local settings = require('src.settings')

-- normalized prefs (the typed table writeplan expects): per-detection deduped, write mode.
local PREFS = settings.normalizedPrefs({ confidenceThreshold = 0.6,
    singleKeywordPerPhoto = false, dryRun = false })

-- ---------------------------------------------------------------------------
-- Fixture builders (validated detection shape, mirrors contract.lua).
-- ---------------------------------------------------------------------------
local function speciesDet(common, scientific, conf)
    return {
        bbox = { 0.1, 0.1, 0.9, 0.9 },
        common_name = common,
        scientific_name = scientific,
        confidence = conf,
        identified_rank = 'species',
        rank_name = scientific,
    }
end

local function genusDet(rankName, conf)
    return {
        bbox = { 0.1, 0.1, 0.9, 0.9 },
        common_name = rankName,
        scientific_name = rankName,
        confidence = conf,
        identified_rank = 'genus',
        rank_name = rankName,
    }
end

local function orderDet()
    return {
        bbox = { 0.1, 0.1, 0.9, 0.9 },
        common_name = 'Passerine',
        scientific_name = 'Passeriformes',
        confidence = 0.9,
        identified_rank = 'order',
        rank_name = 'Passeriformes',
    }
end

local function resp(birdPresent, dets)
    return { bird_present = birdPresent, detections = dets }
end

-- The confident-species keyword we expect for the Northern Cardinal fixture.
local CARDINAL = 'Northern Cardinal (Cardinalis cardinalis)'

-- entryFor(plan, key) -> the plan entry whose photoKey == key, or nil. (Plan only contains
-- photos with a NON-EMPTY addKeywords list.)
local function entryFor(plan, key)
    for _, e in ipairs(plan.entries) do
        if e.photoKey == key then return e end
    end
    return nil
end

-- =====================================================================
-- 1. Photo A: one confident-species detection, existingNames={} -> one entry, addCount 1.
-- =====================================================================
do
    local results = {
        { photoKey = 'A', photo = 'handleA',
          response = resp(true, { speciesDet('Northern Cardinal', 'Cardinalis cardinalis', 0.82) }),
          existingNames = {} },
    }
    local out = W.build(results, PREFS)
    local e = entryFor(out.plan, 'A')
    assert_true(e ~= nil, "A: has a plan entry")
    assert_eq(#e.addKeywords, 1, "A: one keyword to add")
    assert_eq(e.addKeywords[1], CARDINAL, "A: the cardinal keyword")
    assert_eq(e.photo, 'handleA', "A: photo handle passed through untouched")
    local p = out.summary.perPhoto['A']
    assert_eq(p.found, 1, "A: found 1")
    assert_eq(p.identified, 1, "A: identified 1")
    assert_eq(p.uncertain, 0, "A: uncertain 0")
    assert_eq(p.errors, 0, "A: errors 0")
    assert_eq(p.skipped, 0, "A: skipped 0")
    assert_eq(p.addCount, 1, "A: addCount 1")
end

-- =====================================================================
-- 2. Re-run idempotency: existingNames already includes the desired keyword -> NO entry,
--    but summary still counts found/identified; addCount 0.
-- =====================================================================
do
    local results = {
        { photoKey = 'A', photo = 'handleA',
          response = resp(true, { speciesDet('Northern Cardinal', 'Cardinalis cardinalis', 0.82) }),
          existingNames = { [CARDINAL] = true } },
    }
    local out = W.build(results, PREFS)
    assert_true(entryFor(out.plan, 'A') == nil, "re-run: NO entry (empty diff)")
    local p = out.summary.perPhoto['A']
    assert_eq(p.found, 1, "re-run: found still 1")
    assert_eq(p.identified, 1, "re-run: identified still 1")
    assert_eq(p.addCount, 0, "re-run: addCount 0")
end

-- =====================================================================
-- 3. DEDUPE-COUNT: Photo B with TWO IDENTICAL confident-species detections -> addKeywords
--    length 1, identified 1 (NOT 2), uncertain 0, addCount 1.
-- =====================================================================
do
    local results = {
        { photoKey = 'B', photo = 'hB',
          response = resp(true, {
              speciesDet('Northern Cardinal', 'Cardinalis cardinalis', 0.82),
              speciesDet('Northern Cardinal', 'Cardinalis cardinalis', 0.91),
          }),
          existingNames = {} },
    }
    local out = W.build(results, PREFS)
    local e = entryFor(out.plan, 'B')
    assert_true(e ~= nil, "B: has an entry")
    assert_eq(#e.addKeywords, 1, "B: dedupe collapses identical strings to 1")
    assert_eq(e.addKeywords[1], CARDINAL, "B: the cardinal keyword")
    local p = out.summary.perPhoto['B']
    assert_eq(p.identified, 1, "B: identified counted ONCE from deduped set")
    assert_eq(p.uncertain, 0, "B: uncertain 0")
    assert_eq(p.addCount, 1, "B: addCount 1")
end

-- =====================================================================
-- 4. Cross-photo independence: A (new keyword) + B (keyword already present) ->
--    entries contains A only; B contributes to summary but no entry.
-- =====================================================================
do
    local results = {
        { photoKey = 'A', photo = 'hA',
          response = resp(true, { speciesDet('Northern Cardinal', 'Cardinalis cardinalis', 0.82) }),
          existingNames = {} },
        { photoKey = 'B', photo = 'hB',
          response = resp(true, { speciesDet('Blue Jay', 'Cyanocitta cristata', 0.9) }),
          existingNames = { ['Blue Jay (Cyanocitta cristata)'] = true } },
    }
    local out = W.build(results, PREFS)
    assert_true(entryFor(out.plan, 'A') ~= nil, "cross: A has an entry")
    assert_true(entryFor(out.plan, 'B') == nil, "cross: B has NO entry (already present)")
    assert_eq(#out.plan.entries, 1, "cross: exactly one entry (A)")
    assert_eq(out.summary.perPhoto['B'].identified, 1, "cross: B still counted identified 1")
    assert_eq(out.summary.perPhoto['B'].addCount, 0, "cross: B addCount 0")
end

-- =====================================================================
-- 5. Single-keyword-per-photo: species outranks genus -> keep the species only.
-- =====================================================================
do
    local prefs1 = settings.normalizedPrefs({ confidenceThreshold = 0.6,
        singleKeywordPerPhoto = true, dryRun = false })
    local results = {
        { photoKey = 'C', photo = 'hC',
          response = resp(true, {
              speciesDet('Northern Cardinal', 'Cardinalis cardinalis', 0.82),
              genusDet('Cardinalis', 0.95),
          }),
          existingNames = {} },
    }
    local out = W.build(results, prefs1)
    local e = entryFor(out.plan, 'C')
    assert_true(e ~= nil, "C: has an entry")
    assert_eq(#e.addKeywords, 1, "single-mode: only one keyword kept")
    assert_eq(e.addKeywords[1], CARDINAL, "single-mode: species outranks genus")
    assert_eq(out.summary.perPhoto['C'].identified, 1, "C: identified 1 (the species)")
    assert_eq(out.summary.perPhoto['C'].uncertain, 0, "C: uncertain 0 (genus dropped)")
end

-- =====================================================================
-- 5b. Single-mode TIE-BREAK on decision.confidence: two confident species, higher conf wins.
--     Both are confident (>=0.6) so both render WITHOUT '?'; the tie-break selects by
--     decision.confidence (0.95 > 0.7), keeping the Blue Jay.
-- =====================================================================
do
    local prefs1 = settings.normalizedPrefs({ confidenceThreshold = 0.6,
        singleKeywordPerPhoto = true, dryRun = false })
    local results = {
        { photoKey = 'T', photo = 'hT',
          response = resp(true, {
              speciesDet('Northern Cardinal', 'Cardinalis cardinalis', 0.7),
              speciesDet('Blue Jay', 'Cyanocitta cristata', 0.95),
          }),
          existingNames = {} },
    }
    local out = W.build(results, prefs1)
    local e = entryFor(out.plan, 'T')
    assert_true(e ~= nil, "T: has an entry")
    assert_eq(#e.addKeywords, 1, "tie-break: one keyword kept")
    assert_eq(e.addKeywords[1], 'Blue Jay (Cyanocitta cristata)',
        "tie-break: higher decision.confidence wins")
end

-- =====================================================================
-- 6. Too-coarse skip: single order detection -> no entry; found 1, skipped 1.
-- =====================================================================
do
    local results = {
        { photoKey = 'D', photo = 'hD',
          response = resp(true, { orderDet() }),
          existingNames = {} },
    }
    local out = W.build(results, PREFS)
    assert_true(entryFor(out.plan, 'D') == nil, "D: no entry (too coarse)")
    local p = out.summary.perPhoto['D']
    assert_eq(p.found, 1, "D: found 1 (>=1 detection present)")
    assert_eq(p.skipped, 1, "D: skipped 1 (too coarse)")
    assert_eq(p.identified, 0, "D: identified 0")
    assert_eq(p.uncertain, 0, "D: uncertain 0")
end

-- =====================================================================
-- 7. No detections: bird_present=false, detections={} -> no entry; found 0, skipped 1.
-- =====================================================================
do
    local results = {
        { photoKey = 'E', photo = 'hE', response = resp(false, {}), existingNames = {} },
    }
    local out = W.build(results, PREFS)
    assert_true(entryFor(out.plan, 'E') == nil, "E: no entry")
    assert_eq(out.summary.perPhoto['E'].found, 0, "E: found 0")
    assert_eq(out.summary.perPhoto['E'].skipped, 1, "E: skipped 1")
end

-- =====================================================================
-- 8. CORRECTED semantics: bird_present=true with EMPTY detections -> found 0, skipped 1.
--    (found keys off detections, NOT the flag.)
-- =====================================================================
do
    local results = {
        { photoKey = 'G', photo = 'hG', response = resp(true, {}), existingNames = {} },
    }
    local out = W.build(results, PREFS)
    assert_true(entryFor(out.plan, 'G') == nil, "G: no entry")
    assert_eq(out.summary.perPhoto['G'].found, 0, "G: found 0 (keys off detections, not flag)")
    assert_eq(out.summary.perPhoto['G'].skipped, 1, "G: skipped 1")
end

-- =====================================================================
-- 9. Error photo: response=nil, error set -> no entry; errors 1.
-- =====================================================================
do
    local results = {
        { photoKey = 'F', photo = 'hF', response = nil, error = 'identify-failed',
          existingNames = {} },
    }
    local out = W.build(results, PREFS)
    assert_true(entryFor(out.plan, 'F') == nil, "F: no entry")
    local p = out.summary.perPhoto['F']
    assert_eq(p.errors, 1, "F: errors 1")
    assert_eq(p.found, 0, "F: found 0")
    assert_eq(p.identified, 0, "F: identified 0")
    assert_eq(p.skipped, 0, "F: skipped 0 (errors, not skipped)")
end

-- =====================================================================
-- 10. DUPLICATE photoKey: two records sharing photoKey 'dup' (species + genus) -> a SINGLE
--     entry with merged+deduped addKeywords, and perPhoto['dup'] holds SUMMED counts.
-- =====================================================================
do
    local results = {
        { photoKey = 'dup', photo = 'hdup1',
          response = resp(true, { speciesDet('Northern Cardinal', 'Cardinalis cardinalis', 0.82) }),
          existingNames = {} },
        { photoKey = 'dup', photo = 'hdup2',
          response = resp(true, { genusDet('Cardinalis', 0.4) }),
          existingNames = {} },
    }
    local out = W.build(results, PREFS)
    -- exactly one entry for 'dup'
    local count = 0
    for _, e in ipairs(out.plan.entries) do
        if e.photoKey == 'dup' then count = count + 1 end
    end
    assert_eq(count, 1, "dup: exactly ONE entry")
    local e = entryFor(out.plan, 'dup')
    assert_eq(#e.addKeywords, 2, "dup: merged addKeywords (species + genus)")
    -- genus is conf 0.4 (< 0.6) -> uncertain genus -> 'Cardinalis sp.?'
    local p = out.summary.perPhoto['dup']
    assert_eq(p.found, 2, "dup: found summed (2 records, each >=1 detection)")
    assert_eq(p.identified, 1, "dup: identified summed (the species)")
    assert_eq(p.uncertain, 1, "dup: uncertain summed (the genus)")
    assert_eq(p.addCount, 2, "dup: addCount = final entry length")
end

-- =====================================================================
-- 11. perRun totals equal the column sums across perPhoto; perRun.photos == record count.
-- =====================================================================
do
    local results = {
        { photoKey = 'A', photo = 'hA',
          response = resp(true, { speciesDet('Northern Cardinal', 'Cardinalis cardinalis', 0.82) }),
          existingNames = {} },
        { photoKey = 'D', photo = 'hD', response = resp(true, { orderDet() }), existingNames = {} },
        { photoKey = 'E', photo = 'hE', response = resp(false, {}), existingNames = {} },
        { photoKey = 'F', photo = 'hF', response = nil, error = 'x', existingNames = {} },
    }
    local out = W.build(results, PREFS)
    local pr = out.summary.perRun
    assert_eq(pr.photos, 4, "perRun.photos == record count")
    -- sum the columns
    local sFound, sId, sUnc, sErr, sSkip = 0, 0, 0, 0, 0
    for _, p in pairs(out.summary.perPhoto) do
        sFound = sFound + p.found
        sId = sId + p.identified
        sUnc = sUnc + p.uncertain
        sErr = sErr + p.errors
        sSkip = sSkip + p.skipped
    end
    assert_eq(pr.found, sFound, "perRun.found == column sum")
    assert_eq(pr.identified, sId, "perRun.identified == column sum")
    assert_eq(pr.uncertain, sUnc, "perRun.uncertain == column sum")
    assert_eq(pr.errors, sErr, "perRun.errors == column sum")
    assert_eq(pr.skipped, sSkip, "perRun.skipped == column sum")
    -- concrete expected values: A found+identified, D found+skipped, E skipped, F error
    assert_eq(pr.found, 2, "perRun.found = 2 (A, D)")
    assert_eq(pr.identified, 1, "perRun.identified = 1 (A)")
    assert_eq(pr.skipped, 2, "perRun.skipped = 2 (D too-coarse, E no-detection)")
    assert_eq(pr.errors, 1, "perRun.errors = 1 (F)")
end

-- =====================================================================
-- 12. Dry-run report: planReport(results, {dryRun=true}) -> {plan, summary, dryRun=true}
--     and the plan is IDENTICAL to build(results, prefs).plan (build does not gate on dryRun).
-- =====================================================================
do
    local results = {
        { photoKey = 'A', photo = 'hA',
          response = resp(true, { speciesDet('Northern Cardinal', 'Cardinalis cardinalis', 0.82) }),
          existingNames = {} },
    }
    local prefsDry = settings.normalizedPrefs({ confidenceThreshold = 0.6, dryRun = true })
    local prefsWet = settings.normalizedPrefs({ confidenceThreshold = 0.6, dryRun = false })
    local report = W.planReport(results, prefsDry)
    assert_eq(report.dryRun, true, "planReport: dryRun flag true")
    local built = W.build(results, prefsWet)
    -- plan entries identical (same photoKey + same addKeywords)
    assert_eq(#report.plan.entries, #built.plan.entries, "dry-run: same entry count")
    local re = entryFor(report.plan, 'A')
    local be = entryFor(built.plan, 'A')
    assert_true(re ~= nil and be ~= nil, "dry-run: both have entry A")
    assert_eq(re.addKeywords[1], be.addKeywords[1], "dry-run: identical addKeywords")

    local reportWet = W.planReport(results, prefsWet)
    assert_eq(reportWet.dryRun, false, "planReport: dryRun false when prefs.dryRun=false")
end

-- =====================================================================
-- 13. BL-15: the plan emits LIGHTROOM-WRITABLE names for uncertain detections.
--     createKeyword rejects '?', so writeplan maps the rendered '?' marker to
--     ' (uncertain)' in the plan/diff/idempotency path (not only at the write call).
-- =====================================================================
do
    -- Uncertain genus detection -> planned keyword is ' (uncertain)', never '?'.
    local results = {
        { photoKey = 'U', photo = 'hU',
          response = resp(true, { genusDet('Cardinalis', 0.9) }),
          existingNames = {} },
    }
    local out = W.build(results, PREFS)
    local e = entryFor(out.plan, 'U')
    assert_true(e ~= nil, "BL-15: uncertain genus produces an entry")
    assert_eq(e.addKeywords[1], 'Cardinalis sp. (uncertain)', "BL-15: genus name is writable")
    assert_true(e.addKeywords[1]:find('%?') == nil, "BL-15: no '?' in the planned keyword")
    assert_eq(out.summary.perPhoto['U'].uncertain, 1, "BL-15: counted uncertain")
    assert_eq(out.summary.perPhoto['U'].identified, 0, "BL-15: not counted identified")
end

do
    -- Idempotency: existingNames already holds the WRITABLE form -> NO new add (re-run safe).
    local results = {
        { photoKey = 'U', photo = 'hU',
          response = resp(true, { genusDet('Cardinalis', 0.9) }),
          existingNames = { ['Cardinalis sp. (uncertain)'] = true } },
    }
    local out = W.build(results, PREFS)
    assert_eq(entryFor(out.plan, 'U'), nil, "BL-15: writable name already present -> no entry")
end

-- =====================================================================
-- 14. A1: NORMALIZED existing-keyword comparison (dedup hardening).
--     The add-only diff must recognize an already-present keyword that differs only by
--     ASCII case or whitespace (case-fold + trim + collapse internal runs), so a re-run
--     never re-adds it. The STORED form remains the original rendered string.
-- =====================================================================
do
    -- (a) existing lower-cased form -> incoming canonical-cased rendering produces ZERO adds.
    local results = {
        { photoKey = 'Na', photo = 'hNa',
          response = resp(true, { speciesDet('Northern Cardinal', 'Cardinalis cardinalis', 0.82) }),
          existingNames = { ['northern cardinal (cardinalis cardinalis)'] = true } },
    }
    local out = W.build(results, PREFS)
    assert_eq(entryFor(out.plan, 'Na'), nil, "A1(a): case-only existing match -> no entry")
    assert_eq(out.summary.perPhoto['Na'].addCount, 0, "A1(a): addCount 0")
end

do
    -- (b) existing with trailing space AND a double internal space -> ZERO adds.
    local results = {
        { photoKey = 'Nb', photo = 'hNb',
          response = resp(true, { speciesDet('Northern Cardinal', 'Cardinalis cardinalis', 0.82) }),
          existingNames = { ['Northern  Cardinal (Cardinalis cardinalis) '] = true } },
    }
    local out = W.build(results, PREFS)
    assert_eq(entryFor(out.plan, 'Nb'), nil, "A1(b): whitespace-variant existing match -> no entry")
    assert_eq(out.summary.perPhoto['Nb'].addCount, 0, "A1(b): addCount 0")
end

do
    -- (c) two incoming records for the SAME photo differing only by case -> ONE add
    --     (first rendering wins; the stored form is the first record's canonical render).
    local results = {
        { photoKey = 'Nc', photo = 'hNc',
          response = resp(true, { speciesDet('Northern Cardinal', 'Cardinalis cardinalis', 0.82) }),
          existingNames = {} },
        { photoKey = 'Nc', photo = 'hNc',
          response = resp(true, { speciesDet('NORTHERN CARDINAL', 'CARDINALIS CARDINALIS', 0.82) }),
          existingNames = {} },
    }
    local out = W.build(results, PREFS)
    local e = entryFor(out.plan, 'Nc')
    assert_true(e ~= nil, "A1(c): one entry for the photo")
    assert_eq(#e.addKeywords, 1, "A1(c): exactly one add (case-variants dedupe)")
    assert_eq(e.addKeywords[1], CARDINAL, "A1(c): first rendering wins as the stored form")
end

do
    -- (d) a genuinely-new name still adds (the normalizer must not over-collapse).
    local results = {
        { photoKey = 'Nd', photo = 'hNd',
          response = resp(true, { speciesDet('Blue Jay', 'Cyanocitta cristata', 0.82) }),
          existingNames = { ['northern cardinal (cardinalis cardinalis)'] = true } },
    }
    local out = W.build(results, PREFS)
    local e = entryFor(out.plan, 'Nd')
    assert_true(e ~= nil, "A1(d): new name produces an entry")
    assert_eq(e.addKeywords[1], 'Blue Jay (Cyanocitta cristata)', "A1(d): the new keyword adds")
end
