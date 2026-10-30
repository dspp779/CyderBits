#!/usr/bin/ruby
# Only applies a publisher-verified bundled DXMT; no downloads or signing.
require_relative 'cyder-component-integrity'
require 'fileutils'
require 'tmpdir'
require 'securerandom'
require 'pathname'

class CyderGraphicsUpdate
  C = CyderIntegrity
  class Deferred < StandardError; end
  RECEIPT = '.cyder-dxmt-install.json'.freeze
  def initialize(resources:, runtime:, engine:, prefix:, manifest: nil, probe: nil, extract: nil, fault: nil)
    @resources, @runtime, @engine, @prefix = [resources, runtime, engine, prefix].map { |p| canonical(p) }
    @manifest_input, @probe_input, @extract_input, @fault = manifest, probe, extract, fault
    @deadline = C.now + 60
  end
  def canonical(path)
    value = File.expand_path(path); tail = []
    until File.exist?(value) || File.symlink?(value)
      tail.unshift(File.basename(value)); value = File.dirname(value)
    end
    File.join(File.realpath(value), *tail)
  end
  def prefix_destination(relative)
    root = File.realpath(@prefix)
    parts = C.safe_relative(relative).split('/')
    parts[0...-1].inject(root) do |parent, part|
      child = File.join(parent, part)
      if File.exist?(child) || File.symlink?(child)
        deferred('linked_prefix_directory') unless File.lstat(child).directory? && !File.symlink?(child)
      end
      child
    end
    File.join(root, relative)
  end
  def prepare_parent(path, created)
    parent = File.dirname(path)
    missing = []
    until File.directory?(parent)
      deferred('linked_prefix_directory') if File.symlink?(parent) || File.exist?(parent)
      missing.unshift(parent); parent = File.dirname(parent)
    end
    missing.each { |directory| Dir.mkdir(directory); created << directory }
  end
  def deferred(reason); raise Deferred, reason; end
  def manifest
    return @manifest_input if @manifest_input # explicit unit-test seam, never a CLI option
    C.bundle_trust(@resources, @deadline)
    index = JSON.parse(C.read_small(C.locate(@resources, 'component-manifests/index.json')))
    spec = index.fetch('components').fetch('dxmt')
    bytes = C.read_small(C.locate(@resources, 'component-manifests/dxmt.json'))
    deferred('manifest_digest_mismatch') unless Digest::SHA256.hexdigest(bytes) == spec.fetch('manifestSHA256')
    value = JSON.parse(bytes)
    deferred('manifest_source_mismatch') unless value.fetch('source') == spec.fetch('source')
    value
  end
  def scan(root)
    bytes = JSON.generate(@manifest)
    C.scan(bytes, root, Digest::SHA256.hexdigest(bytes), @source, 'full', @deadline)
  end
  def probe
    return @probe_input.call if @probe_input
    helper = File.join(File.dirname(@resources), 'MacOS', 'CyderSwift')
    _, text, status = C.command([helper, '--graphics-runtime-state', File.dirname(@engine)], @deadline)
    return :idle if status == 10 && text.strip == 'cyder-graphics-v1 idle'
    return :busy if status == 0 && text.strip == 'cyder-graphics-v1 busy'
    :unknown
  end
  def idle!
    state = probe
    deferred(state == :busy ? 'windows_busy_retry_when_idle' : 'process_inventory_unknown') unless state == :idle
  end
  def regular_bytes(path)
    C.read_small(path, 64 * 1024 * 1024)
  end
  def link_matches?(path, target)
    return File.readlink(path) == target if File.symlink?(path)
    deferred('unexpected_graphics_link_type') if File.exist?(path)
    false
  end
  def current_root
    return nil unless File.exist?(@current) || File.symlink?(@current)
    deferred('current_link_type_unknown') unless File.symlink?(@current)
    begin
      target = File.realpath(@current)
    rescue Errno::ENOENT
      return nil # known dangling link; never remove its old destination
    end
    deferred('current_link_outside_managed_runtime') unless target.start_with?(@base + '/') && File.realpath(@base) == @base
    target
  end
  def active_version(root)
    receipt = File.join(root, RECEIPT)
    if File.exist?(receipt)
      return JSON.parse(C.read_small(receipt)).fetch('displayVersion')
    end
    marker = File.join(root, '.cyder-graphics-version')
    return C.read_small(marker).strip[/\A\d+(?:\.\d+)*/] if File.file?(marker)
    version = File.join(root, 'version')
    return C.read_small(version)[/\b(?:v)?(\d+(?:\.\d+)+)/, 1] if File.file?(version)
    nil
  end
  def extract(archive, staging)
    return @extract_input.call(archive, staging) if @extract_input
    zstd = File.join(@resources, 'tools/zstd/zstd')
    Open3.popen3(zstd, '-dc', archive) do |input, output, errors, child|
      input.close
      drain = Thread.new { begin; loop { errors.readpartial(4096) }; rescue EOFError, IOError; end }
      seen = {}; total = 0; pax = {}
      Gem::Package::TarReader.new(C::SequentialTar.new(output)) do |tar|
        tar.each do |entry|
          C.tick(@deadline)
          if entry.header.typeflag == 'x'
            deferred('oversized_pax_metadata') if entry.header.size > 1024 * 1024
            payload = entry.read; position = 0
            while position < payload.bytesize
              length = payload[position..-1].to_i
              deferred('invalid_pax_metadata') unless length > 0 && position + length <= payload.bytesize
              pair = payload.byteslice(position, length).sub(/\A\d+ /, '').chomp.split('=', 2)
              pax[pair[0]] = pair[1]; position += length
            end
            next
          end
          name = (pax['path'] || entry.full_name).sub(/\A\.\//, '').sub(/\/\z/, '')
          pax = {}
          next if name == 'dxmt' && entry.directory?
          deferred('unsafe_archive_entry') unless name.start_with?('dxmt/')
          relative = C.safe_relative(name[5..-1])
          next if entry.directory?
          deferred('unsafe_archive_entry') unless entry.file? && !seen[relative]
          seen[relative] = true; total += entry.header.size
          deferred('archive_budget_exceeded') if seen.length > 20000 || total > 256 * 1024 * 1024
          destination = File.join(staging, 'dxmt', relative)
          FileUtils.mkdir_p(File.dirname(destination))
          File.open(destination, File::WRONLY | File::CREAT | File::EXCL, 0600) do |file|
            until entry.eof?
              C.tick(@deadline); file.write(entry.read(C::CHUNK))
            end
          end
          File.chmod(entry.header.mode & 0777, destination)
        end
      end
      drain.join
      deferred('archive_decompression_failed') unless child.value.success?
    end
  end
  def atomic_link(path, target)
    temporary = path + '.new-' + SecureRandom.hex(8)
    File.symlink(target, temporary)
    File.rename(temporary, path)
  ensure
    File.unlink(temporary) if temporary && File.symlink?(temporary)
  end
  def apply
    deferred('engine_outside_managed_runtime') unless @engine.start_with?(File.join(@runtime, 'Engines') + '/')
    @manifest = manifest; @source = @manifest.fetch('source')
    key = @source.fetch('installKey'); display = @source.fetch('displayVersion')
    deferred('invalid_install_identity') unless @source['component'] == 'dxmt' && key.match(/\A[0-9.]+-[0-9a-f]{64}\z/)
    @base = File.join(@runtime, 'graphics/dxmt'); @current = File.join(@runtime, 'graphics/current-dxmt')
    ['graphics', 'graphics/dxmt'].each do |relative|
      directory = File.join(@runtime, relative)
      if File.exist?(directory) || File.symlink?(directory)
        deferred('linked_install_directory') unless File.lstat(directory).directory? && !File.symlink?(directory)
      end
    end
    lib = File.join(@engine, 'lib')
    deferred('linked_engine_directory') if File.symlink?(lib) || (File.exist?(lib) && !File.directory?(lib))

    deferred('unresolved_previous_update') if %w[.dxmt-update-uncertain .dxmt-update-in-progress].any? { |name| File.exist?(File.join(@runtime, 'graphics', name)) }
    # No mutation if the current scan or process evidence is unknown.
    selector = File.symlink?(@current) ? File.readlink(@current) : nil
    active = current_root
    active_scan = active ? scan(active) : {'status' => 'missing'}
    deferred('installed_verification_unknown') if active_scan['status'] == 'unknown'
    if active
      version = active_version(active)
      deferred('installed_version_unknown') unless version && version.match(/\A\d+(?:\.\d+)*\z/)
      deferred('installed_version_newer') if Gem::Version.new(version) > Gem::Version.new(display)
    end
    receipt = active && File.file?(File.join(active, RECEIPT)) ? JSON.parse(C.read_small(File.join(active, RECEIPT))) : {}
    materialize = active_scan['status'] != 'ok' || receipt['installKey'] != key
    root = active
    engine_link = File.join(@engine, 'lib/dxmt')
    engine_target = Pathname.new(@current).relative_path_from(Pathname.new(File.dirname(engine_link))).to_s
    engine_changed = !link_matches?(engine_link, engine_target)
    prefix_changes = []
    if File.directory?(@prefix)
      %w[x86_64 i386].each do |arch|
        relative = 'drive_c/windows/' + (arch == 'x86_64' ? 'system32' : 'syswow64') + '/winemetal.dll'
        destination = prefix_destination(relative) # refuse linked parents
        expected = @manifest.fetch('files').find { |row| row['path'] == arch + '-windows/winemetal.dll' && row['kind'] == 'file' }
        deferred('expected_prefix_member_missing') unless expected
        matches = false
        if File.exist?(destination) || File.symlink?(destination)
          deferred('prefix_file_type_unknown') unless File.lstat(destination).file? && !File.symlink?(destination)
          bytes = regular_bytes(destination)
          matches = bytes.bytesize == expected['size'] && Digest::SHA256.hexdigest(bytes) == expected['sha256']
        end
        prefix_changes << [arch, destination] unless matches
      end
    end
    return {'status' => 'ok', 'changed' => false, 'version' => display, 'installKey' => key} unless materialize || engine_changed || !prefix_changes.empty?
    idle!
    # A prefix-scoped executor cannot mutate shared graphics. Retry under the global barrier.
    deferred('global_scope_required') unless ENV['CYDER_EXECUTION_RUNTIME_MUTATION'] == '1' || @manifest_input
    FileUtils.mkdir_p(@base)
    deferred('linked_install_directory') unless File.realpath(@base) == @base
    lock_path = File.join(@runtime, 'graphics/.dxmt-update.lock')
    File.open(lock_path, File::RDWR | File::CREAT | File::NOFOLLOW, 0600) do |lock|
      deferred('another_graphics_update') unless lock.flock(File::LOCK_EX | File::LOCK_NB)
      idle!
      deferred('selector_changed_retry') unless (File.symlink?(@current) ? File.readlink(@current) : nil) == selector
      transaction(root, key, display, materialize, engine_link, engine_target, engine_changed, prefix_changes)
    end
  rescue Deferred => e
    {'status' => 'deferred', 'reason' => e.message}
  rescue StandardError
    {'status' => 'deferred', 'reason' => 'verification_or_io_unknown'}
  end
  def transaction(root, key, display, materialize, engine_link, engine_target, engine_changed, prefix_changes)
    staging = Dir.mktmpdir('.dxmt-stage-', File.join(@runtime, 'graphics'))
    object = nil; backups = []; links = []; created = []; committed = false; uncertain = false
    marker = File.join(@runtime, 'graphics/.dxmt-update-in-progress'); marked = false
    begin
      if materialize
        archive = C.locate(@resources, 'graphics/' + C.safe_relative(@source.fetch('archive')))
        deferred('source_archive_digest_mismatch') unless Digest::SHA256.file(archive).hexdigest == @source.fetch('archiveSHA256')
        extract(archive, staging)
        root = File.join(staging, 'dxmt')
        report = scan(root)
        deferred(report['status'] == 'unknown' ? 'candidate_verification_unknown' : 'candidate_verification_failed') unless report['status'] == 'ok'
        File.write(File.join(root, RECEIPT), JSON.generate('schemaVersion' => 1, 'displayVersion' => display, 'installKey' => key))
        File.write(File.join(root, '.cyder-graphics-version'), display + "\n")
        object = File.join(@base, key + '-' + SecureRandom.hex(8))
      end
      # Revalidate immediately before any visible changes under the global executor barrier.
      idle!
      File.open(marker, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0600) { |f| f.write(JSON.generate('installKey' => key)); f.fsync }; marked = true
      if object
        File.rename(root, object); root = object
      end
      prefix_changes.each do |arch, destination|
        @fault.call(:before_prefix) if @fault
        source = File.join(root, arch + '-windows/winemetal.dll')
        deferred('candidate_prefix_member_missing') unless File.file?(source)
        old = destination + '.old-' + SecureRandom.hex(8)
        fresh = destination + '.new-' + SecureRandom.hex(8)
        prepare_parent(destination, created)
        existed = File.exist?(destination)
        original_digest = existed ? Digest::SHA256.hexdigest(regular_bytes(destination)) : nil
        new_digest = Digest::SHA256.hexdigest(regular_bytes(source))
        backups << [destination, old, fresh, existed, original_digest, new_digest]
        FileUtils.cp(source, fresh)
        File.rename(destination, old) if existed
        File.rename(fresh, destination)
      end
      if engine_changed
        FileUtils.mkdir_p(File.dirname(engine_link))
        links << [engine_link, File.symlink?(engine_link) ? File.readlink(engine_link) : nil]
        atomic_link(engine_link, engine_target)
      end
      if object
        links << [@current, File.symlink?(@current) ? File.readlink(@current) : nil]
        @fault.call(:before_switch) if @fault
        atomic_link(@current, Pathname.new(root).relative_path_from(Pathname.new(File.dirname(@current))).to_s)
      end
      committed = true
      {'status' => 'ok', 'changed' => true, 'version' => display, 'installKey' => key}
    ensure
      unless committed
        begin
          links.reverse_each { |path, old| old ? atomic_link(path, old) : (File.unlink(path) if File.symlink?(path)) }
          backups.reverse_each do |destination, old, fresh, existed, original_digest, new_digest|
            if existed
              if File.file?(old)
                File.rename(old, destination)
              else
                raise IOError unless File.file?(destination) && Digest::SHA256.file(destination).hexdigest == original_digest
              end
            elsif File.file?(destination)
              raise IOError unless Digest::SHA256.file(destination).hexdigest == new_digest
              File.unlink(destination)
            end
            File.unlink(fresh) if File.file?(fresh)
          end
        rescue StandardError
          uncertain = true
          File.write(File.join(@runtime, 'graphics/.dxmt-update-uncertain'), 'rollback-incomplete')
        end
      end
      unless uncertain
        backups.each { |_, old, fresh, _| [old, fresh].each { |p| begin; File.unlink(p) if File.file?(p); rescue SystemCallError; end } }
        File.unlink(marker) if marked && File.file?(marker)
        FileUtils.rm_rf(object) if object && !committed
        FileUtils.rm_rf(staging)
        created.reverse_each { |directory| begin; Dir.rmdir(directory); rescue Errno::ENOENT, Errno::ENOTEMPTY; end } unless committed
      end
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  require 'pathname'
  begin
    args = {}; action = ARGV.shift
    OptionParser.new { |p| %w[resources runtime engine prefix].each { |k| p.on("--#{k} PATH") { |v| args[k.to_sym] = v } } }.parse!
    raise 'invalid action' unless action == 'apply' && ARGV.empty? && args.length == 4
    result = CyderGraphicsUpdate.new(**args).apply
    puts JSON.generate(result)
    exit(result['status'] == 'ok' ? 0 : 75)
  rescue StandardError
    puts JSON.generate('status' => 'deferred', 'reason' => 'invalid_or_unavailable_update')
    exit 75
  end
end
