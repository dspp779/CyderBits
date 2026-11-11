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
    func failure(_ reason: String) -> String {
        G.failureSummary(status: 75, output: "diagnostic preamble\n{\"status\":\"deferred\",\"reason\":\"\(reason)\"}\ndiagnostic trailer")
    }
    check(failure("publisher_unverified").contains("發行者"))
    check(!failure("publisher_unverified").contains("關閉 Windows"))
    check(G.failureSummary(status: 75, output: "preamble\r\n{\"status\":\"deferred\",\"reason\":\"publisher_unverified\"}\r\ntrailer").contains("發行者"))
    check(failure("system_signature_verifier_unavailable").contains("驗證服務"))
    check(failure("windows_busy_retry_when_idle").contains("關閉 Windows"))
    check(!failure("process_inventory_unknown").contains("關閉 Windows"))
    check(G.failureSummary(status: 75, output: "invalid").contains("診斷記錄"))
    check(G.failureSummary(status: 1, output: "").contains("發生問題"))
    print("PASS: preparation distinguishes publisher, verifier, busy and unknown failures")
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
    let birth = G.Identity(pid: 123, uid: uid, seconds: 100, micros: 200)
    let foreign = G.CodeIdentity(flags: 1, team: "ABCDEFGHIJ", cdHash: [UInt8](repeating: 7, count: 20))
    func excludes(_ error: Int32 = ENOENT, code: G.CodeIdentity? = foreign, after: G.Identity? = birth) -> Bool {
        G.unrelatedMissingImage(pid: 123, before: birth, pathError: error, readIdentity: { _ in after }, readCode: { _ in code })
    }
    check(excludes())
    for error in [EACCES, EPERM, ESRCH, EIO, 0] { check(!excludes(error)) }
    check(!excludes(code: nil))
    check(!excludes(after: nil))
    check(!excludes(after: .init(pid: 123, uid: uid, seconds: 101, micros: 200)))
    check(!excludes(after: .init(pid: 123, uid: uid + 1, seconds: 100, micros: 200)))
    for flags: UInt32 in [0, 3, 0x10000001] {
        check(!excludes(code: .init(flags: flags, team: foreign.team, cdHash: foreign.cdHash)))
    }
    for team in [G.enginePublisherTeam, "", "SHORT"] {
        check(!excludes(code: .init(flags: 1, team: team, cdHash: foreign.cdHash)))
    }
    check(!excludes(code: .init(flags: 1, team: foreign.team, cdHash: [])))
    check(!excludes(code: .init(flags: 1, team: foreign.team, cdHash: [UInt8](repeating: 0, count: 20))))
    var codes: [G.CodeIdentity?] = [foreign, .init(flags: 1, team: foreign.team, cdHash: [UInt8](repeating: 8, count: 20))]
    check(!G.unrelatedMissingImage(pid: 123, before: birth, pathError: ENOENT, readIdentity: { _ in birth }, readCode: { _ in codes.removeFirst() }))
    codes = [foreign, .init(flags: 3, team: foreign.team, cdHash: foreign.cdHash)]
    check(!G.unrelatedMissingImage(pid: 123, before: birth, pathError: ENOENT, readIdentity: { _ in birth }, readCode: { _ in codes.removeFirst() }))
    var births: [G.Identity?] = [birth, birth, .init(pid: 123, uid: uid, seconds: 999, micros: 0)]
    check(!G.unrelatedMissingImage(pid: 123, before: birth, pathError: ENOENT, readIdentity: { _ in births.removeFirst() }, readCode: { _ in foreign }))
    let teamBlob: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 19] + Array("ABCDEFGHIJ".utf8) + [0]
    check(G.parseTeam(teamBlob) == "ABCDEFGHIJ")
    for size in 0..<teamBlob.count { check(G.parseTeam(Array(teamBlob.prefix(size))) == nil) }
    var bad = teamBlob; bad[7] = 255; check(G.parseTeam(bad) == nil)
    bad = teamBlob; bad[18] = 65; check(G.parseTeam(bad) == nil)
    bad = teamBlob; bad[10] = 0; check(G.parseTeam(bad) == nil)
    print("PASS: ENOENT-only kernel code proof, API/format failures, same Team, invalid/ad-hoc/debugged code, PID/birth/CDHash/status races remain unknown")
    let excluded = G.Entry(pid: 123, uid: uid, image: nil, gone: false, signedOtherPublisherWithMissingImage: true)
    check(G.classify([excluded], engines: engine) == .unknown)
    check(G.classify([excluded], engines: engine, targetPrefix: .idle) == .idle)
    check(G.classify([excluded], engines: engine, targetPrefix: .busy) == .busy)
    check(G.classify([excluded], engines: engine, targetPrefix: .unknown) == .unknown)
    check(G.classify([excluded, entry(nil)], engines: engine, targetPrefix: .idle) == .unknown)
    check(G.classify([excluded, entry("/other/wine")], engines: engine, targetPrefix: .idle) == .busy)
    var prefixStates: [G.State] = [.idle, .busy]
    check(G.probe(engines: engine, prefix: "/prefix", server: "/engine/bin/wineserver", read: { [excluded] }, pause: {}, readPrefix: { _, _ in prefixStates.removeFirst() }) == .busy)
    prefixStates = [.idle, .unknown]
    check(G.probe(engines: engine, prefix: "/prefix", server: "/engine/bin/wineserver", read: { [excluded] }, pause: {}, readPrefix: { _, _ in prefixStates.removeFirst() }) == .unknown)
    check(G.prefixState(prefix: nil, server: nil) == .unknown)
    let testRoot = ProcessInfo.processInfo.environment["CYDER_GRAPHICS_TEST_ROOT"]!
    check(G.prefixState(prefix: testRoot + "/missing-prefix", server: "/usr/bin/true") == .idle)
    let filePrefix = testRoot + "/not-a-prefix"
    try! Data().write(to: URL(fileURLWithPath: filePrefix))
    check(G.prefixState(prefix: filePrefix, server: "/usr/bin/true") == .unknown)
    print("PASS: exclusion also requires target prefix idle; busy/shared-prefix, unknown namespace and second-snapshot changes still defer")
    exit(0)
}
dispatchMain()
SWIFT
swiftc -module-cache-path "$TEMP/cache" "$ROOT/scripts/cyder_execution_owner.swift" \
  "$ROOT/scripts/cyder_lifecycle.swift" "$ROOT/scripts/cyder_environment_probe.swift" \
  "$ROOT/scripts/cyder_graphics_runtime.swift" "$TEMP/main.swift" -o "$TEMP/test"
CYDER_GRAPHICS_TEST_ROOT="$TEMP" "$TEMP/test"
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
