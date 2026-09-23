#!/usr/bin/env bash
# Reproducible, ad-hoc lifecycle test app with fresh private state. Never installs
# or launches the app, accepts no signing identity, and never reuses an output.
set -euo pipefail
if [[ $# -ne 0 ]]; then
  echo "Usage: bash scripts/build-cyder-lifecycle-test.sh" >&2
  exit 64
fi
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d /private/tmp/cyder-lifecycle.XXXXXX)"
export CYDER_LIFECYCLE_TEST_ROOT="$TEST_ROOT"
export CYDER_LIFECYCLE_SOURCE_ROOT="$ROOT"
printf 'Test directory: %s\n' "$TEST_ROOT"
# The app builder prepends the engine's x86 Homebrew. Building this arm64 host
# tool must not require Rosetta; the function is scoped to this script's child.
python3() { /usr/bin/python3 "$@"; }
export -f python3
python3 - <<'PY'
import hashlib,json,os,re
from pathlib import Path
root=Path(os.environ['CYDER_LIFECYCLE_SOURCE_ROOT'])
out=Path(os.environ['CYDER_LIFECYCLE_TEST_ROOT'])
files=re.findall(r'\$SCRIPT_DIR/([^"\s]+\.swift)',(root/'scripts/create-cyder-app.sh').read_text())
files += ['cyder-common.sh','cyder_launcher.sh','cyder-moltenvk-variant.sh','create-cyder-app.sh','build-cyder-lifecycle-test.sh']
inputs={str(root/'scripts'/name):hashlib.sha256((root/'scripts'/name).read_bytes()).hexdigest() for name in files}
(out/'inputs.json').write_text(json.dumps(inputs,indent=2)+'\n')
PY
if ! SIGN_IDENTITY=- CYDER_REQUIRE_NATIVE_SWIFT=1 CYDER_SWIFT_OPTIMIZATION=-Onone \
  bash "$ROOT/scripts/create-cyder-app.sh" "$TEST_ROOT/build" > "$TEST_ROOT/build.log" 2>&1; then
  echo "Build failed; retained log: $TEST_ROOT/build.log" >&2
  tail -n 30 "$TEST_ROOT/build.log" >&2
  exit 1
fi
python3 - <<'PY'
import hashlib,json,os,plistlib,shlex,uuid
from pathlib import Path
root=Path(os.environ['CYDER_LIFECYCLE_SOURCE_ROOT'])
out=Path(os.environ['CYDER_LIFECYCLE_TEST_ROOT'])
inputs=json.loads((out/'inputs.json').read_text())
for path,digest in inputs.items():
    if hashlib.sha256(Path(path).read_bytes()).hexdigest()!=digest:
        raise SystemExit('Source changed during build: '+path)
app=out/'build/Cyder.app'
identity='local.cy.'+uuid.uuid4().hex[:16]
# Darwin sockaddr_un.sun_path includes its terminating NUL in 104 bytes.
# Keep the production sentinel namespace; reject unusable test paths instead.
for socket in [out/'support'/('.native-sentinel-'+identity+'.sock'), out/'support/.requests-v1.sock']:
    if len(os.fsencode(socket)) >= 104:
        raise SystemExit('Isolated socket path exceeds Darwin limit: '+str(socket))
info=app/'Contents/Info.plist'
values=plistlib.loads(info.read_bytes())
values.update(CFBundleIdentifier=identity,CFBundleName='Cyder Lifecycle Test',CFBundleDisplayName='Cyder Lifecycle Test')
info.write_bytes(plistlib.dumps(values))
for folder in ['support','runtime']:
    (out/folder).mkdir(mode=0o700)
wrapper=app/'Contents/MacOS/Cyder'
wrapper.write_text('#!/bin/bash\n'
    +'export CYDER_SUPPORT='+shlex.quote(str(out/'support'))+'\n'
    +'export CYDER_RUNTIME_ROOT='+shlex.quote(str(out/'runtime'))+'\n'
    +'export CYDER_BUNDLE_ID='+shlex.quote(identity)+'\n'
    +'exec "$(dirname "$0")/CyderSwift" "$@"\n')
wrapper.chmod(0o755)
(out/'identity.json').write_text(json.dumps(dict(app=str(app),bundleID=identity,
    support=str(out/'support'),runtime=str(out/'runtime')),indent=2)+'\n')
PY
APP="$TEST_ROOT/build/Cyder.app"
codesign --force --deep --sign - --timestamp=none "$APP" > "$TEST_ROOT/sign.log" 2>&1
codesign --verify --deep --strict --verbose=2 "$APP" >> "$TEST_ROOT/sign.log" 2>&1
lipo "$APP/Contents/MacOS/CyderSwift" -verify_arch arm64 x86_64
python3 - <<'PY'
import hashlib,json,os,subprocess
from pathlib import Path
root=Path(os.environ['CYDER_LIFECYCLE_SOURCE_ROOT'])
out=Path(os.environ['CYDER_LIFECYCLE_TEST_ROOT'])
app=out/'build/Cyder.app'
inputs=json.loads((out/'inputs.json').read_text())
for path,digest in inputs.items():
    if hashlib.sha256(Path(path).read_bytes()).hexdigest()!=digest:
        raise SystemExit('Source changed before verification: '+path)
artifacts={}
for name in ['cyder-common.sh','cyder_launcher.sh','cyder-moltenvk-variant.sh']:
    path=app/'Contents/Resources/ogom-scripts'/name
    if path.read_bytes()!=(root/'scripts'/name).read_bytes():
        raise SystemExit('Packaged script differs: '+name)
    artifacts[str(path)]=hashlib.sha256(path.read_bytes()).hexdigest()
for name in ['Contents/MacOS/Cyder','Contents/MacOS/CyderSwift','Contents/Info.plist']:
    path=app/name
    artifacts[str(path)]=hashlib.sha256(path.read_bytes()).hexdigest()
manifest=dict(sourceHEAD=subprocess.check_output(['git','-C',str(root),'rev-parse','HEAD'],text=True).strip(),
    inputs=inputs,artifacts=artifacts)
# sourceHEAD is context, not a clean-tree claim: input hashes identify the build.
(out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
(out/'verified').write_text('complete\n')
print('PASS: source freeze, packaged scripts, isolated identity, universal binary and ad-hoc signature')
PY
printf 'Verified app: %s\nIdentity and state: %s\nManifest: %s\n' \
  "$APP" "$TEST_ROOT/identity.json" "$TEST_ROOT/manifest.json"
