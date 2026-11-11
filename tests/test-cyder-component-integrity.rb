#!/usr/bin/ruby
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require_relative '../scripts/cyder-component-integrity'

class ComponentIntegrityTest < Minitest::Test
  C = CyderIntegrity
  def setup
    @temp = Dir.mktmpdir('cyder-integrity-')
    @root = File.join(@temp, 'installed')
    FileUtils.mkdir_p(@root)
    @pe = 'MZ'.b + "\0" * 62
    @pe[60, 4] = [64].pack('V')
    @pe << "PE\0\0".b << [0x8664].pack('v') << "\0" * 50
    @macho = [0xfeedfacf, 0x0100000c].pack('V2') + "\0" * 24
    @contents = {'bin/wine' => '#!/bin/sh\nnever execute', 'lib/wine/x86_64-windows/ntdll.dll' => @pe,
                 'lib/wine/x86_64-unix/driver.so' => @macho, 'share/data' => 'data'}
    write_archive
    @manifest = C.inventory(@archive, Digest::SHA256.file(@archive).hexdigest, 'wine-x86_64', 'engine', 'test-v1')
    @contents.each do |path, bytes|
      FileUtils.mkdir_p(File.dirname(File.join(@root, path)))
      File.binwrite(File.join(@root, path), bytes)
    end
  end
  def teardown; FileUtils.remove_entry(@temp); end
  def write_archive(extra = nil)
    @archive = File.join(@temp, 'engine.tar')
    File.open(@archive, 'wb') do |io|
      Gem::Package::TarWriter.new(io) do |tar|
        @contents.each { |path, bytes| tar.add_file_simple("wine-x86_64/#{path}", 0644, bytes.bytesize) { |f| f.write(bytes) } }
        extra.call(tar) if extra
      end
    end
  end
  def scan(depth = 'full', checker = ->(_, _) { 'valid' }, deadline = C.now + 3)
    bytes = JSON.generate(@manifest)
    C.scan(bytes, @root, Digest::SHA256.hexdigest(bytes), @manifest['source'], depth, deadline, checker)
  end
  def snapshot
    Dir.glob(File.join(@temp, '**/*'), File::FNM_DOTMATCH).sort.map do |p|
      stat = File.lstat(p)
      [p, stat.mode, stat.mtime, stat.ctime, stat.file? ? Digest::SHA256.file(p).hexdigest : nil]
    end
  end
  def test_healthy_and_read_only
    before = snapshot
    result = scan
    assert_equal 'ok', result['status']
    assert_equal 4, result['checked']
    assert_equal before, snapshot
    assert_equal 'PE', @manifest['files'].find { |f| f['path'].end_with?('ntdll.dll') }['format']
    assert_equal ['x86_64'], @manifest['files'].find { |f| f['format'] == 'PE' }['architectures']
    assert_equal ['arm64'], @manifest['files'].find { |f| f['format'] == 'Mach-O' }['architectures']
  end
  def test_unsigned_pe_does_not_call_codesign
    calls = []
    result = scan('full', ->(path, _) { calls << path; 'valid' })
    assert_equal 'ok', result['status']
    assert_equal ['driver.so'], calls.map { |p| File.basename(p) }
  end
  def test_missing_file_and_component
    File.unlink(File.join(@root, 'bin/wine'))
    assert_equal 'missing', scan['files'].find { |f| f['path'] == 'bin/wine' }['status']
    assert_equal 'mismatch', scan['status']
    FileUtils.remove_entry(@root)
    assert_equal 'missing', scan['status']
  end
  def test_modified_and_wrong_format
    File.binwrite(File.join(@root, 'bin/wine'), 'tampered')
    assert_equal 'content_mismatch', scan['files'].first['status']
  end
  def test_source_and_manifest_digest_are_external_trust_inputs
    bytes = JSON.generate(@manifest)
    assert_equal 'source_mismatch', C.scan(bytes, @root, '0' * 64, @manifest['source'], 'full', C.now + 1)['status']
    source = @manifest['source'].merge('version' => 'another')
    assert_equal 'source_mismatch', C.scan(bytes, @root, Digest::SHA256.hexdigest(bytes), source, 'full', C.now + 1)['status']
    # A forged marker beside the runtime cannot override the expected manifest digest.
    File.write(File.join(@root, '.cyder-engine-artifact-sha256'), '0' * 64)
    assert_equal 'ok', scan['status']
  end
  def test_invalid_signature_and_unavailable_checker
    invalid = scan('full', ->(_, _) { 'invalid' })
    assert_equal 'signature_invalid', invalid['files'].find { |f| f['path'].end_with?('driver.so') }['status']
    unknown = scan('full', ->(_, _) { raise C::Unknown })
    assert_equal 'unknown', unknown['status']
    assert_equal 'signature_unsigned', scan('full', C.method(:signature))['files'].find { |f| f['path'].end_with?('driver.so') }['status']
  end
  def test_quick_checks_only_critical_entries
    File.unlink(File.join(@root, 'share/data'))
    result = scan('quick', ->(*) { flunk 'non-critical Mach-O should not be inspected' })
    assert_equal 'ok', result['status']
    assert_equal 2, result['checked']
    assert_equal 4, result['inventoryCount']
    assert_equal 'mismatch', scan['status']
  end
  def test_read_errors_and_symlink_parent_never_followed
    directory = File.join(@root, 'lib/wine/x86_64-unix')
    moved = File.join(@temp, 'outside')
    File.rename(directory, moved)
    File.symlink(moved, directory)
    assert_equal 'unknown', scan['status']
    File.unlink(File.join(@root, 'bin/wine'))
    File.mkfifo(File.join(@root, 'bin/wine'))
    assert_equal 'unknown', scan['status'] # no blocking FIFO read
  end
  def test_timeout_and_cancellation_are_unknown
    assert_equal 'timeout', scan('full', ->(*) { 'valid' }, C.now - 1)['reason']
    assert_equal 'cancelled', scan('full', ->(*) { raise C::Cancelled })['reason']
    started = C.now
    assert_raises(C::Expired) { C.command(['/bin/sleep', '5'], C.now + 0.05) }
    assert_operator C.now - started, :<, 1
  end
  def test_changed_during_scan_is_unknown
    result = scan('full', lambda { |path, _| File.binwrite(path, 'changed'); 'valid' })
    assert_equal 'unknown', result['status']
  end
  def test_archive_checksum_traversal_and_duplicate_rejected
    assert_raises(C::SourceMismatch) { C.inventory(@archive, '0' * 64, 'wine-x86_64', 'engine', 'v') }
    ['wine-x86_64/../escape', 'wine-x86_64/bin/wine'].each do |path|
      write_archive(->(tar) { tar.add_file_simple(path, 0644, 1) { |f| f.write('x') } })
      assert_raises(C::Unknown) { C.inventory(@archive, Digest::SHA256.file(@archive).hexdigest, 'wine-x86_64', 'engine', 'v') }
    end
    refute File.exist?(File.join(@temp, 'escape'))
  end
  def test_critical_link_covers_target_and_detects_retarget
    @contents['libexec/loader'] = @contents.delete('bin/wine')
    write_archive(->(tar) { tar.add_symlink('wine-x86_64/bin/wine', '../libexec/loader', 0777) })
    @manifest = C.inventory(@archive, Digest::SHA256.file(@archive).hexdigest, 'wine-x86_64', 'engine', 'v')
    File.unlink(File.join(@root, 'bin/wine'))
    FileUtils.mkdir_p(File.join(@root, 'libexec'))
    File.write(File.join(@root, 'libexec/loader'), @contents['libexec/loader'])
    File.symlink('../libexec/loader', File.join(@root, 'bin/wine'))
    assert_equal 'ok', scan('quick')['status']
    File.write(File.join(@root, 'libexec/loader'), 'wrong')
    assert_equal 'mismatch', scan('quick')['status']
    File.unlink(File.join(@root, 'bin/wine'))
    File.symlink('/bin/echo', File.join(@root, 'bin/wine'))
    assert_equal 'content_mismatch', scan('quick')['files'].first['status']
  end
  def test_real_bundle_trust_rejects_unverified_source
    assert_raises(C::Unknown) { C.bundle_trust(@temp, C.now + 1) }
    resources = File.join(@temp, 'Unsigned.app/Contents/Resources')
    FileUtils.mkdir_p(resources)
    report = C.diagnose(resources, @temp, @root, 'all', 'full', 1)
    assert_includes ['source_mismatch', 'unknown'], report['status']
    refute report.key?('trust')
  end
  def test_publisher_policy_and_trust_service_failure
    resources = File.join(@temp, 'Signed.app/Contents/Resources')
    FileUtils.mkdir_p(resources)
    publisher = true
    command = lambda do |args, _|
      if args.include?('-R')
        requirement = args[args.index('-R') + 1]
        assert requirement.start_with?('=anchor apple generic'), 'codesign literal requirements require an equals prefix'
        assert_includes requirement, C::TEAM
        assert_includes requirement, '1.2.840.113635.100.6.1.13'
        [publisher, '']
      else
        [true, '']
      end
    end
    C.stub(:command, command) { assert_equal File.realpath(resources), C.bundle_trust(resources, C.now + 1) }
    publisher = false # Wrong publisher or ad-hoc signing cannot establish provenance.
    C.stub(:command, command) { assert_raises(C::Unknown) { C.bundle_trust(resources, C.now + 1) } }
    C.stub(:command, ->(*) { [false, 'CSSMERR_TP_NOT_TRUSTED'] }) do
      assert_raises(C::Unknown) { C.bundle_trust(resources, C.now + 1) }
      assert_equal 'unknown', C.signature('/unused', C.now + 1)
    end
  end
  def test_signed_index_binding_and_missing_coverage
    resources = File.join(@temp, 'Resources')
    directory = File.join(resources, 'component-manifests')
    FileUtils.mkdir_p(directory)
    bytes = JSON.generate(@manifest)
    File.write(File.join(directory, 'engine.json'), bytes)
    index = {'schemaVersion' => 1, 'components' => {'engine' => {'source' => @manifest['source'], 'manifestSHA256' => Digest::SHA256.hexdigest(bytes)}}}
    File.write(File.join(directory, 'index.json'), JSON.generate(index))
    C.stub(:bundle_trust, ->(path, _) { path }) do
      C.stub(:signature, ->(*) { 'valid' }) do
        # Explicit fixture trust seam; production CLI has no bypass switch.
        good = C.diagnose(resources, @temp, @root, 'engine', 'full', 1)
        assert_equal 'ok', good['status']
        partial = C.diagnose(resources, @temp, @root, 'all', 'full', 1)
        assert_equal 'unknown', partial['status']
        assert_equal 'inventory_not_shipped', partial['components'][1]['reason']
        File.write(File.join(directory, 'engine.json'), bytes + ' ')
        assert_equal 'source_mismatch', C.diagnose(resources, @temp, @root, 'engine', 'full', 1)['components'][0]['status']
      end
    end
    C.stub(:bundle_trust, ->(*) { raise C::Expired }) do
      assert_equal 'timeout', C.diagnose(resources, @temp, @root, 'all', 'full', 1)['reason']
    end
    C.stub(:bundle_trust, ->(*) { raise C::Cancelled }) do
      assert_equal 'cancelled', C.diagnose(resources, @temp, @root, 'all', 'full', 1)['reason']
    end
  end
  def test_builder_binds_all_archive_inventories_without_changing_inputs
    resources = File.join(@temp, 'build-resources')
    graphics = File.join(resources, 'graphics')
    tools = File.join(resources, 'tools/zstd')
    FileUtils.mkdir_p([graphics, tools])
    decoder = File.join(tools, 'zstd')
    # Offline tar fixtures; this stand-in only streams their bytes.
    File.write(decoder, "#!/bin/sh\nexec /bin/cat \"$2\"\n")
    File.chmod(0755, decoder)
    %w[engine dxvk dxmt].each do |component|
      directory = component == 'engine' ? resources : graphics
      archive = File.join(directory, "#{component}-v1.tar.zst")
      prefix = component == 'engine' ? 'wine-x86_64' : component
      File.open(archive, 'wb') do |io|
        Gem::Package::TarWriter.new(io) do |tar|
          tar.add_file_simple("#{prefix}/bin/wine", 0755, 4) { |f| f.write('data') }
        end
      end
      File.write(File.join(directory, "#{component}-version.txt"), 'v1')
      digest = Digest::SHA256.file(archive).hexdigest
      File.write(File.join(directory, "#{component}-artifact-sha256.txt"), component == 'engine' ? digest : "#{digest}  #{File.basename(archive)}")
      File.write(File.join(resources, 'engine-archive.txt'), File.basename(archive)) if component == 'engine'
    end
    before = Dir.glob(File.join(resources, '**/*')).select { |p| File.file?(p) }.map { |p| [p, Digest::SHA256.file(p).hexdigest] }
    script = File.expand_path('../scripts/build-component-manifests.rb', __dir__)
    output, status = Open3.capture2e('/usr/bin/ruby', script, resources)
    assert status.success?, output
    index = JSON.parse(File.read(File.join(resources, 'component-manifests/index.json')))
    assert_equal %w[dxmt dxvk engine], index['components'].keys.sort
    index['components'].each do |name, spec|
      bytes = File.read(File.join(resources, 'component-manifests', "#{name}.json"))
      assert_equal spec['manifestSHA256'], Digest::SHA256.hexdigest(bytes)
      assert_equal spec['source'], JSON.parse(bytes)['source']
    end
    before.each { |path, hash| assert_equal hash, Digest::SHA256.file(path).hexdigest }
    first_index = File.read(File.join(resources, 'component-manifests/index.json'))
    _, repeat = Open3.capture2e('/usr/bin/ruby', script, resources)
    assert repeat.success?
    assert_equal first_index, File.read(File.join(resources, 'component-manifests/index.json'))
    denied, formal = Open3.capture2e({'CYDER_GRAPHICS_CHANNEL' => 'release'}, '/usr/bin/ruby', script, resources)
    refute formal.success?, 'formal build must reject legacy unprovenanced graphics'
    assert_includes denied, 'Formal DXMT requires'
    marker = File.join(graphics, 'dxmt-version.txt')
    File.rename(marker, marker + '.saved')
    _, missing = Open3.capture2e({'CYDER_GRAPHICS_CHANNEL' => 'release', 'CYDER_ALLOW_MISSING_GRAPHICS' => '1'}, '/usr/bin/ruby', script, resources)
    refute missing.success?, 'formal build must not bypass graphics through the test-only missing override'
    File.rename(marker + '.saved', marker)
    File.write(File.join(resources, 'engine-artifact-sha256.txt'), '0' * 64)
    _, status = Open3.capture2e('/usr/bin/ruby', script, resources)
    refute status.success?, 'build must reject an archive with an invalid expected hash'
  end
  def test_supported_moltenvk_variant_is_not_a_content_change
    path = 'lib/wine/x86_64-unix/'
    @contents[path + 'libMoltenVK-1.4.2.dylib'] = 'new variant'
    @contents[path + 'libMoltenVK-1.2.10.dylib'] = 'old variant'
    @contents.each { |p, bytes| File.binwrite(File.join(@root, p), bytes) }
    write_archive(->(tar) { tar.add_symlink('wine-x86_64/' + path + 'libMoltenVK.real.dylib', 'libMoltenVK-1.4.2.dylib', 0777) })
    @manifest = C.inventory(@archive, Digest::SHA256.file(@archive).hexdigest, 'wine-x86_64', 'engine', 'v')
    alias_path = File.join(@root, path, 'libMoltenVK.real.dylib')
    File.symlink('libMoltenVK-1.2.10.dylib', alias_path)
    assert_equal 'ok', scan['status']
    File.unlink(alias_path)
    File.symlink('other.dylib', alias_path)
    assert_equal 'mismatch', scan['status']
  end
  def test_unsigned_exception_is_bound_to_reviewed_source_path_and_digest
    row = {'path' => C::DXMT_NATIVE, 'sha256' => C::DXMT_UPSTREAM['fileSHA256'], 'format' => 'Mach-O',
           'architectures' => ['x86_64'], 'upstream' => C::DXMT_UPSTREAM, 'signature' => 'upstream-unsigned'}
    source = {'component' => 'dxmt', 'version' => '0.80'}
    assert C.upstream_unsigned?(row, source)
    assert C.valid_signature_policy?(row, source)
    refute C.upstream_unsigned?(row, source.merge('version' => '0.80-cyder.1'))
    refute C.upstream_unsigned?(row.merge('sha256' => '0' * 64), source)
    refute C.upstream_unsigned?(row.merge('path' => 'other.so'), source)
    refute C.upstream_unsigned?(row.merge('upstream' => {}), source)
    # A fixture cannot gain the exception merely by declaring it in a manifest.
    @manifest['source'] = source
    @manifest['files'].find { |r| r['format'] == 'Mach-O' }['signature'] = 'upstream-unsigned'
    assert_equal 'unknown', scan['status']
  end
  def test_unsigned_and_invalid_signatures_are_distinct_from_content_mismatch
    unsigned = scan('full', ->(*) { 'unsigned' })
    row = unsigned['files'].find { |r| r['path'].end_with?('driver.so') }
    assert_equal 'signature_unsigned', row['status']
    assert_equal 'match', row['content']
    assert_equal 'unsigned', row['signature']
    assert_equal 'signature_invalid', scan('full', ->(*) { 'invalid' })['files'].find { |r| r['path'].end_with?('driver.so') }['status']
  end
  def test_developer_policy_enforces_team_and_timestamp
    row = @manifest['files'].find { |r| r['format'] == 'Mach-O' }
    old = File.join(@root, row['path'])
    row.merge!('path' => C::DXMT_NATIVE, 'signature' => 'developer-id', 'architectures' => ['arm64'],
      'upstream' => C::DXMT_UPSTREAM, 'teamIdentifier' => C::TEAM, 'requireTimestamp' => true)
    # Expected host format for this policy is x86_64. Update this isolated fixture's header and hash.
    @macho[4,4] = [0x01000007].pack('V')
    target = File.join(@root, C::DXMT_NATIVE)
    FileUtils.mkdir_p(File.dirname(target)); File.binwrite(target, @macho)
    row.merge!('architectures' => ['x86_64'], 'sha256' => Digest::SHA256.hexdigest(@macho))
    @manifest['source'] = {'component' => 'dxmt', 'version' => '0.80-cyder.1'}
    C.stub(:developer_signature, ->(*) { 'valid' }) { assert_equal 'ok', scan['status'] }
    C.stub(:developer_signature, ->(*) { 'policy_mismatch' }) do
      assert_equal 'signature_policy_mismatch', scan['files'].find { |f| f['path'] == C::DXMT_NATIVE }['status']
    end
    row['teamIdentifier'] = 'OTHER'
    assert_equal 'unknown', scan['status']
    check = lambda { |args, _| [true, args.include?('-dv') ? 'Timestamp=valid' : ''] }
    C.stub(:command, check) { assert_equal 'valid', C.developer_signature('/safe/path', C.now + 1, '0.80-cyder.1') }
    C.stub(:command, ->(*) { [true, 'Timestamp=none'] }) { assert_equal 'policy_mismatch', C.developer_signature('/safe/path', C.now + 1, '0.80-cyder.1') }
    C.stub(:command, ->(*) { [false, 'requirement failed'] }) { assert_equal 'policy_mismatch', C.developer_signature('/safe/path', C.now + 1, '0.80-cyder.1') }
  end
  def test_release_provenance_assigns_policy_and_rejects_forgery
    rows = Marshal.load(Marshal.dump(@manifest['files']))
    native = rows.find { |r| r['format'] == 'Mach-O' }
    native.merge!('path' => C::DXMT_NATIVE, 'architectures' => ['x86_64'])
    meta = {'schemaVersion' => 1, 'component' => 'dxmt', 'channel' => 'release', 'packageVersion' => '0.80-cyder.1',
      'upstream' => C::DXMT_UPSTREAM, 'teamIdentifier' => C::TEAM, 'requireTimestamp' => true,
      'signingIdentifier' => 'local.cyder.dxmt.0.80-cyder.1.winemetal',
      'files' => rows.map { |r| {'path' => r['path'], 'size' => r['size'], 'sha256' => r['sha256'],
        'sourceSHA256' => r['path'] == C::DXMT_NATIVE ? C::DXMT_UPSTREAM['fileSHA256'] : r['sha256'],
        'signature' => r['path'] == C::DXMT_NATIVE ? 'developer-id' : 'not-required'} }}
    C.apply_graphics_policy(rows, 'dxmt', '0.80-cyder.1', meta)
    assert_equal 'developer-id', native['signature']
    assert_equal C::TEAM, native['teamIdentifier']
    assert_equal true, native['requireTimestamp']
    forged = Marshal.load(Marshal.dump(meta)); forged['teamIdentifier'] = 'OTHER'
    assert_raises(C::Unknown) { C.apply_graphics_policy(rows, 'dxmt', '0.80-cyder.1', forged) }
    forged = Marshal.load(Marshal.dump(meta)); forged['files'].find { |r| r['path'] == C::DXMT_NATIVE }['sourceSHA256'] = '0' * 64
    assert_raises(C::Unknown) { C.apply_graphics_policy(rows, 'dxmt', '0.80-cyder.1', forged) }
    forged = Marshal.load(Marshal.dump(meta)); forged['files'].first['sha256'] = '0' * 64
    assert_raises(C::Unknown) { C.apply_graphics_policy(rows, 'dxmt', '0.80-cyder.1', forged) }
    assert_raises(C::Unknown) { C.apply_graphics_policy(rows, 'dxmt', '0.80-cyder.2', meta) }
  end
  def test_install_identity_binds_digest_policy_and_signer_without_changing_display_version
    rows = [{'path'=>'x86_64-unix/winemetal.so', 'format'=>'Mach-O', 'signature'=>'developer-id', 'teamIdentifier'=>C::TEAM, 'requireTimestamp'=>true}]
    key = C.dxmt_install_key('a'*64, 'v2', rows, '0.80')
    assert_match(/\A0\.80-[0-9a-f]{64}\z/, key)
    assert_equal key, C.dxmt_install_key('a'*64, 'v2', rows.reverse, '0.80')
    refute_equal key, C.dxmt_install_key('b'*64, 'v2', rows, '0.80')
    refute_equal key, C.dxmt_install_key('a'*64, 'v3', rows, '0.80')
    refute_equal key, C.dxmt_install_key('a'*64, 'v2', [rows[0].merge('teamIdentifier'=>'OTHER')], '0.80')
  end
  def test_fat_macho_and_legacy_mz
    fat = [0xcafebabe, 2, 0x0100000c, 0, 0, 0, 0, 0x01000007, 0, 0, 0, 0].pack('N*')
    assert_equal ['arm64', 'x86_64'], C.format(fat)['architectures']
    assert_equal 'data', C.format('MZ' + "\0" * 80)['format']
  end
end
