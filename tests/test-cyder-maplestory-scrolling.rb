require 'minitest/autorun'
require 'tmpdir'
require_relative '../scripts/cyder-maplestory-scrolling'

# Offline Wine-registry double. This checks persistence and the AppDefaults
# lookup contract, not native macdrv loading or actual mouse-wheel events.
class ScrollingRegistry
  attr_accessor :fail_export, :fail_import, :ignore_import
  attr_reader :values, :imports
  GLOBAL = 'HKEY_CURRENT_USER\\Software\\Wine\\Mac Driver'
  def initialize
    @values = {CyderMapleStoryScrolling::ROOT => {}, GLOBAL => {'UsePreciseScrolling' => '"Y"', 'RetinaMode' => '"n"'}}
    @imports = 0
  end
  def run(*args)
    if args.first == 'export'
      return false if fail_export
      body = "Windows Registry Editor Version 5.00\r\n\r\n"
      @values.each { |key, values| body += "[#{key}]\r\n" + values.map { |k,v| "\"#{k}\"=#{v}\r\n" }.join + "\r\n" }
      File.binwrite(args[2], "\xFF\xFE".b + body.encode('UTF-16LE').b)
    elsif args.first == 'import'
      @imports += 1
      return false if fail_import
      return true if ignore_import
      text = File.binread(args[1]).byteslice(2..-1).force_encoding('UTF-16LE').encode('UTF-8')
      key = text[/^\[([^\]]+)\]/, 1]
      raise 'Must only import an EXE AppDefaults key' unless key.start_with?(CyderScrolling::ROOT + '\\AppDefaults\\') && key.end_with?('\\Mac Driver')
      raise 'Must only change scrolling' unless text.scan(/^"/).size == 1
      key = @values.keys.find { |existing| existing.casecmp(key).zero? } || key
      raw = text[/^"UsePreciseScrolling"=(.*)\r$/, 1]
      @values[key] ||= {}
      raw == '-' ? @values[key].delete('UsePreciseScrolling') : @values[key]['UsePreciseScrolling'] = raw
    else
      raise 'Unexpected registry command'
    end
    true
  end
  def launch(exe)
    key = @values.keys.find { |k| k.casecmp("HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\#{exe}\\Mac Driver").zero? }
    (@values[key] || {})['UsePreciseScrolling'] || @values[GLOBAL]['UsePreciseScrolling'] || '"Y"'
  end
end

class MapleStoryScrollingTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    File.write(File.join(@dir, 'user.reg'), 'untouched')
    @reg = ScrollingRegistry.new
    @tool = CyderMapleStoryScrolling.new(@dir, @reg.method(:run))
  end
  def teardown
    FileUtils.remove_entry(@dir)
  end
  def backup
    File.join(@dir, '.cyder-maplestory-scrolling', 'original.json')
  end
  def test_general_game_and_maplestory_share_prefix_without_leaking_settings
    maple = @tool
    normal = CyderScrolling.new(@dir, @reg.method(:run), 'OtherGame.exe')
    maple.run('traditional')
    normal.run('precise')
    assert_equal '"N"', @reg.launch('MapleStory.exe')
    assert_equal '"Y"', @reg.launch('OtherGame.exe')
    normal.run('restore')
    assert_equal '"N"', @reg.launch('MapleStory.exe')
    assert_equal '"Y"', @reg.launch('OtherGame.exe')
    # Same basename shares both value and backup, regardless of casing/path.
    same = CyderScrolling.new(@dir, @reg.method(:run), 'MAPLESTORY.EXE')
    same.run('precise')
    assert_equal '"Y"', @reg.launch('MapleStory.exe')
    same.run('restore')
    assert_nil maple.run('status')
    assert_equal '"Y"', @reg.values[ScrollingRegistry::GLOBAL]['UsePreciseScrolling']
  end
  def test_unmanaged_untracked_game_does_not_read_or_modify_registry
    # Even a manually configured value must remain untouched without a baseline.
    @reg.values[CyderScrolling::KEY] = {'UsePreciseScrolling' => '"N"'}
    @reg.fail_export = true
    assert_nil @tool.run('restore')
    assert_equal '"N"', @reg.launch('MapleStory.exe')
    assert_equal 0, @reg.imports
  end
  def test_invalid_exe_cannot_escape_appdefaults
    ['../MapleStory.exe', "bad\nname.exe", 'folder\\Game.exe', 'name].exe', 'file.txt'].each do |name|
      assert_raises(RuntimeError) { CyderScrolling.new(@dir, @reg.method(:run), name) }
    end
  end
  def test_default_is_inherit_and_no_registry_write
    assert_nil @tool.run('status')
    assert_equal 0, @reg.imports
    assert_equal '"Y"', @reg.launch('MapleStory.exe')
    assert_equal '"Y"', @reg.launch('Game.exe')
    refute File.exist?(File.dirname(backup))
  end
  def test_shared_prefix_and_child_launches_are_scoped
    global = @reg.values[ScrollingRegistry::GLOBAL].dup
    @tool.run('traditional')
    saved = File.binread(backup)
    3.times do
      # New helper instance simulates a new app session; settings persist.
      CyderMapleStoryScrolling.new(@dir, @reg.method(:run)).run('traditional')
      assert_equal '"N"', @reg.launch('MapleStory.exe')
      assert_equal '"Y"', @reg.launch('OtherGame.exe')
      assert_equal '"Y"', @reg.launch('GGMWebStart.exe')
      assert_equal '"Y"', @reg.launch('Maplestory_Classic.exe')
    end
    assert_equal saved, File.binread(backup)
    assert_equal 1, @reg.imports
    assert_equal global, @reg.values[ScrollingRegistry::GLOBAL]
    assert_equal 'untouched', File.read(File.join(@dir, 'user.reg'))
    # Same EXE name, even under another path, intentionally shares this value.
    assert_equal '"N"', @reg.launch('maplestory.EXE')
  end
  def test_restore_absent_value_inherits_original_global_n
    @reg.values[ScrollingRegistry::GLOBAL]['UsePreciseScrolling'] = '"N"'
    @tool.run('precise')
    assert_equal '"Y"', @reg.launch('MapleStory.exe')
    assert_equal '"N"', @reg.launch('Game.exe')
    assert_nil @tool.run('restore')
    assert_equal '"N"', @reg.launch('MapleStory.exe')
    refute File.exist?(backup)
    count = @reg.imports
    @tool.run('restore')
    assert_equal count, @reg.imports
  end
  def test_restore_original_string_and_preserve_other_values
    @reg.values[CyderMapleStoryScrolling::KEY] = {'UsePreciseScrolling' => '"y"', 'RetinaMode' => '"y"'}
    @tool.run('traditional')
    @tool.run('precise')
    assert_equal '"y"', @tool.run('restore')
    assert_equal '"y"', @reg.values[CyderMapleStoryScrolling::KEY]['RetinaMode']
    # A new opt-in captures the baseline again after a completed restore.
    @reg.values[CyderMapleStoryScrolling::KEY]['UsePreciseScrolling'] = '"N"'
    @tool.run('precise')
    assert_equal '"N"', @tool.run('restore')
  end
  def test_export_failure_and_unsupported_type_do_not_mutate
    @reg.fail_export = true
    assert_raises(RuntimeError) { @tool.run('traditional') }
    refute File.exist?(backup)
    @reg.fail_export = false
    @reg.values[CyderMapleStoryScrolling::KEY] = {'UsePreciseScrolling' => 'dword:00000000'}
    assert_raises(RuntimeError) { @tool.run('traditional') }
    assert_equal 0, @reg.imports
    refute File.exist?(backup)
  end
  def test_write_and_restore_failures_retain_baseline_for_retry
    @reg.fail_import = true
    assert_raises(RuntimeError) { @tool.run('traditional') }
    assert File.exist?(backup)
    @reg.fail_import = false
    @tool.run('traditional')
    @reg.fail_import = true
    assert_raises(RuntimeError) { @tool.run('restore') }
    assert File.exist?(backup)
    @reg.fail_import = false
    assert_nil @tool.run('restore')
  end
  def test_success_exit_without_registry_change_fails_verification
    @reg.ignore_import = true
    assert_raises(RuntimeError) { @tool.run('traditional') }
    assert File.exist?(backup)
  end
  def test_invalid_selection_and_uninitialized_prefix
    assert_raises(RuntimeError) { @tool.run('all-games') }
    File.unlink(File.join(@dir, 'user.reg'))
    assert_raises(RuntimeError) { @tool.run('traditional') }
    assert_equal 0, @reg.imports
  end
  def test_corrupt_backup_never_imports_untrusted_registry_text
    @tool.run('traditional')
    File.write(backup, JSON.generate('version' => 1, 'original' => "\"Y\"\n[HKEY_OTHER]"))
    count = @reg.imports
    assert_raises(RuntimeError) { @tool.run('restore') }
    assert_raises(RuntimeError) { @tool.run('precise') }
    assert_equal count, @reg.imports
  end
  def test_incomplete_export_cannot_be_saved_as_absent_baseline
    tool = CyderMapleStoryScrolling.new(@dir, lambda do |*args|
      File.binwrite(args[2], "\xFF\xFE".b + "Windows Registry Editor Version 5.00\r\n".encode('UTF-16LE').b)
      true
    end)
    assert_raises(RuntimeError) { tool.run('traditional') }
    refute File.exist?(backup)
  end
  def test_escaped_unicode_original_is_restored_verbatim
    original = '"中文\\測試\"value"'
    @reg.values[CyderMapleStoryScrolling::KEY] = {'UsePreciseScrolling' => original}
    @tool.run('traditional')
    assert_equal original, @tool.run('restore')
  end
  def test_lock_prevents_concurrent_updates
    FileUtils.mkdir_p(File.dirname(backup))
    File.open(File.join(File.dirname(backup), 'lock'), 'w+') do |lock|
      lock.flock(File::LOCK_EX)
      assert_raises(RuntimeError) { @tool.run('traditional') }
    end
    assert_equal 0, @reg.imports
  end
  def test_separate_prefix_has_independent_baseline
    Dir.mktmpdir do |other|
      File.write(File.join(other, 'user.reg'), 'initialized')
      other_registry = ScrollingRegistry.new
      other_tool = CyderMapleStoryScrolling.new(other, other_registry.method(:run))
      @tool.run('traditional')
      assert_nil other_tool.run('status')
      assert_equal '"Y"', other_registry.launch('MapleStory.exe')
      refute File.exist?(File.join(other, '.cyder-maplestory-scrolling', 'original.json'))
    end
  end
end

class ScrollingWineRunnerTest < Minitest::Test
  Result = Struct.new(:ok) do
    def success?; ok; end
  end
  def test_paths_use_actual_prefix_drive_mapping_and_argument_boundaries
    calls = []
    executor = lambda do |*argv|
      calls << argv
      argv.include?('winepath') ? ["Q:\\temp\\中文 space.reg\n", '', Result.new(true)] : ['', '', Result.new(true)]
    end
    runner = CyderScrollingWineRegistry.new('/prefix space', '/engine space/bin/wine', executor)
    assert runner.call('export', CyderMapleStoryScrolling::ROOT, '/tmp/中文 space.reg', '/y')
    assert_equal [{'WINEPREFIX' => '/prefix space'}, '/usr/bin/arch', '-x86_64', '/engine space/bin/wine', 'winepath', '-w', '/tmp/中文 space.reg'], calls[0]
    assert_equal ['reg', 'export', CyderMapleStoryScrolling::ROOT, 'Q:\\temp\\中文 space.reg', '/y'], calls[1][4..-1]
    assert runner.call('import', '/tmp/中文 space.reg')
    assert_equal ['reg', 'import', 'Q:\\temp\\中文 space.reg'], calls[3][4..-1]
  end
  def test_failed_or_malformed_path_conversion_never_invokes_reg
    [Result.new(false), Result.new(true)].each do |result|
      calls = []
      runner = CyderScrollingWineRegistry.new('/prefix', '/engine/bin/wine', lambda { |*argv| calls << argv; ["invalid\npath", '', result] })
      _out, _err = capture_io { refute runner.call('import', '/tmp/file.reg') }
      assert_equal 1, calls.size
    end
  end
  def test_registry_failure_is_returned
    calls = 0
    runner = CyderScrollingWineRegistry.new('/prefix', '/engine/bin/wine', lambda do |*argv|
      calls += 1
      calls == 1 ? ['Z:\\tmp\\file.reg', '', Result.new(true)] : ['', 'failed', Result.new(false)]
    end)
    _out, _err = capture_io { refute runner.call('import', '/tmp/file.reg') }
  end
end
