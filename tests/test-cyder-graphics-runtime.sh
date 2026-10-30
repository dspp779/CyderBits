#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP="$(mktemp -d /private/tmp/cyder-graphics-runtime.XXXXXX)"
trap 'rm -rf "$TEMP"' EXIT
cat >"$TEMP/main.swift" <<'SWIFT'
import Foundation
import Darwin
if CommandLine.arguments.count > 1 {
    DispatchQueue.global().async { exit(CyderGraphicsRuntime.run(arguments: CommandLine.arguments)) }
    dispatchMain()
}
func check(_ value: @autoclosure () -> Bool) { if !value() { fatalError("graphics runtime evidence failed") } }
DispatchQueue.global().async {
    typealias G = CyderGraphicsRuntime
    let engine = "/runtime/Engines", uid = getuid()
    func entry(_ image: String?, gone: Bool = false, user: uid_t? = nil) -> G.Entry {
        .init(pid: 123, uid: user ?? uid, image: image, gone: gone)
    }
    check(G.classify(nil, engines: engine) == .unknown)
    check(G.classify([entry(nil)], engines: engine) == .unknown)
    check(G.classify([entry(nil, gone: true)], engines: engine) == .idle)
    check(G.classify([entry(nil, user: uid + 1)], engines: engine) == .idle)
    check(G.classify([entry("/Applications/Browser")], engines: engine) == .idle)
    for path in [engine + "/a/bin/wine", "/other/wineserver", "/games/MapleStory.exe", "/other/wine64-preloader"] {
        check(G.classify([entry(path)], engines: engine) == .busy)
    }
    var samples: [[G.Entry]?] = [[], nil]
    check(G.probe(engines: engine, read: { samples.removeFirst() }, pause: {}) == .unknown)
    samples = [[], [entry("/other/wine")]]
    check(G.probe(engines: engine, read: { samples.removeFirst() }, pause: {}) == .busy)
    print("PASS: busy, incomplete inventory, foreign UID, zombie and race evidence")
    exit(0)
}
dispatchMain()
SWIFT
swiftc -module-cache-path "$TEMP/cache" "$ROOT/scripts/cyder_execution_owner.swift" \
  "$ROOT/scripts/cyder_graphics_runtime.swift" "$TEMP/main.swift" -o "$TEMP/test"
"$TEMP/test"
mkdir -p "$TEMP/resources/ogom-scripts" "$TEMP/owners" "$TEMP/runtime" "$TEMP/prefix"
chmod 700 "$TEMP/owners"
cat >"$TEMP/resources/ogom-scripts/cyder-graphics-update.rb" <<'RUBY'
abort 'global scope missing' unless ENV['CYDER_EXECUTION_RUNTIME_MUTATION'] == '1'
puts 'PASS: standalone update executes inside native global barrier'
RUBY
"$TEMP/test" --graphics-update-guard "$TEMP/owners" "$TEMP/resources" "$TEMP/runtime" "$TEMP/runtime/Engines/wine" "$TEMP/prefix"

/usr/bin/python3 - "$TEMP/test" "$TEMP" <<'PYGUARD'
import fcntl,os,pathlib,subprocess,sys
exe,root=sys.argv[1],pathlib.Path(sys.argv[2])
lock=root/'owners/all-environments.lock'
for mode in [fcntl.LOCK_EX,fcntl.LOCK_SH]:
 with lock.open('a') as f:
  os.chmod(lock,0o600);fcntl.flock(f,mode|fcntl.LOCK_NB)
  result=subprocess.run([exe,'--graphics-update-guard',str(root/'owners'),str(root/'resources'),str(root/'runtime'),str(root/'runtime/Engines/wine'),str(root/'prefix')],capture_output=True)
  assert result.returncode==75 and not result.stdout, (result.returncode,result.stdout)
print('PASS: another native global owner defers graphics without executing the mutation')
PYGUARD
