-- test/results_spec.lua (09-01 Task 7b — PURE per-photo RESULT MODEL)
--
-- Exercises BirdAID.lrdevplugin/src/results.lua: a PURE module (no Lr, deterministic, no
-- math.random) require-able under stock lua / luajit. Joins the pool's anchor terminal-status map
-- (worker_pool.run().statusByAnchorKey) with the cluster follower->anchor map and the collected
-- anchor responses (responseByAnchorKey) into EXACTLY ONE per-photo result for EVERY selected
-- photo (BL-06/BL-07). photoKey-keyed and Lr-free; the photoKey->handle binding is the orchestrator's.
--
-- Loaded via dofile; runner globals assert_eq / assert_true. Lua 5.1 common subset.

local results = require('src.results')

assert_true(type(results) == 'table', "require 'src.results' resolves")
assert_true(type(results.build) == 'function', "results exposes build")

-- a stand-in contract-valid response (the model only carries it, never validates it).
local function resp(name) return { bird_present = true, detections = {}, _name = name } end

local function count(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end

-- =====================================================================
-- Clustering OFF (anchors == selection, no followers): identified / deferred / cancelled passthrough.
-- =====================================================================
do
    local out = results.build({
        selection = { 'p1', 'p2', 'p3', 'p4' },
        anchors = { 'p1', 'p2', 'p3', 'p4' },
        followerToAnchor = {},
        anchorStatus = { p1 = 'identified', p2 = 'deferred', p3 = 'cancelled', p4 = 'fatal' },
        anchorResponse = { p1 = resp('r1') },
    })
    local byKey = out.byPhoto
    assert_eq(count(byKey), 4, "one result per selected photo (clustering off)")
    assert_eq(byKey.p1.status, 'identified', "p1 identified")
    assert_eq(byKey.p1.response._name, 'r1', "p1 carries its own response")
    assert_eq(byKey.p2.status, 'deferred', "p2 deferred")
    assert_eq(byKey.p2.response, nil, "deferred carries no response")
    assert_eq(byKey.p3.status, 'cancelled', "p3 cancelled")
    assert_eq(byKey.p4.status, 'deferred', "p4 fatal anchor -> deferred (cluster-level)")
    assert_eq(byKey.p4.response, nil, "fatal->deferred carries no response")
    -- the photo field is the photoKey.
    assert_eq(byKey.p1.photo, 'p1', "result.photo is the photoKey")
    -- ordered array in selection order.
    assert_eq(#out.ordered, 4, "ordered array has all four")
    assert_eq(out.ordered[1].photo, 'p1', "ordered[1] is p1")
    assert_eq(out.ordered[4].photo, 'p4', "ordered[4] is p4")
end

-- =====================================================================
-- One anchor + 2 followers, anchor IDENTIFIED -> all three identified; followers inherit the
-- anchor response with inheritedFrom set.
-- =====================================================================
do
    local out = results.build({
        selection = { 'a', 'f1', 'f2' },
        anchors = { 'a' },
        followerToAnchor = { f1 = 'a', f2 = 'a' },
        anchorStatus = { a = 'identified' },
        anchorResponse = { a = resp('ra') },
    })
    local k = out.byPhoto
    assert_eq(k.a.status, 'identified', "anchor identified")
    assert_eq(k.a.inheritedFrom, nil, "anchor has no inheritedFrom")
    assert_eq(k.f1.status, 'identified', "follower f1 identified (inherits)")
    assert_eq(k.f1.response._name, 'ra', "f1 inherits the anchor's response")
    assert_eq(k.f1.inheritedFrom, 'a', "f1 inheritedFrom = a")
    assert_eq(k.f2.status, 'identified', "follower f2 identified")
    assert_eq(k.f2.response._name, 'ra', "f2 inherits the anchor's response")
    assert_eq(k.f2.inheritedFrom, 'a', "f2 inheritedFrom = a")
    assert_eq(count(k), 3, "exactly three results")
end

-- =====================================================================
-- Anchor FATAL -> anchor AND both followers deferred (no response on any of the three).
-- =====================================================================
do
    local out = results.build({
        selection = { 'a', 'f1', 'f2' },
        anchors = { 'a' },
        followerToAnchor = { f1 = 'a', f2 = 'a' },
        anchorStatus = { a = 'fatal' },
        anchorResponse = {},
    })
    local k = out.byPhoto
    assert_eq(k.a.status, 'deferred', "fatal anchor -> deferred")
    assert_eq(k.a.response, nil, "no response on a deferred anchor")
    assert_eq(k.f1.status, 'deferred', "follower deferred when anchor fatal")
    assert_eq(k.f1.response, nil, "no inherited response on a deferred cluster")
    assert_eq(k.f1.inheritedFrom, 'a', "follower still records its anchor")
    assert_eq(k.f2.status, 'deferred', "follower f2 deferred")
end

-- =====================================================================
-- Anchor DEFERRED (breaker open at dispatch OR pre-call gate) -> anchor + followers all deferred.
-- =====================================================================
do
    local out = results.build({
        selection = { 'a', 'f1' },
        anchors = { 'a' },
        followerToAnchor = { f1 = 'a' },
        anchorStatus = { a = 'deferred' },
        anchorResponse = {},
    })
    local k = out.byPhoto
    assert_eq(k.a.status, 'deferred', "deferred anchor stays deferred")
    assert_eq(k.f1.status, 'deferred', "follower inherits deferred")
    assert_eq(k.f1.response, nil, "no response (breaker-induced defer, never inherit)")
end

-- =====================================================================
-- Anchor CANCELLED -> anchor + followers all cancelled.
-- =====================================================================
do
    local out = results.build({
        selection = { 'a', 'f1', 'f2' },
        anchors = { 'a' },
        followerToAnchor = { f1 = 'a', f2 = 'a' },
        anchorStatus = { a = 'cancelled' },
        anchorResponse = {},
    })
    local k = out.byPhoto
    assert_eq(k.a.status, 'cancelled', "cancelled anchor")
    assert_eq(k.f1.status, 'cancelled', "follower inherits cancelled")
    assert_eq(k.f2.status, 'cancelled', "follower f2 cancelled")
    assert_eq(k.f1.inheritedFrom, 'a', "follower records its anchor even when cancelled")
end

-- =====================================================================
-- A follower whose anchor key is MISSING from anchorStatus -> deferred (safe).
-- =====================================================================
do
    local out = results.build({
        selection = { 'a', 'f1' },
        anchors = { 'a' },
        followerToAnchor = { f1 = 'ghost' },   -- 'ghost' is not in anchorStatus
        anchorStatus = { a = 'identified' },
        anchorResponse = { a = resp('ra') },
    })
    local k = out.byPhoto
    assert_eq(k.f1.status, 'deferred', "follower of a missing anchor -> deferred (safe)")
    assert_eq(k.f1.response, nil, "no response for a missing-anchor follower")
end

-- =====================================================================
-- INVARIANT: every selection photo appears EXACTLY ONCE; mixed clusters.
-- =====================================================================
do
    local out = results.build({
        selection = { 'a', 'fa', 'b', 'fb', 'c' },
        anchors = { 'a', 'b', 'c' },
        followerToAnchor = { fa = 'a', fb = 'b' },
        anchorStatus = { a = 'identified', b = 'fatal', c = 'cancelled' },
        anchorResponse = { a = resp('ra') },
    })
    local k = out.byPhoto
    assert_eq(count(k), 5, "every selection photo present exactly once")
    assert_eq(k.a.status, 'identified', "a identified")
    assert_eq(k.fa.status, 'identified', "fa inherits identified")
    assert_eq(k.fa.response._name, 'ra', "fa inherits ra")
    assert_eq(k.b.status, 'deferred', "b fatal -> deferred")
    assert_eq(k.fb.status, 'deferred', "fb inherits deferred (anchor fatal)")
    assert_eq(k.c.status, 'cancelled', "c cancelled")
    -- ordered preserves selection order.
    assert_eq(out.ordered[1].photo, 'a', "ordered respects selection order")
    assert_eq(out.ordered[2].photo, 'fa', "ordered[2]=fa")
    assert_eq(out.ordered[5].photo, 'c', "ordered[5]=c")
end

-- =====================================================================
-- An anchor missing from anchorStatus entirely -> deferred (safe).
-- =====================================================================
do
    local out = results.build({
        selection = { 'a' },
        anchors = { 'a' },
        followerToAnchor = {},
        anchorStatus = {},        -- a is absent
        anchorResponse = {},
    })
    assert_eq(out.byPhoto.a.status, 'deferred', "anchor absent from status -> deferred (safe)")
end

-- =====================================================================
-- Only status=='identified' carries a response (even if a stray response is present for a
-- deferred anchor, it must NOT leak).
-- =====================================================================
do
    local out = results.build({
        selection = { 'a' },
        anchors = { 'a' },
        followerToAnchor = {},
        anchorStatus = { a = 'deferred' },
        anchorResponse = { a = resp('stray') },   -- present but the anchor is deferred
    })
    assert_eq(out.byPhoto.a.status, 'deferred', "deferred anchor")
    assert_eq(out.byPhoto.a.response, nil, "a stray response on a deferred anchor does NOT leak")
end

-- =====================================================================
-- S2: an 'identified' anchor with a MISSING / invalid response must NOT yield identified+nil.
-- It (and its followers) DEGRADE to 'deferred' (no response, no keywords).
-- =====================================================================
do
    local out = results.build({
        selection = { 'a', 'f' },
        anchors = { 'a' },
        followerToAnchor = { f = 'a' },
        anchorStatus = { a = 'identified' },
        anchorResponse = {},   -- MISSING response for the identified anchor.
    })
    assert_eq(out.byPhoto.a.status, 'deferred', "identified anchor w/ missing response -> deferred")
    assert_eq(out.byPhoto.a.response, nil, "degraded anchor carries NO response")
    assert_eq(out.byPhoto.f.status, 'deferred', "follower of degraded anchor -> deferred")
    assert_eq(out.byPhoto.f.response, nil, "degraded follower carries NO response")
    assert_eq(out.byPhoto.f.inheritedFrom, 'a', "follower still records its anchor")
end

-- a non-table (invalid) response also degrades.
do
    local out = results.build({
        selection = { 'a' },
        anchors = { 'a' },
        followerToAnchor = {},
        anchorStatus = { a = 'identified' },
        anchorResponse = { a = "not-a-table" },   -- INVALID response type.
    })
    assert_eq(out.byPhoto.a.status, 'deferred', "identified anchor w/ non-table response -> deferred")
    assert_eq(out.byPhoto.a.response, nil, "no response leaked from a degraded anchor")
end
