// Standalone integration checks do not instantiate the full Settings UI.
// The actual controller is compiled by the Release archive check.
import AppKit
@MainActor final class SettingsWindowController {
    static let shared = SettingsWindowController()
    func showWindow() { preconditionFailure("Settings UI is outside this test harness") }
}
