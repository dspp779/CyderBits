#!/usr/bin/env bash
# No Wine, screen, network or existing game needed. Fixtures exercise the
# installed Ruby helper, native APFS clone and the real launcher environment.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cyder-cnc-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
manager="$root/scripts/cyder-cnc-game-legacy.rb"
mkdir -p "$tmp/support"
export CYDER_SUPPORT="$tmp/support"
call() { /usr/bin/ruby "$manager" "$@"; }
reject() { if "$@" >"$tmp/error" 2>&1; then echo "Expected rejection: $*" >&2; exit 1; fi; }
expect() { grep -Fq "$1" "$tmp/error" || { cat "$tmp/error" >&2; exit 1; }; }
sha() { shasum -a 256 "$1" | cut -d ' ' -f1; }
mkdir "$tmp/來源 game" "$tmp/prefix" "$tmp/prefix/drive_c"
source_exe="$tmp/來源 game/game.exe"
python3 "$root/tests/fixtures/make-cnc-pe.py" "$source_exe"
printf 'untouched\n' >"$tmp/來源 game/DDraw.ini"
printf 'before\n' >"$tmp/來源 game/save.dat"
a="$tmp/A/game.exe"; b="$tmp/B/game.exe"
call plan "$source_exe" | grep -q '"files":3'
call copy "$source_exe" "$tmp/A" >/dev/null
call copy "$source_exe" "$tmp/B" >/dev/null
reject call copy "$source_exe" "$tmp/A"; expect '已存在'
reject call copy "$source_exe" "$tmp/來源 game/nested"; expect '以外'
if [[ -d "$tmp/來源 GAME" ]]; then
  reject call copy "$source_exe" "$tmp/來源 GAME/nested"; expect '以外'
  test -z "$(find "$tmp/來源 game" -name '.cyder-cnc-copy-*' -print)"
fi
test ! -e "$tmp/來源 game/ddraw.dll"
test ! -e "$tmp/來源 game/.cyder-cnc-ddraw"
printf 'after\n' >"$tmp/A/save.dat"
test "$(cat "$tmp/來源 game/save.dat")" = before
test "$(cat "$tmp/B/save.dat")" = before
test "$(cat "$tmp/A/DDraw.ini")" = untouched
test "$(sha "$tmp/A/ddraw.dll")" = 85e0f7d530dfda134793a57cb3e76b0287dcc96892ee57162dd68f47283b03a9
test -f "$tmp/A/.cyder-cnc-ddraw/LICENSE"
test -f "$tmp/A/.cyder-cnc-ddraw/THIRD-PARTY-NOTICES.txt"
echo 'PASS isolated clones, explicit destination, source & progress preservation'

launch='
  set -e
  source "$1/scripts/cyder-common.sh"
  CYDER_SCRIPTS="$1/scripts"
  cyder_prepare_cnc_game "$2" "$3"
  test -z "${CNC_DDRAW_CONFIG_FILE:-}"
  cyder_apply_cnc_game_environment
  printf "%s|%s\n" "${CNC_DDRAW_CONFIG_FILE:-}" "${WINEDLLOVERRIDES:-}"
'
out_a="$(WINEDLLOVERRIDES='mscoree,mshtml=' bash -c "$launch" _ "$root" "$a" "$tmp/prefix")"
out_b="$(bash -c "$launch" _ "$root" "$b" "$tmp/prefix")"
test "$out_a" != "$out_b"
[[ "$out_a" == *'|mscoree,mshtml=;ddraw=n' ]]
[[ "$out_b" == *'|ddraw=n' ]]
test "$(find "$tmp/prefix/drive_c/CyderCncDdraw" -name '*.ini' | wc -l | tr -d ' ')" = 2
for backend in dxmt d3dmetal dxvk; do
  reject env CYDER_GRAPHICS_PREFERENCE="$backend" bash -c "$launch" _ "$root" "$a" "$tmp/prefix"; expect '互斥'
done
for conflict in 'WINEDLLOVERRIDES=dxgi,d3d11=n' 'CX_GRAPHICS_BACKEND=dxmt' 'CYDER_GRAPHICS_BACKEND=dxvk' 'WINEDLLOVERRIDES=mscoree=;*ddraw.dll=b' 'CYDER_WINE_DLL_OVERRIDES=ddraw=b' 'CYDER_BLUECG_BLIT_FILTER=gpu-linear' 'CYDER_GRAPHICS_BACKEND_PATH=/tmp/other'; do
  reject env "$conflict" bash -c "$launch" _ "$root" "$a" "$tmp/prefix"
done
# The new dispatcher sanitizes inherited internal INI/path values before any
# prefix helper. The preserved legacy CLI still rejects foreign values itself.
sanitized="$(CNC_DDRAW_CONFIG_FILE='C:\other.ini' CYDER_DDRAW_PATH='Z:\other\ddraw.dll' bash -c "$launch" _ "$root" "$a" "$tmp/prefix")"
[[ "$sanitized" == *'|ddraw=n' && "$sanitized" != *other.ini* ]]
reject env CNC_DDRAW_CONFIG_FILE='C:\other.ini' bash -c 'exec 8<"${2%/*}/.cyder-cnc-ddraw/lock"; /usr/bin/ruby "$1" launch "$2" "$3"' _ "$manager" "$a" "$tmp/prefix"
expect '互斥'
reject bash -c 'source "$1/scripts/cyder-common.sh"; CYDER_SCRIPTS="$1/scripts"; cyder_prepare_cnc_game "$2" "$3"; /usr/bin/ruby "$4" disable "$2"' _ "$root" "$a" "$tmp/prefix" "$manager"
expect '執行中'
test "$(bash -c "$launch" _ "$root" "$source_exe" "$tmp/prefix")" = '|'
echo 'PASS process-only environment, per-copy INI, unrelated launch, graphics conflicts, launch lease'

# Exercise the normal launch settings stage, shell supervisor, game cwd, and
# the final Wine command. Only the OS/runtime APIs use fixture implementations.
mkdir -p "$tmp/engine/bin" "$tmp/support"
touch "$tmp/engine/bin/wine"
printf '[EnvironmentVariables]\n"MARKER" = "preserve"\n' > "$tmp/prefix/cxbottle.conf"
cp "$tmp/prefix/cxbottle.conf" "$tmp/bottle-before"
(
  source "$root/scripts/cyder-common.sh"
  export CYDER_SUPPORT="$tmp/support" CYDER_SCRIPTS="$root/scripts"
  export CYDER_CAPTURE_WINE_LOG=0 CYDER_WINE_DIAGNOSTICS=quiet CYDER_SESSION_GUARD=0
  export CYDER_MSYNC=1 CYDER_ESYNC=0 CYDER_POWER_MODE=normal CYDER_WINE_DETACH=0
  export CYDER_SCROLLING_PREFERENCE=unmanaged CYDER_GRAPHICS_PREFERENCE=wined3d
  export WINEDLLOVERRIDES='mscoree='
  cyder_load_game_settings() { :; }
  cyder_apply_user_settings() {
    test -z "${CNC_DDRAW_CONFIG_FILE:-}"
    test "$WINEDLLOVERRIDES" = mscoree=
  }
  cyder_configure_compatdb() { :; }
  cyder_apply_moltenvk_os_floor() { :; }
  cyder_apply_moltenvk_variant_from_preference() { :; }
  cyder_apply_gptk_launch_environment() { :; }
  cyder_validate_moltenvk_for_backend() { :; }
  cyder_wine_is_crossover_frontend() { return 1; }
  cyder_wine_locale_exports() { :; }
  cyder_exec_wine() {
    test "$CYDER_EXECUTION_FINAL" = 1
    test "$PWD" -ef "$(dirname "$a")"
    test "$2" -ef "$a"
    test "$3" = 'argument with spaces'
    printf '%s|%s\n' "$CNC_DDRAW_CONFIG_FILE" "$WINEDLLOVERRIDES" >"$tmp/final-exec"
  }
  cyder_prepare_game_launch_settings "$tmp/engine/bin/wine" "$tmp/engine" "$tmp/prefix" "$a"
  test -z "${CNC_DDRAW_CONFIG_FILE:-}"
  cyder_run_wine_exe "$tmp/engine/bin/wine" "$a" "$tmp/prefix" 'argument with spaces'
  test -z "${CNC_DDRAW_CONFIG_FILE:-}"
  test "$WINEDLLOVERRIDES" = mscoree=
  cyder_prepare_cnc_game "$source_exe" "$tmp/prefix"
  call disable "$a" >/dev/null
  call enable "$a" >/dev/null
)
cmp "$tmp/bottle-before" "$tmp/prefix/cxbottle.conf"
grep -Fq '|mscoree=;ddraw=n' "$tmp/final-exec"
echo 'PASS final Wine dispatch, original argv/cwd, pristine helper environment, untouched bottle and released prior lease'

# A live, scoped UNIX listener blocks mutation. A stale socket from a crash
# must not permanently prevent restoration. Use only a private test directory.
/usr/bin/ruby -rsocket -rtmpdir -rfileutils -ropen3 - "$manager" "$a" "$tmp/prefix" <<'RUBY'
manager, exe, prefix = ARGV
Dir.mktmpdir('cyder-sock-', '/tmp') do |root|
  stat = File.stat(prefix)
  dir = File.join(root, ".wine-#{Process.uid}", 'server-%x-%x' % [stat.dev, stat.ino])
  FileUtils.mkdir_p(dir)
  path = File.join(dir, 'socket')
  args = [{ 'TMPDIR' => root }, '/usr/bin/ruby', manager, 'disable', exe]
  UNIXServer.open(path) do
    out, status = Open3.capture2e(*args)
    abort "live environment incorrectly accepted" unless !status.success? && out.include?('仍在執行')
  end
  abort "fixture did not leave a socket inode" unless File.socket?(path)
  out, status = Open3.capture2e(*args)
  abort "stale socket prevented restore: #{out}" unless status.success? && out.include?('"off"')
end
RUBY
call enable "$a" >/dev/null
echo 'PASS live server protection and stale socket recovery'

ini_name="${out_b%%|*}"; ini_name="${ini_name##*\\}"
printf 'edited externally\n' >"$tmp/prefix/drive_c/CyderCncDdraw/$ini_name"
reject bash -c "$launch" _ "$root" "$b" "$tmp/prefix"; expect '已變更'
test "$(cat "$tmp/prefix/drive_c/CyderCncDdraw/$ini_name")" = 'edited externally'
call disable "$a" | grep -q '"off"'
test ! -e "$tmp/A/ddraw.dll"
test -e "$tmp/B/ddraw.dll"
test "$(cat "$tmp/A/save.dat")" = after
test "$(bash -c "$launch" _ "$root" "$a" "$tmp/prefix")" = '|'
call enable "$a" | grep -q '"on"'
call enable "$a" | grep -q '"on"'
mv "$tmp/A/ddraw.dll" "$tmp/A/.cyder-cnc-ddraw/switch-backup"
call status "$a" | grep -q '"recovery"'
reject bash -c "$launch" _ "$root" "$a" "$tmp/prefix"; expect '尚未完成'
call recover "$a" | grep -q '"on"'
printf 'unknown replacement\n' >"$tmp/A/ddraw.dll"
reject call enable "$a"; expect '已由其他程式變更'
reject call disable "$a"; expect '已由其他程式變更'
test "$(cat "$tmp/A/ddraw.dll")" = 'unknown replacement'
echo 'PASS update, restore, interrupted switch, changed DLL & INI preserved'

cp -R "$tmp/B/.cyder-cnc-ddraw" "$tmp/來源 game/.cyder-cnc-ddraw"
printf 'unmanaged wrapper\n' >"$tmp/來源 game/ddraw.dll"
reject call enable "$source_exe"; expect '不屬於目前'
test "$(cat "$tmp/來源 game/ddraw.dll")" = 'unmanaged wrapper'
cp "$tmp/A/.cyder-cnc-ddraw/receipt.json" "$tmp/receipt-before"
python3 - "$tmp/A/.cyder-cnc-ddraw/receipt.json" "$tmp/A/ddraw.dll" <<'PY'
import json, hashlib, sys
p = sys.argv[1]; r = json.load(open(p))
r['dllSHA256'] = hashlib.sha256(open(sys.argv[2], 'rb').read()).hexdigest()
open(p, 'w').write(json.dumps(r))
PY
reject call enable "$a"; expect '未受信任'
test "$(cat "$tmp/A/ddraw.dll")" = 'unknown replacement'
cp "$tmp/receipt-before" "$tmp/A/.cyder-cnc-ddraw/receipt.json"
echo 'PASS replayed, forged and self-reported release hashes rejected'

mkdir "$tmp/other"; cp "$source_exe" "$tmp/other/other.exe"
ln -s "$tmp/來源 game/save.dat" "$tmp/other/linked"
reject call copy "$tmp/other/other.exe" "$tmp/alias-copy"; expect '包含連結'
test ! -e "$tmp/alias-copy"
cp "$tmp/other/other.exe" "$tmp/64.exe"
python3 - "$tmp/64.exe" <<'PY'
import sys
with open(sys.argv[1], 'r+b') as f:
    f.seek(132); f.write(b'\x64\x86')
PY
reject call status "$tmp/64.exe"; expect '32 位元'
ln -s "$tmp/來源 game/ddraw.dll" "$tmp/other/ddraw.dll"
reject call status "$tmp/other/other.exe"
echo 'PASS source symlinks, unknown wrappers and non-x86 PE excluded'
