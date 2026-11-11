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
let filter = controls.first { $0.identifier?.rawValue == "game-cnc-filter" } as! NSPopUpButton
let toggle = options.toggle
check(filter.itemTitles.count == 4 && filter.itemTitles.contains { $0.hasPrefix("Bicubic") } && filter.itemTitles.contains { $0.hasPrefix("Lanczos") },
      "scaling filters must include Bicubic and Lanczos")
func ready() -> Bool { options.refresh.isEnabled && !options.busy }
options.reload()
pump { ready() }
check(toggle.isEnabled && toggle.state == .off, "off state must offer an enabled, off switch")
check(!filter.isEnabled && !rate.isEnabled, "options must stay disabled until cnc-ddraw is on")
check(options.repair.isHidden, "off state exposes repair")

func flip(_ state: NSControl.StateValue, expectMode: String) {
    toggle.state = state
    check(toggle.sendAction(toggle.action!, to: toggle.target), "switch target unavailable")
    check(options.busy && !toggle.isEnabled && !filter.isEnabled, "mutation must lock the switch and options until confirmed")
    pump { ready() }
    check(savedState()["mode"] as? String == expectMode, "switch helper did not reach \(expectMode)")
}
flip(.on, expectMode: "on")
check(toggle.state == .on && toggle.isEnabled && filter.isEnabled && rate.isEnabled, "confirmed enable must unlock the options")
rate.selectItem(withTitle: "30")
check(rate.sendAction(rate.action!, to: rate.target), "frame-rate selection target unavailable")
pump { ready() }
check((savedState()["settings"] as? [String: Any])?["maxfps"] as? Int == 30, "frame-rate update not saved")
for (index, value) in [(1, "bicubic"), (2, "lanczos"), (3, "nearest"), (0, "bilinear")] {
    filter.selectItem(at: index)
    check(filter.sendAction(filter.action!, to: filter.target), "filter selection target unavailable")
    pump { ready() }
    check((savedState()["settings"] as? [String: Any])?["filter"] as? String == value, "filter \(value) not saved")
}
flip(.off, expectMode: "off")
check(toggle.state == .off && !filter.isEnabled && !rate.isEnabled, "disable must lock the options again")
flip(.on, expectMode: "on"); flip(.off, expectMode: "off")

options.selectedBackend = { .dxvk }
toggle.state = .on
check(toggle.sendAction(toggle.action!, to: toggle.target), "switch target unavailable")
check(!options.busy && toggle.state == .off && savedState()["mode"] as? String == "off", "a conflicting renderer must not enable cnc-ddraw")
options.selectedBackend = { .default }

for legacy in ["on", "outdated"] {
    setState("legacy", legacy: legacy)
    options.reload()
    pump { ready() }
    check(toggle.state == .on && toggle.isEnabled && !filter.isEnabled, "legacy active/outdated must show an on switch without options")
    flip(.off, expectMode: "legacy")
    check(savedState()["legacyMode"] as? String == "off", "legacy restore helper did not run")
    check(toggle.state == .off && toggle.isEnabled && options.repair.isHidden, "legacy-off availability incorrect")
}
setState("legacy", legacy: "recovery")
options.reload()
pump { ready() && !options.repair.isHidden }
check(!toggle.isEnabled && options.repair.isEnabled, "legacy recovery must offer repair instead of the switch")
options.repair.performClick(nil)
pump { ready() }
check(savedState()["legacyMode"] as? String == "on", "recovery helper did not run")
check(toggle.state == .on && toggle.isEnabled && options.repair.isHidden, "recovered legacy active state cannot restore")
setState("unknown")
options.reload()
pump { ready() && options.detail.stringValue == "無法確認 DirectDraw 狀態" }
check(!toggle.isEnabled && !filter.isEnabled, "unknown state exposes mutation")
print("PASS \(assertions) native CNC options assertions: switch on/off, options locked until on, Bicubic/Lanczos, renderer conflict, legacy restore and recovery; no Window/Wine/game")
