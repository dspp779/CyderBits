#!/usr/bin/ruby
# App-layer inventory of the exact archives copied into Resources. Does not repack an engine.
require_relative 'cyder-component-integrity'
require 'fileutils'
resources = File.realpath(ARGV.fetch(0))
output = File.join(resources, 'component-manifests')
FileUtils.mkdir_p(output)
index = {'schemaVersion' => 1, 'components' => {}}
%w[engine dxvk dxmt].each do |component|
  if component == 'engine'
    archive = File.join(resources, File.read(File.join(resources, 'engine-archive.txt')).strip)
    version = File.read(File.join(resources, 'engine-version.txt')).strip
    sha = File.read(File.join(resources, 'engine-artifact-sha256.txt')).strip
    prefix = 'wine-x86_64'
  else
    source = File.join(resources, 'graphics')
    if !File.exist?(File.join(source, "#{component}-version.txt")) && ENV['CYDER_ALLOW_MISSING_GRAPHICS'] == '1' && ENV['CYDER_GRAPHICS_CHANNEL'] != 'release'
      next # index explicitly lacks coverage; diagnostics report unknown
    end
    version = File.read(File.join(source, "#{component}-version.txt")).strip
    CyderIntegrity.safe_relative(version)
    archive = File.join(source, "#{component}-#{version}.tar.zst")
    sha, name = File.read(File.join(source, "#{component}-artifact-sha256.txt")).split
    raise 'Graphics sidecar names another archive' unless name == File.basename(archive)
    prefix = component
  end
  raise 'Invalid archive path' unless File.dirname(archive) == (component == 'engine' ? resources : File.join(resources, 'graphics'))
  manifest = CyderIntegrity.inventory(archive, sha, prefix, component, version, File.join(resources, 'tools/zstd/zstd'))
  if component == 'dxmt' && ENV['CYDER_GRAPHICS_CHANNEL'] == 'release'
    raise 'Formal DXMT requires a signed package revision/provenance' unless manifest['provenance']
    verifier = File.join(__dir__, 'graphics-signing.py')
    raise 'DXMT release verification failed' unless system('python3', verifier, 'verify-archive',
      '--archive', archive, '--zstd', File.join(resources, 'tools/zstd/zstd'), '--package-version', version)
  end
  bytes = JSON.pretty_generate(manifest) + "\n"
  raise "Component inventory exceeds runtime limit" if bytes.bytesize > CyderIntegrity::MAX_MANIFEST
  File.write(File.join(output, "#{component}.json"), bytes)
  index['components'][component] = {'manifestSHA256' => Digest::SHA256.hexdigest(bytes), 'source' => manifest['source']}
  puts "==> Component inventory: #{component} #{manifest['source']['displayVersion'] || version} (#{manifest['files'].length} entries)"
end
File.write(File.join(output, 'index.json'), JSON.pretty_generate(index) + "\n")
