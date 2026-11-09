#!/usr/bin/ruby
# Per-executable DirectDraw rules. Never clone or write the game directory.
require_relative 'cyder-cnc-game-legacy'

class CNCLaunchGame < CNCGame
  FILES = {
    'ddraw.dll' => DLL_SHA,
    'ddraw.ini' => '2571322a64a767022627ed076f9539179eff322efa336016e8af1f2337cc8fcb',
    'Shaders/interpolation/catmull-rom-bilinear.glsl' => '18e89f829f4c82d5b1e0d1fa9b41d6698cf3fbd2d45ef8abb9f6d7a2452c9426'
  }.freeze
  DEFAULTS = { 'filter' => 'bilinear', 'maxfps' => 60 }.freeze
  CAPABILITY = 'native-ddraw-path-v1'
  MARKER = 'CYDER_NATIVE_DDRAW_PATH_V1'

  # Match native/profile.sh identity: physical parent plus the original leaf.
  # A stock launch may use a leaf symlink; external eligibility rejects it via regular!.
  def initialize(exe)
    raise '請選擇 Windows EXE。' unless File.file?(exe) && File.extname(exe).casecmp('.exe').zero?
    @exe = File.join(File.realpath(File.dirname(File.expand_path(exe))), File.basename(exe))
    raise '遊戲路徑含不支援的控制字元。' if @exe.match?(/[[:cntrl:]]/)
    @name = File.basename(@exe)
    @dir = File.dirname(@exe)
    @state = File.join(@dir, STATE)
  end

  def profile_id
    'profile-' + Digest::SHA256.hexdigest(@exe)[0, 24]
  end

  def directory!(path)
    s = File.lstat(path)
    raise 'DirectDraw 私人目錄有衝突。' unless s.directory? && !s.symlink? && s.uid == Process.uid
    path
  end

  def private_dir(parent, name)
    directory!(parent)
    path = File.join(parent, name)
    begin
      Dir.mkdir(path, 0o700)
    rescue Errno::EEXIST
      directory!(path)
    end
    raise 'DirectDraw 私人目錄權限有衝突。' unless (File.stat(path).mode & 0o777) == 0o700
    path
  end

  def support(create: false)
    path = File.expand_path(ENV.fetch('CYDER_SUPPORT', File.join(Dir.home, 'Library/Application Support/Cyder')))
    if !File.exist?(path) && !File.symlink?(path)
      return nil unless create
      FileUtils.mkdir_p(path, mode: 0o700)
    end
    raise 'DirectDraw 支援目錄不存在或為連結。' unless File.directory?(path) && !File.symlink?(path)
    root = File.join(File.realpath(directory!(path)), 'directdraw')
    return private_dir(File.realpath(path), 'directdraw') if create
    return nil unless File.exist?(root) || File.symlink?(root)
    directory!(root)
  end

  def profile_dir(create: false)
    root = support(create: create)
    return nil unless root
    dir = File.join(root, profile_id)
    return private_dir(root, profile_id) if create
    return nil unless File.exist?(dir) || File.symlink?(dir)
    directory!(dir)
  end

  def settings!(settings)
    raise 'DirectDraw 設定格式不正確。' unless settings.is_a?(Hash) && settings.keys.sort == %w[filter maxfps] &&
      %w[nearest bilinear].include?(settings['filter']) && settings['maxfps'].is_a?(Integer) && (30..240).include?(settings['maxfps'])
    settings
  end

  def rule
    dir = profile_dir
    return nil unless dir
    path = File.join(dir, 'settings.json')
    return nil unless File.exist?(path) || File.symlink?(path)
    value = JSON.parse(File.binread(regular!(path)))
    raise 'DirectDraw 遊戲設定記錄不符。' unless value.is_a?(Hash) && value.keys.sort == %w[enabled executable profileID schema settings template] &&
      value['schema'] == 1 && value['profileID'] == profile_id && value['executable'] == @exe && [true, false].include?(value['enabled'])
    settings!(value['settings'])
    raise 'DirectDraw 設定範本不符。' unless value['template'] == config(value['settings'])
    value
  end

  def locked(dir)
    path = File.join(dir, 'lock')
    raise 'DirectDraw 鎖有衝突。' if File.symlink?(path)
    File.open(path, File::RDWR | File::CREAT | File::NOFOLLOW, 0o600) do |io|
      raise 'DirectDraw 鎖有衝突。' unless io.stat.file? && io.stat.uid == Process.uid
      io.flock(File::LOCK_EX)
      yield
    end
  end

  def save_rule(enabled, settings)
    dir = profile_dir(create: true)
    locked(dir) do
      rule # Validate any existing record before replacing it.
      value = { 'schema' => 1, 'profileID' => profile_id, 'executable' => @exe,
                'enabled' => enabled, 'settings' => settings!(settings), 'template' => config(settings) }
      Dir.mktmpdir('stage-', dir) do |stage|
        fresh = File.join(stage, 'settings.json')
        File.open(fresh, 'wx', 0o600) { |io| io.write(JSON.pretty_generate(value) + "\n") }
        File.rename(fresh, File.join(dir, 'settings.json'))
      end
    end
  end

  def legacy
    return nil unless File.exist?(@state) || File.symlink?(@state)
    CNCGame.new(@exe)
  end

  def legacy_mode
    legacy&.status&.fetch('mode')
  end

  def external_eligible!
    mode = legacy_mode
    raise '請先明確還原舊版 DirectDraw DLL，再啟用外部模式。' if mode && mode != 'off'
    available_without_legacy!
  end

  def available_without_legacy!
    game_compatible!
    dll = own_dll
    if File.exist?(dll) || File.symlink?(dll)
      raise '遊戲已有未辨識的 ddraw.dll。請保留原檔並先處理衝突。' unless bluecg? && digest(dll) == BLUECG_DLL
    end
  end

  def engine_capable!(engine)
    raise '目前 Wine 引擎不支援外部 DirectDraw 路徑，請更新引擎。' unless engine && !engine.empty?
    path = File.join(File.realpath(directory!(engine)), 'engine-manifest.json')
    data = JSON.parse(File.binread(regular!(path)))
    raise '目前 Wine 引擎不支援外部 DirectDraw 路徑，請更新引擎。' unless data.is_a?(Hash) && data['capabilities'].is_a?(Array) && data['capabilities'].include?(CAPABILITY)
    pe = File.join(engine, 'lib/wine/i386-windows/ntdll.dll')
    pe32!(pe, dll: true)
    raise 'Wine 引擎的 DirectDraw 功能標記不符。' unless File.binread(regular!(pe)).include?(MARKER)
    true
  rescue StandardError => error
    raise "DirectDraw 引擎功能檢查未通過，請更新引擎。#{error.message}"
  end

  def status(engine = nil)
    old = legacy_mode
    value = rule
    result = { 'mode' => old && (!value || old != 'off') ? 'legacy' : (value && value['enabled'] ? 'on' : 'off'),
               'profileID' => profile_id, 'settings' => value ? value['settings'] : DEFAULTS,
               'version' => VERSION, 'bluecg' => bluecg? }
    result.merge!('legacyMode' => old, 'legacyPreserved' => true) if old
    external_eligible! unless result['mode'] == 'legacy'
    if engine
      begin
        engine_capable!(engine); result['capability'] = 'available'
      rescue StandardError
        result['capability'] = 'unavailable'
      end
    end
    result
  end

  def enable(argument = nil)
    external_eligible!
    check_payload!
    value = rule
    settings = argument ? JSON.parse(argument) : (value ? value['settings'] : DEFAULTS)
    save_rule(true, settings)
    status
  end

  def disable
    raise '舊版副本請使用明確的還原操作。' if legacy && !rule
    value = rule
    save_rule(false, value ? value['settings'] : DEFAULTS)
    status
  end

  def legacy_action(command)
    old = legacy
    raise '這不是舊版 DirectDraw 副本。' unless old
    old.configure(command == 'restore' ? 'disable' : 'recover')
    status
  end

  def immutable(path, bytes)
    bytes = bytes.b
    if File.exist?(path) || File.symlink?(path)
      raise 'DirectDraw 私人檔案已被變更。' unless File.binread(regular!(path)) == bytes && (File.stat(path).mode & 0o777) == 0o444
      return path
    end
    Dir.mktmpdir('stage-', File.dirname(path)) do |stage|
      fresh = File.join(stage, 'file')
      File.open(fresh, 'wx', 0o600) { |io| io.write(bytes) }
      File.chmod(0o444, fresh)
      begin
        NativeFiles.publish(fresh, path)
      rescue Errno::EEXIST
        raise 'DirectDraw 私人檔案已被變更。' unless File.binread(regular!(path)) == bytes && (File.stat(path).mode & 0o777) == 0o444
      end
    end
    path
  end

  def staged_dll
    check_payload!
    root = support(create: true)
    locked(root) do
      versions = private_dir(root, 'payloads')
      dir = private_dir(versions, VERSION + '-' + DLL_SHA[0, 16])
      FILES.each do |name, expected|
        bytes, error, result = Open3.capture3('/usr/bin/unzip', '-p', File.join(payload, 'cnc-ddraw.zip'), name)
        raise '官方 DirectDraw 內容校驗失敗。' unless result.success? && Digest::SHA256.hexdigest(bytes) == expected
        parent = dir
        name.split('/')[0...-1].each { |part| parent = private_dir(parent, part) }
        immutable(File.join(parent, File.basename(name)), bytes)
      end
      %w[LICENSE THIRD-PARTY-NOTICES.txt].each { |name| immutable(File.join(dir, name), File.binread(regular!(File.join(payload, name)))) }
      dll = File.join(dir, 'ddraw.dll')
      pe32!(dll, dll: true)
      dll
    end
  end

  def config(settings)
    private_config.sub('shader=Bilinear', 'shader=' + (settings['filter'] == 'nearest' ? 'Nearest neighbor' : 'Bilinear'))
                  .sub(/maxfps=60\r\n/, '') + "maxfps=#{settings['maxfps']}\r\n"
  end

  def snapshot(prefix, template)
    directory!(prefix)
    drive = directory!(File.join(File.realpath(prefix), 'drive_c'))
    dir = private_dir(private_dir(drive, 'CyderCncDdraw'), profile_id)
    bytes = template
    locked(dir) do
      name = Digest::SHA256.hexdigest(bytes) + '.ini'
      immutable(File.join(dir, name), bytes)
      "C:\\CyderCncDdraw\\#{profile_id}\\#{name}"
    end
  end

  def validate_environment!
    backends = %w[CYDER_GRAPHICS_PREFERENCE CYDER_GRAPHICS_BACKEND CX_GRAPHICS_BACKEND].map { |key| ENV[key] }
    conflict = backends.compact.find { |value| !['', 'default', 'wined3d'].include?(value) }
    raise "cnc-ddraw 與 #{conflict} 互斥。請使用 WineD3D 或相容的預設。" if conflict
    [ENV['WINEDLLOVERRIDES'], ENV['CYDER_WINE_DLL_OVERRIDES']].compact.join(';').split(';').each do |group|
      modules = group.partition('=')[0].split(',').map { |name| name.strip.downcase.tr('\\', '/').split('/').last.to_s.delete_prefix('*').sub(/\.dll\z/, '') }
      raise '請先移除互斥的圖形 DLL 載入覆寫。' unless (modules & %w[ddraw d3d8 d3d9 d3d10 d3d10core d3d11 d3d12 dxgi opengl32]).empty?
    end
    # Windows environment lookup is case-insensitive, including empty aliases.
    # A direct CLI caller must not supply a competing spelling of our pair.
    ENV.each_key do |key|
      if %w[CYDER_DDRAW_PATH CNC_DDRAW_CONFIG_FILE].any? { |name| key.casecmp?(name) }
        raise "請先移除內部 DirectDraw 環境設定 #{key}。"
      end
    end
    %w[CYDER_BLUECG_BLIT_FILTER CYDER_GRAPHICS_BACKEND_PATH].each do |key|
      raise "請先移除互斥的遊戲環境設定 #{key}。" unless ENV[key].to_s.empty?
    end
    raise '請先移除前端 --dll 自訂覆寫。' if ENV['CYDER_WINE_FRONTEND_ARGS'].to_s.split.any? { |arg| arg == '--dll' || arg.start_with?('--dll=') }
  end

  def launch(prefix, engine, phase = nil)
    old = legacy_mode
    value = rule
    return { 'mode' => 'legacy', 'legacyMode' => old } if old && !value
    raise '請先明確還原舊版 DirectDraw DLL，再使用外部模式設定。' if old && old != 'off'
    return { 'mode' => 'off' } unless value && value['enabled']
    external_eligible!
    validate_environment!
    engine_capable!(engine)
    return { 'mode' => 'on', 'preparationOnly' => true } if phase == 'prepare'
    dll = staged_dll
    raise 'DirectDraw DLL 路徑不支援控制字元。' if dll.match?(/[[:cntrl:]]/)
    { 'mode' => 'on', 'dllPath' => 'Z:' + dll.tr('/', '\\'), 'configPath' => snapshot(prefix, value['template']) }
  end
end

return unless __FILE__ == $PROGRAM_NAME
begin
  command, exe, argument, engine, phase = ARGV
  raise '缺少 Windows 執行檔。' unless exe
  game = CNCLaunchGame.new(exe)
  result = case command
           when 'status' then game.status(argument)
           when 'enable' then game.enable(argument)
           when 'disable' then game.disable
           when 'restore', 'recover' then game.legacy_action(command)
           when 'launch' then game.launch(argument, engine, phase)
           else raise '未知的 cnc-ddraw 指令。'
           end
  puts JSON.generate(result)
rescue StandardError => e
  warn "CYD-CNC-020：#{e.message}"
  exit 1
end
