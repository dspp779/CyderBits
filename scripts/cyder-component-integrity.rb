#!/usr/bin/ruby
# Read-only runtime diagnostics. Inventory generation is a separate build-only action.
require 'json'
require 'digest'
require 'optparse'
require 'open3'
require 'rubygems/package'

module CyderIntegrity
  VERSION = 1
  TEAM = '3U9565WWM2'.freeze
  DXMT_NATIVE = 'x86_64-unix/winemetal.so'.freeze
  GRAPHICS_META = 'cyder-graphics-provenance.json'.freeze
  DXMT_UPSTREAM = {
    'version' => 'v0.80',
    'url' => 'https://github.com/3Shain/dxmt/releases/download/v0.80/dxmt-v0.80-builtin.tar.gz',
    'archiveSHA256' => '8f260e36b5739e68f3bad613381441385c4dc7b85b78ba8de653d5a6a264529d',
    'fileSHA256' => '3d50d7f39c64778c71d0af2fce1cde818d09ffbce7c4f7b8ae24ae1df567c0ca'
  }.freeze

  CHUNK = 128 * 1024
  MAX_MANIFEST = 8 * 1024 * 1024
  MAX_FILES = 20000
  class Unknown < StandardError; end
  class Expired < Unknown; end
  class Cancelled < Unknown; end
  class SourceMismatch < StandardError; end

  def self.now; Process.clock_gettime(Process::CLOCK_MONOTONIC); end
  def self.tick(deadline)
    raise Expired, 'deadline' if now >= deadline
  end

  # Only these owned metadata commands are spawned; never Wine or scanned binaries.
  def self.command(argv, deadline)
    tick(deadline)
    reader, writer = IO.pipe
    pid = Process.spawn(*argv, :out => writer, :err => writer, :in => File::NULL)
    writer.close
    output = ''.b
    status = nil
    begin
      loop do
        tick(deadline)
        if IO.select([reader], nil, nil, 0.02)
          begin
            data = reader.read_nonblock(4096)
            output << data.byteslice(0, [8192 - output.bytesize, 0].max)
          rescue IO::WaitReadable, EOFError
          end
        end
        done = Process.waitpid(pid, Process::WNOHANG)
        if done
          status = $?
          pid = nil
          break
        end
      end
      # Drain a bounded tail without waiting on an inherited pipe.
      begin
        loop do
          data = reader.read_nonblock(4096)
          output << data.byteslice(0, [8192 - output.bytesize, 0].max)
        end
      rescue IO::WaitReadable, EOFError
      end
      [status.success?, output.force_encoding('UTF-8').scrub, status.exitstatus]
    ensure
      writer.close unless writer.closed?
      reader.close
      if pid
        begin
          Process.kill('TERM', pid)
          limit = now + 0.2
          loop do
            if Process.waitpid(pid, Process::WNOHANG)
              pid = nil
              break
            end
            break if now >= limit
            sleep 0.01
          end
          if pid
            begin
              Process.kill('KILL', pid)
              Process.waitpid(pid)
            rescue Errno::ESRCH, Errno::ECHILD
            end
          end
        rescue Errno::ESRCH, Errno::ECHILD
        end
      end
    end
  rescue Errno::ENOENT, Errno::EACCES
    raise Unknown, 'metadata_command_unavailable'
  end

  def self.safe_relative(path)
    raise Unknown, 'unsafe_path' unless path.is_a?(String) && path.valid_encoding? &&
      !path.empty? && path.bytesize < 2048 && !path.start_with?('/') &&
      !path.match(/[\x00-\x1f\x7f\\]/) && path.split('/').all? { |p| !['', '.', '..'].include?(p) }
    path
  end

  def self.identity(stat)
    [stat.dev, stat.ino, stat.size, stat.mtime, stat.ctime, stat.mode]
  end

  # Refuse linked parents and linked files. Link entries themselves are checked separately.
  def self.locate(root, relative)
    parts = safe_relative(relative).split('/')
    parts[0...-1].inject(root) do |parent, part|
      child = File.join(parent, part)
      s = File.lstat(child)
      raise Unknown, 'linked_or_non_directory_parent' unless s.directory? && !s.symlink?
      child
    end
    File.join(root, relative)
  end

  def self.read_small(path, maximum = MAX_MANIFEST)
    flags = File::RDONLY | File::NOFOLLOW | File::NONBLOCK
    File.open(path, flags) do |f|
      s = f.stat
      raise Unknown, 'invalid_metadata_file' unless s.file? && s.size <= maximum
      bytes = f.read(maximum + 1)
      raise Unknown, 'metadata_changed' unless bytes.bytesize == s.size && identity(s) == identity(f.stat)
      bytes
    end
  end

  def self.cpu(value)
    {7 => 'x86', 0x01000007 => 'x86_64', 12 => 'arm', 0x0100000c => 'arm64'}[value] || "cpu-#{value}"
  end

  def self.format(header)
    magic = header.byteslice(0, 4)
    if ["\xce\xfa\xed\xfe".b, "\xcf\xfa\xed\xfe".b, "\xfe\xed\xfa\xce".b, "\xfe\xed\xfa\xcf".b].include?(magic)
      raise Unknown, 'truncated_macho' if header.bytesize < 28
      endian = magic.start_with?("\xfe".b) ? 'N' : 'V'
      return {'format' => 'Mach-O', 'architectures' => [cpu(header.byteslice(4, 4).unpack(endian).first)]}
    end
    if ["\xca\xfe\xba\xbe".b, "\xca\xfe\xba\xbf".b].include?(magic)
      count = header.byteslice(4, 4).to_s.unpack('N').first
      raise Unknown, 'invalid_fat_macho' unless count && (1..16).include?(count)
      stride = magic == "\xca\xfe\xba\xbf".b ? 32 : 20
      raise Unknown, 'truncated_fat_macho' if header.bytesize < 8 + count * stride
      return {'format' => 'Mach-O', 'architectures' => count.times.map { |i| cpu(header.byteslice(8 + stride * i, 4).unpack('N').first) }.sort}
    end
    if header.start_with?('MZ')
      return {'format' => 'data', 'architectures' => []} if header.bytesize < 64
      offset = header.byteslice(60, 4).unpack('V').first
      return {'format' => 'data', 'architectures' => []} unless offset <= 1024 * 1024 && header.byteslice(offset, 4) == "PE\0\0".b
      machine = header.byteslice(offset + 4, 2).to_s.unpack('v').first
      architecture = {0x14c => 'x86', 0x8664 => 'x86_64', 0xaa64 => 'arm64'}[machine] || "machine-#{machine}"
      return {'format' => 'PE', 'architectures' => [architecture]}
    end
    {'format' => 'data', 'architectures' => []}
  end

  def self.critical?(path)
    !!(path.match(/\A(?:version|engine-manifest\.json|cyder-graphics-provenance\.json|bin\/(wine|wine64|wineloader|wineserver))\z/) ||
       path.match(/\/(ntdll|kernel32|kernelbase|winemac|d3d11|dxgi|winemetal)\.(dll|so)\z/))
  end

  # Ruby 2.6 TarReader asks for pos/seek even for a sequential tar stream.
  class SequentialTar
    def initialize(io); @io = io; @position = 0; end
    def pos; @position; end
    def read(length = nil)
      bytes = @io.read(length)
      @position += bytes.bytesize if bytes
      bytes
    end
    def getc; read(1); end
    def eof?; @io.eof?; end
    def seek(*); raise Errno::EINVAL; end
  end

  def self.dxmt_install_key(archive_sha, policy_id, rows, display_version)
    policy = rows.select { |r| r['format'] == 'Mach-O' }.sort_by { |r| r['path'] }.map do |r|
      [r['path'], r['signature'], r['teamIdentifier'], r['requireTimestamp'], r['upstream']]
    end
    display_version + '-' + Digest::SHA256.hexdigest(JSON.generate([archive_sha, policy_id, policy]))
  end

  def self.inventory(archive, expected_sha, prefix, component, version, zstd = nil)
    raise SourceMismatch, 'archive_digest_mismatch' unless expected_sha.match(/\A[0-9a-f]{64}\z/) && Digest::SHA256.file(archive).hexdigest == expected_sha
    raise Unknown, 'invalid_component' unless %w[engine dxvk dxmt].include?(component)
    safe_relative(prefix)
    rows = []
    provenance = nil
    hardlinks = []
    seen = {}
    decompressor = if archive.end_with?('.tar.zst')
      raise Unknown, 'missing_zstd' unless zstd && File.executable?(zstd)
      [zstd, '-dc', archive]
    elsif archive.end_with?('.tar.xz')
      xz = ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).map { |dir| File.join(dir, 'xz') }.find { |path| File.file?(path) && File.executable?(path) }
      raise Unknown, 'missing_xz' unless xz
      [File.realpath(xz), '-dc', archive]
    elsif archive.end_with?('.tar')
      ['/bin/cat', archive]
    else
      raise Unknown, 'unsupported_archive'
    end
    # Streaming inventory never extracts archive paths or executes its contents.
    Open3.popen3(*decompressor) do |stdin, stream, errors, wait|
      stdin.close
      error_reader = Thread.new do
        begin
          loop { errors.readpartial(4096) }
        rescue EOFError, IOError
        end
      end # decompressor errors are not included in reports
      long_name = nil
      long_link = nil
      pax = {}
      Gem::Package::TarReader.new(SequentialTar.new(stream)) do |tar|
        tar.each do |entry|
          type = entry.header.typeflag
          if type == 'L'
            long_name = entry.read.sub(/\0.*\z/m, '')
            next
          elsif type == 'K'
            long_link = entry.read.sub(/\0.*\z/m, '')
            next
          elsif type == 'x' || type == 'g'
            payload = entry.read
            position = 0
            while position < payload.bytesize
              length = payload[position..-1].to_i
              raise Unknown, 'invalid_pax' unless length > 0
              row = payload.byteslice(position, length)
              pair = row.sub(/\A\d+ /, '').chomp.split('=', 2)
              pax[pair[0]] = pair[1]
              position += length
            end
            next
          end
          name = pax['path'] || long_name || entry.full_name
          name = name.sub(/\A\.\//, '').sub(/\/\z/, '')
          link = pax['linkpath'] || long_link || entry.header.linkname
          long_name = nil
          long_link = nil
          pax = {}
          # AppleDouble sidecars describe macOS metadata, not installed payload files.
          next if File.basename(name).start_with?('._')
          next if name == prefix && entry.directory?
          raise Unknown, "archive_outside_component: #{name.inspect}" unless name.start_with?(prefix + '/')
          relative = safe_relative(name[(prefix.length + 1)..-1])
          next if entry.directory?
          # These roots are supplied and linked by separate versioned graphics payloads.
          next if component == 'engine' && relative.match(/\Alib\/(dxvk|dxmt)(\/|\z)/)
          next if File.basename(relative).start_with?('.cyder-')
          raise Unknown, 'duplicate_archive_entry' if seen[relative]
          seen[relative] = true
          raise Unknown, 'inventory_too_large' if seen.length > MAX_FILES
          if type == '2'
            target = link
            raise Unknown, 'invalid_link' if target.match(/[\x00-\x1f]/)
            row = {'path' => relative, 'kind' => 'symlink', 'target' => target, 'critical' => critical?(relative)}
            if component == 'engine' && relative == 'lib/wine/x86_64-unix/libMoltenVK.real.dylib'
              row['allowedTargets'] = ['libMoltenVK-1.4.2.dylib', 'libMoltenVK-1.2.10.dylib']
            end
            rows << row
          elsif type == '1'
            target = link.sub(/\A\.\//, '')
            raise Unknown, 'invalid_hardlink' unless target.start_with?(prefix + '/')
            hardlinks << [relative, safe_relative(target[(prefix.length + 1)..-1])]
          elsif entry.file?
            digest = Digest::SHA256.new
            header = ''.b
            until entry.eof?
              bytes = entry.read(CHUNK)
              digest.update(bytes)
              header << bytes.byteslice(0, [1024 * 1024 + 512 - header.bytesize, 0].max)
            end
            if component == 'dxmt' && relative == GRAPHICS_META
              raise Unknown, 'oversized_graphics_provenance' if entry.header.size > 1024 * 1024
              provenance = JSON.parse(header)
            end
            info = format(header)
            rows << info.merge('path' => relative, 'kind' => 'file', 'size' => entry.header.size,
                               'sha256' => digest.hexdigest, 'signature' => info['format'] == 'Mach-O' ? 'verify' : 'not-required',
                               'critical' => critical?(relative))
          else
            raise Unknown, 'unsupported_archive_entry'
          end
        end
      end
      error_reader.join
      raise Unknown, 'archive_read_failed' unless wait.value.success?
    end
    hardlinks.length.times do
      hardlinks.delete_if do |path, target|
        source = rows.find { |r| r['path'] == target && r['kind'] == 'file' }
        if source
          rows << source.merge('path' => path, 'critical' => critical?(path))
          true
        else
          false
        end
      end
    end
    raise Unknown, 'unresolved_hardlink' unless hardlinks.empty?
    # A critical link must also cover its in-component target in quick mode.
    lookup = rows.each_with_object({}) { |row, h| h[row['path']] = row }
    queue = rows.select { |r| r['critical'] && r['kind'] == 'symlink' }
    until queue.empty?
      link = queue.shift
      target = File.expand_path(link['target'], '/' + File.dirname(link['path'])).sub(/\A\//, '')
      row = lookup[target]
      raise Unknown, 'external_critical_link' unless row
      unless row['critical']
        row['critical'] = true
        queue << row if row['kind'] == 'symlink'
      end
    end
    raise Unknown, 'empty_inventory' if rows.empty?
    apply_graphics_policy(rows, component, version, provenance)
    source = {'component' => component, 'version' => version, 'archive' => File.basename(archive), 'archiveSHA256' => expected_sha}
    if component == 'dxmt'
      source['displayVersion'] = provenance ? provenance.fetch('upstream').fetch('version').sub(/\Av/, '') : version
      source['signaturePolicy'] = 'dxmt-policy-v2'
      source['installKey'] = dxmt_install_key(expected_sha, source['signaturePolicy'], rows, source['displayVersion'])
    end
    {'schemaVersion' => VERSION, 'source' => source, 'files' => rows.sort_by { |r| r['path'] },
     'provenance' => provenance}.reject { |_, v| v.nil? }
  end

  # No broad unsigned exception: one reviewed upstream file/version/digest only.
  def self.upstream_unsigned?(row, source)
    source['component'] == 'dxmt' && source['version'] == '0.80' && row['path'] == DXMT_NATIVE &&
      row['sha256'] == DXMT_UPSTREAM['fileSHA256'] && row['format'] == 'Mach-O' &&
      row['architectures'] == ['x86_64'] && row['upstream'] == DXMT_UPSTREAM
  end

  def self.apply_graphics_policy(rows, component, version, provenance)
    return unless component == 'dxmt'
    if provenance
      raise Unknown, 'invalid_graphics_provenance' unless provenance['schemaVersion'] == 1 &&
        provenance['component'] == 'dxmt' && provenance['channel'] == 'release' &&
        provenance['packageVersion'] == version && version.match(/\A0\.80-cyder\.[1-9][0-9]*\z/) &&
        provenance['teamIdentifier'] == TEAM && provenance['requireTimestamp'] == true && provenance['upstream'] == DXMT_UPSTREAM &&
        provenance['signingIdentifier'] == "local.cyder.dxmt.#{version}.winemetal"
      files = provenance['files']
      payload = rows.reject { |r| r['path'] == GRAPHICS_META }
      raise Unknown, 'missing_or_unreviewed_graphics_native' unless payload.select { |r| r['format'] == 'Mach-O' }.map { |r| r['path'] } == [DXMT_NATIVE]
      raise Unknown, 'invalid_graphics_inventory' unless files.is_a?(Array) && files.length == payload.length &&
        files.map { |f| f['path'] }.uniq.length == files.length &&
        files.map { |f| f['path'] }.sort == payload.map { |f| f['path'] }.sort
      payload.each do |row|
        original = files.find { |f| f['path'] == row['path'] }
        raise Unknown, 'graphics_content_mismatch' unless row['kind'] == 'file' && original['sha256'] == row['sha256'] && original['size'] == row['size']
        if row['format'] == 'Mach-O'
          raise Unknown, 'unreviewed_graphics_native' unless row['path'] == DXMT_NATIVE && original['signature'] == 'developer-id' &&
            original['sourceSHA256'] == DXMT_UPSTREAM['fileSHA256'] && row['architectures'] == ['x86_64']
          row.merge!('signature' => 'developer-id', 'teamIdentifier' => TEAM, 'requireTimestamp' => true, 'upstream' => DXMT_UPSTREAM)
        else
          raise Unknown, 'unexpected_graphics_transformation' unless original['sourceSHA256'] == row['sha256'] && original['signature'] == 'not-required'
        end
      end
    else
      row = rows.find { |r| r['path'] == DXMT_NATIVE }
      if row
        candidate = row.merge('upstream' => DXMT_UPSTREAM)
        if upstream_unsigned?(candidate, {'component' => component, 'version' => version})
          row.merge!('signature' => 'upstream-unsigned', 'upstream' => DXMT_UPSTREAM)
        end
      end
    end
  end

  def self.valid_signature_policy?(row, source)
    return row['signature'] == 'not-required' unless row['format'] == 'Mach-O'
    case row['signature']
    when 'verify' then true
    when 'upstream-unsigned' then upstream_unsigned?(row, source)
    when 'developer-id'
      source['component'] == 'dxmt' && source['version'].match(/\A0\.80-cyder\.[1-9][0-9]*\z/) &&
        row['path'] == DXMT_NATIVE && row['architectures'] == ['x86_64'] && row['teamIdentifier'] == TEAM &&
        row['requireTimestamp'] == true && row['upstream'] == DXMT_UPSTREAM
    else false
    end
  end

  def self.developer_signature(path, deadline, package_version)
    raise Unknown, 'invalid_package_revision' unless package_version.match(/\A0\.80-cyder\.[1-9][0-9]*\z/)
    raise Unknown, 'unsafe_signature_path' if path.match(/[\x00-\x1f\x7f]/)
    requirement = "=anchor apple generic and certificate leaf[subject.OU] = \"#{TEAM}\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
    requirement += " and identifier \"local.cyder.dxmt.#{package_version}.winemetal\""
    good, detail = command(['/usr/bin/codesign', '--verify', '--strict', '-R', requirement, path], deadline)
    return 'unknown' if !good && detail.match(/CSSMERR|errSec|operation not permitted/i)
    return 'policy_mismatch' unless good
    good, description = command(['/usr/bin/codesign', '-dv', '--verbose=4', path], deadline)
    return 'unknown' unless good
    description.lines.any? { |l| l.start_with?('Timestamp=') && !['', 'none', 'not set'].include?(l.split('=', 2)[1].to_s.strip) } ? 'valid' : 'policy_mismatch'
  end

  def self.signature(path, deadline)
    good, detail = command(['/usr/bin/codesign', '--verify', '--strict', path], deadline)
    return 'valid' if good
    return 'unsigned' if detail.match(/code object is not signed at all/)
    return 'unknown' if detail.match(/CSSMERR|errSec|service.*unavailable|operation not permitted/i)
    detail.match(/invalid signature|not signed at all|invalid.*(format|object)|code object is not signed|unrecognized|modified|not a bundle/i) ? 'invalid' : 'unknown'
  end

  def self.scan(bytes, root, expected_sha, expected_source, depth, deadline, checker = method(:signature))
    started = now
    raise SourceMismatch, 'manifest_digest_mismatch' unless Digest::SHA256.hexdigest(bytes) == expected_sha
    manifest = JSON.parse(bytes)
    raise SourceMismatch, 'component_source_mismatch' unless manifest['source'] == expected_source
    rows = manifest['files']
    raise Unknown, 'invalid_manifest' unless manifest['schemaVersion'] == VERSION && rows.is_a?(Array) && (1..MAX_FILES).include?(rows.length)
    paths = rows.map { |r| safe_relative(r.fetch('path')) }
    raise Unknown, 'duplicate_manifest_path' unless paths.uniq.length == paths.length
    root = File.realpath(root)
    result = []
    bytes_read = 0
    selected = depth == 'quick' ? rows.select { |r| r['critical'] == true } : rows
    raise Unknown, 'no_critical_inventory' if selected.empty?
    selected.each do |row|
      tick(deadline)
      status = 'ok'
      reason = nil
      signature_evidence = nil
      content_evidence = nil
      begin
        path = locate(root, row['path'])
        stat = File.lstat(path)
        if row['kind'] == 'symlink'
          allowed = row['allowedTargets'] || [row['target']]
          status = 'content_mismatch' unless stat.symlink? && allowed.include?(File.readlink(path))
        elsif row['kind'] == 'file'
          raise Unknown, 'unexpected_file_type' unless stat.file? && !stat.symlink?
          raise Unknown, 'invalid_file_policy' unless row['sha256'].is_a?(String) && row['sha256'].match(/\A[0-9a-f]{64}\z/) &&
            %w[Mach-O PE data].include?(row['format']) && row['architectures'].is_a?(Array) &&
            valid_signature_policy?(row, expected_source)
          digest = Digest::SHA256.new
          header = ''.b
          File.open(path, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |file|
            raise Unknown, 'file_replaced' unless identity(file.stat) == identity(stat)
            loop do
              tick(deadline)
              chunk = file.read(CHUNK)
              break unless chunk
              digest.update(chunk)
              bytes_read += chunk.bytesize
              header << chunk.byteslice(0, [1024 * 1024 + 512 - header.bytesize, 0].max)
            end
            raise Unknown, 'file_changed_during_read' unless identity(file.stat) == identity(stat)
          end
          info = format(header)
          if digest.hexdigest != row['sha256'] || stat.size != row['size'] || info['format'] != row['format'] || info['architectures'] != row['architectures']
            status = 'content_mismatch'
          else
            content_evidence = 'match'
            if row['signature'] == 'upstream-unsigned'
              signature_evidence = 'unsigned'
              reason = 'reviewed_upstream_unsigned_original'
            elsif %w[verify developer-id].include?(row['signature'])
              sig = checker.call(path, deadline)
              signature_evidence = sig
              status = sig == 'valid' ? 'ok' : (sig == 'unsigned' ? 'signature_unsigned' : (sig == 'invalid' ? 'signature_invalid' : 'unknown'))
              reason = 'signature_not_present' if sig == 'unsigned'
              reason = 'signature_verifier_unavailable' if status == 'unknown'
              if sig == 'valid' && row['signature'] == 'developer-id'
                policy = developer_signature(path, deadline, expected_source['version'])
                status = policy == 'valid' ? 'ok' : (policy == 'unknown' ? 'unknown' : 'signature_policy_mismatch')
                reason = 'publisher_or_timestamp_unverified' unless policy == 'valid'
              end
            end
          end
          raise Unknown, 'file_changed_during_check' unless identity(File.lstat(path)) == identity(stat)
        else
          raise Unknown, 'invalid_entry_kind'
        end
      rescue Errno::ENOENT
        status = 'missing'
      rescue Expired, Cancelled
        raise
      rescue Unknown, SystemCallError, IOError
        status = 'unknown'
        reason = 'unreadable_or_changed'
      end
      result << {'path' => row['path'], 'status' => status, 'reason' => reason, 'content' => content_evidence, 'signature' => signature_evidence,
                 'signaturePolicy' => signature_evidence ? row['signature'] : nil,
                 'policyResult' => signature_evidence ? (status == 'ok' ? 'allowed' : (status == 'unknown' ? 'unknown' : 'rejected')) : nil}.reject { |_, v| v.nil? }
    end
    {'component' => expected_source['component'], 'version' => expected_source['displayVersion'] || expected_source['version'], 'depth' => depth,
     'status' => result.any? { |r| r['status'] == 'unknown' } ? 'unknown' : (result.all? { |r| r['status'] == 'ok' } ? 'ok' : 'mismatch'),
     'checked' => result.length, 'inventoryCount' => rows.length, 'bytesRead' => bytes_read,
     'elapsedMs' => ((now - started) * 1000).round, 'files' => result}
  rescue SourceMismatch => e
    {'component' => expected_source['component'], 'status' => 'source_mismatch', 'reason' => e.message}
  rescue Expired, Cancelled => e
    {'component' => expected_source['component'], 'status' => 'unknown', 'reason' => e.is_a?(Expired) ? 'timeout' : 'cancelled',
     'checked' => result ? result.length : 0, 'bytesRead' => bytes_read || 0}
  rescue Errno::ENOENT
    {'component' => expected_source['component'], 'status' => 'missing', 'reason' => 'component_not_installed'}
  rescue Unknown, JSON::ParserError, KeyError, TypeError, SystemCallError, IOError
    {'component' => expected_source['component'], 'status' => 'unknown', 'reason' => 'invalid_or_unavailable_inventory'}
  end

  def self.bundle_trust(resources, deadline)
    resources = File.realpath(resources)
    app = File.dirname(File.dirname(resources))
    raise Unknown, 'not_app_resources' unless File.basename(app).end_with?('.app') && resources == File.join(app, 'Contents/Resources')
    # A denied/unavailable system trust service cannot establish signature failure.
    control, = command(['/usr/bin/codesign', '--verify', '--strict', '/usr/bin/true'], deadline)
    raise Unknown, 'system_signature_verifier_unavailable' unless control
    good, detail = command(['/usr/bin/codesign', '--verify', '--deep', '--strict', app], deadline)
    raise Unknown, 'system_signature_verifier_unavailable' if !good && detail.match(/CSSMERR|errSec|operation not permitted/i)
    raise SourceMismatch, 'bundle_signature_invalid' unless good
    # Enforce a Security.framework requirement, never parse a path-containing
    # display string as publisher evidence (filenames may contain newlines).
    requirement = "=anchor apple generic and certificate leaf[subject.OU] = \"#{TEAM}\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
    publisher, = command(['/usr/bin/codesign', '--verify', '--strict', '-R', requirement, app], deadline)
    raise Unknown, 'publisher_unverified' unless publisher
    resources
  end

  def self.dxmt_current_root(runtime, source)
    base = File.join(File.realpath(runtime), 'graphics', 'dxmt')
    [File.dirname(base), base].each do |directory|
      raise Unknown, 'graphics_directory_linked' if File.symlink?(directory)
    end
    selection = safe_relative(source['installKey'] || source['version'])
    # Current is a selector, never a trust root. scan still checks every expected digest/policy.
    current = File.join(File.realpath(runtime), 'graphics', 'current-dxmt')
    return File.join(base, selection) unless File.symlink?(current)
    target = File.realpath(current)
    raise Unknown, 'graphics_link_outside_runtime' unless target.start_with?(base + '/') && File.realpath(base) == base
    target
  end

  def self.diagnose(resources, runtime, engine, component, depth, budget)
    deadline = now + budget
    resources = bundle_trust(resources, deadline)
    index = JSON.parse(read_small(locate(resources, 'component-manifests/index.json'), 65536))
    raise Unknown, 'invalid_index' unless index['schemaVersion'] == VERSION && index['components'].is_a?(Hash)
    names = component == 'all' ? %w[engine dxvk dxmt] : [component]
    reports = names.map do |name|
      spec = index['components'][name]
      if !spec
        {'component' => name, 'status' => 'unknown', 'reason' => 'inventory_not_shipped'}
      else
        raise Unknown, 'invalid_component_source' unless spec['source'].is_a?(Hash) && spec['source']['component'] == name &&
          spec['source']['version'].is_a?(String) && (1..128).include?(spec['source']['version'].bytesize) &&
          !spec['source']['version'].match(/[\x00-\x1f\x7f]/) &&
          (name == 'engine' || spec['source']['version'].match(/\A[A-Za-z0-9._-]+\z/))
        root = if name == 'engine'
          engine
        elsif name == 'dxmt' && spec['source']['installKey']
          dxmt_current_root(runtime, spec['source'])
        else
          File.join(runtime, 'graphics', name, spec['source']['version'])
        end
        bytes = read_small(locate(resources, "component-manifests/#{name}.json"))
        scan(bytes, root, spec['manifestSHA256'], spec['source'], depth, deadline)
      end
    end
    {'schemaVersion' => VERSION, 'trust' => 'verified-publisher', 'depth' => depth,
     'status' => reports.all? { |r| r['status'] == 'ok' } ? 'ok' : (reports.any? { |r| %w[mismatch missing source_mismatch].include?(r['status']) } ? 'mismatch' : 'unknown'),
     'components' => reports, 'notice' => 'Read-only integrity evidence; not antivirus or game acceptance.'}
  rescue SourceMismatch => e
    {'status' => 'source_mismatch', 'reason' => e.message, 'components' => []}
  rescue Expired, Cancelled => e
    {'status' => 'unknown', 'reason' => e.is_a?(Cancelled) ? 'cancelled' : 'timeout', 'components' => []}
  rescue Unknown => e
    reasons = %w[publisher_unverified system_signature_verifier_unavailable not_app_resources invalid_index invalid_component_source]
    {'status' => 'unknown', 'reason' => reasons.include?(e.message) ? e.message : 'trust_or_inventory_unavailable', 'components' => []}
  rescue SystemCallError, JSON::ParserError, TypeError
    {'status' => 'unknown', 'reason' => 'trust_or_inventory_unavailable', 'components' => []}
  end
end

if __FILE__ == $PROGRAM_NAME
  begin
    options = {'depth' => 'quick', 'component' => 'all', 'budget' => 5.0}
    action = ARGV.shift
    OptionParser.new do |p|
      %w[resources runtime engine archive sha256 prefix component version zstd depth output].each { |key| p.on("--#{key} VALUE") { |v| options[key] = v } }
      p.on('--summary') { options['summary'] = true }
      p.on('--budget SECONDS', Float) { |v| options['budget'] = v }
    end.parse!
    raise CyderIntegrity::Unknown, 'invalid_arguments' unless ARGV.empty?
    if action == 'inventory'
      result = CyderIntegrity.inventory(*%w[archive sha256 prefix component version].map { |k| options.fetch(k) }, options['zstd'])
      bytes = JSON.pretty_generate(result) + "\n"
      File.write(options.fetch('output'), bytes)
    elsif action == 'check'
      raise CyderIntegrity::Unknown, 'invalid_arguments' unless %w[quick full].include?(options['depth']) &&
        %w[all engine dxvk dxmt].include?(options['component']) && options['budget'] > 0 && options['budget'] <= 300
      Signal.trap('TERM') { raise CyderIntegrity::Cancelled }
      Signal.trap('INT') { raise CyderIntegrity::Cancelled }
      result = CyderIntegrity.diagnose(*%w[resources runtime engine component depth budget].map { |k| options.fetch(k) })
      if options['summary']
        (result['components'] || []).each do |component|
          files = component.delete('files') || []
          component['fileStatuses'] = files.group_by { |f| f['status'] }.transform_values(&:length)
          component['signaturePolicies'] = files.select { |f| f['signaturePolicy'] }.group_by { |f| f['signaturePolicy'] }.transform_values(&:length)
        end
      end
      puts JSON.generate(result)
      exit(result['status'] == 'ok' ? 0 : (result['status'] == 'unknown' ? 3 : 2))
    else
      raise CyderIntegrity::Unknown, 'unknown_action'
    end
  rescue StandardError
    puts JSON.generate('status' => 'unknown', 'reason' => 'invalid_or_unavailable_input', 'components' => [])
    exit 3
  end
end
