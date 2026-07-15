#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
CACHE="$TMP/module-cache"
BIN="$TMP/cyder-profiles-harness"

swiftc -O -module-cache-path "$CACHE" \
  "$ROOT/scripts/cyder_profiles.swift" \
  "$ROOT/tests/fixtures/cyder_profiles_harness.swift" \
  -o "$BIN"

mkdir -p "$TMP/games/一號" "$TMP/games/另一個" "$TMP/store"
printf 'exe\n' >"$TMP/games/一號/遊戲.exe"
printf 'exe\n' >"$TMP/games/另一個/遊戲.exe"

first="$($BIN "$TMP/store" "$TMP/games/一號/遊戲.exe")"
second="$($BIN "$TMP/store" "$TMP/games/另一個/遊戲.exe")"
[[ "$first" == uncreated\ profile-* && "$second" == uncreated\ profile-* ]] || {
  echo "ASSERT failed: Unicode profiles should start uncreated" >&2; exit 1;
}
first_id="${first#uncreated }"
second_id="${second#uncreated }"
[[ "$first_id" != "$second_id" ]] || {
  echo "ASSERT failed: same basename paths must have different IDs" >&2; exit 1;
}

mkdir -p "$TMP/store/profiles/$first_id" "$TMP/store/bottles/$first_id"
canonical="$TMP/games/一號/遊戲.exe"
printf '{"schemaVersion":1,"profileId":"%s","sourcePath":"%s","baseTemplate":"recommended","recipeId":null,"legacy":false,"layoutVersion":1}\n' "$first_id" "$canonical" >"$TMP/store/profiles/$first_id/profile.json"
ready="$($BIN "$TMP/store" "$canonical")"
[[ "$ready" == "ready $first_id $canonical" ]] || {
  echo "ASSERT failed: valid metadata should resolve ready: $ready" >&2; exit 1;
}

rm -rf "$TMP/store/bottles/$first_id"
printf 'not-a-directory\n' >"$TMP/store/bottles/$first_id"
regular_bottle="$($BIN "$TMP/store" "$canonical")"
[[ "$regular_bottle" == damaged\ * ]] || {
  echo "ASSERT failed: regular-file bottle should be damaged: $regular_bottle" >&2; exit 1
}
rm "$TMP/store/bottles/$first_id"
mkdir -p "$TMP/store/bottles/$first_id"

mv "$TMP/store/profiles/$first_id/profile.json" "$TMP/metadata.json"
ln -s "$TMP/metadata.json" "$TMP/store/profiles/$first_id/profile.json"
metadata_link="$($BIN "$TMP/store" "$canonical")"
[[ "$metadata_link" == damaged\ * ]] || {
  echo "ASSERT failed: symlink profile.json should be damaged: $metadata_link" >&2; exit 1
}
rm "$TMP/store/profiles/$first_id/profile.json"
mv "$TMP/metadata.json" "$TMP/store/profiles/$first_id/profile.json"
printf '{"schemaVersion":1,"profileId":"%s","sourcePath":"%s","baseTemplate":"recommended","recipeId":"Bad ID","legacy":false,"layoutVersion":1}\n' "$first_id" "$canonical" >"$TMP/store/profiles/$first_id/profile.json"
bad_recipe="$($BIN "$TMP/store" "$canonical")"
[[ "$bad_recipe" == damaged\ * ]] || {
  echo "ASSERT failed: invalid recipeId should be damaged: $bad_recipe" >&2; exit 1
}
printf '{"schemaVersion":1,"profileId":"%s","sourcePath":"%s","baseTemplate":"recommended","recipeId":"","legacy":false,"layoutVersion":1}\n' "$first_id" "$canonical" >"$TMP/store/profiles/$first_id/profile.json"
empty_recipe="$($BIN "$TMP/store" "$canonical")"
[[ "$empty_recipe" == damaged\ * ]] || {
  echo "ASSERT failed: empty recipeId should be damaged: $empty_recipe" >&2; exit 1
}

printf '{broken\n' >"$TMP/store/profiles/$first_id/profile.json"
damaged="$($BIN "$TMP/store" "$canonical")"
[[ "$damaged" == damaged\ * ]] || {
  echo "ASSERT failed: broken metadata should be damaged: $damaged" >&2; exit 1;
}

rm -f "$TMP/store/profiles/$first_id/profile.json"
rm -rf "$TMP/store/bottles/$first_id"
ln -s "$TMP/games/一號" "$TMP/store/bottles/$first_id"
symlinked="$($BIN "$TMP/store" "$canonical")"
[[ "$symlinked" == damaged\ * ]] || {
  echo "ASSERT failed: symlink bottle should be damaged: $symlinked" >&2; exit 1;
}
rm "$TMP/store/bottles/$first_id"
ln -s "$TMP/does-not-exist" "$TMP/store/bottles/$first_id"
dangling="$($BIN "$TMP/store" "$canonical")"
[[ "$dangling" == damaged\ * ]] || {
  echo "ASSERT failed: dangling bottle symlink should be damaged: $dangling" >&2; exit 1;
}

echo "PASS test-cyder-profiles-swift"
