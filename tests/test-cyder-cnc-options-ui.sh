#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TEST_DIR="$(mktemp -d /private/tmp/cyder-cnc-options-ui.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
/usr/bin/python3 - "$ROOT" "$TEST_DIR" <<'PY'
import os,pathlib,plistlib,subprocess,sys
root,tmp=map(pathlib.Path,sys.argv[1:])
source=pathlib.Path(os.environ.get('CYDER_CNC_OPTIONS_UI_SOURCE',root/'scripts/cyder_game_library_ui.swift')).read_text()
start=source.index('private final class CyderDirectDrawOptions: NSObject {')
end=source.index('\nfinal class CyderGameSettingsWindowController:',start)
settings=(root/'scripts/cyder_settings.swift').read_text()
backend=settings[settings.index('enum CyderGraphicsBackend:'):settings.index('\nenum CyderDxvkFrameRate:')]
main='import AppKit\nimport Foundation\n'+backend+'\n'+source[start:end]+'\n'+(root/'tests/fixtures/cyder_cnc_options_ui_harness.swift').read_text()
(tmp/'main.swift').write_text(main)
contents=tmp/'CNCOptionsFixture.app/Contents';resources=contents/'Resources/ogom-scripts'
resources.mkdir(parents=True);(contents/'MacOS').mkdir()
(contents/'Info.plist').write_bytes(plistlib.dumps(dict(CFBundleExecutable='CNCOptionsFixture',CFBundleIdentifier='local.cyder.cnc-options-fixture',CFBundlePackageType='APPL')))
(resources/'cyder-cnc-game.rb').write_text('''require 'json'
path=ENV.fetch('CYDER_CNC_UI_FIXTURE_STATE')
state=JSON.parse(File.read(path))
case ARGV[0]
when 'enable'; state['mode']='on'; state['settings']=JSON.parse(ARGV[2])
when 'disable'; state['mode']='off'
when 'restore'; state['mode']='legacy'; state['legacyMode']='off'
when 'recover'; state['mode']='legacy'; state['legacyMode']='on'
when 'status'
else; abort 'unexpected fixture command'
end
File.write(path,JSON.generate(state))
puts JSON.generate(state)
''')
subprocess.run(['swiftc','-module-cache-path',str(tmp/'cache'),str(root/'scripts/cyder_paths.swift'),str(root/'scripts/cyder_process_runner.swift'),str(root/'scripts/cyder_directdraw_operation.swift'),str(tmp/'main.swift'),'-o',str(contents/'MacOS/CNCOptionsFixture')],check=True)
env=dict(os.environ,CYDER_SUPPORT=str(tmp/'support'),CYDER_RUNTIME_ROOT=str(tmp/'runtime'),CYDER_CNC_UI_FIXTURE_STATE=str(tmp/'state.json'))
subprocess.run([str(contents/'MacOS/CNCOptionsFixture')],env=env,check=True)
PY
