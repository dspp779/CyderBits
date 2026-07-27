#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

TOOL="$ROOT/scripts/cyder-compatdb.py"
RULES="$ROOT/compatdb/rules"
FIXTURES="$ROOT/compatdb/tests/fixtures"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/cyder-compatdb-data.XXXXXX")"
trap 'rm -rf "$TEST_TMP"' EXIT

expect_failure() {
  local message="$1"
  shift
  if "$@" >"$TEST_TMP/failure.stdout" 2>"$TEST_TMP/failure.stderr"; then
    echo "EXPECTED FAILURE: $message" >&2
    exit 1
  fi
}

python3 "$TOOL" validate "$RULES" >"$TEST_TMP/validate.txt"
assert_contains "$(cat "$TEST_TMP/validate.txt")" "3 authoring rules, 2 enabled" \
  "validation should include Steam and cnc-ddraw game rules"

python3 "$TOOL" compile "$RULES" -o "$TEST_TMP/first.cdb" >/dev/null
python3 "$TOOL" compile "$RULES" -o "$TEST_TMP/second.cdb" >/dev/null
assert cmp -s "$TEST_TMP/first.cdb" "$TEST_TMP/second.cdb"
assert cmp -s \
  "$TEST_TMP/first.cdb" \
  "$ROOT/compatdb/tests/golden/bundled-v1.cdb"

inspection="$(python3 "$TOOL" inspect "$TEST_TMP/first.cdb" --json)"
assert_contains "$inspection" '"rule_count": 2' \
  "only enabled rules should be emitted"
assert_contains "$inspection" '"launcher.steam.webhelper.cef-gpu"' \
  "Steam WebHelper rule should be emitted"
assert_contains "$inspection" '"game.richman-4.cnc-ddraw"' \
  "Richman 4 cnc-ddraw rule should be emitted"
if [[ "$inspection" == *"launcher.steam.client.macos-compositor"* ]]; then
  echo "disabled experimental Steam client rule was emitted" >&2
  exit 1
fi

python3 "$TOOL" compile "$FIXTURES/dll-override.yml" \
  -o "$TEST_TMP/dll-override.cdb" >/dev/null
dll_inspection="$(python3 "$TOOL" inspect "$TEST_TMP/dll-override.cdb" --json)"
assert_contains "$dll_inspection" '"ddraw=n,b"' \
  "DLL override authoring should normalize module and load order"

python3 "$TOOL" compile "$FIXTURES/all-actions.yml" \
  -o "$TEST_TMP/all-actions.cdb" >/dev/null
all_actions="$(python3 "$TOOL" inspect "$TEST_TMP/all-actions.cdb" --json)"
assert_contains "$all_actions" '"TEST_SET=from-compatdb"' \
  "set_env should use canonical environment names"
assert_contains "$all_actions" '"TEST_REMOVE"' \
  "unset_env should be encoded"
assert_contains "$all_actions" '"graphics_backend": "wined3d"' \
  "graphics backend should select the translation stack"
assert_contains "$all_actions" '"wined3d_renderer": "gdi"' \
  "WineD3D renderer should use its runtime value"
assert_contains "$all_actions" '"replace_executable": "\\replace-target.exe"' \
  "executable replacement should use a normalized path suffix"

expect_failure "malformed YAML must be rejected" \
  python3 "$TOOL" validate "$FIXTURES/malformed.yml"
expect_failure "unknown schema keys must be rejected" \
  python3 "$TOOL" validate "$FIXTURES/unknown-key.yml"
expect_failure "YAML aliases must be rejected" \
  python3 "$TOOL" validate "$FIXTURES/alias.yml"
expect_failure "CDB v1 path suffixes must be printable ASCII" \
  python3 "$TOOL" validate "$FIXTURES/unicode-path-suffix.yml"
expect_failure "runtime-controlled environment variables must be rejected" \
  python3 "$TOOL" validate "$FIXTURES/unsafe-actions.yml"
expect_failure "replacement dot segments must be rejected" \
  python3 "$TOOL" validate "$FIXTURES/unsafe-replacement.yml"

cp "$ROOT/compatdb/rules/steam.yml" "$TEST_TMP/duplicate.yml"
expect_failure "duplicate rule IDs across inputs must be rejected" \
  python3 "$TOOL" validate "$ROOT/compatdb/rules/steam.yml" "$TEST_TMP/duplicate.yml"
expect_failure "same-priority overlapping option conflicts must be rejected" \
  python3 "$TOOL" validate "$FIXTURES/conflict.yml"
expect_failure "same-priority overlapping DLL conflicts must be rejected" \
  python3 "$TOOL" validate "$FIXTURES/dll-conflict.yml"
expect_failure "same-priority environment conflicts must be rejected" \
  python3 "$TOOL" validate "$FIXTURES/env-conflict.yml"
expect_failure "same-priority exclusive conflicts must be rejected" \
  python3 "$TOOL" validate "$FIXTURES/exclusive-conflict.yml"
expect_failure "same-priority graphics conflicts must be rejected" \
  python3 "$TOOL" validate "$FIXTURES/graphics-conflict.yml"
expect_failure "WineD3D renderer cannot configure another backend" \
  python3 "$TOOL" validate "$FIXTURES/incompatible-graphics.yml"

# Insert an unknown TLV immediately before RULE_END and update the header counts.
# Optional unknown records are skipped; required unknown records invalidate only
# their containing rule.
python3 -c '
import struct, sys
source, optional, required = sys.argv[1:]
data = bytearray(open(source, "rb").read())
insert_at = len(data) - 8
def write(path, flags):
    record = struct.pack("<HHI", 0x7ffe, flags, 3) + b"new"
    result = data[:insert_at] + record + data[insert_at:]
    struct.pack_into("<Q", result, 16, len(result))
    count = struct.unpack_from("<I", result, 24)[0]
    struct.pack_into("<I", result, 24, count + 1)
    open(path, "wb").write(result)
write(optional, 0)
write(required, 1)
' "$TEST_TMP/first.cdb" "$TEST_TMP/unknown-optional.cdb" "$TEST_TMP/unknown-required.cdb"

optional="$(python3 "$TOOL" inspect "$TEST_TMP/unknown-optional.cdb" --json)"
assert_contains "$optional" '"valid": true' \
  "unknown optional records should be skipped"
assert_contains "$optional" '"0x7ffe"' \
  "inspect should report skipped optional records"

required="$(python3 "$TOOL" inspect "$TEST_TMP/unknown-required.cdb" --json)"
assert_contains "$required" '"valid": false' \
  "unknown required records should invalidate only the rule"
assert_contains "$required" 'unknown required record 0x7ffe' \
  "inspect should explain the invalid rule"

# Duplicate the complete rule byte sequence. Duplicate runtime IDs are a
# structural ambiguity and reject the complete database.
python3 -c '
import struct, sys
data = bytearray(open(sys.argv[1], "rb").read())
body = bytes(data[40:])
data.extend(body)
struct.pack_into("<Q", data, 16, len(data))
record_count = struct.unpack_from("<I", data, 24)[0]
rule_count = struct.unpack_from("<I", data, 28)[0]
struct.pack_into("<I", data, 24, record_count * 2)
struct.pack_into("<I", data, 28, rule_count * 2)
open(sys.argv[2], "wb").write(data)
' "$TEST_TMP/first.cdb" "$TEST_TMP/duplicate-runtime-id.cdb"
expect_failure "duplicate runtime rule IDs must reject the complete database" \
  python3 "$TOOL" inspect "$TEST_TMP/duplicate-runtime-id.cdb"
assert_contains "$(cat "$TEST_TMP/failure.stderr")" "duplicate rule ID" \
  "decoder should identify duplicate runtime rule IDs"

python3 -c '
import sys
data = open(sys.argv[1], "rb").read()
open(sys.argv[2], "wb").write(data[:-1])
' "$TEST_TMP/first.cdb" "$TEST_TMP/truncated.cdb"
expect_failure "truncated TLV/database must be rejected" \
  python3 "$TOOL" inspect "$TEST_TMP/truncated.cdb"

python3 -c '
import struct, sys
path = sys.argv[1]
data = bytearray(open(path, "rb").read())
struct.pack_into("<Q", data, 16, 4 * 1024 * 1024 + 1)
open(sys.argv[2], "wb").write(data)
' "$TEST_TMP/first.cdb" "$TEST_TMP/bad-size.cdb"
expect_failure "declared file size mismatch must be rejected" \
  python3 "$TOOL" inspect "$TEST_TMP/bad-size.cdb"

echo "PASS test-cyder-compatdb-data"
