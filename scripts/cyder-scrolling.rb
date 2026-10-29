#!/usr/bin/ruby
# Explicit, persistent EXE-scoped opt-in; never changes the prefix-wide default.
require 'json'
require 'open3'
require 'tempfile'
require 'fileutils'
require 'digest'

# Keep Unix temporary paths out of reg.exe's Windows path parser. winepath
# resolves the prefix's actual drive mappings rather than assuming Z: exists.
class CyderScrollingWineRegistry
  def initialize(prefix, wine, executor = Open3.method(:capture3))
    @prefix, @wine, @executor = prefix, wine, executor
  end

  def execute(*args)
    @executor.call({'WINEPREFIX' => @prefix}, '/usr/bin/arch', '-x86_64', @wine, *args)
  end

  def call(*args)
    path_index = args.first == 'export' ? 2 : 1
    converted, errors, status = execute('winepath', '-w', args[path_index])
    unless status.success? && converted.strip =~ /\A[A-Za-z]:\\[^\r\n]*\z/
      warn errors
      return false
    end
    args[path_index] = converted.strip
    output, errors, status = execute('reg', *args)
    warn output + errors unless status.success?
    status.success?
  end
end

class CyderScrolling
  KEY = 'HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\MapleStory.exe\\Mac Driver'.freeze
  ROOT = 'HKEY_CURRENT_USER\\Software\\Wine'.freeze
  NAME = 'UsePreciseScrolling'.freeze
  # Preserve arbitrary REG_SZ strings verbatim, including escaped Unicode text.
  # Unexpected types are refused before mutation instead of being coerced.
  STRING = /\A"(?:[^"\\\r\n]|\\[^\r\n])*"\z/

  def initialize(prefix, runner, basename = 'MapleStory.exe')
    raise 'A plain EXE filename is required' unless basename =~ /\A[^\\\/\[\]":*?<>|\x00-\x1f\x7f]+\.exe\z/i
    raise 'EXE filename exceeds Wine Mac Driver limit' if basename.encode('UTF-16LE').bytesize >= 520
    @prefix, @runner = prefix, runner
    @key = ROOT + '\\AppDefaults\\' + basename + '\\Mac Driver'
    # Retain the original MapleStory baseline from the earlier explicit tool.
    @state_dir = if basename.casecmp('MapleStory.exe').zero?
      File.join(prefix, '.cyder-maplestory-scrolling')
    else
      File.join(prefix, '.cyder-scrolling', Digest::SHA256.hexdigest(basename.downcase))
    end
  end

  def managed?
    File.exist?(File.join(@state_dir, 'original.json')) || File.symlink?(File.join(@state_dir, 'original.json'))
  end

  def value
    Tempfile.create(['cyder-scroll-', '.reg']) do |file|
      call('export', ROOT, file.path, '/y')
      bytes = File.binread(file.path)
      raise 'Invalid Wine registry export' unless bytes.start_with?("\xFF\xFE".b)
      text = bytes.byteslice(2..-1).force_encoding('UTF-16LE').encode('UTF-8')
      raise 'Invalid Wine registry export header' unless text.start_with?('Windows Registry Editor Version 5.00')
      found = []
      found_root = false
      active = false
      text.each_line do |line|
        line = line.strip
        if line.start_with?('[')
          found_root = true if line.casecmp('[' + ROOT + ']').zero?
          active = line.casecmp('[' + @key + ']').zero?
        elsif active && line =~ /\A"UsePreciseScrolling"=(.*)\z/i
          raw = Regexp.last_match(1)
          raise 'Existing UsePreciseScrolling is not a supported REG_SZ; nothing changed' unless STRING.match(raw)
          found << raw
        end
      end
      raise 'Incomplete Wine registry export' unless found_root
      raise 'Duplicate scrolling registry values' if found.length > 1
      found.first
    end
  end

  def call(*args)
    raise "Wine registry #{args.first} failed; backup retained for retry" unless @runner.call(*args)
  end

  def run(mode)
    raise 'Choose traditional, precise, restore, or status' unless %w[traditional precise restore status].include?(mode)
    raise 'An initialized Wine prefix is required' unless File.file?(File.join(@prefix, 'user.reg'))
    return value if mode == 'status'
    return nil if mode == 'restore' && !managed?
    dir = @state_dir
    raise 'Scrolling state must not be a symlink' if File.symlink?(dir) || File.symlink?(File.join(@prefix, '.cyder-scrolling'))
    FileUtils.mkdir_p(dir, :mode => 0700)
    lock = File.join(dir, 'lock')
    raise 'Scrolling lock must not be a symlink' if File.symlink?(lock)
    File.open(lock, File::RDWR | File::CREAT, 0600) do |file|
      raise 'Another scrolling update is running' unless file.flock(File::LOCK_EX | File::LOCK_NB)
      backup = File.join(dir, 'original.json')
      raise 'Scrolling backup must not be a symlink' if File.symlink?(backup)
      current = value
      saved = nil
      if File.exist?(backup)
        saved = JSON.parse(File.read(backup))
        original = saved.fetch('original')
        raise 'Invalid scrolling backup' unless saved['version'] == 1 && (original.nil? || (original.is_a?(String) && STRING.match(original)))
      end
      if mode == 'restore'
        return current unless saved
        original = saved.fetch('original')
        write(original) unless current == original
        raise 'Registry restore verification failed; backup retained' unless value == original
        File.unlink(backup)
        return original
      end
      unless File.exist?(backup)
        # Durable baseline is published before any registry write. Failed or
        # interrupted operations can therefore always retry or restore.
        Tempfile.create('baseline-', dir) do |temp|
          temp.chmod(0600)
          temp.write(JSON.generate('version' => 1, 'original' => current))
          temp.flush
          temp.fsync
          File.rename(temp.path, backup)
        end
      end
      desired = mode == 'traditional' ? '"N"' : '"Y"'
      write(desired) unless current == desired
      raise 'Registry write verification failed; backup retained' unless value == desired
      desired
    end
  end

  def write(raw)
    # Import only this single value. Absence is restored with a value deletion,
    # leaving all other Mac Driver settings and AppDefaults intact.
    Tempfile.create(['cyder-scroll-', '.reg']) do |file|
      body = "Windows Registry Editor Version 5.00\r\n\r\n[#{@key}]\r\n\"#{NAME}\"=#{raw || '-'}\r\n"
      file.binmode
      file.write("\xFF\xFE".b + body.encode('UTF-16LE').b)
      file.flush
      call('import', file.path)
    end
  end
end

def cyder_scrolling_cli
  begin
    raise 'Usage: WINEPREFIX=... WINE_INSTALL=... ruby cyder-scrolling.rb traditional|precise|restore|status [EXE filename]' unless (1..2).include?(ARGV.length)
    prefix = File.realpath(ENV.fetch('WINEPREFIX'))
    wine = File.join(ENV.fetch('WINE_INSTALL'), 'bin', 'wine')
    raise 'Wine executable is missing' unless File.executable?(wine)
    runner = CyderScrollingWineRegistry.new(prefix, wine).method(:call)
    tool = CyderScrolling.new(prefix, runner, ARGV[1] || 'MapleStory.exe')
    if ARGV.first == 'restore' && !tool.managed?
      puts 'No saved Cyder scrolling override; existing registry unchanged.'
      return
    end
    result = tool.run(ARGV.first)
    puts "#{ARGV[1] || 'MapleStory.exe'} UsePreciseScrolling: #{result || '(inherit prefix default)'}"
    puts 'Applies to newly started matching EXE processes. Game input still requires in-game verification.'
  rescue StandardError => error
    warn error.message
    exit 1
  end
end

cyder_scrolling_cli if __FILE__ == $PROGRAM_NAME
