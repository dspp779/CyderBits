#!/usr/bin/ruby
# Manage only Cyder-created, independent game directories. The DLL is the
# single switch. Wine reads the INI from a private, per-game launch path.
require 'digest'
require 'fiddle/import'
require 'fileutils'
require 'find'
require 'json'
require 'open3'
require 'socket'
require 'tmpdir'

module NativeFiles
  extend Fiddle::Importer
  dlload Fiddle.dlopen(nil)
  extern 'int clonefile(const char *, const char *, int)'
  extern 'int renamex_np(const char *, const char *, unsigned int)'
  RENAME_EXCL = 4

  def self.check(result)
    raise SystemCallError.new('檔案操作', Fiddle.last_error) unless result.zero?
  end

  def self.publish(src, dst)
    check(renamex_np(src, dst, RENAME_EXCL))
  end
end

class CNCGame
  STATE = '.cyder-cnc-ddraw'
  VERSION = '7.1.0.0'
  SOURCE = 'https://github.com/FunkyFr3sh/cnc-ddraw/releases/tag/v7.1.0.0'
  ARCHIVE_SHA = '0b13ab89a64c9918189b1dadd449ef6ed3cb3b7b19cabd96d8adbd95505bb908'
  BUNDLE_SHA = 'b260f7a0d7005be457671d1af11723362a64bce8a46a7097a3158eb626ba0332'
  NOTICES_SHA = '1c1c4eeb29ce801472ad8ee0a16717a59a2a4a7affd3baf4bf5070fef37aba11'
  DLL_SHA = '85e0f7d530dfda134793a57cb3e76b0287dcc96892ee57162dd68f47283b03a9'
  LICENSE_SHA = 'a705144535bbfccc05e8310c4f8ab5f0b6f0ec2c9371b76ca5a522cf90e031f5'
  # Add an older release here only after verifying its official archive and DLL.
  TRUSTED = {
    VERSION => [ARCHIVE_SHA, DLL_SHA],
    '7.0.0.0' => ['f9640f69c2b8c012b97720ce0a9aac483989563908fc19446b9d1ba16e7239d6',
                  'c7b25b41c8be1e8c5c46fdf79dd5a06a455cc95bf0d6625436c8170b9bb65133']
  }.freeze
  BLUECG_DLL = 'c7ba81e067690fc0d77a31c4d7a6ad4af1d0b84255275ca4974971a70394c0c7'
  BLUECG_CORE = '832fd1de73783849251a1b397f082d289feb957eaabac1473a77ce4a28d8ed1a'
  BLUECG_CLIENT = '54196345594f5f7c9e1e8b586736cc371780b1cbd3b7cfe470ba12f8c66a77c8'
  # Exact verified client/core identities; unknown combinations remain refused.
  BLUECG_PAIRS = [
    [BLUECG_CLIENT, BLUECG_CORE].freeze,
    [BLUECG_CLIENT, 'd75cfabcabae504afcfe9fe22fa814aba05b74ddaa29c0fb6531a09fed2cea4a'].freeze
  ].freeze

  def initialize(exe)
    raise '請選擇遊戲目錄中的實體 EXE。' unless File.file?(exe) && !File.symlink?(exe) && File.extname(exe).casecmp('.exe').zero?
    @exe = File.realpath(exe)
    raise '遊戲路徑含不支援的控制字元。' if @exe.match?(/[[:cntrl:]]/)
    @name = File.basename(@exe)
    @dir = File.dirname(@exe)
    @state = File.join(@dir, STATE)
  end

  def regular!(path)
    raise "檔案遺失或為連結：#{File.basename(path)}" unless File.file?(path) && !File.symlink?(path)
    path
  end

  def digest(path)
    Digest::SHA256.file(regular!(path)).hexdigest
  end

  def pe32!(path, dll: false)
    File.open(regular!(path), 'rb') do |io|
      header = io.read(64)
      if header && header.bytesize == 64 && header.start_with?('MZ')
        io.seek(header[60, 4].unpack1('V'))
        pe = io.read(26)
        return if pe && pe.bytesize == 26 && pe.start_with?("PE\0\0") &&
          pe[4, 2].unpack1('v') == 0x14c && pe[24, 2].unpack1('v') == 0x10b &&
          (pe[22, 2].unpack1('v') & 0x0002) != 0 && ((pe[22, 2].unpack1('v') & 0x2000) != 0) == dll
      end
    end
    raise "官方 cnc-ddraw 需要 32 位元 Intel Windows #{dll ? 'DLL' : 'EXE'}。"
  end

  def bluecg?
    %w[bluelauncher.exe bluecg.exe].include?(@name.downcase)
  end

  def own_dll
    matches = Dir.children(@dir).select { |entry| entry.casecmp('ddraw.dll').zero? }
    raise '有多個大小寫不同的 ddraw.dll，請先釐清。' if matches.size > 1
    File.join(@dir, matches.first || 'ddraw.dll')
  end

  def game_compatible!
    pe32!(@exe)
    if bluecg?
      client = File.join(@dir, 'bluecg.exe')
      pe32!(client)
      raise '這個 BlueCG 客戶端版本尚未驗證。' unless BLUECG_PAIRS.include?([digest(client), digest(File.join(@dir, 'bluecg.dll'))])
    end
    graphics_files = %w[d3d8.dll d3d9.dll d3d10.dll d3d10core.dll d3d11.dll d3d12.dll dxgi.dll
                        dxwrapper.dll dgvoodoo.conf glide2x.dll glide3x.dll opengl32.dll]
    conflicts = Dir.children(@dir).select { |entry| graphics_files.include?(entry.downcase) }
    raise "遊戲已有其他圖形轉譯 DLL（#{conflicts.join('、')}）。" unless conflicts.empty?
  end

  def payload
    bundled = File.expand_path("../Components/cnc-ddraw/#{VERSION}", __dir__)
    File.directory?(bundled) ? bundled : File.expand_path("../vendor/cnc-ddraw/#{VERSION}", __dir__)
  end

  def check_payload!(directory = payload)
    raise '官方封存檔校驗失敗。' unless [ARCHIVE_SHA, BUNDLE_SHA].include?(digest(File.join(directory, 'cnc-ddraw.zip')))
    raise '第三方授權聲明校驗失敗。' unless digest(File.join(directory, 'THIRD-PARTY-NOTICES.txt')) == NOTICES_SHA
    raise '官方授權檔校驗失敗。' unless digest(File.join(directory, 'LICENSE')) == LICENSE_SHA
  end

  def scan
    bytes = 0
    files = 0
    snapshot = Digest::SHA256.new
    excluded = ['/', '/Applications', '/Library', '/System', '/Users', '/Volumes', Dir.home] +
      %w[Desktop Documents Downloads Library].map { |name| File.join(Dir.home, name) }
    raise '請選擇獨立的遊戲資料夾。' if excluded.any? { |dir| File.exist?(dir) && File.identical?(dir, @dir) } ||
      File.stat(File.dirname(@dir)).dev != File.stat(@dir).dev || File.exist?(File.join(@dir, 'system.reg')) ||
      File.directory?(File.join(@dir, 'dosdevices'))
    device = File.stat(@dir).dev
    Find.find(@dir, ignore_error: false) do |path|
      s = File.lstat(path)
      raise '遊戲目錄包含連結、掛載點或特殊檔案。請另選獨立且完整的遊戲資料夾。' unless s.dev == device && (s.directory? || s.file?)
      snapshot.update([path, s.dev, s.ino, s.size, s.mtime.to_r, s.ctime.to_r].join("\0") + "\0")
      next if s.directory?
      bytes += s.size
      files += 1
    end
    { 'bytes' => bytes, 'files' => files, 'snapshot' => snapshot.hexdigest }
  end

  def available
    game_compatible!
    raise '這是已建立的專用副本。' if File.exist?(@state) || File.symlink?(@state)
    dll = own_dll
    if File.exist?(dll) || File.symlink?(dll)
      raise '遊戲已有未辨識的 ddraw.dll。請保留原檔，並改用沒有其他 wrapper 的遊戲副本。' unless bluecg? && digest(dll) == BLUECG_DLL
    end
    { 'mode' => 'source', 'bluecg' => bluecg? }
  end

  def create(destination)
    available
    source_root = @dir
    parent = File.realpath(File.dirname(File.expand_path(destination)))
    dest = File.join(parent, File.basename(destination))
    raise '目的地必須是遊戲資料夾以外的新位置。' if %w[. ..].include?(File.basename(destination))
    # macOS may resolve case/Unicode variants to the same directory without
    # normalizing their spelling. Compare the physical ancestry before staging.
    ancestor = parent
    loop do
      raise '目的地必須是遊戲資料夾以外的新位置。' if File.identical?(ancestor, source_root)
      upper = File.dirname(ancestor)
      break if upper == ancestor
      ancestor = upper
    end
    raise '目的地已存在，請使用新名稱。' if File.exist?(dest) || File.symlink?(dest)
    raise '請選同一個 APFS 卷宗，避免完整複製。' unless File.stat(parent).dev == File.stat(source_root).dev
    info = scan
    source_device = File.stat(source_root).dev
    check_payload!
    Dir.mktmpdir('.cyder-cnc-copy-', parent) do |tmp|
      copy = File.join(tmp, 'game')
      Dir.mkdir(copy, 0o700)
      Find.find(source_root, ignore_error: false) do |path|
        next if path == source_root
        relative = path.delete_prefix(source_root + '/')
        target = File.join(copy, relative)
        stat = File.lstat(path)
        if stat.directory? && stat.dev == source_device
          Dir.mkdir(target, 0o700)
        elsif stat.file? && stat.dev == source_device
          # CLONE_NOFOLLOW. No fallback to streaming a potentially huge tree.
          NativeFiles.check(NativeFiles.clonefile(path, target, 1))
          regular!(target)
        else
          raise '來源內容在複製期間變動，請關閉遊戲與更新程式再試。'
        end
      end
      managed = CNCGame.new(File.join(copy, @name))
      raise '遊戲正被修改。請關閉遊戲與更新程式後重試。' unless info == scan
      # Validate the clone again. An updater may have changed the source.
      managed.available
      managed.record_copy(@exe)
      NativeFiles.publish(copy, dest)
    end
    info.merge('executable' => File.join(dest, @name), 'mode' => 'on')
  end

  def record_copy(source_exe)
    Dir.mkdir(@state, 0o700)
    File.open(File.join(@state, 'lock'), 'wx', 0o600) {}
    Dir.mkdir(File.join(@state, 'prefixes'), 0o700)
    dll = own_dll
    original = nil
    if File.exist?(dll)
      original = digest(dll)
      NativeFiles.check(NativeFiles.clonefile(dll, File.join(@state, 'original.dll'), 1))
    end
    @receipt = {
      'schema' => 2, 'executable' => @name, 'sourceExecutable' => source_exe,
      'directoryIdentity' => [File.stat(@dir).dev, File.stat(@dir).ino],
      'originalFile' => File.basename(dll), 'originalSHA256' => original, 'sourceExecutableSHA256' => digest(@exe),
      'bluecgHD1' => bluecg?,
      'version' => VERSION, 'source' => SOURCE, 'archiveSHA256' => ARCHIVE_SHA,
      'dllSHA256' => DLL_SHA
    }
    File.write(File.join(@state, 'receipt.json'), JSON.pretty_generate(@receipt) + "\n", mode: 'wx')
    %w[LICENSE THIRD-PARTY-NOTICES.txt].each { |name| FileUtils.cp(File.join(payload, name), File.join(@state, name)) }
    install_dll(dll, original)
  end

  def load_receipt!
    raise '請先為這個遊戲建立專用副本。' unless File.directory?(@state) && !File.symlink?(@state)
    @receipt = JSON.parse(File.read(regular!(File.join(@state, 'receipt.json'))))
    raise '此副本屬於另一個遊戲項目；請從原先選取的 EXE 啟動。' unless @receipt['schema'] == 2 && @receipt['executable'] == @name
    stat = File.stat(@dir)
    source = @receipt['sourceExecutable']
    raise '此記錄不屬於目前的遊戲副本。' unless @receipt['directoryIdentity'] == [stat.dev, stat.ino] &&
      source.is_a?(String) && source.start_with?('/') && File.dirname(source) != @dir &&
      (!File.exist?(File.dirname(source)) || !File.identical?(File.dirname(source), @dir))
    raise '此副本記載的封裝版本或校驗碼未受信任。' unless TRUSTED[@receipt['version']] == [@receipt['archiveSHA256'], @receipt['dllSHA256']] &&
      @receipt['source'] == "https://github.com/FunkyFr3sh/cnc-ddraw/releases/tag/v#{@receipt['version']}"
    original = @receipt['originalSHA256']
    raise '副本來源記錄異常。' unless @receipt['originalFile'].is_a?(String) && @receipt['originalFile'].casecmp('ddraw.dll').zero? &&
      (original.nil? || (bluecg? && original == BLUECG_DLL)) && @receipt['bluecgHD1'] == bluecg?
    raise '原版 DLL 備份校驗失敗。' if original && digest(File.join(@state, 'original.dll')) != original
  end

  def current
    load_receipt!
    path = own_dll
    sha = (File.exist?(path) || File.symlink?(path)) ? digest(path) : nil
    mode = case sha
           when @receipt['originalSHA256'] then 'off'
           when DLL_SHA then 'on'
           when @receipt['dllSHA256'] then 'outdated'
           else raise 'ddraw.dll 已由其他程式變更。請先備份並處理差異，Cyder 已保留目前檔案。'
           end
    { 'mode' => mode, 'bluecg' => bluecg?, 'version' => mode == 'on' ? VERSION : @receipt['version'] }
  end

  def status
    return available unless File.exist?(@state) || File.symlink?(@state)
    load_receipt!
    parked = File.join(@state, 'switch-backup')
    return { 'mode' => 'recovery', 'bluecg' => bluecg? } if File.exist?(parked) || File.symlink?(parked)
    current
  end

  def with_lock(write:)
    lock = regular!(File.join(@state, 'lock'))
    File.open(lock, 'rb') do |io|
      raise '副本正在啟動或執行中，請關閉後再試。' unless io.flock((write ? File::LOCK_EX : File::LOCK_SH) | File::LOCK_NB)
      yield
    end
  end

  def prefix_dir
    dir = File.join(@state, 'prefixes')
    raise '副本的執行記錄有誤。' unless File.directory?(dir) && !File.symlink?(dir)
    dir
  end

  def check_idle!
    Dir.children(prefix_dir).each do |id|
      raise '副本的執行記錄有誤。' unless id.match?(/\A[0-9a-f]+-[0-9a-f]+\z/)
      [Dir.tmpdir, '/tmp'].uniq.each do |tmp|
        path = File.join(tmp, ".wine-#{Process.uid}", "server-#{id}", 'socket')
        begin
          stat = File.lstat(path)
          raise '無法確認 Windows 環境狀態，請稍後再試。' unless stat.socket? && stat.uid == Process.uid
          Socket.open(:UNIX, :STREAM, 0) do |socket|
            # A crashed server can leave a socket inode behind. A refused
            # connection is stale; pending/unknown states remain conservative.
            socket.connect_nonblock(Socket.sockaddr_un(path))
          end
          raise '此副本使用的 Windows 環境仍在執行，請關閉該環境中的遊戲後再試。'
        rescue Errno::ENOENT, Errno::ECONNREFUSED
          next
        rescue SystemCallError, SocketError
          raise '無法確認 Windows 環境狀態，請關閉該環境後再試。'
        end
      end
    end
  end

  # Move the expected file out first, without following or overwriting it.
  # Publish using RENAME_EXCL so a concurrently created file is never replaced.
  # An interrupted operation keeps the old data under the fixed recovery name.
  def switch_dll(path, expected, replacement)
    parked = File.join(@state, 'switch-backup')
    if File.exist?(parked) || File.symlink?(parked)
      raise '上次切換尚未完成。請使用「修復上次切換」保留或還原原檔。'
    end
    moved = false
    begin
      if expected
        NativeFiles.publish(path, parked)
        moved = true
        raise '切換時發現不同版本的 DLL，已中止。' unless digest(parked) == expected
      end
      NativeFiles.publish(replacement, path) if replacement
      File.unlink(parked) if moved
    rescue StandardError
      NativeFiles.publish(parked, path) if moved && !File.exist?(path) && !File.symlink?(path)
      raise
    end
  end

  def install_dll(path, expected)
    check_payload!
    bytes, status = Open3.capture2('/usr/bin/unzip', '-p', File.join(payload, 'cnc-ddraw.zip'), 'ddraw.dll')
    raise '無法驗證封存檔中的 DLL。' unless status.success? && Digest::SHA256.hexdigest(bytes) == DLL_SHA
    Dir.mktmpdir('stage-', @state) do |stage|
      fresh = File.join(stage, 'ddraw.dll')
      File.binwrite(fresh, bytes)
      pe32!(fresh, dll: true)
      switch_dll(path, expected, fresh)
    end
  end

  def recover
    load_receipt!
    parked = File.join(@state, 'switch-backup')
    return unless File.exist?(parked) || File.symlink?(parked)
    sha = digest(parked)
    known = [@receipt['originalSHA256'], @receipt['dllSHA256'], DLL_SHA].compact
    raise '備份含未辨識的 DLL，請先人工比對 switch-backup；檔案已保留。' unless known.include?(sha)
    path = File.join(@dir, @receipt['originalFile'])
    if File.exist?(path) || File.symlink?(path)
      raise '目前 DLL 與備份衝突，請人工比對；檔案已保留。' unless known.include?(digest(path))
      File.unlink(parked)
    else
      NativeFiles.publish(parked, path)
    end
  end

  def configure(command)
    load_receipt!
    with_lock(write: true) do
      check_idle!
      recover
      info = current
      return info if command == 'recover'
      path = File.join(@dir, @receipt.fetch('originalFile'))
      original = @receipt['originalSHA256']
      if command == 'disable'
        return info if info['mode'] == 'off'
        expected = info['mode'] == 'on' ? DLL_SHA : @receipt.fetch('dllSHA256')
        Dir.mktmpdir('stage-', @state) do |stage|
          fresh = nil
          if original
            fresh = File.join(stage, 'original.dll')
            NativeFiles.check(NativeFiles.clonefile(File.join(@state, 'original.dll'), fresh, 1))
          end
          switch_dll(path, expected, fresh)
        end
      else
        game_compatible!
        check_payload!
        expected = info['mode'] == 'off' ? original : @receipt.fetch('dllSHA256')
        install_dll(path, expected) unless info['mode'] == 'on'
        if @receipt['version'] != VERSION || @receipt['dllSHA256'] != DLL_SHA
          @receipt.merge!('version' => VERSION, 'archiveSHA256' => ARCHIVE_SHA, 'dllSHA256' => DLL_SHA, 'source' => SOURCE)
          Dir.mktmpdir('stage-', @state) do |stage|
            fresh = File.join(stage, 'receipt')
            File.write(fresh, JSON.pretty_generate(@receipt) + "\n")
            File.rename(fresh, File.join(@state, 'receipt.json'))
          end
        end
      end
      current
    end
  end

  def private_config
    values = { 'renderer' => 'opengl', 'shader' => 'Bilinear', 'windowed' => 'true',
               'maintas' => 'true', 'savesettings' => '0' }
    if bluecg?
      values.merge!('fake_mode' => '961x721x32', 'fullscreen' => 'false', 'width' => '0', 'height' => '0',
                    'boxing' => 'false', 'adjmouse' => 'true', 'toggle_borderless' => 'true',
                    'toggle_upscaled' => 'false', 'devmode' => 'true', 'maxfps' => '60', 'game_handles_close' => 'true')
    end
    (["[#{bluecg? ? 'bluecg' : 'ddraw'}]"] + values.map { |key, value| "#{key}=#{value}" }).join("\r\n") + "\r\n"
  end

  def launch(prefix)
    load_receipt!
    # Bash retains FD 8 in the launch supervisor, including across detach.
    io = File.for_fd(8, autoclose: false)
    raise '啟動鎖不符。' unless io.stat.ino == File.stat(regular!(File.join(@state, 'lock'))).ino &&
      io.stat.dev == File.stat(File.join(@state, 'lock')).dev && io.flock(File::LOCK_SH | File::LOCK_NB)
    parked = File.join(@state, 'switch-backup')
    raise '上次切換尚未完成，請從遊戲的 DirectDraw 選項修復。' if File.exist?(parked) || File.symlink?(parked)
    info = current
    stat = File.stat(prefix)
    id = '%x-%x' % [stat.dev, stat.ino]
    marker = File.join(prefix_dir, id)
    begin
      File.open(marker, 'wx', 0o600) {}
    rescue Errno::EEXIST
      regular!(marker)
    end
    return 'off' if info['mode'] == 'off'
    raise '請使用遊戲的 DirectDraw 選項更新封裝。' unless info['mode'] == 'on'
    game_compatible!
    backends = %w[CYDER_GRAPHICS_PREFERENCE CYDER_GRAPHICS_BACKEND CX_GRAPHICS_BACKEND].map { |key| ENV[key] }
    conflict = backends.compact.find { |value| !['', 'default', 'wined3d'].include?(value) }
    raise "cnc-ddraw 與 #{conflict} 互斥。請在此遊戲的「圖形轉譯」選 WineD3D，或使用相容的預設。" if conflict
    overrides = [ENV['WINEDLLOVERRIDES'], ENV['CYDER_WINE_DLL_OVERRIDES']].compact.join(';')
    overrides.split(';').each do |group|
      modules = group.partition('=')[0].split(',').map { |name| name.strip.downcase.tr('\\', '/').split('/').last.to_s.delete_prefix('*').sub(/\.dll\z/, '') }
      raise '請先移除這個遊戲的 ddraw DLL 載入覆寫。' if modules.include?('ddraw')
      graphics = modules & %w[d3d8 d3d9 d3d10 d3d10core d3d11 d3d12 dxgi opengl32]
      raise "其他圖形 DLL 載入覆寫與 cnc-ddraw 互斥：#{graphics.join('、')}。" unless graphics.empty?
    end
    %w[CNC_DDRAW_CONFIG_FILE CYDER_BLUECG_BLIT_FILTER CYDER_GRAPHICS_BACKEND_PATH].each do |key|
      raise "請先移除互斥的遊戲環境設定 #{key}。" unless ENV[key].to_s.empty?
    end
    raise '請先移除前端 --dll 自訂覆寫。' if ENV['CYDER_WINE_FRONTEND_ARGS'].to_s.split.any? { |arg| arg == '--dll' || arg.start_with?('--dll=') }
    config = private_config
    key = Digest::SHA256.hexdigest(@exe)[0, 24]
    filename = "#{key}-#{Digest::SHA256.hexdigest(config)[0, 16]}.ini"
    drive = File.join(File.realpath(prefix), 'drive_c')
    raise 'Windows 環境的 C 槽不存在或為連結。' unless File.directory?(drive) && !File.symlink?(drive)
    dir = File.join(drive, 'CyderCncDdraw')
    begin
      Dir.mkdir(dir, 0o700)
    rescue Errno::EEXIST
      raise '私人設定目錄有衝突。' unless File.directory?(dir) && !File.symlink?(dir)
    end
    ini = File.join(dir, filename)
    Dir.mktmpdir('stage-', dir) do |stage|
      fresh = File.join(stage, 'ddraw.ini')
      File.binwrite(fresh, config)
      begin
        NativeFiles.publish(fresh, ini)
      rescue Errno::EEXIST
        raise '私人設定檔已變更，請保留並移走該檔案後再試。' unless File.binread(regular!(ini)) == config
      end
    end
    "C:\\CyderCncDdraw\\#{filename}"
  end
end

return unless __FILE__ == $PROGRAM_NAME

begin
  # Finder-launched apps run without LANG, which makes Ruby read paths as
  # ASCII-8BIT and fail on non-ASCII game folders.
  Encoding.default_external = Encoding::UTF_8
  ARGV.map! { |value| value.dup.force_encoding(Encoding::UTF_8) }
  command, exe, argument = ARGV
  raise '缺少 Windows 執行檔。' unless exe
  game = CNCGame.new(exe)
  result = case command
           when 'status' then game.status
           when 'plan' then game.available.merge(game.scan)
           when 'copy' then game.create(argument)
           when 'enable', 'disable', 'recover' then game.configure(command)
           when 'launch' then game.launch(argument)
           else raise '未知的 cnc-ddraw 指令。'
           end
  puts(result.is_a?(String) ? result : JSON.generate(result))
rescue StandardError => e
  warn "CYD-CNC-020：#{e.message}"
  exit 1
end
