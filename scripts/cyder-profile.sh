#!/usr/bin/env bash
# Safe profile/bottle helpers. These helpers deliberately do not run Wine.
set -Eeuo pipefail

cyder_profile_id_for_path() {
  local path="$1" canonical digest
  [[ -e "$path" ]] || { echo "profile path does not exist: $path" >&2; return 1; }
  canonical="$(cd "$(dirname "$path")" && printf '%s/%s' "$(pwd -P)" "$(basename "$path")")"
  if command -v shasum >/dev/null 2>&1; then
    digest="$(printf '%s' "$canonical" | shasum -a 256 | awk '{print $1}')"
  else
    digest="$(printf '%s' "$canonical" | md5 | awk '{print $NF}')"
  fi
  printf 'profile-%s\n' "${digest:0:24}"
}

cyder_profile_init_layout() {
  local root="$1"
  mkdir -p "$root/templates/pristine" \
    "$root/templates/recommended" "$root/profiles" "$root/bottles" \
    "$root/staging" "$root/backups"
}

cyder_profile_assert_safe_destination() {
  local source="$1" destination="$2"
  [[ -d "$source" ]] || { echo "clone source is not a directory: $source" >&2; return 1; }
  [[ ! -e "$destination" && ! -L "$destination" ]] || {
    echo "clone destination already exists: $destination" >&2
    return 1
  }
  case "$destination/" in
    "$source"/*) echo "clone destination cannot be inside source" >&2; return 1 ;;
  esac
}

# Clone a bottle into destination and publish it atomically. APFS clonefile is
# requested explicitly; ordinary copy is a portable fallback for non-APFS test
# environments. Existing destinations are never overwritten.
cyder_profile_clone_bottle() {
  local source="$1" destination="$2"
  cyder_profile_assert_safe_destination "$source" "$destination" || return $?
  local parent staging method
  parent="$(dirname "$destination")"
  staging="$parent/.cyder-clone-$(basename "$destination")-$$"
  rm -rf "$staging"
  mkdir -p "$parent" "$staging"
  if [[ "${CYDER_PROFILE_COPY_MODE:-auto}" != fallback ]] && cp -cR -p "$source"/. "$staging"/ 2>/dev/null; then
    method="apfs-clone"
  else
    rm -rf "$staging"
    mkdir -p "$staging"
    cp -R -p "$source"/. "$staging"/
    method="ordinary-copy"
  fi
  printf 'clone_method=%s\n' "$method" >&2
  mv "$staging" "$destination"
}

cyder_recipe_validate() {
  local recipe="$1"
  [[ -f "$recipe" ]] || { echo "recipe not found: $recipe" >&2; return 1; }
  if command -v ruby >/dev/null 2>&1; then
    ruby -rjson -e 'JSON.parse(File.read(ARGV.fetch(0)))' "$recipe" >/dev/null
  elif command -v plutil >/dev/null 2>&1; then
    plutil -lint "$recipe" >/dev/null || { echo "invalid recipe JSON: $recipe" >&2; return 1; }
  else
    echo "recipe validation requires plutil or ruby" >&2
    return 1
  fi
  return 0
}

cyder_profile_cli() {
  case "${1:-}" in
    id) shift; cyder_profile_id_for_path "$1" ;;
    layout) shift; cyder_profile_init_layout "$1" ;;
    clone) shift; cyder_profile_clone_bottle "$1" "$2" ;;
    validate-recipe) shift; cyder_recipe_validate "$1" ;;
    *) echo "usage: cyder-profile.sh {id|layout|clone|validate-recipe} ..." >&2; return 2 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  cyder_profile_cli "$@"
fi
