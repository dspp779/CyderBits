#!/usr/bin/env bash
# Safe profile/bottle helpers. These helpers deliberately do not run Wine.
set -Eeuo pipefail

cyder_profile_canonical_path() {
  local path="$1"
  [[ -e "$path" ]] || { echo "profile path does not exist: $path" >&2; return 1; }
  (cd "$(dirname "$path")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$path")")
}

cyder_profile_id_for_path() {
  local path="$1" canonical digest
  canonical="$(cyder_profile_canonical_path "$path")"
  if command -v shasum >/dev/null 2>&1; then
    digest="$(printf '%s' "$canonical" | shasum -a 256 | awk '{print $1}')"
  else
    digest="$(printf '%s' "$canonical" | md5 | awk '{print $NF}')"
  fi
  printf 'profile-%s\n' "${digest:0:24}"
}

cyder_profile_create() {
  local exe_path="$1" template_dir="$2" root="$3"
  [[ -f "$exe_path" ]] || { echo "EXE does not exist: $exe_path" >&2; return 1; }
  [[ -d "$template_dir" ]] || { echo "template directory does not exist: $template_dir" >&2; return 1; }
  cyder_profile_init_layout "$root"
  local template_name id bottle profile canonical
  template_name="$(basename "$template_dir")"
  [[ "$template_name" == pristine || "$template_name" == golden || "$template_name" == recommended ]] || {
    echo "template must be pristine, golden, or recommended: $template_dir" >&2
    return 1
  }
  cyder_profile_validate_template_manifest "$template_dir/manifest.json" "$template_name" || return 1
  id="$(cyder_profile_id_for_path "$exe_path")"
  bottle="$root/bottles/$id"
  profile="$root/profiles/$id"
  canonical="$(cyder_profile_canonical_path "$exe_path")"
  [[ ! -L "$profile" && ! -L "$bottle" ]] || {
    echo "profile or bottle symlink is not allowed: $id" >&2
    return 1
  }
  if [[ -f "$profile/profile.json" && -d "$bottle" ]]; then
    cyder_profile_resolve "$exe_path" "$root" >/dev/null || return 1
    printf '%s\n' "$bottle"
    return 0
  fi
  [[ ! -e "$bottle" && ! -e "$profile" ]] || {
    echo "incomplete profile already exists: $id" >&2
    return 1
  }
  if ! cyder_profile_clone_bottle "$template_dir" "$bottle"; then
    rm -rf "$bottle"
    return 1
  fi
  if ! mkdir "$profile" || ! cyder_profile_write_metadata "$profile" "$id" "$canonical" "$template_name"; then
    rm -rf "$bottle" "$profile"
    echo "profile metadata publish failed; profile rolled back" >&2
    return 1
  fi
  printf '%s\n' "$bottle"
}

cyder_profile_resolve() {
  local exe_path="$1" root="$2"
  [[ -f "$exe_path" ]] || { echo "EXE does not exist: $exe_path" >&2; return 1; }
  local id profile bottle canonical metadata_source
  id="$(cyder_profile_id_for_path "$exe_path")"
  profile="$root/profiles/$id"
  bottle="$root/bottles/$id"
  [[ ! -L "$profile" && ! -L "$bottle" ]] || {
    echo "profile or bottle symlink is not allowed: $id" >&2
    return 1
  }
  cyder_profile_validate_metadata "$profile/profile.json" "$id" || return 1
  canonical="$(cyder_profile_canonical_path "$exe_path")"
  metadata_source="$(/usr/bin/plutil -extract sourcePath raw -o - "$profile/profile.json")"
  [[ "$metadata_source" == "$canonical" ]] || {
    echo "profile metadata source mismatch for $id" >&2
    return 1
  }
  [[ -d "$bottle" ]] || { echo "profile bottle missing: $bottle" >&2; return 1; }
  printf '%s\n' "$bottle"
}

# Remove a per-game profile and its bottle after the caller has confirmed that
# the bottle is not running. The EXE itself is never touched.
cyder_profile_remove() {
  local exe_path="$1" root="$2"
  [[ -f "$exe_path" ]] || { echo "EXE does not exist: $exe_path" >&2; return 1; }
  local id profile bottle canonical metadata_source
  id="$(cyder_profile_id_for_path "$exe_path")"
  profile="$root/profiles/$id"
  bottle="$root/bottles/$id"
  [[ ! -L "$profile" && ! -L "$bottle" ]] || {
    echo "profile or bottle symlink is not allowed: $id" >&2
    return 1
  }
  cyder_profile_validate_metadata "$profile/profile.json" "$id" || return 1
  canonical="$(cyder_profile_canonical_path "$exe_path")"
  metadata_source="$(/usr/bin/plutil -extract sourcePath raw -o - "$profile/profile.json")"
  [[ "$metadata_source" == "$canonical" ]] || {
    echo "profile metadata source mismatch for $id" >&2
    return 1
  }
  [[ -d "$profile" && -d "$bottle" ]] || {
    echo "profile bottle is incomplete: $id" >&2
    return 1
  }
  rm -rf "$profile" "$bottle"
}

cyder_profile_init_layout() {
  local root="$1"
  mkdir -p "$root/templates/pristine" \
    "$root/templates/golden" "$root/templates/recommended" "$root/profiles" "$root/bottles" \
    "$root/staging" "$root/backups"
}

# Write the stable, machine-readable contract for a profile. Metadata is
# published atomically so an interrupted clone cannot leave a valid-looking
# profile.json behind. The source path is canonicalized before it is recorded.
cyder_profile_write_metadata() {
  local profile_dir="$1" profile_id="$2" source_path="$3"
  local base_template="${4:-pristine}" recipe_id="${5:-}" legacy="${6:-false}"
  [[ -d "$profile_dir" ]] || { echo "profile directory does not exist: $profile_dir" >&2; return 1; }
  [[ "$profile_id" =~ ^profile-[a-f0-9]{24}$ ]] || {
    echo "invalid profile id: $profile_id" >&2; return 1;
  }
  [[ "$base_template" == pristine || "$base_template" == golden || "$base_template" == recommended ]] || {
    echo "invalid profile template: $base_template" >&2; return 1;
  }
  [[ -e "$source_path" ]] || { echo "profile source does not exist: $source_path" >&2; return 1; }
  [[ "$legacy" == true || "$legacy" == false ]] || { echo "invalid legacy flag: $legacy" >&2; return 1; }
  local canonical tmp plist_tmp
  canonical="$(cd "$(dirname "$source_path")" && printf '%s/%s' "$(pwd -P)" "$(basename "$source_path")")"
  tmp="$profile_dir/.profile.json.$$"
  plist_tmp="$profile_dir/.profile.plist.$$"
  rm -f "$tmp" "$plist_tmp"
  /usr/bin/plutil -create xml1 "$plist_tmp"
  /usr/bin/plutil -insert schemaVersion -integer 1 "$plist_tmp"
  /usr/bin/plutil -insert profileId -string "$profile_id" "$plist_tmp"
  /usr/bin/plutil -insert sourcePath -string "$canonical" "$plist_tmp"
  /usr/bin/plutil -insert baseTemplate -string "$base_template" "$plist_tmp"
  if [[ -n "$recipe_id" ]]; then
    /usr/bin/plutil -insert recipeId -string "$recipe_id" "$plist_tmp"
  fi
  /usr/bin/plutil -insert legacy -bool "$legacy" "$plist_tmp"
  /usr/bin/plutil -insert layoutVersion -integer 1 "$plist_tmp"
  if ! /usr/bin/plutil -convert json -o "$tmp" "$plist_tmp"; then
    rm -f "$tmp" "$plist_tmp"
    return 1
  fi
  rm -f "$plist_tmp"
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
  abort "invalid base template" unless %w[pristine golden recommended].include?(value["baseTemplate"])
  abort "invalid layout version" unless value["layoutVersion"] == 1
  abort "invalid recipe id" unless value["recipeId"].nil? || (value["recipeId"].is_a?(String) && value["recipeId"].match?(/\A[a-z0-9][a-z0-9-]*\z/))
  abort "invalid legacy flag" unless !value.key?("legacy") || value["legacy"] == true || value["legacy"] == false
rescue JSON::ParserError => error
  abort "invalid metadata JSON: #{error.message}"
end
RUBY
}

cyder_profile_write_template_manifest() {
  local template_dir="$1" revision="$2" recipe_id="${3:-}" engine_version="${4:-}"
  [[ -d "$template_dir" ]] || { echo "template directory does not exist: $template_dir" >&2; return 1; }
  [[ "$revision" =~ ^[1-9][0-9]*$ ]] || { echo "invalid template revision: $revision" >&2; return 1; }
  [[ -z "$recipe_id" || "$recipe_id" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "invalid manifest recipe id: $recipe_id" >&2; return 1; }
  command -v ruby >/dev/null 2>&1 || { echo "manifest writing requires ruby" >&2; return 1; }
  local template_id tmp
  template_id="${5:-$(basename "$template_dir")}"
  [[ "$template_id" == pristine || "$template_id" == golden || "$template_id" == recommended ]] || {
    echo "invalid template name: $template_id" >&2; return 1;
  }
  tmp="$template_dir/.manifest.json.$$"
  local schema_version=1
  [[ -n "$engine_version" ]] && schema_version=2
  ruby -rjson - "$tmp" "$template_id" "$revision" "$recipe_id" "$engine_version" "$schema_version" <<'RUBY'
target, template_id, revision, recipe_id, engine_version, schema_version = ARGV
manifest = {
  "schemaVersion" => Integer(schema_version),
  "templateId" => template_id,
  "revision" => Integer(revision),
  "recipeId" => (recipe_id.empty? ? nil : recipe_id)
}
manifest["engineVersion"] = engine_version unless engine_version.empty?
File.write(target, JSON.pretty_generate(manifest) + "\n")
RUBY
  mv "$tmp" "$template_dir/manifest.json"
}

cyder_profile_validate_template_manifest() {
  local manifest="$1" expected_template="${2:-}"
  [[ -f "$manifest" ]] || { echo "template manifest not found: $manifest" >&2; return 1; }
  command -v ruby >/dev/null 2>&1 || { echo "manifest validation requires ruby" >&2; return 1; }
  ruby -rjson - "$manifest" "$expected_template" <<'RUBY'
path, expected_template = ARGV
value = JSON.parse(File.read(path))
abort "manifest must be an object" unless value.is_a?(Hash)
%w[schemaVersion templateId revision].each { |key| abort "manifest missing #{key}" unless value.key?(key) }
abort "unsupported manifest schema" unless [1, 2].include?(value["schemaVersion"])
abort "invalid template id" unless %w[pristine golden recommended].include?(value["templateId"])
abort "template id mismatch" unless expected_template.empty? || value["templateId"] == expected_template
abort "invalid revision" unless value["revision"].is_a?(Integer) && value["revision"] >= 1
abort "invalid recipe id" if value.key?("recipeId") && !value["recipeId"].nil? && (!value["recipeId"].is_a?(String) || !value["recipeId"].match?(/\A[a-z0-9][a-z0-9-]*\z/))
abort "invalid engine version" if value.key?("engineVersion") && (!value["engineVersion"].is_a?(String) || value["engineVersion"].empty?)
abort "schema-2 manifest requires engine version" if value["schemaVersion"] == 2 && (!value.key?("engineVersion") || !value["engineVersion"].is_a?(String) || value["engineVersion"].empty?)
RUBY
}

# Atomically publish a pristine, golden, or recommended template. Callers must stop
# Wine and verify that the source prefix is inactive before invoking this API.
# Existing templates remain in place until the complete clone and manifest are
# ready; an interrupted copy therefore cannot replace a usable template.
cyder_profile_publish_template() {
  local source="$1" template_name="$2" root="$3" revision="$4" engine_version="$5" recipe_id="${6:-}"
  [[ -d "$source" ]] || { echo "template source does not exist: $source" >&2; return 1; }
  [[ "$template_name" == pristine || "$template_name" == golden || "$template_name" == recommended ]] || {
    echo "template must be pristine, golden, or recommended: $template_name" >&2
    return 1
  }
  [[ "$revision" =~ ^[1-9][0-9]*$ ]] || { echo "invalid template revision: $revision" >&2; return 1; }
  [[ -n "$engine_version" ]] || { echo "engine version is required" >&2; return 1; }
  cyder_profile_init_layout "$root"
  local parent="$root/templates" destination="$root/templates/$template_name"
  local lock="$parent/.cyder-template-${template_name}.lock"
  local staging="$parent/.cyder-template-${template_name}-$$"
  local backup="$parent/.cyder-template-${template_name}-old-$$"
  cyder_profile_acquire_clone_lock "$lock" || return $?
  find "$parent" -maxdepth 1 -type d -name ".cyder-template-${template_name}-*" -exec rm -rf {} +
  rm -rf "$staging" "$backup"
  if ! cyder_profile_clone_bottle "$source" "$staging"; then
    cyder_profile_release_clone_lock "$lock"
    return 1
  fi
  if ! cyder_profile_write_template_manifest "$staging" "$revision" "$recipe_id" "$engine_version" "$template_name"; then
    rm -rf "$staging"
    cyder_profile_release_clone_lock "$lock"
    return 1
  fi
  [[ ! -L "$destination" ]] || {
    rm -rf "$staging"
    cyder_profile_release_clone_lock "$lock"
    echo "template destination must not be a symlink: $destination" >&2
    return 1
  }
  if [[ -e "$destination" ]]; then
    if ! mv "$destination" "$backup"; then
      rm -rf "$staging"
      cyder_profile_release_clone_lock "$lock"
      return 1
    fi
  fi
  if ! mv "$staging" "$destination"; then
    rm -rf "$staging"
    if [[ -e "$backup" ]]; then mv "$backup" "$destination" || true; fi
    cyder_profile_release_clone_lock "$lock"
    return 1
  fi
  rm -rf "$backup"
  cyder_profile_release_clone_lock "$lock"
  printf '%s\n' "$destination"
}

# Return success only when a template exists and exactly matches the requested
# revision and engine version. Legacy schema-1 manifests remain readable but
# are not considered ready until republished with engineVersion.
cyder_profile_template_ready() {
  local template_name="$1" root="$2" revision="$3" engine_version="$4"
  local manifest="$root/templates/$template_name/manifest.json"
  [[ "$template_name" == pristine || "$template_name" == golden || "$template_name" == recommended ]] || return 1
  [[ ! -L "$root/templates/$template_name" && ! -L "$manifest" ]] || return 1
  [[ -f "$manifest" ]] || return 1
  cyder_profile_validate_template_manifest "$manifest" "$template_name" >/dev/null 2>&1 || return 1
  command -v ruby >/dev/null 2>&1 || return 1
  ruby -rjson - "$manifest" "$revision" "$engine_version" <<'RUBY'
path, revision, engine_version = ARGV
value = JSON.parse(File.read(path))
exit 1 unless value["revision"] == Integer(revision)
exit 1 unless value["engineVersion"] == engine_version
exit 0
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

cyder_profile_cleanup_staging() {
  local parent="$1" destination_name="$2"
  [[ -d "$parent" ]] || return 0
  find "$parent" -maxdepth 1 -type d -name ".cyder-clone-${destination_name}-*" -exec rm -rf {} +
}

cyder_profile_acquire_clone_lock() {
  local lock="$1" pid
  if mkdir "$lock" 2>/dev/null; then
    printf '%s\n' "$$" >"$lock/pid"
    return 0
  fi
  pid="$(cat "$lock/pid" 2>/dev/null || true)"
  if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
    echo "clone destination is busy: ${lock%.lock}" >&2
    return 75
  fi
  rm -rf "$lock"
  if ! mkdir "$lock" 2>/dev/null; then
    echo "clone destination lock could not be acquired: $lock" >&2
    return 75
  fi
  printf '%s\n' "$$" >"$lock/pid"
}

cyder_profile_release_clone_lock() {
  local lock="$1"
  rm -rf "$lock"
}

# Clone a bottle into destination and publish it atomically. APFS clonefile is
# requested explicitly; ordinary copy is a portable fallback for non-APFS test
# environments. Existing destinations are never overwritten.
cyder_profile_clone_bottle() {
  local source="$1" destination="$2"
  cyder_profile_assert_safe_destination "$source" "$destination" || return $?
  local parent destination_name staging method lock
  parent="$(dirname "$destination")"
  if ! mkdir -p "$parent"; then
    echo "clone destination parent could not be created: $parent" >&2
    return 1
  fi
  destination_name="$(basename "$destination")"
  [[ "$destination_name" =~ ^[A-Za-z0-9._-]+$ ]] || {
    echo "invalid clone destination name: $destination_name" >&2
    return 1
  }
  lock="$parent/.cyder-clone-${destination_name}.lock"
  cyder_profile_acquire_clone_lock "$lock" || return $?
  cyder_profile_cleanup_staging "$parent" "$destination_name"
  staging="$parent/.cyder-clone-${destination_name}-$$"
  rm -rf "$staging"
  if ! mkdir -p "$parent" "$staging"; then
    rm -rf "$staging"
    cyder_profile_release_clone_lock "$lock"
    return 1
  fi
  if [[ "${CYDER_PROFILE_COPY_MODE:-auto}" != fallback ]] && cp -cR -p "$source"/. "$staging"/ 2>/dev/null; then
    method="apfs-clone"
  else
    rm -rf "$staging"
    mkdir -p "$staging"
    if ! cp -R -p "$source"/. "$staging"/; then
      rm -rf "$staging"
      cyder_profile_release_clone_lock "$lock"
      echo "clone failed; staging removed" >&2
      return 1
    fi
    method="ordinary-copy"
  fi
  printf 'clone_method=%s\n' "$method" >&2
  if ! mv "$staging" "$destination"; then
    rm -rf "$staging"
    cyder_profile_release_clone_lock "$lock"
    echo "clone publish failed; staging removed" >&2
    return 1
  fi
  cyder_profile_release_clone_lock "$lock"
}

# Register an existing shared bottle without copying or modifying it. This
# gives legacy users a profile identity while preserving the original bottle.
cyder_profile_import_legacy_bottle() {
  local source="$1" root="$2"
  [[ -d "$source" ]] || { echo "legacy bottle does not exist: $source" >&2; return 1; }
  cyder_profile_init_layout "$root"
  local id profile_dir
  id="$(cyder_profile_id_for_path "$source")"
  profile_dir="$root/profiles/$id"
  if [[ -e "$profile_dir" ]]; then
    cyder_profile_validate_metadata "$profile_dir/profile.json" "$id"
    return $?
  fi
  mkdir "$profile_dir"
  if ! cyder_profile_write_metadata "$profile_dir" "$id" "$source" pristine "" true; then
    rmdir "$profile_dir"
    return 1
  fi
  printf '%s\n' "$id"
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
    abort "recipe #{index} has invalid baseTemplate" unless %w[pristine golden recommended].include?(recipe["baseTemplate"])
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
    create) shift; cyder_profile_create "$@" ;;
    resolve) shift; cyder_profile_resolve "$@" ;;
    remove) shift; cyder_profile_remove "$@" ;;
    metadata) shift; cyder_profile_write_metadata "$@" ;;
    validate-metadata) shift; cyder_profile_validate_metadata "$@" ;;
    template-manifest) shift; cyder_profile_write_template_manifest "$@" ;;
    validate-template-manifest) shift; cyder_profile_validate_template_manifest "$@" ;;
    publish-template) shift; cyder_profile_publish_template "$@" ;;
    template-ready) shift; cyder_profile_template_ready "$@" ;;
    clone) shift; cyder_profile_clone_bottle "$1" "$2" ;;
    import-legacy) shift; cyder_profile_import_legacy_bottle "$@" ;;
    validate-recipe) shift; cyder_recipe_validate "$1" ;;
    *) echo "usage: cyder-profile.sh {id|layout|create|resolve|remove|metadata|validate-metadata|template-manifest|validate-template-manifest|publish-template|template-ready|clone|import-legacy|validate-recipe} ..." >&2; return 2 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  cyder_profile_cli "$@"
fi
