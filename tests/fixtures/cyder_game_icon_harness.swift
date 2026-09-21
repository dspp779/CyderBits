import AppKit
import Foundation
import Darwin

func pump(_ condition: () -> Bool, timeout: TimeInterval = 10) {
    let end = ProcessInfo.processInfo.systemUptime + timeout
    while !condition() && ProcessInfo.processInfo.systemUptime < end { RunLoop.main.run(until: Date().addingTimeInterval(0.002)) }
    precondition(condition(), "icon harness timeout")
}
func extract(_ url: URL) -> CGImage? {
    var done = false; var image: CGImage?
    DispatchQueue.global().async { let result = try? CyderPEIcon.extract(from: url); DispatchQueue.main.async { image = result; done = true } }
    pump { done }; return image
}
let root = URL(fileURLWithPath: CommandLine.arguments[1])
for name in ["png-32", "png-64", "dib-32", "dib-64"] {
    guard let image = extract(root.appendingPathComponent(name + ".exe")) else { fputs("FAIL decode \(name)\n", stderr); exit(1) }
    precondition(image.width == 2 && image.height == 2)
    let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: 2, height: 2))
    let pixel = context.data!.assumingMemoryBound(to: UInt8.self)
    precondition(pixel[0] > 240 && pixel[1] < 5 && pixel[2] < 5 && pixel[3] > 240, "incorrect decoded resource pixels")
}
for name in ["bad-rva", "directory-cycle", "length-mismatch", "huge-entry-count", "truncated", "not-pe"] {
    precondition(extract(root.appendingPathComponent(name + ".exe")) == nil, "malformed PE accepted: \(name)")
}
let base = try Data(contentsOf: root.appendingPathComponent("png-64.exe"))
var random: UInt64 = 0x4359444552
for index in 0..<96 {
    var bytes = base
    for _ in 0..<4 { random = random &* 6364136223846793005 &+ 1; bytes[Int(random % UInt64(bytes.count))] ^= UInt8(truncatingIfNeeded: random >> 32) }
    let url = root.appendingPathComponent("mutation.exe"); try bytes.write(to: url)
    _ = extract(url)
    if index == 95 { try FileManager.default.removeItem(at: url) }
}
let app = NSApplication.shared; app.setActivationPolicy(.accessory)
let game = CyderGameRecord(id: "profile-000000000000000000000001", executablePath: root.appendingPathComponent("png-64.exe").path)
let store = CyderGameIconStore(); var completed = false
store.ensureExtracted(game) { completed = true }; pump { completed }
precondition(store.logo(for: game) != nil)
let cache = CyderPaths.support.appendingPathComponent("game-icons/\(game.id).png")
precondition(FileManager.default.fileExists(atPath: cache.path), "native PNG cache missing")
try Data("bad cache".utf8).write(to: cache)
completed = false
store.ensureExtracted(game, force: true) { completed = true }; pump { completed }
let regenerated = try Data(contentsOf: cache)
precondition(CyderPEIcon.decode(regenerated) != nil, "corrupt cache not regenerated")
let warm = CyderGameIconStore(); completed = false
warm.ensureExtracted(game) { completed = true }; pump { completed }
precondition(warm.logo(for: game) != nil)
final class Count {
    let lock = NSLock(); var n = 0
    func start() { precondition(!Thread.isMainThread); lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
let lateImage = CyderPEIcon.decode(try Data(contentsOf: root.appendingPathComponent("expected.png")))!
let count = Count(), gate = DispatchSemaphore(value: 0)
let blocked = CyderGameIconStore(deadline: 0.1, read: { _ in count.start(); gate.wait(); return lateImage })
var callbacks = 0
for index in 0..<40 {
    let record = CyderGameRecord(id: "fixture-\(index)", executablePath: "/unread/\(index).exe")
    blocked.ensureExtracted(record) { callbacks += 1 }
    _ = blocked.image(for: record)
}
var tick = false; DispatchQueue.main.async { tick = true }
pump { tick && callbacks == 40 }
precondition(count.value == 2, "deadline released physical readers")
blocked.quiesce(); gate.signal(); gate.signal()
var after = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { after = true }; pump { after }
precondition(callbacks == 40, "late reader completed twice")
precondition(blocked.logo(for: .init(id: "fixture-0", executablePath: "/unread/0.exe")) == nil, "late image escaped quit/deadline fence")
if CommandLine.arguments.count > 2 {
    let real = extract(URL(fileURLWithPath: CommandLine.arguments[2]))
    precondition(real != nil, "trusted existing Wine notepad resource did not decode")
    print("PASS read-only existing Wine notepad PE resource: \(real!.width)x\(real!.height); executable not launched")
}
store.quiesce(); warm.quiesce()
try Data("ok".utf8).write(to: root.appendingPathComponent("completed"))
print("PASS native PE icons: PE32/PE32+ PNG/DIB pixels, invalid RVA/cycle/count/truncation, 96 seeded mutations, actual cache regeneration, main memory projection, retained two hung readers, quit and late-result fence; no Wine process")
