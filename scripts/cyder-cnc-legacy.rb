#!/usr/bin/ruby
# Retain the original Richman recipe CLI and recognize its 0.13 manifests.
# The library UI uses independent game copies through cyder-cnc-game.rb.
require_relative 'cyder-cnc-game'

class CNCRecipe < CNCGame
  FILES = %w[ddraw.dll ddraw.ini Shaders/interpolation/catmull-rom-bilinear.glsl].freeze
  # Sorted "file<TAB>sha256<TAB>relative-name" rows from the pinned release.
  LEGACY_INVENTORY = 'd21490e5eb57a35a30e9d1c79c5f742d390bb3d94a103be04cff342a2c1854c2'
  SUBSET_INVENTORY = '431ca2af012272a64e5dc4bc418df9d46a53b9046404ff7d4450fa1b61fb1ead'

  def safe_dir!(path)
    raise 'unsafe package directory' unless File.directory?(path) && !File.symlink?(path)
  end

  def initialize(exe, bottle)
    super(exe)
    safe_dir!(bottle)
    base = File.realpath(bottle)
    [ '.cyder-runtime', 'packages', "cnc-ddraw-#{Digest::SHA256.hexdigest(@exe)}" ].each do |part|
      base = File.join(base, part)
      begin
        Dir.mkdir(base, 0o700)
      rescue Errno::EEXIST
        safe_dir!(base)
      end
    end
    @manifest = File.join(base, 'manifest.tsv')
  end

  def guarded
    File.open(@dir) do |dir|
      raise 'game directory is in use' unless dir.flock(File::LOCK_EX | File::LOCK_NB)
      raise 'this game is managed through its DirectDraw options' if File.exist?(@state) || File.symlink?(@state)
      yield
    end
  end

  def inventory
    lines = File.readlines(regular!(@manifest), chomp: true)
    meta, entries = lines.partition { |line| !line.start_with?("file\t") }
    header, ids = meta.partition { |line| !line.start_with?("identity\t") }
    stat = File.stat(@dir)
    v1 = ["schema=1", "version=#{VERSION}", "archive_sha256=#{ARCHIVE_SHA}", "executable=#{@exe}"]
    v2 = ["schema=2", "version=#{VERSION}", "archive_sha256=#{ARCHIVE_SHA}", "executable=#{@exe}", "directory=#{stat.dev}-#{stat.ino}"]
    fingerprint = Digest::SHA256.hexdigest(entries.sort.join("\n") + "\n")
    unless (header == v1 && ids.empty? && fingerprint == LEGACY_INVENTORY) || (header == v2 && fingerprint == SUBSET_INVENTORY)
      raise 'unsafe manifest: target, version or official file checksums do not match'
    end
    @identities = nil
    if header == v2
      @identities = ids.to_h do |row|
        kind, dev, ino, name = row.split("\t")
        raise 'unsafe file identity' unless kind == 'identity' && /\A\d+\z/.match?(dev) && /\A\d+\z/.match?(ino)
        [name, [Integer(dev), Integer(ino)]]
      end
      raise 'incomplete file identities' unless ids.size == FILES.size && @identities.keys.sort == FILES.sort
    end
    entries.to_h do |line|
      _, hash, name = line.split("\t")
      # Never reach through a symlink into another directory. Validate every
      # entry before removal; leave all files alone when any ancestor is unsafe.
      parent = @dir
      name.split('/')[0...-1].each do |part|
        parent = File.join(parent, part)
        safe_dir!(parent) if File.exist?(parent) || File.symlink?(parent)
      end
      [name, hash]
    end
  end

  def owned_file?(path, name)
    return true unless @identities # The old schema recorded exact hashes only.
    stat = File.lstat(path)
    @identities[name] == [stat.dev, stat.ino]
  end

  def install(source)
    safe_dir!(source)
    check_payload!(source)
    pe32!(@exe)
    if File.exist?(@manifest) || File.symlink?(@manifest)
      files = inventory
      complete = files.all? do |name, _|
        path = File.join(@dir, name)
        File.file?(path) && !File.symlink?(path) && owned_file?(path, name)
      end
      unless complete && digest(File.join(@dir, 'ddraw.dll')) == DLL_SHA
        raise 'managed installation was modified or interrupted; uninstall before reinstalling'
      end
      return ' unchanged=true'
    end
    roots = %w[ddraw.dll ddraw.ini Shaders]
    conflict = Dir.children(@dir).find { |entry| roots.any? { |r| r.casecmp(entry).zero? } }
    raise "refusing to overwrite unmanaged #{conflict}" if conflict
    archive = File.join(source, 'cnc-ddraw.zip')
    Dir.mktmpdir('.cyder-cnc-stage-', @dir) do |stage|
      raise 'could not extract the pinned subset' unless system('/usr/bin/unzip', '-qq', archive, *FILES, '-d', stage)
      rows = FILES.map { |name| "file\t#{digest(File.join(stage, name))}\t#{name}" }
      raise 'unexpected file checksums in archive' unless Digest::SHA256.hexdigest(rows.sort.join("\n") + "\n") == SUBSET_INVENTORY
      stat = File.stat(@dir)
      header = ["schema=2", "version=#{VERSION}", "archive_sha256=#{ARCHIVE_SHA}", "executable=#{@exe}", "directory=#{stat.dev}-#{stat.ino}"]
      identities = FILES.map do |name|
        identity = File.lstat(File.join(stage, name))
        "identity\t#{identity.dev}\t#{identity.ino}\t#{name}"
      end
      # Publish the receipt first. A crash leaves an actionable uninstall
      # journal; exclusive renames never overwrite concurrently created files.
      Dir.mktmpdir('stage-', File.dirname(@manifest)) do |journal|
        fresh = File.join(journal, 'manifest')
        File.write(fresh, (header + identities + rows).join("\n") + "\n", mode: 'wx', perm: 0o600)
        NativeFiles.publish(fresh, @manifest)
      end
      roots.each { |root| NativeFiles.publish(File.join(stage, root), File.join(@dir, root)) }
    end
    ''
  end

  def uninstall
    raise 'no managed cnc-ddraw installation' unless File.exist?(@manifest) || File.symlink?(@manifest)
    files = inventory
    preserved = false
    dirs = []
    files.each do |name, expected|
      path = File.join(@dir, name)
      dirs << File.dirname(path)
      next unless File.exist?(path) || File.symlink?(path)
      if File.symlink?(path) || !File.file?(path) || !owned_file?(path, name) || digest(path) != expected
        warn "preserved modified cnc-ddraw file: #{path}"
        preserved = true
        next
      end
      # A concurrent updater may replace a verified path. Move it within the
      # same directory and check again before deleting any bytes.
      stage = Dir.mktmpdir('.cyder-cnc-remove-', File.dirname(path))
      parked = File.join(stage, 'original')
      begin
        NativeFiles.publish(path, parked)
        raise "concurrent change; preserved at #{parked}" unless owned_file?(parked, name) && digest(parked) == expected
        File.unlink(parked)
      rescue StandardError
        if (File.exist?(parked) || File.symlink?(parked)) && !File.exist?(path) && !File.symlink?(path)
          NativeFiles.publish(parked, path)
        end
        raise
      ensure
        Dir.rmdir(stage) if Dir.empty?(stage)
      end
    end
    # Only retire known package directories. User-created empty trees survive.
    dirs << File.join(@dir, 'Shaders')
    dirs.uniq.sort_by(&:size).reverse_each do |dir|
      Dir.rmdir(dir) if dir != @dir && File.directory?(dir) && !File.symlink?(dir) && Dir.empty?(dir)
    end
    File.unlink(@manifest)
    " preserved_modified=#{preserved ? 1 : 0}"
  end
end

begin
  Encoding.default_external = Encoding::UTF_8
  ARGV.map! { |value| value.dup.force_encoding(Encoding::UTF_8) }
  action, source, exe, bottle = ARGV
  game = CNCRecipe.new(exe, bottle)
  result = game.guarded { action == 'install' ? game.install(source) : game.uninstall }
  puts "#{action}ed=cnc-ddraw@#{CNCGame::VERSION} executable=#{File.realpath(exe)}#{result}"
rescue StandardError => e
  warn "CYD-CNC-011: #{e.message}"
  exit 1
end
