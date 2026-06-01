-- test/keyring_spec.lua (Phase 11 — DKEY-02 selection/failover/per-key-cooldown/EXHAUSTED
-- + DKEY-03 no-leak)
--
-- Exercises BirdAID.lrdevplugin/src/net/keyring.lua: a PURE module (no Lr, no wall-clock
-- reads, no randomness) require-able under stock lua / luajit. Proves the per-slot key
-- selection / failover / cooldown / retire / EXHAUSTED state machine that holds per-slot
-- health, selects the FIRST healthy slot in user priority POSITION order (D-05 — NOT numeric
-- minimum), composes src/net/backoff for per-key cooldown (D-03/D-06), distinguishes
-- AUTH-fatal (401/403 -> retire, D-04) from REQUEST-fatal (400/404/422 -> per-photo error,
-- no retire), parks a backoff-exhausted slot in a distinct EXHAUSTED state so it never
-- hammers, and returns nil so the orchestrator opens the run breaker (D-07) when no key is
-- usable. The state()/summary leaks NO token value (SC3 / DKEY-03).
--
-- Loaded by test/run.lua via dofile; uses the runner globals assert_eq / assert_true.
-- nowTick is ALWAYS an injected integer (never read from a wall clock). Strictly Lua 5.1 subset
-- (no \u{}, no //, no goto, no <close>; unpack is global).

local keyring = require('src.net.keyring')
local backoff = require('src.net.backoff')

assert_true(type(keyring) == 'table', "require 'src.net.keyring' resolves")
assert_true(type(keyring.new) == 'function', "keyring exposes new")

-- =====================================================================
-- new(opts) returns the {select, record, state} object.
-- =====================================================================
do
    local k = keyring.new({ priorityOrder = { 1, 2, 3 } })
    assert_true(type(k) == 'table', "new returns a table")
    assert_true(type(k.select) == 'function', "object exposes select")
    assert_true(type(k.record) == 'function', "object exposes record")
    assert_true(type(k.state) == 'function', "object exposes state")
end

-- =====================================================================
-- D-05 STRICT PRIORITY BY POSITION (NOT numeric minimum). With
-- priorityOrder = {2,1,3} all healthy, select() returns 2 (the first
-- entry in priority ORDER), proving position-not-min.
-- =====================================================================
do
    local k = keyring.new({ priorityOrder = { 2, 1, 3 } })
    assert_eq(k.select(100), 2, "select returns the FIRST healthy slot in priority position (2, not numeric-min 1)")
end

-- =====================================================================
-- D-05 PREEMPTION: a cooled higher-priority slot rejoins once its
-- coolUntil <= nowTick.
-- =====================================================================
do
    local k = keyring.new({ priorityOrder = { 1, 2 } })
    -- cool slot 1 at tick 100, attempt 1 (within-cap -> retry, coolUntil = 100 + delay).
    k.record(1, 'cooldown', 100, 1, nil)
    assert_eq(k.select(100), 2, "while slot 1 cools, select fails over to slot 2 (no sleep, D-06)")
    -- backoff.next(1, 429, nil) -> delay BASE*2^0 = 1, so coolUntil = 101.
    assert_eq(k.select(101), 1, "slot 1 PREEMPTS back into use once coolUntil <= nowTick (D-05)")
end

-- =====================================================================
-- D-06 429 IMMEDIATE FAILOVER: cooling the current slot makes select()
-- return the next healthy ordinal right away (no sleep in the keyring).
-- =====================================================================
do
    local k = keyring.new({ priorityOrder = { 1, 2 } })
    assert_eq(k.select(50), 1, "slot 1 selected first while healthy")
    k.record(1, 'cooldown', 50, 1, nil)
    assert_eq(k.select(50), 2, "429-cooled slot 1 fails over immediately to slot 2 at the same tick (D-06)")
end

-- =====================================================================
-- EXHAUSTED guard (Pitfall / T-11-03): when backoff.next returns
-- retry==false (attempt at MAX_ATTEMPTS, or over-cap retryAfter) the
-- slot is parked EXHAUSTED — NOT cooled to nowTick — so it is NOT
-- instantly healthy (no hammer loop).
-- =====================================================================
do
    -- (a) MAX_ATTEMPTS exhaustion: each cooldown bumps the slot's OWN attempt; once the slot's
    -- attempt reaches MAX_ATTEMPTS, backoff.next(MAX,429,nil).retry==false -> EXHAUSTED.
    -- With another healthy slot, the exhausted slot is skipped.
    local k = keyring.new({ priorityOrder = { 1, 2 } })
    for _ = 1, backoff.MAX_ATTEMPTS do
        k.record(1, 'cooldown', 100, nil, nil)
    end
    assert_eq(k.select(100), 2, "exhausted slot 1 is skipped at nowTick; healthy slot 2 selected")
    assert_eq(k.state()[1].exhausted, true, "slot 1 state is EXHAUSTED (not cooled to nowTick)")

    -- (b) over-cap retryAfter exhaustion (> backoff.CAP) also parks EXHAUSTED.
    local k2 = keyring.new({ priorityOrder = { 1 } })
    k2.record(1, 'cooldown', 100, 1, backoff.CAP + 5) -- over-cap -> retry==false
    assert_eq(k2.state()[1].exhausted, true, "over-cap retryAfter parks the only slot EXHAUSTED")
    assert_eq(k2.select(100), nil, "an exhausted last slot makes select() return nil at nowTick (no hammer)")
    -- and NOT instantly healthy at any later tick either (exhausted is a per-run park).
    assert_eq(k2.select(100000), nil, "exhausted slot never re-appears healthy at a later tick")
end

-- =====================================================================
-- D-04 AUTH-fatal RETIRE: record('retire') (mapped from 401/403) retires
-- the slot for the run; another healthy slot keeps working.
-- =====================================================================
do
    local k = keyring.new({ priorityOrder = { 1, 2 } })
    k.record(1, 'retire', 100, nil, nil)
    assert_eq(k.select(100), 2, "retired slot 1 is skipped; slot 2 still selectable (D-04)")
    assert_eq(k.state()[1].retired, true, "slot 1 is permanently retired for the run")
    -- retire is permanent: not healthy even far in the future.
    assert_eq(k.select(999999), 2, "retired slot never rejoins; slot 2 remains the selection")
end

-- =====================================================================
-- D-04 REQUEST-fatal NO-OP: record('request-error') (mapped from
-- 400/404/422) leaves the slot HEALTHY — no retire, no cooldown, no
-- attempt bump. It is a per-photo provider error, not a key-health issue.
-- =====================================================================
do
    local k = keyring.new({ priorityOrder = { 1, 2 } })
    k.record(1, 'request-error', 100, nil, nil)
    assert_eq(k.select(100), 1, "request-error leaves slot 1 HEALTHY and still selectable (D-04)")
    assert_eq(k.state()[1].retired, nil, "request-error did NOT retire the slot")
    assert_eq(k.state()[1].exhausted, nil, "request-error did NOT exhaust the slot")
    assert_eq(k.state()[1].coolUntil, nil, "request-error did NOT cool the slot")
    assert_true((k.state()[1].attempt or 0) == 0, "request-error did NOT bump the per-slot attempt")
end

-- =====================================================================
-- D-07 TRIGGER: no healthy slot (all cooling/exhausted/retired) ->
-- select() returns nil (caller opens the run breaker).
-- =====================================================================
do
    local k = keyring.new({ priorityOrder = { 1, 2 } })
    k.record(1, 'retire', 200, nil, nil)              -- retired
    k.record(2, 'cooldown', 200, 1, nil)              -- cooling (coolUntil = 201)
    assert_eq(k.select(200), nil, "all slots down (retired + cooling) -> select() returns nil (D-07)")
end

-- =====================================================================
-- Pitfall 6 PER-SLOT ISOLATION: cooling slot 1 does NOT change slot 2's
-- coolUntil or attempt (each slot carries its OWN backoff state).
-- =====================================================================
do
    local k = keyring.new({ priorityOrder = { 1, 2 } })
    k.record(1, 'cooldown', 100, 1, nil)
    assert_eq(k.state()[2] and k.state()[2].coolUntil or nil, nil, "cooling slot 1 leaves slot 2 coolUntil unchanged (nil)")
    assert_true((k.state()[2] and k.state()[2].attempt or 0) == 0, "cooling slot 1 leaves slot 2 attempt unchanged (0)")
    assert_eq(k.select(100), 2, "slot 2 stays fully healthy while slot 1 cools (Pitfall 6)")
end

-- =====================================================================
-- 'ok' RECOVERY: a recovered key rejoins (coolUntil/exhausted cleared,
-- attempt reset).
-- =====================================================================
do
    local k = keyring.new({ priorityOrder = { 1 } })
    for _ = 1, backoff.MAX_ATTEMPTS do k.record(1, 'cooldown', 100, nil, nil) end -- exhausted
    assert_eq(k.select(100), nil, "exhausted single slot -> nil")
    k.record(1, 'ok', 100, nil, nil)
    assert_eq(k.select(100), 1, "after 'ok' the slot rejoins as healthy")
    assert_true((k.state()[1].attempt or 0) == 0, "'ok' resets the per-slot attempt")
end

-- =====================================================================
-- SC3 / DKEY-03 NO-LEAK (recursive): state() (and a representative
-- summary line built from it) contains NO value matching token patterns
-- 'sk-', 'sk-ant-', 'AIza', 'Bearer ' AND every slot-reference key is an
-- integer ordinal. (Mirrors src/redact.lua token patterns.)
-- =====================================================================
do
    -- Drive a slot through every outcome so state() carries real records.
    local k = keyring.new({ priorityOrder = { 2, 1, 3 } })
    k.record(1, 'cooldown', 10, nil, nil)
    k.record(2, 'retire', 10, nil, nil)
    for _ = 1, backoff.MAX_ATTEMPTS do k.record(3, 'cooldown', 10, nil, nil) end -- exhausted

    -- Recursive walker: for a table, recurse on values; for a string, run visit(s). At the TOP
    -- (slot-reference) level the snapshot keys MUST be integer storage ordinals; deeper levels
    -- are per-slot field tables whose keys are field names — so the ordinal assertion is applied
    -- only at depth 0 (atTop).
    local function walk(v, visit, atTop)
        if type(v) == 'table' then
            for kk, vv in pairs(v) do
                if atTop then
                    assert_true(type(kk) == 'number' and kk == math.floor(kk),
                        "every state() key is an integer storage ordinal (got " .. tostring(kk) .. ")")
                end
                walk(vv, visit, false)
            end
        elseif type(v) == 'string' then
            visit(v)
        end
    end

    local function assertTokenFree(s)
        assert_eq(s:find('sk-', 1, true), nil, "no 'sk-' token value in state/summary string")
        assert_eq(s:find('AIza', 1, true), nil, "no 'AIza' token value in state/summary string")
        assert_eq(s:find('Bearer ', 1, true), nil, "no 'Bearer ' token value in state/summary string")
    end

    walk(k.state(), assertTokenFree, true)

    -- Representative summary line built from state() — reference slots by ORDINAL only.
    local parts = {}
    for ordinal, slot in pairs(k.state()) do
        local label = 'healthy'
        if slot.retired then label = 'retired'
        elseif slot.exhausted then label = 'exhausted'
        elseif slot.coolUntil ~= nil then label = 'cooling' end
        parts[#parts + 1] = 'slot ' .. tostring(ordinal) .. '=' .. label
    end
    local summary = table.concat(parts, '; ')
    assertTokenFree(summary)
    assert_true(#summary > 0, "summary line built from state() is non-empty")
end
