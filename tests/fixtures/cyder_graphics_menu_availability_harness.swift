// These stand-ins supply values only; popup setup, capability gating and menu
// updates above are extracted unchanged from the two production controllers.
struct TestCapabilities {
    var hasD3DMetal = false
    var hasDxmt = false
    var hasDxvk = false
}
enum CyderGraphicsBackend { case `default`, d3dmetal, dxmt, dxvk, wined3d }
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fputs("FAIL \(message)\n", stderr); exit(1) }
}
let app = NSApplication.shared
// Never call activate, create NSWindow, open a menu, or send desktop input.
let policyAccepted = app.setActivationPolicy(.prohibited)
let global = GlobalGraphics(), game = GameGraphics()
var cycles = 0
for available in [false, true, false] {
    let caps = TestCapabilities(hasD3DMetal: available, hasDxmt: available, hasDxvk: available)
    global.presentation = caps; game.presentation = caps
    global.updateD3DMetalMenuItemAvailability(); global.updateDxmtMenuItemAvailability(); global.updateDxvkMenuItemAvailability()
    game.updateD3DMetalMenuItemAvailability(); game.updateDxmtMenuItemAvailability(); game.updateDxvkMenuItemAvailability()
    for (name, popup, first) in [("global", global.graphicsBackend, 1), ("game", game.graphicsBackend, 2)] {
        let expected = [available && global.supportsD3DMetalOS, available && global.supportsDxmtOS, available]
        let before = popup.menu!.items.map(\.isEnabled)
        for round in 1...2 {
            // NSMenu.update performs the same AppKit validation that used to
            // overwrite manual availability when the menu was opened.
            popup.menu!.update()
            if round == 1 {
                let line = "CHECK \(name) available=\(available) before=\(before) after=\(popup.menu!.items.map(\.isEnabled))\n"
                FileHandle.standardOutput.write(Data(line.utf8))
            }
            for (offset, enabled) in expected.enumerated() {
                let item = popup.item(at: first + offset)!
                check(item.isEnabled == enabled, "\(name) \(item.title) availability=\(available) changed during AppKit menu validation")
                check(enabled || item.toolTip != nil, "\(name) unavailable \(item.title) lacks explanation")
            }
            check(popup.item(at: 0)!.isEnabled && popup.lastItem!.isEnabled, "\(name) fallback choices disabled")
            cycles += 1
        }
    }
    global.graphicsBackend.selectItem(at: 3); game.graphicsBackend.selectItem(at: 4)
    check(global.graphicsBackendValue == (available ? .dxvk : .default), "global DXVK capability guard changed")
    check(game.graphicsBackendOverride == (available ? .dxvk : nil), "game DXVK capability guard changed")
}
check(app.windows.isEmpty, "harness created a window")
print("PASS graphics menu availability: both production popup setups; absent/present/absent payload capabilities; \(cycles) native menu validation cycles; windows=\(app.windows.count); activationPolicy=\(app.activationPolicy().rawValue); prohibitedPolicyAccepted=\(policyAccepted)")
