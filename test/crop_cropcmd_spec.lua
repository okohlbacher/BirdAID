-- test/crop_cropcmd_spec.lua (Phase 6 — Crop-for-ID, PURE shell-safe command builder, CROP-02)
--
-- Exercises BirdAID.lrdevplugin/src/crop/cropcmd.lua: a PURE module (pulls in NO Lightroom
-- SDK namespace at load time), require-able under stock lua / luajit. This is the SECURITY
-- BOUNDARY of Phase 6 (file paths + the AI-returned bbox flow into a /bin/sh command), so
-- the assertions are deliberately exhaustive:
--   * shquote: POSIX single-quote escaping ('\'') for EVERY metacharacter (NOT %q) [CODEX #3].
--   * geometry: "WxH+X+Y" AND a (nil,'bad-geometry') reject for any non-finite-int rect [CODEX #3].
--   * build: the EXACT full command string incl. the -resize shrink-only backstop [CODEX #14];
--            injection payloads neutralized verbatim inside single quotes.
--   * decodeExit: ONLY raw==0 is success; nil/9/65280/256 are failures (no floor(raw/256)) [CODEX #4].
--
-- Loaded by test/run.lua via dofile; uses the runner globals assert_eq / assert_true.
-- Strictly Lua 5.1 common subset (no //, no goto, no <close>; unpack global).

local C = require('src.crop.cropcmd')

-- =====================================================================
-- shquote: wrap in single quotes; replace every embedded ' with the close-escape-reopen
-- sequence '\''. Assert the EXACT output for a battery of injection payloads.
-- =====================================================================
assert_eq(C.shquote("a b"), "'a b'", "shquote: space -> single-quoted")
assert_eq(C.shquote("it's"), "'it'\\''s'", "shquote: apostrophe -> '\\'' escape")
assert_eq(C.shquote("$(rm -rf ~)"), "'$(rm -rf ~)'", "shquote: command-substitution neutralized")
assert_eq(C.shquote("`id`"), "'`id`'", "shquote: backtick neutralized")
assert_eq(C.shquote(";reboot"), "';reboot'", "shquote: semicolon neutralized")
assert_eq(C.shquote("a&b"), "'a&b'", "shquote: ampersand neutralized")
-- embedded newline: a literal newline inside single quotes is fine for /bin/sh.
assert_eq(C.shquote("a\nb"), "'a\nb'", "shquote: newline neutralized (literal inside single quotes)")
-- a unicode (CJK, literal bytes) path segment quotes cleanly with no crash.
assert_eq(C.shquote("\230\151\165"), "'\230\151\165'", "shquote: unicode bytes quoted verbatim")

-- shquote coerces non-strings (defensive) and never raises.
assert_eq(C.shquote(42), "'42'", "shquote: number coerced via tostring")
assert_true(pcall(C.shquote, nil), "shquote never raises on nil")

-- The CORE injection invariant: for an apostrophe-bearing string, the ONLY way to embed an
-- apostrophe is the exact '\'' sequence; there is no UNescaped lone single-quote that would
-- reopen interpolation. We verify the round-trip structure precisely.
do
    local q = C.shquote("o'brien $(reboot)")
    assert_eq(q, "'o'\\''brien $(reboot)'", "shquote: apostrophe + $() fully neutralized in one token")
    -- The result begins and ends with a single quote (a complete quoted token).
    assert_eq(q:sub(1, 1), "'", "shquote result opens with a single quote")
    assert_eq(q:sub(-1), "'", "shquote result closes with a single quote")
end

-- =====================================================================
-- geometry: "WxH+X+Y" for a valid integer rect.
-- =====================================================================
assert_eq(C.geometry({ x = 3, y = 4, w = 10, h = 20 }), "10x20+3+4", "geometry: WxH+X+Y order")
assert_eq(C.geometry({ x = 0, y = 0, w = 1, h = 1 }), "1x1+0+0", "geometry: minimal valid rect")

-- =====================================================================
-- geometry VALIDATION [CODEX #3]: reject (nil,'bad-geometry') for any rect whose fields are
-- not FINITE INTEGERS satisfying x>=0,y>=0,w>0,h>0.
-- =====================================================================
do
    local g, e = C.geometry(nil)
    assert_eq(g, nil, "geometry: nil rect -> nil")
    assert_eq(e, "bad-geometry", "geometry: nil rect -> 'bad-geometry'")

    g, e = C.geometry({ x = nil, y = 0, w = 10, h = 10 })
    assert_eq(g, nil, "geometry: x=nil -> nil")
    assert_eq(e, "bad-geometry", "geometry: x=nil -> 'bad-geometry'")

    g, e = C.geometry({ x = 0, y = 0, w = 0, h = 10 })
    assert_eq(g, nil, "geometry: w==0 -> nil")
    assert_eq(e, "bad-geometry", "geometry: w==0 -> 'bad-geometry'")

    g, e = C.geometry({ x = 0, y = 0, w = 10, h = 0 })
    assert_eq(g, nil, "geometry: h==0 -> nil")

    g, e = C.geometry({ x = -1, y = 0, w = 10, h = 10 })
    assert_eq(g, nil, "geometry: x<0 -> nil")
    assert_eq(e, "bad-geometry", "geometry: x<0 -> 'bad-geometry'")

    g, e = C.geometry({ x = 0, y = -1, w = 10, h = 10 })
    assert_eq(g, nil, "geometry: y<0 -> nil")

    g, e = C.geometry({ x = 0, y = 0, w = 10.5, h = 10 })
    assert_eq(g, nil, "geometry: non-integer w -> nil")
    assert_eq(e, "bad-geometry", "geometry: non-integer w -> 'bad-geometry'")

    g, e = C.geometry({ x = 0, y = 0, w = 1 / 0, h = 10 })
    assert_eq(g, nil, "geometry: +inf w -> nil (finite guard)")
    assert_eq(e, "bad-geometry", "geometry: +inf w -> 'bad-geometry'")

    -- never raises over the battery
    local bads = {
        nil, "x", {}, { x = 0 }, { x = 0, y = 0, w = -5, h = 5 },
        { x = "0", y = 0, w = 10, h = 10 }, { x = 0, y = 0, w = 0 / 0, h = 10 },
    }
    for i = 1, #bads do
        assert_true(pcall(C.geometry, bads[i]), "geometry never raises (battery " .. i .. ")")
    end
end

-- =====================================================================
-- build: the EXACT full command string, with each path single-quoted and the -resize
-- shrink-only backstop present [CODEX #14]. Assert byte-for-byte equality (no false-green
-- substring gate).
-- =====================================================================
do
    local tool = "/opt/homebrew/bin/magick"
    local inp  = "/tmp/BirdAID/run-abc/export-00001.jpg"
    local rect = { x = 12, y = 34, w = 800, h = 600 }
    local outp = "/tmp/BirdAID/run-abc/crop-00001.jpg"
    local errp = "/tmp/BirdAID/run-abc/err-00001"
    local cmd  = C.build(tool, inp, rect, outp, errp, 2048)

    local expected = "'/opt/homebrew/bin/magick' '/tmp/BirdAID/run-abc/export-00001.jpg'"
        .. " -crop 800x600+12+34 +repage -resize '2048x2048>'"
        .. " '/tmp/BirdAID/run-abc/crop-00001.jpg' 2>'/tmp/BirdAID/run-abc/err-00001'"
    assert_eq(cmd, expected, "build: EXACT command string (single-quoted paths + -crop + +repage + -resize backstop)")

    -- the -resize shrink-only modifier (the trailing '>') MUST be present.
    assert_true(cmd:find("-resize '2048x2048>'", 1, true) ~= nil,
        "build: -resize '<edge>x<edge>>' shrink-only backstop present")
    -- +repage discards the virtual canvas offset.
    assert_true(cmd:find("+repage", 1, true) ~= nil, "build: +repage present")
end

-- =====================================================================
-- build: INJECTION path fully neutralized. A path containing $() appears verbatim ONLY
-- inside a single-quoted region; the command never lets it reach the shell unquoted.
-- =====================================================================
do
    local evil = "/x/$(reboot)/a.jpg"
    local cmd = C.build("/opt/homebrew/bin/magick", evil,
        { x = 0, y = 0, w = 10, h = 10 }, "/tmp/o.jpg", "/tmp/e", 2048)
    -- it appears verbatim, wrapped in single quotes.
    assert_true(cmd:find("'/x/$(reboot)/a.jpg'", 1, true) ~= nil,
        "build: $() injection path appears verbatim INSIDE single quotes")
    -- and there is NO unquoted occurrence: the only occurrence is the single-quoted one.
    local _, count = cmd:gsub("%$%(reboot%)", "")
    assert_eq(count, 1, "build: the $() payload appears exactly once (the quoted operand)")

    -- apostrophe path is escaped, not left to reopen the shell.
    local cmd2 = C.build("/opt/homebrew/bin/magick", "/Users/o'brien/bird.jpg",
        { x = 0, y = 0, w = 10, h = 10 }, "/tmp/o.jpg", "/tmp/e", 2048)
    assert_true(cmd2:find("'/Users/o'\\''brien/bird.jpg'", 1, true) ~= nil,
        "build: apostrophe path escaped via '\\'' inside its quoted operand")
end

-- =====================================================================
-- NIT: argv[0] is the absolute single-quoted toolPath, so a leading-dash basename under an
-- absolute directory is a QUOTED OPERAND, not option injection. ImageMagick receives it as a
-- filename, not a flag. We assert the leading-dash path stays a quoted operand.
-- =====================================================================
do
    local dashPath = "/tmp/BirdAID/run-x/-rf.jpg"  -- leading-dash BASENAME under an absolute dir
    local cmd = C.build("/opt/homebrew/bin/magick", dashPath,
        { x = 0, y = 0, w = 10, h = 10 }, "/tmp/o.jpg", "/tmp/e", 2048)
    assert_true(cmd:find("'/tmp/BirdAID/run-x/-rf.jpg'", 1, true) ~= nil,
        "build: leading-dash basename stays a QUOTED OPERAND (not option injection)")
end

-- =====================================================================
-- build: propagates the geometry gate — an invalid rect yields (nil,'bad-geometry').
-- =====================================================================
do
    local cmd, e = C.build("/opt/homebrew/bin/magick", "/in.jpg",
        { x = 0, y = 0, w = 0, h = 10 }, "/out.jpg", "/err", 2048)
    assert_eq(cmd, nil, "build: invalid rect -> nil (propagates geometry gate)")
    assert_eq(e, "bad-geometry", "build: invalid rect -> 'bad-geometry'")

    cmd, e = C.build("/opt/homebrew/bin/magick", "/in.jpg", nil, "/out.jpg", "/err", 2048)
    assert_eq(cmd, nil, "build: nil rect -> nil")
    assert_eq(e, "bad-geometry", "build: nil rect -> 'bad-geometry'")

    assert_true(pcall(C.build, "/m", "/in", { x = 0, y = 0, w = -1, h = 1 }, "/o", "/e", 2048),
        "build never raises on an invalid rect")
end

-- =====================================================================
-- build: maxEdge VALIDATION [CODEX #6]. maxEdge must be a FINITE POSITIVE INTEGER; nil / NaN /
-- <=0 / non-integer is rejected (nil,'bad-max-edge') rather than emitting `-resize 'nilxnil>'`.
-- =====================================================================
do
    local tool, inp, outp, errp = "/m", "/in.jpg", "/out.jpg", "/err"
    local rect = { x = 0, y = 0, w = 10, h = 10 }

    local cmd, e = C.build(tool, inp, rect, outp, errp, nil)
    assert_eq(cmd, nil, "build: nil maxEdge -> nil")
    assert_eq(e, "bad-max-edge", "build: nil maxEdge -> 'bad-max-edge' (no -resize 'nilxnil>')")

    cmd, e = C.build(tool, inp, rect, outp, errp, 0)
    assert_eq(cmd, nil, "build: maxEdge==0 -> nil")
    assert_eq(e, "bad-max-edge", "build: maxEdge==0 -> 'bad-max-edge'")

    cmd, e = C.build(tool, inp, rect, outp, errp, -5)
    assert_eq(cmd, nil, "build: negative maxEdge -> nil")
    assert_eq(e, "bad-max-edge", "build: negative maxEdge -> 'bad-max-edge'")

    cmd, e = C.build(tool, inp, rect, outp, errp, 2048.5)
    assert_eq(cmd, nil, "build: non-integer maxEdge -> nil")
    assert_eq(e, "bad-max-edge", "build: non-integer maxEdge -> 'bad-max-edge'")

    cmd, e = C.build(tool, inp, rect, outp, errp, 0 / 0)
    assert_eq(cmd, nil, "build: NaN maxEdge -> nil")
    assert_eq(e, "bad-max-edge", "build: NaN maxEdge -> 'bad-max-edge'")

    cmd, e = C.build(tool, inp, rect, outp, errp, 1 / 0)
    assert_eq(cmd, nil, "build: +inf maxEdge -> nil")
    assert_eq(e, "bad-max-edge", "build: +inf maxEdge -> 'bad-max-edge'")

    -- a finite positive integer still builds and emits the resize backstop.
    cmd, e = C.build(tool, inp, rect, outp, errp, 1024)
    assert_true(cmd ~= nil and cmd:find("-resize '1024x1024>'", 1, true) ~= nil,
        "build: valid integer maxEdge emits the -resize backstop")

    -- never raises over the bad-maxEdge battery (n explicit so a leading nil hole is counted).
    local maxes = { n = 8, [1] = nil, [2] = 0, [3] = -1, [4] = 2048.5,
        [5] = 0 / 0, [6] = 1 / 0, [7] = "x", [8] = {} }
    for i = 1, maxes.n do
        assert_true(pcall(C.build, tool, inp, rect, outp, errp, maxes[i]),
            "build never raises on a bad maxEdge (battery " .. i .. ")")
    end
end

-- =====================================================================
-- decodeExit [CODEX #4]: success is RAW STATUS EXACTLY 0. nil/non-zero/signal-killed fail.
-- NO floor(raw/256) masking (which would turn 9 into 0/success and nil into 0/success).
-- =====================================================================
do
    local ok, code = C.decodeExit(0)
    assert_eq(ok, true, "decodeExit(0) -> ok true")
    assert_eq(code, 0, "decodeExit(0) -> exit 0")

    ok, code = C.decodeExit(9)
    assert_eq(ok, false, "decodeExit(9) -> ok false (signal kill, NOT masked to 0)")
    assert_eq(code, 9, "decodeExit(9) -> exit 9")

    ok, code = C.decodeExit(65280)
    assert_eq(ok, false, "decodeExit(65280) -> ok false")
    assert_eq(code, 65280, "decodeExit(65280) -> exit 65280")

    ok, code = C.decodeExit(256)
    assert_eq(ok, false, "decodeExit(256) -> ok false (NOT floor(256/256)=1->masked)")
    assert_eq(code, 256, "decodeExit(256) -> exit 256")

    ok, code = C.decodeExit(nil)
    assert_eq(ok, false, "decodeExit(nil) -> ok false (nil is NOT success)")
    assert_eq(code, -1, "decodeExit(nil) -> exit -1 (sentinel, no raise)")

    -- never raises on odd input.
    assert_true(pcall(C.decodeExit, "x"), "decodeExit never raises on a string")
    ok, code = C.decodeExit("x")
    assert_eq(ok, false, "decodeExit('x') -> ok false (non-number is not success)")
    assert_eq(code, -1, "decodeExit('x') -> exit -1")
end
