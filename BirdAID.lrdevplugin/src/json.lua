-- SPDX-License-Identifier: MIT
-- BirdAID.lrdevplugin/src/json.lua (FND-04)
--
-- PURE-LUA thin wrapper over the vendored dkjson. Imports NO Lr* module at load time,
-- so it is require-able under stock lua / lua5.1 / luajit for offline unit testing
-- (the CODEX-mandated separation invariant).
--
-- decode() normalizes dkjson's multi-return into a (ok, value, err) tuple. CRITICAL:
-- success is keyed on the PRESENCE of a dkjson error, NOT on value==nil. dkjson returns
-- nil + a non-nil error string on a real parse failure, but returns nil (or the null
-- sentinel) with a NIL error for a valid JSON `null` -- so valid `null` is a success,
-- not a failure. decode never raises; malformed input yields (false, nil, err). This
-- satisfies the V5 input-validation control.
--
-- Strictly Lua 5.1 common subset.

local dkjson = require 'src.lib.dkjson'

local M = {}

-- encode(obj[, opts]) -> JSON string. opts may carry { indent = true, keyorder = {...} }
-- and is passed straight through as dkjson's `state` argument.
function M.encode(obj, opts)
    return dkjson.encode(obj, opts)
end

-- decode(str) -> (ok, value, err)
-- Calls dkjson.decode(str, 1, dkjson.null) so a JSON `null` materializes as the
-- distinguishable null sentinel rather than a bare nil. Classifies success on the
-- ABSENCE of a dkjson error: (false, nil, err) ONLY when err ~= nil; otherwise
-- (true, value, nil) where value may legitimately be nil or the null sentinel.
function M.decode(str)
    local value, _, err = dkjson.decode(str, 1, dkjson.null)
    if err ~= nil then
        return false, nil, err
    end
    return true, value, nil
end

return M
