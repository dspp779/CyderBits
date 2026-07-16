#!/usr/bin/env bash
# Validate and apply declarative game recipes without executing recipe data.
# This is intentionally a small offline framework: settings are staged as
# bottle-local desired state; external component installers are rejected until
# their source, license and checksum metadata are supplied.
set -euo pipefail

usage() {
  echo "usage: $(basename "$0") {validate|plan|apply} RECIPE.json [recipe-id] [bottle]" >&2
}

command_name="${1:-}"
recipe_file="${2:-}"
recipe_id="${3:-}"
bottle="${4:-}"
[[ -n "$command_name" && -n "$recipe_file" ]] || { usage; exit 2; }
case "$command_name" in validate|plan|apply) ;; *) usage; exit 2 ;; esac
[[ -f "$recipe_file" ]] || { echo "CYD-REC-001: recipe not found: $recipe_file" >&2; exit 1; }

command -v ruby >/dev/null 2>&1 || {
  echo "CYD-REC-002: recipe validation requires Ruby" >&2
  exit 1
}

ruby -rjson - "$command_name" "$recipe_file" "$recipe_id" "$bottle" <<'RUBY'
command_name, path, wanted_id, bottle = ARGV
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
if recipe['settings']['renderer'] == 'cnc-ddraw'
  abort "CYD-REC-003: recipe #{wanted_id} requires a pinned cnc-ddraw payload; source, license and checksum are not available offline, so nothing was applied"
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
  abort "CYD-REC-005: recipe settings were not marked applied: #{e.message}"
end
puts "applied=#{wanted_id}@#{recipe['revision']} bottle=#{bottle}"
RUBY
