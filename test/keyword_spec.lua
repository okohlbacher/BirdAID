-- test/keyword_spec.lua (Phase 4 — Keyword core: ID-01 + KW-01 + KW-02)
--
-- Exercises BirdAID.lrdevplugin/src/keyword.lua: a PURE module (imports NO Lr*),
-- require-able under stock lua / luajit. Covers the FULL branch matrix of:
--   * decide(detection, prefs) -> decision (ID-01): confident species, boundary
--     confidence==threshold, low-confidence species with/without a qualifying genus/family
--     alternative, genus>family precedence, empty-rank_name alt skipped, malformed
--     (non-table) alternative ignored, nil confidence => uncertain, primary genus/family,
--     primary order/class => skip. ALSO asserts decision.confidence == the SELECTED
--     source's confidence (adopted alt's when degraded; primary's otherwise; nil if none).
--   * render(decision) -> string|nil (KW-01/KW-02): LOCKED formats, missing-name branches
--     (scientific-only / common-only), blank-stem => nil, whitespace/"nil"/"" treated as
--     missing, names containing ?/()/. pinned (render APPENDS, never strips), skip => nil.
--   * dedupePhoto(names): first-seen-order dedupe; nil/empty => {}.
--
-- Loaded by test/run.lua via dofile; uses the runner globals assert_eq / assert_true.
-- Strictly Lua 5.1 common subset (no \u{}, no //, no goto, no <close>; unpack global).

local K = require('src.keyword')

local PREFS = { confidenceThreshold = 0.6 }

-- Fixture builder: a validated species detection (confidence overridable; alternatives nil).
local function speciesDet(conf, alts)
    return {
        bbox = { 0.1, 0.2, 0.5, 0.6 },
        common_name = 'Northern Cardinal',
        scientific_name = 'Cardinalis cardinalis',
        confidence = conf,
        identified_rank = 'species',
        rank_name = 'Cardinalis cardinalis',
        alternatives = alts,
    }
end

-- =====================================================================
-- decide(): SPECIES branches
-- =====================================================================
-- confident species (conf 0.82 >= 0.6)
do
    local d = K.decide(speciesDet(0.82), PREFS)
    assert_eq(d.action, 'write', "confident species -> write")
    assert_eq(d.rank, 'species', "confident species -> rank species")
    assert_eq(d.uncertain, false, "confident species -> uncertain false")
    assert_eq(d.confidence, 0.82, "confident species -> decision.confidence == primary 0.82")
end

-- BOUNDARY: confidence == threshold (0.6) counts as CONFIDENT (>=)
do
    local d = K.decide(speciesDet(0.6), PREFS)
    assert_eq(d.action, 'write', "boundary conf==threshold -> write")
    assert_eq(d.rank, 'species', "boundary conf==threshold -> rank species")
    assert_eq(d.uncertain, false, "boundary conf==threshold -> CONFIDENT (>=)")
    assert_eq(d.confidence, 0.6, "boundary -> decision.confidence == 0.6")
end

-- low-confidence species, NO qualifying alternative -> uncertain species
do
    local d = K.decide(speciesDet(0.3), PREFS)
    assert_eq(d.action, 'write', "low-conf species no alt -> write")
    assert_eq(d.rank, 'species', "low-conf species no alt -> rank species")
    assert_eq(d.uncertain, true, "low-conf species no alt -> uncertain")
    assert_eq(d.confidence, 0.3, "low-conf species no alt -> decision.confidence == primary 0.3")
end

-- low-confidence species WITH a confident genus alternative -> degrade to genus
do
    local alts = {
        { common_name = 'Cardinals', scientific_name = 'Cardinalis',
          confidence = 0.9, identified_rank = 'genus', rank_name = 'Cardinalis' },
    }
    local d = K.decide(speciesDet(0.3, alts), PREFS)
    assert_eq(d.action, 'write', "low-conf species + genus alt -> write")
    assert_eq(d.rank, 'genus', "low-conf species + genus alt -> rank genus")
    assert_eq(d.uncertain, true, "degraded to genus -> uncertain")
    assert_eq(d.rankName, 'Cardinalis', "degraded genus -> rankName from alt")
    assert_eq(d.confidence, 0.9, "degraded genus -> decision.confidence == ADOPTED alt 0.9")
end

-- genus AND family confident alternatives -> genus wins (more specific)
do
    local alts = {
        { common_name = 'Cardinal family', scientific_name = 'Cardinalidae',
          confidence = 0.95, identified_rank = 'family', rank_name = 'Cardinalidae' },
        { common_name = 'Cardinals', scientific_name = 'Cardinalis',
          confidence = 0.85, identified_rank = 'genus', rank_name = 'Cardinalis' },
    }
    local d = K.decide(speciesDet(0.3, alts), PREFS)
    assert_eq(d.rank, 'genus', "genus+family confident -> genus wins (more specific)")
    assert_eq(d.rankName, 'Cardinalis', "genus wins -> rankName Cardinalis")
    assert_eq(d.confidence, 0.85, "genus wins -> decision.confidence == genus alt 0.85")
end

-- family-only confident alternative (no genus) -> family adopted
do
    local alts = {
        { common_name = 'Cardinal family', scientific_name = 'Cardinalidae',
          confidence = 0.9, identified_rank = 'family', rank_name = 'Cardinalidae' },
    }
    local d = K.decide(speciesDet(0.3, alts), PREFS)
    assert_eq(d.rank, 'family', "family-only confident alt -> rank family")
    assert_eq(d.rankName, 'Cardinalidae', "family-only -> rankName Cardinalidae")
    assert_eq(d.confidence, 0.9, "family-only -> decision.confidence == family alt 0.9")
end

-- two genus alternatives, tie on rank -> higher confidence wins
do
    local alts = {
        { common_name = 'Cardinals lo', scientific_name = 'Cardinalis',
          confidence = 0.7, identified_rank = 'genus', rank_name = 'CardinalisLo' },
        { common_name = 'Cardinals hi', scientific_name = 'Cardinalis',
          confidence = 0.92, identified_rank = 'genus', rank_name = 'CardinalisHi' },
    }
    local d = K.decide(speciesDet(0.3, alts), PREFS)
    assert_eq(d.rankName, 'CardinalisHi', "two genus alts -> higher confidence wins")
    assert_eq(d.confidence, 0.92, "two genus alts -> decision.confidence == higher 0.92")
end

-- otherwise-confident genus alt with EMPTY rank_name -> skipped; fall through to uncertain species
do
    local alts = {
        { common_name = 'Cardinals', scientific_name = 'Cardinalis',
          confidence = 0.95, identified_rank = 'genus', rank_name = '' },
    }
    local d = K.decide(speciesDet(0.3, alts), PREFS)
    assert_eq(d.rank, 'species', "empty rank_name alt skipped -> species fallthrough")
    assert_eq(d.uncertain, true, "empty rank_name alt skipped -> uncertain species")
    assert_eq(d.confidence, 0.3, "empty rank_name alt skipped -> decision.confidence == primary 0.3")
end

-- malformed alternatives entry (a string, non-table) -> ignored, no crash
do
    local alts = {
        'not-a-table',
        { common_name = 'Cardinals', scientific_name = 'Cardinalis',
          confidence = 0.9, identified_rank = 'genus', rank_name = 'Cardinalis' },
    }
    local d = K.decide(speciesDet(0.3, alts), PREFS)
    assert_eq(d.rank, 'genus', "malformed (string) alt ignored; genus still adopted")
    assert_eq(d.rankName, 'Cardinalis', "malformed alt ignored -> genus rankName")
    assert_eq(d.confidence, 0.9, "malformed alt ignored -> decision.confidence 0.9")
end

-- a below-threshold genus alt does NOT qualify -> species uncertain fallthrough
do
    local alts = {
        { common_name = 'Cardinals', scientific_name = 'Cardinalis',
          confidence = 0.4, identified_rank = 'genus', rank_name = 'Cardinalis' },
    }
    local d = K.decide(speciesDet(0.3, alts), PREFS)
    assert_eq(d.rank, 'species', "below-threshold genus alt not adopted -> species")
    assert_eq(d.uncertain, true, "below-threshold genus alt -> uncertain species")
end

-- nil confidence on a species -> treated as below threshold -> uncertain species
do
    local d = K.decide(speciesDet(nil), PREFS)
    assert_eq(d.action, 'write', "nil-conf species -> write")
    assert_eq(d.rank, 'species', "nil-conf species -> rank species")
    assert_eq(d.uncertain, true, "nil-conf species -> uncertain")
    assert_eq(d.confidence, nil, "nil-conf species -> decision.confidence == nil")
end

-- =====================================================================
-- decide(): PRIMARY genus / family / order / class
-- =====================================================================
do
    local d = K.decide({
        bbox = { 0.1, 0.2, 0.5, 0.6 }, common_name = 'Cardinals',
        scientific_name = 'Cardinalis', confidence = 0.88,
        identified_rank = 'genus', rank_name = 'Cardinalis',
    }, PREFS)
    assert_eq(d.action, 'write', "primary genus -> write")
    assert_eq(d.rank, 'genus', "primary genus -> rank genus")
    assert_eq(d.uncertain, true, "primary genus -> always uncertain")
    assert_eq(d.rankName, 'Cardinalis', "primary genus -> rankName")
    assert_eq(d.confidence, 0.88, "primary genus -> decision.confidence == primary 0.88")
end

do
    local d = K.decide({
        bbox = { 0.1, 0.2, 0.5, 0.6 }, common_name = 'Cardinal family',
        scientific_name = 'Cardinalidae', confidence = 0.77,
        identified_rank = 'family', rank_name = 'Cardinalidae',
    }, PREFS)
    assert_eq(d.rank, 'family', "primary family -> rank family")
    assert_eq(d.uncertain, true, "primary family -> always uncertain")
    assert_eq(d.rankName, 'Cardinalidae', "primary family -> rankName")
end

do
    local d = K.decide({
        bbox = { 0.1, 0.2, 0.5, 0.6 }, common_name = 'Passerines',
        scientific_name = 'Passeriformes', confidence = 0.99,
        identified_rank = 'order', rank_name = 'Passeriformes',
    }, PREFS)
    assert_eq(d.action, 'skip', "primary order -> skip")
    assert_eq(d.reason, 'too-coarse', "primary order -> reason too-coarse")
end

do
    local d = K.decide({
        bbox = { 0.1, 0.2, 0.5, 0.6 }, common_name = 'Birds',
        scientific_name = 'Aves', confidence = 0.99,
        identified_rank = 'class', rank_name = 'Aves',
    }, PREFS)
    assert_eq(d.action, 'skip', "primary class -> skip")
    assert_eq(d.reason, 'too-coarse', "primary class -> reason too-coarse")
end

-- =====================================================================
-- render(): SPECIES (KW-01, KW-02)
-- =====================================================================
assert_eq(K.render({ action = 'write', rank = 'species',
    displayName = 'Northern Cardinal', scientificName = 'Cardinalis cardinalis', uncertain = false }),
    'Northern Cardinal (Cardinalis cardinalis)', "confident species -> Common (Scientific)")

assert_eq(K.render({ action = 'write', rank = 'species',
    displayName = 'Northern Cardinal', scientificName = 'Cardinalis cardinalis', uncertain = true }),
    'Northern Cardinal (Cardinalis cardinalis)?', "uncertain species -> trailing ?")

assert_eq(K.render({ action = 'write', rank = 'species',
    displayName = nil, scientificName = 'Cardinalis cardinalis', uncertain = false }),
    'Cardinalis cardinalis', "species missing common -> SCIENTIFIC ONLY (no parens)")

assert_eq(K.render({ action = 'write', rank = 'species',
    displayName = nil, scientificName = 'Cardinalis cardinalis', uncertain = true }),
    'Cardinalis cardinalis?', "species missing common uncertain -> Scientific?")

assert_eq(K.render({ action = 'write', rank = 'species',
    displayName = 'Northern Cardinal', scientificName = nil, uncertain = false }),
    'Northern Cardinal', "species missing scientific -> Common only")

assert_eq(K.render({ action = 'write', rank = 'species',
    displayName = 'Northern Cardinal', scientificName = nil, uncertain = true }),
    'Northern Cardinal?', "species missing scientific uncertain -> Common?")

assert_eq(K.render({ action = 'write', rank = 'species',
    displayName = '', scientificName = '', uncertain = true }),
    nil, "species BOTH names missing -> nil (no blank keyword)")

-- =====================================================================
-- render(): GENUS / FAMILY
-- =====================================================================
assert_eq(K.render({ action = 'write', rank = 'genus', rankName = 'Cardinalis', uncertain = true }),
    'Cardinalis sp.?', "genus -> <Genus> sp.?")

assert_eq(K.render({ action = 'write', rank = 'genus', rankName = '', uncertain = true }),
    nil, "genus blank stem -> nil (no ' sp.?' with blank stem)")

assert_eq(K.render({ action = 'write', rank = 'family', rankName = 'Cardinalidae', uncertain = true }),
    'Cardinalidae (family)?', "family -> <Family> (family)?")

assert_eq(K.render({ action = 'write', rank = 'family', rankName = '', uncertain = true }),
    nil, "family blank stem -> nil (no ' (family)?' with blank stem)")

-- =====================================================================
-- render(): EMPTY-GUARD (whitespace / literal "nil" / "") treated as MISSING
-- =====================================================================
assert_eq(K.render({ action = 'write', rank = 'species',
    displayName = '   ', scientificName = 'Cardinalis cardinalis', uncertain = false }),
    'Cardinalis cardinalis', "whitespace displayName treated as missing -> scientific only")

assert_eq(K.render({ action = 'write', rank = 'species',
    displayName = 'Northern Cardinal', scientificName = 'nil', uncertain = false }),
    'Northern Cardinal', "literal 'nil' scientific treated as missing -> common only")

assert_eq(K.render({ action = 'write', rank = 'genus', rankName = '   ', uncertain = true }),
    nil, "whitespace genus rankName treated as missing -> nil")

-- =====================================================================
-- render(): skip decision -> nil
-- =====================================================================
assert_eq(K.render({ action = 'skip', reason = 'too-coarse', rank = 'order' }),
    nil, "skip decision -> render nil")

-- =====================================================================
-- render(): NIT — names with parens are NOT stripped (we APPEND the format around them)
-- =====================================================================
assert_eq(K.render({ action = 'write', rank = 'species',
    displayName = 'Cardinal (red)', scientificName = 'Cardinalis cardinalis', uncertain = false }),
    'Cardinal (red) (Cardinalis cardinalis)', "name with parens -> format APPENDED, not stripped")

-- =====================================================================
-- render(): NIT #4 (phase-4 code review) — NO DOUBLE '?'. When the rendered species stem
-- already ends with '?' and the decision is uncertain, the appended uncertainty marker
-- REPLACES the trailing '?' rather than doubling it. (CHANGED ASSERTION: this used to pin
-- the old doubling behavior 'Cardinal? (Cardinalis cardinalis)?' — now a SINGLE trailing '?'.)
-- =====================================================================
-- displayName carries an inner '?' but the RENDERED stem ends with ')', so the marker just
-- appends a single trailing '?': the inner '?' is preserved, the trailing is not doubled.
assert_eq(K.render({ action = 'write', rank = 'species',
    displayName = 'Cardinal?', scientificName = 'Cardinalis cardinalis', uncertain = true }),
    'Cardinal? (Cardinalis cardinalis)?', "inner '?' preserved; single trailing '?' (no ??)")

-- scientific-only stem already ending '?' + uncertain -> single trailing '?'.
assert_eq(K.render({ action = 'write', rank = 'species',
    scientificName = 'Cardinalis?', uncertain = true }),
    'Cardinalis?', "scientific-only stem ending '?' -> single '?' (no ??)")

-- displayName-only stem already ending '?' + uncertain -> single trailing '?'.
assert_eq(K.render({ action = 'write', rank = 'species',
    displayName = 'Cardinal?', uncertain = true }),
    'Cardinal?', "displayName-only stem ending '?' -> single '?' (no ??)")

-- NOT uncertain: an existing '?' in the name is PRESERVED (never stripped).
assert_eq(K.render({ action = 'write', rank = 'species',
    displayName = 'Cardinal?', scientificName = 'Cardinalis cardinalis', uncertain = false }),
    'Cardinal? (Cardinalis cardinalis)', "not-uncertain preserves an existing '?' in the name")

-- =====================================================================
-- dedupePhoto(): first-seen order; nil/empty => {}
-- =====================================================================
do
    local out = K.dedupePhoto({ 'A', 'B', 'A' })
    assert_eq(#out, 2, "dedupePhoto collapses duplicate -> 2 entries")
    assert_eq(out[1], 'A', "dedupePhoto preserves first-seen order [1]=A")
    assert_eq(out[2], 'B', "dedupePhoto preserves first-seen order [2]=B")
end
do
    local out = K.dedupePhoto(nil)
    assert_eq(type(out), 'table', "dedupePhoto(nil) -> table")
    assert_eq(#out, 0, "dedupePhoto(nil) -> empty")
end
do
    local out = K.dedupePhoto({})
    assert_eq(#out, 0, "dedupePhoto({}) -> empty")
end

-- decide()/render() NEVER raise on the fixture battery (pcall battery)
do
    assert_true(pcall(K.decide, speciesDet(0.5), PREFS), "decide never raises (low-conf)")
    assert_true(pcall(K.decide, speciesDet(nil), nil), "decide never raises (nil prefs)")
    assert_true(pcall(K.render, { action = 'write', rank = 'species' }), "render never raises (sparse decision)")
    assert_true(pcall(K.render, {}), "render never raises (empty decision)")
end
