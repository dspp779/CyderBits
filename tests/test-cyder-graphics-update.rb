#!/usr/bin/ruby
require 'minitest/autorun'
require_relative '../scripts/cyder-graphics-update'
class GraphicsUpdateTest < Minitest::Test
  C = CyderIntegrity
  def setup
    @temp = File.realpath(Dir.mktmpdir('cyder-update-'))
    @runtime = File.join(@temp, 'runtime'); @engine = File.join(@runtime, 'Engines/wine')
    @prefix = File.join(@temp, 'prefix'); @resources = File.join(@temp, 'resources')
    FileUtils.mkdir_p([File.join(@engine, 'lib'), File.join(@prefix, 'drive_c/windows/system32'), File.join(@prefix, 'drive_c/windows/syswow64'), File.join(@resources, 'graphics')])
    File.write(File.join(@prefix, 'user.reg'), 'settings remain unchanged')
    @payload = File.join(@temp, 'payload'); FileUtils.mkdir_p(@payload)
    configure('A')
  end
  def teardown; FileUtils.remove_entry(@temp); end
  def configure(label, policy = 'policy-v2')
    files = {'x86_64-unix/winemetal.so' => 'native ' + label,
      'x86_64-windows/winemetal.dll' => '64 ' + label, 'i386-windows/winemetal.dll' => '32 ' + label, 'version' => 'dxmt v0.80'}
    rows = files.map do |relative, bytes|
      path = File.join(@payload, relative); FileUtils.mkdir_p(File.dirname(path)); File.write(path, bytes)
      {'path' => relative, 'kind' => 'file', 'format' => 'data', 'architectures' => [], 'signature' => 'not-required',
        'size' => bytes.bytesize, 'sha256' => Digest::SHA256.hexdigest(bytes), 'critical' => true}
    end
    archive = File.join(@resources, 'graphics/dxmt-test.tar.zst'); File.write(archive, label)
    @manifest = {'schemaVersion' => 1, 'source' => {'component' => 'dxmt', 'version' => '0.80-cyder.1', 'displayVersion' => '0.80',
      'archive' => File.basename(archive), 'archiveSHA256' => Digest::SHA256.file(archive).hexdigest,
      'installKey' => '0.80-' + Digest::SHA256.hexdigest(label + policy), 'signaturePolicy' => policy}, 'files' => rows}
  end
  def updater(probe: -> { :idle }, extract: nil, fault: nil, trusted: true)
    extract ||= lambda { |_, target| FileUtils.cp_r(@payload, File.join(target, 'dxmt')) }
    CyderGraphicsUpdate.new(resources: @resources, runtime: @runtime, engine: @engine, prefix: @prefix,
      manifest: trusted ? @manifest : nil, probe: probe, extract: extract, fault: fault)
  end
  def apply(**args); updater(**args).apply; end
  def current; File.realpath(File.join(@runtime, 'graphics/current-dxmt')); end
  def bytes; File.read(File.join(@prefix, 'drive_c/windows/system32/winemetal.dll')); end
  def snapshot
    Dir.glob(@runtime + '/**/*', File::FNM_DOTMATCH).sort.map do |p|
      next if ['.', '..'].include?(File.basename(p))
      s=File.lstat(p); [p, s.mode, s.mtime, s.ctime, s.symlink? ? File.readlink(p) : s.file? ? Digest::SHA256.file(p).hexdigest : nil]
    end.compact
  end
  def assert_settings; assert_equal 'settings remain unchanged', File.read(File.join(@prefix, 'user.reg')); end
  def test_first_install_and_repeated_noop_even_when_busy
    first = apply; assert_equal 'ok', first['status']; assert first['changed']; assert_equal '0.80', first['version']
    root = current; before = snapshot
    second = apply(probe: -> { :busy }, extract: ->(*) { flunk 'no extraction for a healthy current install' })
    assert_equal false, second['changed']; assert_equal root, current; assert_equal before, snapshot; assert_settings
  end
  def test_same_version_content_or_policy_update_uses_new_immutable_object
    assert_equal 'ok', apply['status']; old = current
    configure('B'); assert_equal 'ok', apply['status']; second = current
    refute_equal old, second; assert File.directory?(old); assert_equal 'native A', File.read(File.join(old, 'x86_64-unix/winemetal.so'))
    assert_equal '64 B', bytes
    stamp=File.stat(File.join(@prefix,'drive_c/windows/system32/winemetal.dll')).mtime
    configure('B', 'policy-v3'); assert_equal 'ok', apply['status']; assert_equal stamp,File.stat(File.join(@prefix,'drive_c/windows/system32/winemetal.dll')).mtime; refute_equal second, current; assert File.directory?(second); assert_settings
  end
  def test_busy_and_unknown_never_change_current_install
    apply; old = current; configure('B'); before=snapshot
    [:busy, :unknown].each do |state|
      result=apply(probe: -> { state }); assert_equal 'deferred', result['status']; assert_equal old,current; assert_equal before,snapshot
    end
    assert_settings
  end
  def test_installed_verification_unknown_never_writes
    apply; before=snapshot; update=updater
    update.stub(:scan, {'status'=>'unknown'}) { assert_equal 'installed_verification_unknown', update.apply['reason'] }
    assert_equal before,snapshot
  end
  def test_missing_or_untrusted_manifest_never_mutates
    before=snapshot
    assert_equal 'deferred', apply(trusted: false)['status']; assert_equal before,snapshot
  end
  def test_bad_candidate_keeps_old_files_and_registry
    apply; old=current; configure('B')
    result=apply(extract: lambda { |_, target| FileUtils.cp_r(@payload,File.join(target,'dxmt')); File.write(File.join(target,'dxmt/x86_64-unix/winemetal.so'),'corrupt') })
    assert_equal 'candidate_verification_failed', result['reason']; assert_equal old,current; assert_equal '64 A',bytes; assert_settings
  end
  def test_running_process_appears_before_commit_then_retry_succeeds
    apply; old=current; configure('B'); states=[:idle,:idle,:busy]
    assert_equal 'windows_busy_retry_when_idle', apply(probe: -> { states.shift || :busy })['reason']
    assert_equal old,current; assert_equal '64 A',bytes
    assert_equal 'ok',apply['status']; assert_equal '64 B',bytes
  end
  def test_known_corruption_is_replaced_without_overwriting_old_object
    apply; old=current; File.write(File.join(old,'x86_64-unix/winemetal.so'),'bad')
    assert_equal 'ok',apply['status']; refute_equal old,current
    assert_equal 'bad',File.read(File.join(old,'x86_64-unix/winemetal.so')); assert_settings
  end
  def test_failure_during_switch_rolls_back_prefix_and_links
    apply; old=current; configure('B')
    result=apply(fault: ->(phase) { raise IOError if phase == :before_switch })
    assert_equal 'deferred',result['status']; assert_equal old,current; assert_equal '64 A',bytes; assert_settings
    assert_equal 'ok',apply['status']
  end
  def test_newer_installed_version_is_not_downgraded
    apply; root=current; path=File.join(root,CyderGraphicsUpdate::RECEIPT)
    receipt=JSON.parse(File.read(path)); receipt['displayVersion']='0.81'; File.write(path,JSON.generate(receipt))
    before=snapshot
    assert_equal 'installed_version_newer',apply['reason']; assert_equal before,snapshot
  end
  def test_external_selector_and_prefix_symlink_are_unknown
    apply; link=File.join(@runtime,'graphics/current-dxmt'); File.unlink(link); File.symlink(@temp,link)
    assert_equal 'current_link_outside_managed_runtime',apply['reason']
  end
  def test_prefix_repair_waits_for_idle_and_does_not_replace_healthy_object
    apply; root=current; File.write(File.join(@prefix,'drive_c/windows/system32/winemetal.dll'),'stale')
    assert_equal 'deferred',apply(probe: -> { :busy })['status']; assert_equal 'stale',bytes
    assert_equal 'ok',apply['status']; assert_equal root,current; assert_equal '64 A',bytes; assert_settings
  end
  def test_prefix_copy_failure_restores_original_and_incomplete_transaction_blocks_retry
    apply; old=current; configure('B')
    FileUtils.stub(:cp, ->(*) { raise IOError }) do
      assert_equal 'deferred',apply['status']
    end
    assert_equal old,current; assert_equal '64 A',bytes; assert_settings
    marker=File.join(@runtime,'graphics/.dxmt-update-in-progress'); File.write(marker,'interrupted')
    before=snapshot; assert_equal 'unresolved_previous_update',apply['reason']; assert_equal before,snapshot
  end
  def test_real_extractor_rejects_traversal_links_and_duplicate_members
    decoder=File.join(@resources,'tools/zstd/zstd'); FileUtils.mkdir_p(File.dirname(decoder))
    File.write(decoder,"#!/bin/sh\nexec /bin/cat \"$2\"\n"); File.chmod(0755,decoder)
    update=updater(extract: nil)
    update.instance_variable_set(:@extract_input,nil)
    ['dxmt/../escape', 'link', 'duplicate'].each do |kind|
      archive=File.join(@temp,'unsafe.tar')
      File.open(archive,'wb') do |f|
        Gem::Package::TarWriter.new(f) do |tar|
          if kind=='link'
            tar.add_symlink('dxmt/link','/tmp/outside',0777)
          else
            name=kind=='duplicate' ? 'dxmt/file' : kind
            tar.add_file_simple(name,0644,1) { |w| w.write('x') }
            tar.add_file_simple(name,0644,1) { |w| w.write('x') } if kind=='duplicate'
          end
        end
      end
      stage=Dir.mktmpdir('extract-',@temp)
      assert_raises(StandardError) { update.extract(archive,stage) }
      refute File.exist?(File.join(@temp,'escape'))
    end
  end
  def test_symlinked_runtime_parent_is_rejected_before_creating_external_directories
    outside=File.join(@temp,'outside'); Dir.mkdir(outside)
    File.symlink(outside, File.join(@runtime,'graphics'))
    assert_equal 'linked_install_directory',apply['reason']
    assert_equal [],Dir.children(outside)
  end
  def test_two_prefixes_share_one_digest_and_busy_defers_switch_for_both
    apply; first=current
    second=File.join(@temp,'second-prefix'); FileUtils.mkdir_p(second)
    configure('B')
    update=CyderGraphicsUpdate.new(resources:@resources,runtime:@runtime,engine:@engine,prefix:second,
      manifest:@manifest,probe:-> { :busy },extract:->(_,stage) { FileUtils.cp_r(@payload,File.join(stage,'dxmt')) })
    assert_equal 'deferred',update.apply['status']; assert_equal first,current; assert_equal '64 A',bytes
    update.instance_variable_set(:@probe_input, -> { :idle })
    assert_equal 'ok',update.apply['status']; refute_equal first,current
    assert_equal '64 A',bytes # other inactive prefix is repaired when it next prepares, not overwritten now
    assert_equal 'ok',apply['status']; assert_equal '64 B',bytes; assert_settings
  end
  def test_global_scope_required_for_actual_mutation
    update=updater(trusted:false); old=ENV['CYDER_EXECUTION_RUNTIME_MUTATION']; ENV['CYDER_EXECUTION_RUNTIME_MUTATION']='0'
    update.stub(:manifest,@manifest) { assert_equal 'global_scope_required',update.apply['reason'] }
  ensure
    ENV['CYDER_EXECUTION_RUNTIME_MUTATION']=old
  end
end
