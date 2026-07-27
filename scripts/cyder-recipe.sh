#!/usr/bin/env bash
# Validate and apply declarative game recipes without executing recipe data.
# Settings are staged as bottle-local desired state. Only explicitly supported,
# pinned offline payloads such as cnc-ddraw may be provisioned; unknown external
# components remain rejected.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  echo "usage: $(basename "$0") {validate|plan|apply} RECIPE.json [recipe-id] [bottle] [exe]" >&2
}

command_name="${1:-}"
recipe_file="${2:-}"
recipe_id="${3:-}"
bottle="${4:-}"
executable="${5:-}"
[[ -n "$command_name" && -n "$recipe_file" ]] || { usage; exit 2; }
case "$command_name" in validate|plan|apply) ;; *) usage; exit 2 ;; esac
[[ -f "$recipe_file" ]] || { echo "CYD-REC-001: recipe not found: $recipe_file" >&2; exit 1; }

command -v ruby >/dev/null 2>&1 || {
  echo "CYD-REC-002: recipe validation requires Ruby" >&2
  exit 1
}

if [[ -d "$SCRIPT_DIR/../Components/cnc-ddraw/7.1.0.0" ]]; then
  CYDER_CNC_DDRAW_PAYLOAD="${CYDER_CNC_DDRAW_PAYLOAD:-$SCRIPT_DIR/../Components/cnc-ddraw/7.1.0.0}"
else
  CYDER_CNC_DDRAW_PAYLOAD="${CYDER_CNC_DDRAW_PAYLOAD:-$SCRIPT_DIR/../vendor/cnc-ddraw/7.1.0.0}"
fi
export CYDER_CNC_DDRAW_PAYLOAD
export CYDER_CNC_DDRAW_INSTALLER="${CYDER_CNC_DDRAW_INSTALLER:-$SCRIPT_DIR/cyder-cnc-ddraw.sh}"

ruby -rjson -ropen3 - "$command_name" "$recipe_file" "$recipe_id" "$bottle" "$executable" <<'RUBY'
command_name, path, wanted_id, bottle, executable = ARGV
begin
  root = JSON.parse(File.read(path))
rescue JSON::ParserError => e
  abort "CYD-REC-001: invalid recipe JSON: #{e.message}"
end
abort "CYD-REC-001: recipe root must be an array" unless root.is_a?(Array)

required = %w[id revision displayName baseTemplate settings environment arguments components]
allowed_settings = %w[dpi retinaMode msync esync renderer]
allowed_renderers = %w[builtin cnc-ddraw]
ids = {}
root.each_with_index do |recipe, index|
  abort "CYD-REC-001: recipe #{index} must be an object" unless recipe.is_a?(Hash)
  unknown = recipe.keys - required
  abort "CYD-REC-001: recipe #{index} has unknown field(s): #{unknown.join(', ')}" unless unknown.empty?
  missing = required - recipe.keys
  abort "CYD-REC-001: recipe #{index} missing: #{missing.join(', ')}" unless missing.empty?
  id = recipe['id']
  abort "CYD-REC-001: recipe #{index} has invalid id" unless id.is_a?(String) && id.match?(/\A[a-z0-9][a-z0-9-]*\z/)
  abort "CYD-REC-001: duplicate recipe id: #{id}" if ids.key?(id)
  ids[id] = true
  abort "CYD-REC-001: recipe #{id} revision must be a positive integer" unless recipe['revision'].is_a?(Integer) && recipe['revision'] >= 1
  abort "CYD-REC-001: recipe #{id} displayName must not be empty" unless recipe['displayName'].is_a?(String) && !recipe['displayName'].empty?
  abort "CYD-REC-001: recipe #{id} has invalid baseTemplate" unless %w[pristine golden recommended].include?(recipe['baseTemplate'])
  settings = recipe['settings']
  abort "CYD-REC-001: recipe #{id} settings must be an object" unless settings.is_a?(Hash)
  unknown_settings = settings.keys - allowed_settings
  abort "CYD-REC-001: recipe #{id} has unknown setting(s): #{unknown_settings.join(', ')}" unless unknown_settings.empty?
  if settings.key?('dpi')
    abort "CYD-REC-001: recipe #{id} dpi must be an integer from 1 to 768" unless settings['dpi'].is_a?(Integer) && settings['dpi'].between?(1, 768)
  end
  %w[retinaMode msync esync].each do |key|
    abort "CYD-REC-001: recipe #{id} #{key} must be boolean" if settings.key?(key) && ![true, false].include?(settings[key])
  end
  if settings.key?('renderer')
    abort "CYD-REC-001: recipe #{id} renderer must be builtin or cnc-ddraw" unless allowed_renderers.include?(settings['renderer'])
  end
  abort "CYD-REC-001: recipe #{id} environment must be string map" unless recipe['environment'].is_a?(Hash) && recipe['environment'].all? { |k, v| k.is_a?(String) && v.is_a?(String) }
  %w[arguments components].each do |key|
    abort "CYD-REC-001: recipe #{id} #{key} must be an array of strings" unless recipe[key].is_a?(Array) && recipe[key].all? { |value| value.is_a?(String) && !value.empty? }
  end
end

if wanted_id.empty?
  abort "CYD-REC-001: recipe id is required for #{command_name}" unless command_name == 'validate'
  puts "validated #{root.length} recipe(s)"
  exit 0
end
recipe = root.find { |item| item['id'] == wanted_id }
abort "CYD-REC-001: recipe not found: #{wanted_id}" unless recipe

if command_name == 'validate'
  puts "validated #{wanted_id}@#{recipe['revision']}"
  exit 0
end

puts "recipe=#{recipe['id']}"
puts "revision=#{recipe['revision']}"
puts "base_template=#{recipe['baseTemplate']}"
recipe['settings'].sort.each { |key, value| puts "setting.#{key}=#{value}" }
recipe['environment'].sort.each { |key, value| puts "environment.#{key}=#{value}" }
recipe['arguments'].each_with_index { |value, index| puts "argument[#{index}]=#{value}" }
recipe['components'].each { |value| puts "component=#{value}" }
exit 0 if command_name == 'plan'

abort "CYD-REC-004: target bottle is required" if bottle.empty?
abort "CYD-REC-004: target bottle must be an existing directory: #{bottle}" unless File.directory?(bottle) && !File.symlink?(bottle)

# Component installers are deliberately metadata-only until their source,
# license and checksum are pinned. Never mark a recipe applied in this case.
unless recipe['components'].empty?
  abort "CYD-REC-003: recipe #{wanted_id} declares components (#{recipe['components'].join(', ')}); installers are not available offline, so nothing was applied"
end
cnc_installed = false
cnc_unchanged = false
if recipe['settings']['renderer'] == 'cnc-ddraw'
  abort "CYD-REC-004: recipe #{wanted_id} requires an explicit executable path" if executable.empty?
  installer = ENV.fetch('CYDER_CNC_DDRAW_INSTALLER')
  payload = ENV.fetch('CYDER_CNC_DDRAW_PAYLOAD')
  stdout, stderr, status = Open3.capture3(installer, 'install', payload, executable, bottle)
  $stdout.write(stdout)
  $stderr.write(stderr)
  abort "CYD-REC-003: cnc-ddraw provisioning failed" unless status.success?
  cnc_installed = true
  cnc_unchanged = stdout.include?('unchanged=true')
end

settings_path = File.join(bottle, '.cyder-recipe-settings.json')
applied_path = File.join(bottle, '.cyder-recipe-applied.json')
settings_payload = {
  'recipeId' => recipe['id'],
  'revision' => recipe['revision'],
  'settings' => recipe['settings'],
  'environment' => recipe['environment'],
  'arguments' => recipe['arguments']
}
applied_payload = { 'recipeId' => recipe['id'], 'revision' => recipe['revision'] }

def atomic_json(path, value)
  temp = "#{path}.tmp-#{Process.pid}"
  File.open(temp, 'wx', 0o600) { |io| io.write(JSON.pretty_generate(value)); io.write("\n") }
  File.rename(temp, path)
rescue StandardError
  File.delete(temp) if temp && File.exist?(temp)
  raise
end

begin
  atomic_json(settings_path, settings_payload)
  atomic_json(applied_path, applied_payload)
rescue StandardError => e
  if cnc_installed && !cnc_unchanged
    system(
      ENV.fetch('CYDER_CNC_DDRAW_INSTALLER'), 'uninstall', executable, bottle,
      out: File::NULL, err: File::NULL
    )
  end
  abort "CYD-REC-005: recipe settings were not marked applied: #{e.message}"
end
puts "applied=#{wanted_id}@#{recipe['revision']} bottle=#{bottle}"
RUBY
