import AppKit

/// Native feedback shared by reminder presentation and drop-region entry.
/// AppKit exposes patterns, not an adjustable vibration amplitude.
@MainActor
enum NotchHapticFeedback {
    static func perform(
        enabled: Bool = UserDefaults.standard.object(forKey: "enableHaptics") as? Bool ?? true,
        feedback: () -> Void = {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    ) {
        guard enabled else { return }
        feedback()
    }
}
