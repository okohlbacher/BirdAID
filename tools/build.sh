#!/usr/bin/env bash
#
# tools/build.sh (Phase 8 — HARD-03 release packaging)
#
# Produces the shippable dist/BirdAID.lrplugin from the BirdAID.lrdevplugin dev tree:
#   copy → PRUNE dev-only directories THEMSELVES (.git/, .planning/, test/) → strip
#   dev-only leaves (Debug*.lua, .DS_Store) → swap in the debug-free release manifest →
#   GATES (RECURSIVE-Debug; .planning/.git/test absent as DIRS; the PURE build_manifest
#   exclusion-truth walk; the manifest-parity spec) → optional ditto zip.
#
# [CODEX #1/#4] The "what is dev-only" truth lives in the PURE tools/build_manifest.lua
# (08-01). build.sh CONSUMES that helper itself (not a hardcoded rm list): after building
# the dist it runs a Lua gate that walks the dist tree, maps each file to its plugin-relative
# path, and FAILS the build on ANY file classified isDevOnly==true. build.sh ALSO runs the
# manifest-parity spec (dev Info.lua ↔ Info.release.lua stable fields + the real menu item)
# and the dist-parity spec as build gates. So `bash tools/build.sh` ALONE — not just the
# test suite — catches packaging drift (a leaked dev file OR a drifted identifier/menu).
#
# [CODEX #2] The dev-only DIRECTORIES are pruned WHOLESALE: an empty .git/, .planning/, or
# test/ directory must NOT ship. The post-build gate asserts none of those dir NAMES exist
# anywhere in the package.
#
# Security: `set -euo pipefail`; ALL path variables quoted (paths may contain spaces);
# no eval, no Keychain read, no secret embedded in the package (ASVS V5/V12).
#
# Idempotent: re-running rebuilds dist/BirdAID.lrplugin from scratch.

set -euo pipefail

# Resolve repo root from this script's location (tools/ is one level down).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC="$ROOT/BirdAID.lrdevplugin"
DIST="$ROOT/dist"
OUT="$DIST/BirdAID.lrplugin"
RELEASE_MANIFEST="$ROOT/tools/Info.release.lua"
BUILD_MANIFEST="$ROOT/tools/build_manifest.lua"

# Pick a Lua interpreter for the build-time gates (the PURE exclusion-truth walk + parity).
LUA_BIN=""
for cand in lua luajit lua5.1; do
    if command -v "$cand" >/dev/null 2>&1; then LUA_BIN="$cand"; break; fi
done

if [ ! -d "$SRC" ]; then
    echo "build: FATAL — source tree not found: $SRC" >&2
    exit 1
fi
if [ ! -f "$RELEASE_MANIFEST" ]; then
    echo "build: FATAL — release manifest not found: $RELEASE_MANIFEST" >&2
    exit 1
fi
if [ ! -f "$BUILD_MANIFEST" ]; then
    echo "build: FATAL — exclusion-truth helper not found: $BUILD_MANIFEST" >&2
    exit 1
fi
if [ -z "$LUA_BIN" ]; then
    echo "build: FATAL — no Lua interpreter (lua/luajit/lua5.1) for the build gates" >&2
    exit 1
fi

# (1) Clean + recreate the output (idempotent).
rm -rf "$OUT"
mkdir -p "$DIST"

# (2) Copy the dev tree into the .lrplugin package.
cp -R "$SRC" "$OUT"

# (3) [CODEX #2] PRUNE the dev-only DIRECTORIES THEMSELVES (not just their contents): an
#     empty .git/, .planning/, or test/ dir must NOT ship. -depth + -exec rm -rf removes the
#     whole subtree including the directory node. (The dev source tree should not normally
#     contain these, but a stray BirdAID.lrdevplugin/test/ would otherwise be copied in.)
find "$OUT" -depth \( -name '.git' -o -name '.planning' -o -name 'test' \) -type d \
    -exec rm -rf {} +

# (4) Strip dev-only entry points: the Debug*.lua leaves.
rm -f "$OUT"/Debug*.lua

# (5) Hygiene: drop macOS Finder metadata anywhere in the tree.
find "$OUT" -name '.DS_Store' -delete

# (6) Swap in the debug-free release manifest as the dist Info.lua.
cp "$RELEASE_MANIFEST" "$OUT/Info.lua"

# (7) GATE — each check fails the build (set -e + the `!`/`grep -q` idiom) on violation.

# 6a. No Debug*.lua leaves remain.
if ls "$OUT"/Debug*.lua >/dev/null 2>&1; then
    echo "build: GATE FAILED — Debug*.lua files remain in $OUT" >&2
    exit 1
fi

# 6b. [CODEX #9] RECURSIVE Debug-clean: NO 'Debug' string ANYWHERE in the dist
#     (manifest, comments, or any shipped src file). Relies on 08-03 having cleaned the
#     shipped src tree, so this is the strong, whole-tree claim.
if grep -rn "Debug" "$OUT" >/dev/null 2>&1; then
    echo "build: GATE FAILED — 'Debug' string found in the dist (recursive):" >&2
    grep -rn "Debug" "$OUT" >&2 || true
    exit 1
fi

# 6c. The real menu item is present in the swapped manifest.
if ! grep -q "IdentifyBirds.lua" "$OUT/Info.lua"; then
    echo "build: GATE FAILED — real IdentifyBirds.lua menu item missing from Info.lua" >&2
    exit 1
fi

# 6d. LrToolkitIdentifier is byte-identical (scopes the user's Keychain token + prefs).
if ! grep -q "com.okohlbacher.birdaid" "$OUT/Info.lua"; then
    echo "build: GATE FAILED — LrToolkitIdentifier com.okohlbacher.birdaid missing" >&2
    exit 1
fi

# 6e. [CODEX #2] NO .git / .planning / test DIRECTORY (by NAME) anywhere — not even an
#     EMPTY one. We assert the directory NODE itself is absent, so a stripped-but-present
#     empty test/ would still fail the build.
LEAKED_DIRS="$(find "$OUT" \( -name '.git' -o -name '.planning' -o -name 'test' \) -print)"
if [ -n "$LEAKED_DIRS" ]; then
    echo "build: GATE FAILED — dev-only directory leaked into the dist:" >&2
    echo "$LEAKED_DIRS" >&2
    exit 1
fi

# 6f. [CODEX #1/#4] PURE EXCLUSION-TRUTH WALK. Consume tools/build_manifest.lua as the
#     authority: walk EVERY shipped file, map it to its plugin-relative path, and fail the
#     build on ANY file classified isDevOnly==true. This is the build catching packaging
#     drift ITSELF (independent of the test suite), so a future BirdAID.lrdevplugin/test/...
#     dev file cannot silently ship.
"$LUA_BIN" - "$BUILD_MANIFEST" "$OUT" <<'LUA_GATE'
local manifestPath, outDir = arg[1], arg[2]
local bm = dofile(manifestPath)
-- Enumerate every regular file in the dist; map "./src/x.lua" -> "BirdAID.lrdevplugin/src/x.lua".
local p = assert(io.popen('cd "' .. outDir .. '" && find . -type f 2>/dev/null'))
local offenders, checked = {}, 0
for line in p:lines() do
    if line ~= "" then
        local rel = line:gsub("^%./", "")
        local devRel = "BirdAID.lrdevplugin/" .. rel
        if bm.isDevOnly(devRel) then offenders[#offenders + 1] = rel end
        checked = checked + 1
    end
end
p:close()
if checked == 0 then
    io.stderr:write("build: GATE FAILED — dist contains ZERO files (broken build)\n")
    os.exit(1)
end
if #offenders > 0 then
    io.stderr:write("build: GATE FAILED — dev-only file(s) shipped per build_manifest.isDevOnly:\n")
    for _, f in ipairs(offenders) do io.stderr:write("  " .. f .. "\n") end
    os.exit(1)
end
io.write(("build: exclusion-truth walk OK (%d shipped files, 0 dev-only)\n"):format(checked))
LUA_GATE

# 6g. [CODEX #1/#4] MANIFEST-PARITY + DIST-PARITY as BUILD gates. The specs reference paths
#     RELATIVE to the repo root (e.g. "tools/Info.release.lua", "dist/BirdAID.lrplugin"), so
#     we run the interpreter WITH $ROOT as the working directory (subshell `cd`). A minimal
#     in-process harness provides the runner's global assert_eq/assert_true. dist_parity_spec
#     thus sees the FRESH dist we just built, and manifest_parity_spec catches identifier/menu
#     drift — so `bash tools/build.sh` FAILS if a dev file shipped OR the identifier/menu
#     drifted dev↔release, independently of the full test suite.
(
    cd "$ROOT"
    "$LUA_BIN" - <<'LUA_PARITY'
package.path = package.path
    .. ";./BirdAID.lrdevplugin/?.lua"
    .. ";./BirdAID.lrdevplugin/?/init.lua"
local fails = 0
function assert_eq(a, b, msg)
    if a ~= b then fails = fails + 1
        io.stderr:write(("  FAIL: %s (got %s, want %s)\n"):format(tostring(msg), tostring(a), tostring(b))) end
end
function assert_true(v, msg)
    if not v then fails = fails + 1
        io.stderr:write(("  FAIL: %s (got %s, want truthy)\n"):format(tostring(msg), tostring(v))) end
end
for _, spec in ipairs({ "test/manifest_parity_spec.lua", "test/dist_parity_spec.lua" }) do
    local okrun, err = pcall(dofile, spec)
    if not okrun then
        fails = fails + 1
        io.stderr:write(("  FAIL: spec errored: %s (%s)\n"):format(spec, tostring(err)))
    end
end
if fails > 0 then
    io.stderr:write("build: GATE FAILED — manifest/dist parity spec(s) failed\n")
    os.exit(1)
end
io.write("build: manifest + dist parity gates OK\n")
LUA_PARITY
)

# (8) OPTIONAL archive — ditto preserves the macOS package bit. Skip gracefully if absent.
if command -v ditto >/dev/null 2>&1; then
    ZIP="$DIST/BirdAID-$(date +%Y%m%d).zip"
    ( cd "$DIST" && ditto -c -k --keepParent "BirdAID.lrplugin" "$ZIP" )
    echo "build: archived → $ZIP"
else
    echo "build: ditto not found — skipping the optional zip archive"
fi

echo "build: OK — produced $OUT (debug-free, identifier byte-identical, real menu item)"
