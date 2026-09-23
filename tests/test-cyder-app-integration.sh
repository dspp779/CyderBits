#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d /private/tmp/cy-app.XXXXXX)"
printf 'App integration fixture: %s\n' "$TEST_DIR"
# Preserve all files on failure. Cleanup signals are limited to unreaped fixture
# Popen children in the Python driver; this harness never runs Wine.
/usr/bin/python3 - "$ROOT" "$TEST_DIR" <<'PY'
import pathlib,plistlib,re,shutil,subprocess,sys
root,tmp=map(pathlib.Path,sys.argv[1:])
source=(root/'scripts/create-cyder-app.sh').read_text()
files=list(dict.fromkeys(re.findall(r'\$SCRIPT_DIR/([^"\s]+\.swift)',source)))
files=[str(root/'scripts'/f) for f in files if f not in ['cyder_app_main.swift','cyder_diagnostics.swift']]
main=(root/'scripts/cyder_app_main.swift').read_text()
assert main.count('@main\nstruct CyderMain') == 1
# Preserve every production body, including CyderMain.main(). The fixture
# supplies the compiler entrypoint and the diagnostic initializer's I/O hook.
(tmp/'app.swift').write_text(main.replace('@main\nstruct CyderMain','struct CyderMain'))
diagnostics=(root/'scripts/cyder_diagnostics.swift').read_text()
assert diagnostics.count('static let shared = CyderDiagnostics()') == 1
(tmp/'diagnostics.swift').write_text(diagnostics.replace('static let shared = CyderDiagnostics()',
    'static let shared = CyderDiagnostics(beforeIO: cyderFixtureDiagnosticIO)'))
shutil.copyfile(root/'tests/fixtures/cyder_app_integration_harness.swift',tmp/'main.swift')
contents=tmp/'Cyder.app/Contents'
(contents/'MacOS').mkdir(parents=True)
(contents/'Resources').mkdir()
(contents/'Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier='local.cyder.app-integration.'+tmp.name,CFBundleExecutable='CyderSwift',CFBundleName='Cyder Integration Fixture',CFBundlePackageType='APPL',LSUIElement=True)))
subprocess.run(['swiftc','-target','arm64-apple-macosx11.0','-module-cache-path',str(tmp/'cache')]+files+[str(tmp/'app.swift'),str(tmp/'diagnostics.swift'),str(tmp/'main.swift'),'-o',str(contents/'MacOS/CyderSwift')],check=True)
subprocess.run(['codesign','--force','--deep','--sign','-','--timestamp=none',str(tmp/'Cyder.app')],check=True)
PY
/usr/bin/python3 "$ROOT/tests/fixtures/cyder_app_integration.py" "$TEST_DIR"
test "$(cat "$TEST_DIR/complete")" = complete
if [[ -n "${CYDER_APP_INTEGRATION_ARTIFACTS:-}" ]]; then
  /usr/bin/python3 - "$TEST_DIR" "$CYDER_APP_INTEGRATION_ARTIFACTS" <<'PY'
import pathlib,shutil,sys
source,destination=map(pathlib.Path,sys.argv[1:])
for name in ['menu','direct','runloop','unavailable','slowlog','recovery','complete']:
    entry=source/name
    for path in entry.rglob('*') if entry.is_dir() else [entry]:
        # Logs, metadata and durable state suffice; never copy live socket
        # nodes or replicate each fixture's executable into the evidence.
        if path.is_file() and 'Cyder.app' not in path.parts:
            target=destination/path.relative_to(source)
            target.parent.mkdir(parents=True,exist_ok=True)
            shutil.copy2(path,target)
PY
fi
rm -rf "$TEST_DIR"
