#!/usr/bin/env python3
"""Run the unmodified product wrapper with macOS /bin/bash and isolated sinks.

No Wine, AppKit, Terminal or AppleScript runs. Only OS/readiness and downstream
receivers are substituted; parsing and both nounset-sensitive calls are real.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
BASH = '/bin/bash'
version = subprocess.check_output([BASH, '--version'], text=True).splitlines()[0]


def nul_values(path):
    data = path.read_bytes()
    assert data.endswith(b'\0'), f'missing NUL terminator: {path}'
    return [value.decode() for value in data[:-1].split(b'\0')]


with tempfile.TemporaryDirectory(prefix='cyder-wrapper-argv-', dir='/private/tmp') as temp:
    base = Path(temp)
    app = base / 'App with spaces.app' / 'Contents'
    macos = app / 'MacOS'
    resources = app / 'Resources'
    scripts = resources / 'ogom-scripts'
    scripts.mkdir(parents=True)
    macos.mkdir()
    wrapper = macos / 'Cyder'
    shutil.copyfile(ROOT / 'scripts/cyder-macos-wrapper.sh', wrapper)
    # A genuine Mach-O satisfies the wrapper's native-entry check. It is never
    # executed: the substituted architecture helper below records its arguments.
    shutil.copyfile('/bin/echo', macos / 'CyderSwift')
    (macos / 'CyderSwift').chmod(0o755)
    (resources / 'engine-archive.txt').write_text('fixture-engine.tar.zst\n')
    (resources / 'fixture-engine.tar.zst').touch()
    (scripts / 'cyder-macos-compat.sh').write_text('''
cyder_macos_at_least() { [[ "$CYDER_TEST_WRAPPER_MODE" == native || "$CYDER_TEST_WRAPPER_MODE" == modern-shell ]]; }
cyder_apply_moltenvk_os_floor() { :; }
cyder_exec_cyder_swift() {
  shift
  if (($#)); then printf '%s\\0' "$@" > "$CYDER_TEST_WRAPPER_RECORD";
  else : > "$CYDER_TEST_WRAPPER_RECORD"; fi
  exit 0
}
''')
    (scripts / 'cyder-common.sh').write_text('''
cyder_init_paths() { :; }
cyder_engine_is_ready_for_launch() { [[ "$CYDER_TEST_WRAPPER_MODE" == catalina-ready ]]; }
''')
    launcher = scripts / 'cyder_launcher.sh'
    launcher.write_text('#!/bin/bash\nprintf \'%s\\0\' "$@" > "$CYDER_TEST_WRAPPER_RECORD"\n')
    launcher.chmod(0o755)
    bootstrap = scripts / 'cyder-catalina-bootstrap.command'
    bootstrap.write_text('#!/bin/bash\nexit 96\n')
    bootstrap.chmod(0o755)
    guard = base / 'no-desktop.bash'
    guard.write_text('''
function /usr/bin/open() { printf '%s\\0' "$@" > "$CYDER_TEST_WRAPPER_OPEN"; }
function /usr/bin/osascript() { echo 'FAIL unexpected AppleScript' >&2; return 95; }
''')
    exe = base / 'Windows fixture with spaces.EXE'
    exe.touch()
    cases = [[], [''], ['two words'], ['', 'two words', '--', '--flag', '中文 空白']]
    checks = 0
    for mode in ['native', 'catalina-ready', 'catalina-bootstrap', 'modern-shell']:
        native_path = macos / 'CyderSwift'
        if mode == 'modern-shell':
            native_path.rename(macos / 'UnusedNative')
        for index, game_args in enumerate(cases):
            for separator in [False, True]:
                state = base / f'{mode}-{index}-{int(separator)}'
                state.mkdir()
                record = state / 'received.nul'
                opened = state / 'opened.nul'
                support = state / 'support'
                env = {**os.environ, 'BASH_ENV': str(guard), 'CYDER_SUPPORT': str(support),
                       'CYDER_TEST_WRAPPER_MODE': mode, 'CYDER_TEST_WRAPPER_RECORD': str(record),
                       'CYDER_TEST_WRAPPER_OPEN': str(opened)}
                args = [str(exe)] + (['--'] if separator else []) + game_args
                # Without a separator, the first raw -- is parsing syntax. Use
                # the separator when the intended payload itself contains --.
                if not separator and '--' in game_args:
                    continue
                result = subprocess.run([BASH, str(wrapper), *args], env=env, capture_output=True, text=True)
                assert result.returncode == 0, (mode, args, result.returncode, result.stderr)
                assert not result.stderr, (mode, args, result.stderr)
                if mode == 'catalina-bootstrap':
                    assert nul_values(support / 'catalina-pending-launch') == [str(exe), *game_args]
                    assert nul_values(opened) == ['-a', 'Terminal', str(bootstrap)]
                    assert not record.exists(), 'bootstrap path started a launcher directly'
                elif mode == 'native':
                    assert nul_values(record) == [str(exe), *game_args]
                    assert not opened.exists()
                else:
                    expected = ['--engine-src', str(resources / 'fixture-engine.tar.zst'), '--launch-exe', str(exe)]
                    if game_args:
                        expected += ['--', *game_args]
                    assert nul_values(record) == expected
                    assert not opened.exists()
                checks += 1
        if mode == 'modern-shell':
            (macos / 'UnusedNative').rename(native_path)
    # App-only zero arguments also stays an actually empty vector, rather than
    # manufacturing a blank argument to avoid nounset.
    app_record = base / 'app-only.nul'
    env = {**os.environ, 'BASH_ENV': str(guard), 'CYDER_SUPPORT': str(base / 'app-support'),
           'CYDER_TEST_WRAPPER_MODE': 'native', 'CYDER_TEST_WRAPPER_RECORD': str(app_record),
           'CYDER_TEST_WRAPPER_OPEN': str(base / 'unused-open.nul')}
    result = subprocess.run([BASH, str(wrapper)], env=env, capture_output=True, text=True)
    assert result.returncode == 0 and app_record.read_bytes() == b'', result.stderr
    checks += 1
print(f'PASS {checks} actual {BASH} wrapper argument cases; {version}; no Wine or desktop receivers executed')
