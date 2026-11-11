import AppKit
import Foundation

var assertions = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    assertions += 1
    guard condition() else { fputs("FAIL CNC options UI: \(message)\n", stderr); exit(1) }
}
func pump(_ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(5)
    while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    check(condition(), "helper completion timed out")
}
func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
let application = NSApplication.shared
application.setActivationPolicy(.prohibited) // Native controls, no visible desktop window.
let stateURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CYDER_CNC_UI_FIXTURE_STATE"]!)
func setState(_ mode: String, legacy: String = "") {
    let state: [String: Any] = ["mode": mode, "legacyMode": legacy, "version": "7.1.0.0",
                              "capability": "native-ddraw-path-v1", "settings": ["filter": "bilinear", "maxfps": 60]]
    try! JSONSerialization.data(withJSONObject: state).write(to: stateURL)
}
func savedState() -> [String: Any] { try! JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as! [String: Any] }
setState("off")
private let options = CyderDirectDrawOptions(executable: URL(fileURLWithPath: "/owned-fixture/game.exe"))
options.canMutate = { true }
options.selectedBackend = { .default }
let controls = options.rows.flatMap(descendants)
let rate = controls.first { $0.identifier?.rawValue == "game-cnc-frame-rate" } as! NSPopUpButton
options.reload()
pump { options.refresh.isEnabled && options.action.isEnabled }
check(options.restore.isHidden && !options.restore.isEnabled, "off state exposes a restore action")

func enable() {
    options.action.performClick(nil)
    check(options.busy && !options.restore.isEnabled, "mutation must lock restore until confirmed")
    pump { !options.busy }
    check(savedState()["mode"] as? String == "on", "enable helper did not run")
    check(!options.restore.isHidden && options.restore.isEnabled, "confirmed enable left disable button disabled")
}
enable()
rate.selectItem(withTitle: "30")
check(rate.sendAction(rate.action!, to: rate.target), "frame-rate selection target unavailable")
pump { !options.busy }
check((savedState()["settings"] as? [String: Any])?["maxfps"] as? Int == 30, "frame-rate update not saved")
check(!options.restore.isHidden && options.restore.isEnabled, "frame-rate save disabled the disable button")

func disable() {
    options.restore.performClick(nil)
    check(options.busy && !options.restore.isEnabled, "disable must lock duplicate actions")
    pump { !options.busy }
    check(savedState()["mode"] as? String == "off", "disable helper did not run")
    check(options.action.isEnabled && options.restore.isHidden && !options.restore.isEnabled, "off controls not restored")
}
disable(); enable(); disable()

for legacy in ["on", "outdated"] {
    setState("legacy", legacy: legacy)
    options.reload()
    pump { options.refresh.isEnabled && !options.restore.isHidden }
    check(!options.action.isEnabled && options.restore.isEnabled, "legacy active/outdated restore unavailable")
    check(options.restore.title == "還原舊版 DLL", "legacy restore label changed")
    options.restore.performClick(nil)
    pump { !options.busy }
    check(savedState()["legacyMode"] as? String == "off", "legacy restore helper did not run")
    check(options.action.isEnabled && options.restore.isHidden && !options.restore.isEnabled, "legacy-off availability incorrect")
}
setState("legacy", legacy: "recovery")
options.reload()
pump { options.refresh.isEnabled && options.action.title == "修復上次切換" }
check(options.action.isEnabled && options.restore.isHidden && !options.restore.isEnabled, "legacy recovery exposes restore instead of repair")
options.action.performClick(nil)
pump { !options.busy }
check(savedState()["legacyMode"] as? String == "on", "recovery helper did not run")
check(!options.action.isEnabled && !options.restore.isHidden && options.restore.isEnabled, "recovered legacy active state cannot restore")
setState("unknown")
options.reload()
pump { options.refresh.isEnabled && options.detail.stringValue == "無法確認 DirectDraw 狀態" }
check(!options.action.isEnabled && options.restore.isHidden && !options.restore.isEnabled, "unknown state exposes mutation")
print("PASS \(assertions) native CNC options assertions: enable, frame-rate update, disable round trips, legacy restore and recovery; no Window/Wine/game")
