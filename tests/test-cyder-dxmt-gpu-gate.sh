#!/usr/bin/env bash
# DXMT needs Metal GPU Family Mac 2. On a Mac 1 GPU (old Intel Macs) the
# launcher must not pick DXMT for MapleStory, must drop an explicit DXMT
# choice, and must refuse a CompatDB DXMT-only game (CS2) with CYD-GFX-002
# before Wine starts. Unknown GPU (no helper) keeps the old behaviour.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"
TEST_DIR="$(mktemp -d /private/tmp/cy-dxmt-gpu.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

engine="$TEST_DIR/engine"
for f in lib/dxmt/x86_64-windows/{d3d11,dxgi,winemetal}.dll \
         lib/dxmt/i386-windows/{d3d11,dxgi,winemetal}.dll \
         lib/dxmt/x86_64-unix/winemetal.so \
         lib/dxvk/x86_64-windows/{d3d11,dxgi}.dll \
         lib/wine/x86_64-unix/libMoltenVK.dylib; do
  mkdir -p "$engine/${f%/*}"
  : >"$engine/$f"
done

helper="$TEST_DIR/CyderSwift"
cat >"$helper" <<'EOF'
#!/bin/bash
echo call >>"$GPU_CALLS"
[[ "$1" == --metal-gpu-family ]] || exit 64
printf '%s\n' "$GPU_FAMILY"
EOF
chmod +x "$helper"

# Runs a snippet with cyder-common.sh sourced on a pretend macOS 15 host.
run() {
  local family="$1" snippet="$2"
  : >"$TEST_DIR/calls"
  GPU_FAMILY="$family" GPU_CALLS="$TEST_DIR/calls" \
  CYDER_ENVIRONMENT_HELPER="${HELPER-$helper}" ENGINE="$engine" \
    bash -c '
      source "$1/scripts/cyder-common.sh"
      cyder_macos_at_least() { [[ "$1" -le 15 ]]; }
      eval "$2"
    ' _ "$ROOT" "$snippet" 2>&1
}

maple='/x/drive_c/Nexon/MapleStory/MapleStory.exe'
cs2='/x/drive_c/Program Files (x86)/Steam/steamapps/common/Cities Skylines II/Cities2.exe'

# --- family probe and cache ------------------------------------------------
out="$(run mac2 'cyder_metal_gpu_family; cyder_metal_gpu_family; cyder_dxmt_launch_allowed "$ENGINE" && echo allowed')"
assert_eq "$out" $'mac2\nmac2\nallowed' "a Mac 2 GPU allows DXMT"
assert_eq "$(wc -l <"$TEST_DIR/calls" | tr -d ' ')" 1 "the GPU family is asked once per launcher"

out="$(run garbage 'cyder_metal_gpu_family')"
assert_eq "$out" unknown "unexpected helper output is unknown"

out="$(HELPER=/nonexistent run mac1 'cyder_metal_gpu_family; cyder_dxmt_launch_allowed "$ENGINE" && echo allowed')"
assert_eq "$out" $'unknown\nallowed' "no helper keeps the previous DXMT behaviour"

for family in mac1 none; do
  out="$(run "$family" 'cyder_dxmt_launch_allowed "$ENGINE" && echo allowed || echo blocked')"
  assert_eq "$out" blocked "a $family GPU blocks DXMT"
done

# --- MapleStory automatic choice -------------------------------------------
out="$(run mac2 "cyder_maplestory_auto_graphics_backend '$maple' \"\$ENGINE\"")"
assert_eq "$out" dxmt "MapleStory picks DXMT on a Mac 2 GPU"
out="$(run mac1 "cyder_maplestory_auto_graphics_backend '$maple' \"\$ENGINE\"")"
assert_eq "$out" dxvk "MapleStory falls back to DXVK on a Mac 1 GPU"

# --- explicit DXMT preference ----------------------------------------------
out="$(run mac1 'cyder_apply_graphics_preference dxmt "$ENGINE"; echo "pref=$CYDER_GRAPHICS_PREFERENCE backend=${CYDER_GRAPHICS_BACKEND:-}"')"
assert_contains "$out" "Metal GPU Family Mac 2" "the fallback message names the GPU requirement"
assert_contains "$out" "pref=default backend=" "an explicit DXMT choice falls back to default on a Mac 1 GPU"
out="$(run mac2 'cyder_apply_graphics_preference dxmt "$ENGINE"; echo "backend=$CYDER_GRAPHICS_BACKEND"')"
assert_eq "$out" "backend=dxmt" "an explicit DXMT choice is kept on a Mac 2 GPU"

# --- CompatDB DXMT-only game -----------------------------------------------
refuse() { run "$1" "$2; cyder_refuse_unsupported_dxmt_gpu '$3' && echo ok || echo \"refused \$?\""; }
out="$(refuse mac1 'unset CYDER_GRAPHICS_BACKEND' "$cs2")"
assert_contains "$out" "CYD-GFX-002" "CS2 on a Mac 1 GPU is refused with CYD-GFX-002"
assert_contains "$out" "Cities2.exe 只能使用 DXMT" "the refusal names the executable"
assert_contains "$out" "refused 1" "the refusal fails the launch"
out="$(refuse mac1 'unset CYDER_GRAPHICS_BACKEND' 'D:\Games\CITIES2.EXE')"
assert_contains "$out" "refused 1" "the CS2 match ignores case and Windows separators"
out="$(refuse mac2 'unset CYDER_GRAPHICS_BACKEND' "$cs2")"
assert_eq "$out" ok "CS2 on a Mac 2 GPU is not refused"
out="$(refuse mac1 'export CYDER_GRAPHICS_BACKEND=dxvk' "$cs2")"
assert_eq "$out" ok "a user-chosen backend wins over the CompatDB DXMT rule"
out="$(refuse mac1 'unset CYDER_GRAPHICS_BACKEND' "$maple")"
assert_eq "$out" ok "games without a DXMT-only rule are not refused"
out="$(run mac1 "cyder_macos_at_least() { false; }; unset CYDER_GRAPHICS_BACKEND; cyder_refuse_unsupported_dxmt_gpu '$cs2' && echo ok")"
assert_eq "$out" ok "the GPU refusal only applies where DXMT could run (macOS 15+)"

common="$(cat "$ROOT/scripts/cyder-common.sh")"
assert_contains "$common" $'cyder_resolve_effective_graphics_backend "$engine_root" "$exe"\n  cyder_refuse_unsupported_dxmt_gpu "$exe" || return $?' \
  "game launch preparation refuses an unsupported GPU right after backend resolution"

out="$(bash -c 'source "$1/scripts/cyder-common.sh"; cyder_game_environment_key_is_allowed _CYDER_METAL_GPU_FAMILY && echo allowed || echo blocked' _ "$ROOT")"
assert_eq "$out" blocked "per-game environment cannot fake the GPU family"

# --- the shell list matches the shipped CompatDB ---------------------------
shipped="$(python3 "$ROOT/scripts/cyder-compatdb.py" inspect "$ROOT/compatdb/compiled/compatdb.cdb" --json \
  | python3 -c 'import json,sys
for r in json.load(sys.stdin)["rules"]:
    if r["enabled"] and r["graphics_backend"] == "dxmt":
        for s in r["path_suffixes"]: print(s.rsplit("\\",1)[-1])' | sort)"
assert_eq "$shipped" "cities2.exe" "the shipped CompatDB DXMT rules are the ones the launcher knows"
for exe in $shipped; do
  out="$(bash -c 'source "$1/scripts/cyder-common.sh"; cyder_compatdb_dxmt_only_executable "C:\\x\\$2" && echo yes' _ "$ROOT" "$exe")"
  assert_eq "$out" yes "cyder_compatdb_dxmt_only_executable knows $exe"
done

# --- Swift: CyderSwift --metal-gpu-family and the CYD-GFX-002 alert --------
cat >"$TEST_DIR/main.swift" <<'EOF'
import Foundation
import Metal
func check(_ ok: Bool, _ message: String) { if !ok { print("FAIL: \(message)"); exit(1) } }
check(CyderMetalGPU.family(of: nil) == .none, "no device is none")
check(CyderMetalGPU.run(arguments: ["CyderSwift"]) == 64, "missing flag is a usage error")
check(CyderMetalGPU.run(arguments: ["CyderSwift", "--metal-gpu-family", "x"]) == 64, "extra argument is a usage error")
var printed: [String] = []
check(CyderMetalGPU.run(arguments: ["CyderSwift", "--metal-gpu-family"], device: { nil },
                        output: { printed.append($0) }) == 0, "no device still succeeds")
check(printed == ["none"], "no device prints none")
printed = []
_ = CyderMetalGPU.run(arguments: ["CyderSwift", "--metal-gpu-family"], output: { printed.append($0) })
check(printed == ["mac2"] || printed == ["mac1"], "the real device prints a family: \(printed)")
print("ok")
EOF
swiftc -module-cache-path "$TEST_DIR/cache" "$ROOT/scripts/cyder_metal_gpu.swift" "$TEST_DIR/main.swift" -o "$TEST_DIR/gpu"
assert_eq "$("$TEST_DIR/gpu")" ok "CyderMetalGPU reports the family"

app="$(cat "$ROOT/scripts/cyder_app_main.swift")"
assert_contains "$app" '"--metal-gpu-family"' "CyderSwift dispatches --metal-gpu-family"
assert_contains "$app" 'prepared.outputTail.contains("CYD-GFX-002")' \
  "a refused preparation shows the GPU message instead of CYD-WIN-001"
assert_contains "$(cat "$ROOT/scripts/create-cyder-app.sh")" '"$SCRIPT_DIR/cyder_metal_gpu.swift"' \
  "the app build compiles the GPU probe"
assert_contains "$(cat "$ROOT/scripts/cyder_settings.swift")" 'hasDxmt: hostGPUSupportsDxmt && hasDxmtPayload' \
  "settings only offer DXMT on a supported GPU"

echo "test-cyder-dxmt-gpu-gate: ok"
