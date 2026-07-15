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

# Write the stable, machine-readable contract for a profile. Metadata is
# published atomically so an interrupted clone cannot leave a valid-looking
# profile.json behind. The source path is canonicalized before it is recorded.
cyder_profile_write_metadata() {
  local profile_dir="$1" profile_id="$2" source_path="$3"
  local base_template="${4:-pristine}" recipe_id="${5:-}"
  [[ -d "$profile_dir" ]] || { echo "profile directory does not exist: $profile_dir" >&2; return 1; }
  [[ "$profile_id" =~ ^profile-[a-f0-9]{24}$ ]] || {
    echo "invalid profile id: $profile_id" >&2; return 1;
  }
  [[ "$base_template" == pristine || "$base_template" == recommended ]] || {
    echo "invalid profile template: $base_template" >&2; return 1;
  }
  [[ -e "$source_path" ]] || { echo "profile source does not exist: $source_path" >&2; return 1; }
  command -v ruby >/dev/null 2>&1 || { echo "metadata writing requires ruby" >&2; return 1; }
  local canonical tmp
  canonical="$(cd "$(dirname "$source_path")" && printf '%s/%s' "$(pwd -P)" "$(basename "$source_path")")"
  tmp="$profile_dir/.profile.json.$$"
  ruby -rjson - "$tmp" "$profile_id" "$canonical" "$base_template" "$recipe_id" <<'RUBY'
target, profile_id, source_path, base_template, recipe_id = ARGV
metadata = {
  "schemaVersion" => 1,
  "profileId" => profile_id,
  "sourcePath" => source_path,
  "baseTemplate" => base_template,
  "recipeId" => (recipe_id.empty? ? nil : recipe_id),
  "layoutVersion" => 1
}
File.write(target, JSON.pretty_generate(metadata) + "\n")
RUBY
  mv "$tmp" "$profile_dir/profile.json"
}

cyder_profile_validate_metadata() {
  local metadata="$1" expected_id="${2:-}"
  [[ -f "$metadata" ]] || { echo "profile metadata not found: $metadata" >&2; return 1; }
  command -v ruby >/dev/null 2>&1 || { echo "metadata validation requires ruby" >&2; return 1; }
  ruby -rjson - "$metadata" "$expected_id" <<'RUBY'
path, expected_id = ARGV
begin
  value = JSON.parse(File.read(path))
  required = %w[schemaVersion profileId sourcePath baseTemplate layoutVersion]
  abort "metadata must be an object" unless value.is_a?(Hash)
  abort "metadata missing required field" unless required.all? { |key| value.key?(key) }
  abort "unsupported metadata schema" unless value["schemaVersion"] == 1
  abort "invalid profile id" unless value["profileId"].is_a?(String) && value["profileId"].match?(/\Aprofile-[a-f0-9]{24}\z/)
  abort "profile id mismatch" unless expected_id.empty? || value["profileId"] == expected_id
  abort "invalid source path" unless value["sourcePath"].is_a?(String) && !value["sourcePath"].empty?
  abort "invalid base template" unless %w[pristine recommended].include?(value["baseTemplate"])
  abort "invalid layout version" unless value["layoutVersion"] == 1
  abort "invalid recipe id" unless value["recipeId"].nil? || value["recipeId"].is_a?(String)
rescue JSON::ParserError => error
  abort "invalid metadata JSON: #{error.message}"
end
RUBY
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
    ruby -rjson - "$recipe" <<'RUBY'
path = ARGV.fetch(0)
begin
  recipes = JSON.parse(File.read(path))
  abort "recipe root must be an array" unless recipes.is_a?(Array)
  allowed = %w[id revision displayName baseTemplate settings environment arguments components]
  settings_allowed = %w[dpi retinaMode msync esync renderer]
  recipes.each_with_index do |recipe, index|
    abort "recipe #{index} must be an object" unless recipe.is_a?(Hash)
    abort "recipe #{index} has unknown field" unless (recipe.keys - allowed).empty?
    %w[id revision displayName baseTemplate settings environment arguments components].each do |key|
      abort "recipe #{index} missing #{key}" unless recipe.key?(key)
    end
    abort "recipe #{index} has invalid id" unless recipe["id"].is_a?(String) && recipe["id"].match?(/\A[a-z0-9][a-z0-9-]*\z/)
    abort "recipe #{index} has invalid revision" unless recipe["revision"].is_a?(Integer) && recipe["revision"] >= 1
    abort "recipe #{index} has empty displayName" unless recipe["displayName"].is_a?(String) && !recipe["displayName"].empty?
    abort "recipe #{index} has invalid baseTemplate" unless %w[pristine recommended].include?(recipe["baseTemplate"])
    settings = recipe["settings"]
    abort "recipe #{index} settings must be an object" unless settings.is_a?(Hash)
    abort "recipe #{index} has unknown setting" unless (settings.keys - settings_allowed).empty?
    abort "recipe #{index} has invalid dpi" if settings.key?("dpi") && (!settings["dpi"].is_a?(Integer) || settings["dpi"] < 1 || settings["dpi"] > 768)
    %w[retinaMode msync esync].each { |key| abort "recipe #{index} has invalid #{key}" if settings.key?(key) && ![true, false].include?(settings[key]) }
    abort "recipe #{index} environment must be an object" unless recipe["environment"].is_a?(Hash) && recipe["environment"].all? { |key, value| key.is_a?(String) && value.is_a?(String) }
    %w[arguments components].each { |key| abort "recipe #{index} #{key} must be an array of strings" unless recipe[key].is_a?(Array) && recipe[key].all? { |item| item.is_a?(String) } }
  end
rescue JSON::ParserError => error
  abort "invalid recipe JSON: #{error.message}"
end
RUBY
    local status=$?
    (( status == 0 )) || return "$status"
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
    metadata) shift; cyder_profile_write_metadata "$@" ;;
    validate-metadata) shift; cyder_profile_validate_metadata "$@" ;;
    clone) shift; cyder_profile_clone_bottle "$1" "$2" ;;
    validate-recipe) shift; cyder_recipe_validate "$1" ;;
    *) echo "usage: cyder-profile.sh {id|layout|metadata|validate-metadata|clone|validate-recipe} ..." >&2; return 2 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  cyder_profile_cli "$@"
fi
