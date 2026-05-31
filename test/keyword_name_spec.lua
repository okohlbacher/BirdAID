-- test/keyword_name_spec.lua (BL-15 fix — uncertain keyword write-back)
--
-- Exercises BirdAID.lrdevplugin/src/keyword_name.lua: a PURE module (imports NO Lr*),
-- require-able under stock lua / luajit. Covers toWritable: every uncertain render form maps
-- to a writable ' (uncertain)' name; confident/clean names are unchanged; NO output contains
-- '?'; idempotency (already-writable names are stable); defensive non-string / bare-marker.
--
-- Loaded by test/run.lua via dofile; uses the runner globals assert_eq / assert_true.
-- Strictly Lua 5.1 common subset (no \u{}, no //, no goto, no <close>; unpack global).

print('running test/keyword_name_spec.lua')

local KN = require('src.keyword_name')
local K = require('src.keyword')

-- ---- Direct toWritable mapping over every uncertain render shape ----------------------------

-- uncertain species: "Common (Scientific)?" -> "Common (Scientific) (uncertain)"
assert_eq(KN.toWritable('Northern Cardinal (Cardinalis cardinalis)?'),
    'Northern Cardinal (Cardinalis cardinalis) (uncertain)', 'uncertain species maps')

-- genus: "Genus sp.?" -> "Genus sp. (uncertain)"
assert_eq(KN.toWritable('Cardinalis sp.?'), 'Cardinalis sp. (uncertain)', 'genus maps')

-- family: "Family (family)?" -> "Family (family) (uncertain)"
assert_eq(KN.toWritable('Cardinalidae (family)?'), 'Cardinalidae (family) (uncertain)', 'family maps')

-- scientific-only uncertain: "Scientific?" -> "Scientific (uncertain)"
assert_eq(KN.toWritable('Cardinalis cardinalis?'), 'Cardinalis cardinalis (uncertain)', 'sci-only maps')

-- common-only uncertain: "Common?" -> "Common (uncertain)"
assert_eq(KN.toWritable('Northern Cardinal?'), 'Northern Cardinal (uncertain)', 'common-only maps')

-- ---- Confident / clean names are returned UNCHANGED -----------------------------------------

assert_eq(KN.toWritable('Northern Cardinal (Cardinalis cardinalis)'),
    'Northern Cardinal (Cardinalis cardinalis)', 'confident species unchanged')
assert_eq(KN.toWritable('Mandarin Duck (Aix galericulata)'),
    'Mandarin Duck (Aix galericulata)', 'confident species 2 unchanged')

-- ---- NO output ever contains '?' ------------------------------------------------------------

local samples = {
    'Northern Cardinal (Cardinalis cardinalis)?', 'Cardinalis sp.?',
    'Cardinalidae (family)?', 'Cardinalis cardinalis?', 'Northern Cardinal?',
}
for _, s in ipairs(samples) do
    assert_true(KN.toWritable(s):find('%?') == nil, 'no ? remains in writable name: ' .. s)
end

-- ---- Commas (LrC keyword delimiter) are removed -------------------------------------------

-- confident species with a multi-language common name joined by ", " (real failing case)
assert_eq(KN.toWritable('Western Grebe, Westlicher Haubentaucher (Aechmophorus occidentalis)'),
    'Western Grebe Westlicher Haubentaucher (Aechmophorus occidentalis)', 'comma removed + collapsed')
assert_true(KN.toWritable('Western Grebe, Westlicher Haubentaucher (Aechmophorus occidentalis)')
    :find(',', 1, true) == nil, 'no comma remains')
-- comma AND a trailing uncertainty marker together
assert_eq(KN.toWritable('A, B?'), 'A B (uncertain)', 'comma + marker both handled')
-- a bare comma name collapses without leaving stray whitespace
assert_eq(KN.toWritable('Foo,Bar'), 'Foo Bar', 'comma with no space still split cleanly')
-- ordering edge (CODEX): comma AFTER the '?' must not re-expose a trailing '?'; comma cleaned first
assert_eq(KN.toWritable('A?,'), 'A (uncertain)', 'comma-after-? handled: no stray ? remains')
assert_true(KN.toWritable('A?,'):find('%?') == nil, 'no ? remains for the A?, edge')
-- pathological comma-only input never yields a blank name
assert_eq(KN.toWritable(','), ',', 'comma-only pathological input falls back to original (never blank)')

-- ---- Idempotency: re-mapping an already-writable name is stable ------------------------------

local once = KN.toWritable('Cardinalis sp.?')
assert_eq(KN.toWritable(once), once, 'toWritable is idempotent (no double marker)')
assert_eq(KN.toWritable('Cardinalis sp. (uncertain)'), 'Cardinalis sp. (uncertain)',
    'already-writable name unchanged')

-- ---- Defensive edges ------------------------------------------------------------------------

assert_eq(KN.toWritable(nil), nil, 'nil passes through')
assert_eq(KN.toWritable(42), 42, 'non-string passes through')
assert_eq(KN.toWritable('?'), '?', 'bare marker stem is not turned into a lone suffix')
assert_eq(KN.toWritable('Common (Scientific)??'), 'Common (Scientific) (uncertain)',
    'defensive: collapses a double ?? tail to one marker')
assert_eq(KN.toWritable('Common (Scientific) ?'), 'Common (Scientific) (uncertain)',
    'trailing space before ? is trimmed')

-- ---- Round-trip from the real renderer (every render form is writable) ----------------------

local function writableOf(decision)
    local r = K.render(decision)
    if r == nil then return nil end
    return KN.toWritable(r)
end

-- uncertain species (render appends '?'): writable + no '?'
local us = writableOf({ action = 'write', rank = 'species', uncertain = true,
    displayName = 'Northern Cardinal', scientificName = 'Cardinalis cardinalis' })
assert_eq(us, 'Northern Cardinal (Cardinalis cardinalis) (uncertain)', 'render->writable uncertain species')

-- confident species (render: no '?'): unchanged through toWritable
local cs = writableOf({ action = 'write', rank = 'species', uncertain = false,
    displayName = 'Northern Cardinal', scientificName = 'Cardinalis cardinalis' })
assert_eq(cs, 'Northern Cardinal (Cardinalis cardinalis)', 'render->writable confident species')

-- genus (render always '?'): writable
local gs = writableOf({ action = 'write', rank = 'genus', uncertain = true, rankName = 'Cardinalis' })
assert_eq(gs, 'Cardinalis sp. (uncertain)', 'render->writable genus')

-- family (render always '?'): writable
local fs = writableOf({ action = 'write', rank = 'family', uncertain = true, rankName = 'Cardinalidae' })
assert_eq(fs, 'Cardinalidae (family) (uncertain)', 'render->writable family')
