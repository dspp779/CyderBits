#!/usr/bin/ruby
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require_relative '../scripts/cyder-component-integrity'

class PrefixIntegrityTest < Minitest::Test
  C = CyderIntegrity
  def setup
    @temp = Dir.mktmpdir('cyder-prefix-integrity-')
    @engine = File.join(@temp, 'engine')
    @prefix = File.join(@temp, 'bottle-a')
    @source = {'component' => 'engine', 'version' => 'fixture', 'archiveSHA256' => 'a' * 64}
    @rows = %w[x86_64 i386].flat_map do |arch|
      %w[bcrypt.dll crypt32.dll wintrust.dll winemapi.dll control.exe].map do |name|
        pe = 'MZ'.b + "\0" * 62
        pe[60, 4] = [64].pack('V')
        pe << "PE\0\0".b << [arch == 'i386' ? 0x14c : 0x8664].pack('v') << name
        path = "lib/wine/#{arch}-windows/#{name}"
        destination = File.join(@engine, path)
        FileUtils.mkdir_p(File.dirname(destination))
        File.binwrite(destination, pe)
        C.format(pe).merge('path' => path, 'kind' => 'file', 'size' => pe.bytesize,
                          'sha256' => Digest::SHA256.hexdigest(pe), 'signature' => 'not-required', 'critical' => true)
      end
    end
    @bytes = JSON.generate('schemaVersion' => 1, 'source' => @source, 'files' => @rows)
    make_prefix(@prefix)
  end
  def teardown; FileUtils.remove_entry(@temp); end
  def make_prefix(prefix, arch = 'win64', links = false)
    FileUtils.mkdir_p(prefix)
    File.write(File.join(prefix, 'system.reg'), "WINE REGISTRY Version 2\n#arch=#{arch}\n")
    @rows.each do |row|
      x86 = row['path'].include?('i386-windows')
      next if arch == 'win32' && !x86
      directory = arch == 'win32' || !x86 ? 'system32' : 'syswow64'
      target = File.join(prefix, "drive_c/windows/#{directory}", File.basename(row['path']))
      FileUtils.mkdir_p(File.dirname(target))
      links ? File.symlink(File.join(@engine, row['path']), target) : FileUtils.cp(File.join(@engine, row['path']), target)
    end
  end
  def scan(prefix = @prefix, bytes = @bytes, sha = Digest::SHA256.hexdigest(bytes), deadline = C.now + 3)
    C.scan_prefix(bytes, prefix, @engine, sha, @source, 'quick', deadline)
  end
  def path(name = 'bcrypt.dll', dir = 'system32')
    File.join(@prefix, 'drive_c/windows', dir, name)
  end
  def snapshot
    Dir.glob(File.join(@temp, '**/*'), File::FNM_DOTMATCH).sort.map do |p|
      st = File.lstat(p)
      [p, C.identity(st), st.symlink? ? File.readlink(p) : (st.file? ? Digest::SHA256.file(p).hexdigest : nil)]
    end
  end
  def test_physical_copies_unsigned_pe_and_read_only
    before = snapshot
    C.stub(:signature, ->(*) { flunk 'PE must not invoke codesign' }) do
      result = scan
      assert_equal 'ok', result['status']
      assert_equal 10, result['checked']
      assert_equal ['file'], result['files'].map { |r| r['kind'] }.uniq
    end
    assert_equal before, snapshot
  end
  def test_runtime_healthy_but_prefix_missing_and_architecture_mapping
    File.unlink(path)
    runtime = C.scan(@bytes, @engine, Digest::SHA256.hexdigest(@bytes), @source, 'full', C.now + 3)
    assert_equal 'ok', runtime['status']
    result = scan
    assert_equal 'mismatch', result['status']
    assert_equal ['drive_c/windows/system32/bcrypt.dll'], result['files'].select { |r| r['status'] == 'missing' }.map { |r| r['path'] }
    assert_equal 'ok', result['files'].find { |r| r['path'].include?('syswow64/bcrypt') }['status']
  end
  def test_absolute_and_relative_links_and_broken_runtime_target
    File.unlink(path)
    target = File.join(@engine, @rows.first['path'])
    File.symlink(target, path)
    assert_equal 'ok', scan['status']
    File.unlink(path)
    require 'pathname'
    relative = Pathname.new(target).relative_path_from(Pathname.new(File.dirname(path))).to_s
    File.symlink(relative, path)
    assert_equal 'ok', scan['status']
    File.unlink(target)
    result = scan['files'].find { |r| r['path'].end_with?('system32/bcrypt.dll') }
    assert_equal 'missing', result['status']
  end
  def test_unverified_different_copy_is_unknown_even_with_version_marker
    File.binwrite(path, 'native or older OEM DLL')
    File.write(File.join(@prefix, '.cyder-bootstrap-v1'), "engine=fixture\n")
    result = scan
    assert_equal 'unknown', result['status']
    row = result['files'].find { |r| r['status'] == 'unknown' }
    assert_equal 'prefix_source_unverified', row['reason']
    refute_equal 'content_mismatch', row['status']
  end
  def test_foreign_links_and_linked_parents_are_not_followed
    outside = File.join(@temp, 'outside')
    File.mkfifo(outside)
    File.unlink(path)
    File.symlink(outside, path)
    assert_equal 'prefix_source_unverified', scan['files'].find { |r| r['status'] == 'unknown' }['reason']
    directory = File.dirname(path)
    File.rename(directory, directory + '-old')
    File.symlink(directory + '-old', directory)
    assert_equal 'unknown', scan['status']
  end
  def test_two_prefixes_are_independent_and_win32_uses_system32
    other = File.join(@temp, 'bottle-b')
    make_prefix(other, 'win32', true)
    File.unlink(path)
    assert_equal 'mismatch', scan['status']
    result = scan(other)
    assert_equal 'ok', result['status']
    assert_equal 5, result['checked']
    assert result['files'].all? { |r| r['path'].include?('/system32/') && r['runtimePath'].include?('/i386-windows/') }
  end
  def test_unknown_architecture_missing_prefix_or_registry
    File.write(File.join(@prefix, 'system.reg'), "#arch=win64\n#arch=win32\n")
    assert_equal 'prefix_architecture_unknown', scan['reason']
    File.unlink(File.join(@prefix, 'system.reg'))
    assert_equal 'unknown', scan['status']
    assert_equal 'unknown', scan(File.join(@temp, 'absent'))['status']
  end
  def test_manifest_trust_and_timeout_cannot_be_bypassed
    assert_equal 'source_mismatch', scan(@prefix, @bytes, '0' * 64)['status']
    source = JSON.parse(@bytes)
    source['source']['version'] = 'untrusted'
    assert_equal 'source_mismatch', scan(@prefix, JSON.generate(source))['status']
    assert_equal 'timeout', scan(@prefix, @bytes, Digest::SHA256.hexdigest(@bytes), C.now - 1)['reason']
    C.stub(:scan, ->(*) { raise C::Cancelled }) { assert_equal 'cancelled', scan['reason'] }
  end
  def test_special_file_and_replacement_during_check
    File.unlink(path)
    File.mkfifo(path)
    assert_equal 'unknown', scan['status']
    File.unlink(path)
    FileUtils.cp(File.join(@engine, @rows.first['path']), path)
    original = C.method(:scan)
    C.stub(:scan, ->(*args) { result = original.call(*args); File.binwrite(path, 'changed'); result }) do
      assert_equal 'file_changed_during_check', scan['files'].first['reason']
    end
  end
  def test_old_manifest_flags_still_check_reported_pe_in_quick_mode
    manifest = JSON.parse(@bytes)
    manifest['files'].each { |row| row['critical'] = false }
    bytes = JSON.generate(manifest)
    File.unlink(File.join(@engine, 'lib/wine/i386-windows/bcrypt.dll'))
    result = C.scan(bytes, @engine, Digest::SHA256.hexdigest(bytes), @source, 'quick', C.now + 3)
    assert_equal 'mismatch', result['status']
    assert_equal 10, result['checked']
    assert_equal 'missing', result['files'].find { |r| r['path'].end_with?('/i386-windows/bcrypt.dll') }['status']
  end
  def test_large_registry_body_does_not_disable_prefix_checks
    File.open(File.join(@prefix, 'system.reg'), 'wb') do |file|
      file.write("WINE REGISTRY Version 2\n#arch=win64\n\n[Software\\Fixture]\n")
      file.truncate(C::MAX_MANIFEST + 1024)
    end
    assert_equal 'ok', scan['status']
    File.unlink(path)
    assert_equal 'mismatch', scan['status']
  end
  def test_engine_alias_retarget_during_symlink_check_is_unknown
    selected = File.join(@temp, 'selected-engine')
    other = File.join(@temp, 'other-engine')
    FileUtils.cp_r(@engine, other)
    File.binwrite(File.join(other, @rows.first['path']), 'different engine')
    File.symlink(@engine, selected)
    File.unlink(path)
    File.symlink(File.join(selected, @rows.first['path']), path)
    original = C.method(:scan)
    C.stub(:scan, lambda { |*args|
      if File.readlink(selected) == @engine
        File.unlink(selected)
        File.symlink(other, selected)
      end
      original.call(*args)
    }) do
      result = C.scan_prefix(@bytes, @prefix, selected, Digest::SHA256.hexdigest(@bytes), @source, 'quick', C.now + 3)
      assert_equal 'unknown', result['status']
      assert_equal 'engine_selection_changed', result['files'].first['reason']
    end
  end
  def test_prefix_alias_retarget_during_check_is_unknown
    alias_path = File.join(@temp, 'selected-prefix')
    other = File.join(@temp, 'other-prefix')
    make_prefix(other)
    File.unlink(File.join(other, 'drive_c/windows/system32/bcrypt.dll'))
    File.symlink(@prefix, alias_path)
    original = C.method(:scan)
    C.stub(:scan, lambda { |*args|
      if File.readlink(alias_path) == @prefix
        File.unlink(alias_path)
        File.symlink(other, alias_path)
      end
      original.call(*args)
    }) do
      result = scan(alias_path)
      assert_equal 'unknown', result['status']
      assert_equal 'prefix_selection_changed', result['reason']
    end
  end
  def test_timeout_before_prefix_preserves_completed_runtime_findings
    resources = File.join(@temp, 'Resources')
    directory = File.join(resources, 'component-manifests')
    FileUtils.mkdir_p(directory)
    File.write(File.join(directory, 'engine.json'), @bytes)
    File.write(File.join(directory, 'index.json'), JSON.generate('schemaVersion' => 1, 'components' => {
      'engine' => {'source' => @source, 'manifestSHA256' => Digest::SHA256.hexdigest(@bytes)}}))
    clock = 0.0
    C.stub(:now, -> { clock }) do
      C.stub(:bundle_trust, ->(p, _) { p }) do
        C.stub(:scan, lambda { |*_| clock = 2.0; {'component' => 'engine', 'status' => 'mismatch',
          'files' => [{'path' => @rows.first['path'], 'status' => 'missing'}]} }) do
          result = C.diagnose(resources, @temp, @engine, 'engine', 'quick', 1, [@prefix])
          assert_equal 'mismatch', result['status']
          assert_equal 2, result['components'].length
          assert_equal 'missing', result['components'].first['files'].first['status']
          assert_equal 'timeout', result['components'].last['reason']
        end
      end
    end
  end
  def test_diagnose_includes_prefix_evidence_and_gates_it_on_publisher
    resources = File.join(@temp, 'Resources')
    directory = File.join(resources, 'component-manifests')
    FileUtils.mkdir_p(directory)
    File.write(File.join(directory, 'engine.json'), @bytes)
    index = {'schemaVersion' => 1, 'components' => {'engine' => {'source' => @source, 'manifestSHA256' => Digest::SHA256.hexdigest(@bytes)}}}
    File.write(File.join(directory, 'index.json'), JSON.generate(index))
    File.unlink(path)
    other = File.join(@temp, 'bottle-b')
    make_prefix(other)
    C.stub(:bundle_trust, ->(p, _) { p }) do
      result = C.diagnose(resources, @temp, @engine, 'engine', 'quick', 3, [@prefix, other])
      assert_equal 'mismatch', result['status']
      assert_equal ['ok', 'mismatch', 'ok'], result['components'].map { |r| r['status'] }
      assert_equal [@prefix, other], result['components'].drop(1).map { |r| r['prefix'] }
    end
    C.stub(:bundle_trust, ->(*) { raise C::Unknown, 'publisher_unverified' }) do
      result = C.diagnose(resources, @temp, @engine, 'engine', 'quick', 3, [@prefix])
      assert_equal 'unknown', result['status']
      assert_empty result['components']
    end
  end
end
