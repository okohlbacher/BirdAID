-- SPDX-License-Identifier: MIT
-- BirdAID.lrdevplugin/src/keyword.lua (Phase 4 — ID-01 + KW-01 + KW-02)
--
-- PURE module: it pulls in NO Lightroom SDK namespace at load time and requires nothing
-- (it operates on plain tables passed in), so it is require-able under stock lua / lua5.1
-- / luajit for offline unit testing (the CODEX-mandated separation invariant). It is the
-- offline-provable heart of Phase 4: turn a single VALIDATED detection plus the typed
-- confidence threshold into an honest, deterministic keyword string (or a no-keyword skip).
--
-- Single responsibility: the keyword CORE.
--   * decide(detection, prefs) -> decision   (ID-01): pick confident species / uncertain
--     species / genus / family / skip from identified_rank + confidence + alternatives.
--     Returns decision.confidence = the SELECTED source's confidence (adopted alt's when
--     degraded, primary's otherwise, nil if none).
--   * render(decision) -> string|nil          (KW-01/KW-02): emit the LOCKED keyword format.
--   * dedupePhoto(names) -> array             collapse identical rendered strings (per photo).
--
-- LOCKED render format (do NOT re-derive):
--   * species confident: "Common (Scientific)"   ; uncertain: "Common (Scientific)?"
--   * species, missing common_name: SCIENTIFIC ONLY -> "Scientific" (+ optional "?"),
--     NOT "(Scientific)". missing scientific_name: "Common" (+ optional "?").
--   * genus:  "<rank_name> sp.?"        (trailing ? ALWAYS)
--   * family: "<rank_name> (family)?"   (trailing ? ALWAYS)
--   * MISSING = nil / "" / whitespace-only / the literal string "nil" (nonEmptyString).
--     A blank base => render returns nil (NEVER " ()", " ()?", " sp.?", " (family)?" blank).
--   * action ~= 'write' => render returns nil.
--   * NO DOUBLE '?' (phase-4 code review NIT #4): when the rendered species stem already
--     ends with '?' and the decision is uncertain, the appended uncertainty marker REPLACES
--     that trailing '?' rather than doubling it ("Cardinal? (Sci)?", never "...(Sci)??").
--
-- Although the contract guarantees non-empty names for the primary + each alternative,
-- render is still DEFENSIVE so a future/looser caller cannot produce a blank or " ()"
-- keyword. confidence is OPTIONAL on input (a self-reported hint); nil is treated as
-- below threshold (uncertain) -- a VALIDATED path after the Phase-4 contract refinement.
--
-- Strictly Lua 5.1 common subset: no \u{}, no //, no goto, no <close>; unpack is global;
-- UTF-8 as literal bytes. This module imports no SDK and is kept clean of the SDK-import
-- token so the negative-purity grep prints nothing (NIT 21).

local M = {}

-- nonEmptyString(s) -> the TRIMMED string when s is a string that, after trimming
-- leading/trailing whitespace, is non-empty AND not the literal "nil"; else nil.
-- Treats "", whitespace-only, and "nil" as MISSING. (gsub parenthesized to drop the count.)
local function nonEmptyString(s)
    if type(s) ~= 'string' then return nil end
    local t = (s:gsub('^%s+', ''):gsub('%s+$', ''))
    if t == '' or t == 'nil' then return nil end
    return t
end

-- ---------------------------------------------------------------------------
-- decide(detection, prefs) -> decision table   (ID-01)
-- ---------------------------------------------------------------------------
function M.decide(detection, prefs)
    local d = detection or {}
    local thr = (type(prefs) == 'table' and prefs.confidenceThreshold) or 0.6

    -- confident(conf): a present, finite (NaN-rejecting) number >= threshold.
    local function confident(conf)
        return type(conf) == 'number' and conf == conf and conf >= thr
    end

    local rank = d.identified_rank
    local pc = d.confidence   -- primary confidence (may be nil)

    if rank == 'species' then
        if confident(pc) then
            return {
                action = 'write', rank = 'species',
                displayName = d.common_name, scientificName = d.scientific_name,
                uncertain = false, confidence = pc,
            }
        end

        -- Low / nil confidence: try to degrade to the most specific CONFIDENT higher
        -- rank in alternatives. Scan only if alternatives is a table; ignore any
        -- non-table / malformed entry, any below-threshold / nil-confidence entry, any
        -- non genus/family entry, and any entry without a non-empty rank_name.
        local best = nil           -- the chosen alternative table
        local bestRankScore = nil  -- genus=2 (more specific) > family=1
        local bestConf = nil
        if type(d.alternatives) == 'table' then
            for _, alt in ipairs(d.alternatives) do
                if type(alt) == 'table'
                    and (alt.identified_rank == 'genus' or alt.identified_rank == 'family')
                    and confident(alt.confidence)
                    and nonEmptyString(alt.rank_name) ~= nil then
                    local score = (alt.identified_rank == 'genus') and 2 or 1
                    -- Prefer more specific rank; tie-break on higher confidence.
                    if best == nil
                        or score > bestRankScore
                        or (score == bestRankScore and alt.confidence > bestConf) then
                        best = alt
                        bestRankScore = score
                        bestConf = alt.confidence
                    end
                end
            end
        end

        if best ~= nil then
            return {
                action = 'write', rank = best.identified_rank,
                displayName = best.common_name, scientificName = best.scientific_name,
                rankName = best.rank_name, uncertain = true, confidence = best.confidence,
            }
        end

        -- No qualifying alternative: keep the primary species, mark uncertain.
        return {
            action = 'write', rank = 'species',
            displayName = d.common_name, scientificName = d.scientific_name,
            uncertain = true, confidence = pc,
        }
    elseif rank == 'genus' or rank == 'family' then
        -- Primary already at genus/family: that rank, ALWAYS uncertain (species unknown).
        return {
            action = 'write', rank = rank,
            displayName = d.common_name, scientificName = d.scientific_name,
            rankName = d.rank_name, uncertain = true, confidence = pc,
        }
    end

    -- order / class / anything else: too coarse to keyword.
    return { action = 'skip', reason = 'too-coarse', rank = rank }
end

-- ---------------------------------------------------------------------------
-- render(decision) -> string | nil   (KW-01 / KW-02)
-- ---------------------------------------------------------------------------
-- withMark(s, uncertain) -> s (+ a SINGLE trailing '?' when uncertain). NIT #4 (phase-4
-- code review): if the rendered stem already ends with '?', strip that one trailing '?'
-- before re-appending so the output never doubles into '??' (e.g. "Cardinal? (Sci)?" not
-- "Cardinal? (Sci)??"). When not uncertain, the string is returned verbatim (existing
-- '?'s in the name are preserved, never stripped). Pure Lua 5.1 (gsub parenthesized).
local function withMark(s, uncertain)
    if not uncertain then return s end
    local stem = (s:gsub('%?$', ''))   -- drop at most one trailing '?'
    return stem .. '?'
end

function M.render(decision)
    local dec = decision or {}
    if dec.action ~= 'write' then return nil end

    local uncertain = dec.uncertain and true or false
    local rank = dec.rank

    if rank == 'species' then
        local dn = nonEmptyString(dec.displayName)
        local sn = nonEmptyString(dec.scientificName)
        if dn and sn then
            return withMark(dn .. ' (' .. sn .. ')', uncertain)
        elseif sn then
            return withMark(sn, uncertain)          -- scientific ONLY, NO parens
        elseif dn then
            return withMark(dn, uncertain)
        else
            return nil                  -- both missing => no blank keyword
        end
    elseif rank == 'genus' then
        local stem = nonEmptyString(dec.rankName)
            or nonEmptyString(dec.scientificName)
            or nonEmptyString(dec.displayName)
        if not stem then return nil end
        return stem .. ' sp.?'          -- trailing ? ALWAYS
    elseif rank == 'family' then
        local stem = nonEmptyString(dec.rankName)
            or nonEmptyString(dec.scientificName)
            or nonEmptyString(dec.displayName)
        if not stem then return nil end
        return stem .. ' (family)?'     -- trailing ? ALWAYS
    end

    return nil
end

-- ---------------------------------------------------------------------------
-- dedupePhoto(names) -> array of names with duplicates removed, FIRST-seen order
-- preserved. nil / non-table -> {}. Keyed by the exact rendered string.
-- ---------------------------------------------------------------------------
function M.dedupePhoto(names)
    local out = {}
    if type(names) ~= 'table' then return out end
    local seen = {}
    for _, name in ipairs(names) do
        if not seen[name] then
            seen[name] = true
            out[#out + 1] = name
        end
    end
    return out
end

return M
