//
//  BoringViewCoordinator.swift
//  boringNotch
//
//  Created by Alexander on 2024-11-20.
//

import AppKit
import Combine
import Defaults
import SwiftUI

enum SneakContentType {
    case brightness
    case volume
    case backlight
    case music
    case mic
    case battery
    case download
}

struct sneakPeek {
    var show: Bool = false
    var type: SneakContentType = .music
    var value: CGFloat = 0
    var icon: String = ""
}

struct SharedSneakPeek: Codable {
    var show: Bool
    var type: String
    var value: String
    var icon: String
}

enum BrowserType {
    case chromium
    case safari
}

struct ExpandedItem {
    var show: Bool = false
    var type: SneakContentType = .battery
    var value: CGFloat = 0
    var browser: BrowserType = .chromium
}

@MainActor
class BoringViewCoordinator: ObservableObject {
    static let shared = BoringViewCoordinator()

    @Published var currentView: NotchViews = .home
    private var sneakPeekDispatch: DispatchWorkItem?
    private var expandingViewDispatch: DispatchWorkItem?
    private var hudEnableTask: Task<Void, Never>?

    @AppStorage("firstLaunch") var firstLaunch: Bool = true
    @AppStorage("showWhatsNew") var showWhatsNew: Bool = true
    @AppStorage("musicLiveActivityEnabled") var musicLiveActivityEnabled: Bool = true
    @AppStorage("currentMicStatus") var currentMicStatus: Bool = true

    @AppStorage("alwaysShowTabs") var alwaysShowTabs: Bool = true {
        didSet {
            if !alwaysShowTabs {
                openLastTabByDefault = false
                if ShelfStateViewModel.shared.isEmpty || !Defaults[.openShelfByDefault] {
                    currentView = .home
                }
            }
        }
    }

    @AppStorage("openLastTabByDefault") var openLastTabByDefault: Bool = false {
        didSet {
            if openLastTabByDefault {
                alwaysShowTabs = true
            }
        }
    }
    
    @Default(.hudReplacement) var hudReplacement: Bool
    
    // Legacy storage for migration
    @AppStorage("preferred_screen_name") private var legacyPreferredScreenName: String?
    
    // New UUID-based storage
    @AppStorage("preferred_screen_uuid") var preferredScreenUUID: String? {
        didSet {
            if let uuid = preferredScreenUUID {
                selectedScreenUUID = uuid
            }
            NotificationCenter.default.post(name: Notification.Name.selectedScreenChanged, object: nil)
        }
    }

    @Published var selectedScreenUUID: String = NSScreen.main?.displayUUID ?? ""

    @Published var optionKeyPressed: Bool = true
    private var accessibilityObserver: Any?
    private var hudReplacementCancellable: AnyCancellable?

    private init() {
        // Perform migration from name-based to UUID-based storage
        if preferredScreenUUID == nil, let legacyName = legacyPreferredScreenName {
            // Try to find screen by name and migrate to UUID
            if let screen = NSScreen.screens.first(where: { $0.localizedName == legacyName }),
               let uuid = screen.displayUUID {
                preferredScreenUUID = uuid
                NSLog("✅ Migrated display preference from name '\(legacyName)' to UUID '\(uuid)'")
            } else {
                // Fallback to main screen if legacy screen not found
                preferredScreenUUID = NSScreen.main?.displayUUID
                NSLog("⚠️ Could not find display named '\(legacyName)', falling back to main screen")
            }
            // Clear legacy value after migration
            legacyPreferredScreenName = nil
        } else if preferredScreenUUID == nil {
            // No legacy value, use main screen
            preferredScreenUUID = NSScreen.main?.displayUUID
        }
        
        selectedScreenUUID = preferredScreenUUID ?? NSScreen.main?.displayUUID ?? ""
        // Observe changes to accessibility authorization and react accordingly
        accessibilityObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name.accessibilityAuthorizationChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                let granted = await MediaKeyInterceptor.shared.isAccessibilityAuthorized()
                if !granted {
                    // If permission was revoked, disable HUD replacement
                    Defaults[.hudReplacement] = false
                } else {
                    // If permission granted and user prefers HUD replacement, ensure interceptor is running
                    if Defaults[.hudReplacement] {
                        MediaKeyInterceptor.shared.start(requireAccessibility: true, promptIfNeeded: false)
                    }
                }
            }
        }

        // Observe changes to hudReplacement
        hudReplacementCancellable = Defaults.publisher(.hudReplacement)
            .sink { [weak self] change in
                Task { @MainActor in
                    guard let self = self else { return }

                    self.hudEnableTask?.cancel()
                    self.hudEnableTask = nil

                    if change.newValue {
                        self.hudEnableTask = Task { @MainActor in
                            // Check prior authorization so we only restart if permissions were newly granted
                            let priorAuthorized = await MediaKeyInterceptor.shared.isAccessibilityAuthorized()

                            MediaKeyInterceptor.shared.start(requireAccessibility: true, promptIfNeeded: true)

                            let granted = await MediaKeyInterceptor.shared.ensureAccessibilityAuthorization(promptIfNeeded: false)

                            if Task.isCancelled { return }

                            if granted {
                                // Restart only if authorization was newly granted
                                if !priorAuthorized {
                                    // newly granted; restart
                                    ApplicationRelauncher.restart()
                                } else {
                                    // already granted; no restart needed
                                }
                            } else {
                                Defaults[.hudReplacement] = false
                            }
                        }
                    } else {
                        MediaKeyInterceptor.shared.stop()
                    }
                }
            }

        // On startup, ensure the hudReplacement state reflects current authorization
        Task { @MainActor in
            if Defaults[.hudReplacement] {
                let authorized = await MediaKeyInterceptor.shared.isAccessibilityAuthorized()
                if !authorized {
                    Defaults[.hudReplacement] = false
                } else {
                    MediaKeyInterceptor.shared.start(requireAccessibility: true, promptIfNeeded: false)
                }
            }
        }
    }
    
    @objc func sneakPeekEvent(_ notification: Notification) {
        let decoder = JSONDecoder()
        if let decodedData = try? decoder.decode(
            SharedSneakPeek.self, from: notification.userInfo?.first?.value as! Data)
        {
            let contentType =
                decodedData.type == "brightness"
                ? SneakContentType.brightness
                : decodedData.type == "volume"
                    ? SneakContentType.volume
                    : decodedData.type == "backlight"
                        ? SneakContentType.backlight
                        : decodedData.type == "mic"
                            ? SneakContentType.mic : SneakContentType.brightness

            let formatter = NumberFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.numberStyle = .decimal
            let value = CGFloat((formatter.number(from: decodedData.value) ?? 0.0).floatValue)
            let icon = decodedData.icon

            print("Decoded: \(decodedData), Parsed value: \(value)")

            toggleSneakPeek(status: decodedData.show, type: contentType, value: value, icon: icon)

        } else {
            print("Failed to decode JSON data")
        }
    }

    func toggleSneakPeek(
        status: Bool, type: SneakContentType, duration: TimeInterval = 1.5, value: CGFloat = 0,
        icon: String = ""
    ) {
        let system = [.volume, .brightness, .backlight].contains(type)
        let configured = UserDefaults.standard.object(forKey: "systemHUDDuration") as? Double ?? 1.5
        sneakPeekDuration = system && configured.isFinite ? min(5, max(0.5, configured)) : duration
        if type != .music {
            // close()
            if system {
                guard SystemHUDMonitor.enabled(type) else { return }
            } else if !Defaults[.hudReplacement] { return }
        }
        Task { @MainActor in
            withAnimation(.smooth) {
                self.sneakPeek.show = status
                self.sneakPeek.type = type
                self.sneakPeek.value = value
                self.sneakPeek.icon = icon
            }
        }

        if type == .mic {
            currentMicStatus = value == 1
        }
    }

    private var sneakPeekDuration: TimeInterval = 1.5
    private var sneakPeekTask: Task<Void, Never>?

    // Helper function to manage sneakPeek timer using Swift Concurrency
    private func scheduleSneakPeekHide(after duration: TimeInterval) {
        sneakPeekTask?.cancel()

        sneakPeekTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard let self = self, !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation {
                    self.toggleSneakPeek(status: false, type: .music)
                    self.sneakPeekDuration = 1.5
                }
            }
        }
    }

    @Published var sneakPeek: sneakPeek = .init() {
        didSet {
            if sneakPeek.show {
                scheduleSneakPeekHide(after: sneakPeekDuration)
            } else {
                sneakPeekTask?.cancel()
            }
        }
    }

    func toggleExpandingView(
        status: Bool,
        type: SneakContentType,
        value: CGFloat = 0,
        browser: BrowserType = .chromium
    ) {
        Task { @MainActor in
            withAnimation(.smooth) {
                self.expandingView.show = status
                self.expandingView.type = type
                self.expandingView.value = value
                self.expandingView.browser = browser
            }
        }
    }

    private var expandingViewTask: Task<Void, Never>?

    @Published var expandingView: ExpandedItem = .init() {
        didSet {
            if expandingView.show {
                expandingViewTask?.cancel()
                let duration: TimeInterval = (expandingView.type == .download ? 2 : 3)
                let currentType = expandingView.type
                expandingViewTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(duration))
                    guard let self = self, !Task.isCancelled else { return }
                    self.toggleExpandingView(status: false, type: currentType)
                }
            } else {
                expandingViewTask?.cancel()
            }
        }
    }
    
    func showEmpty() {
        currentView = .home
    }
}


/// Only explicit media keys or a pointer interaction in Control Center can
/// present an indicator. Ambient/automatic level changes never present a HUD.
@MainActor final class SystemHUDMonitor {
    static let shared = SystemHUDMonitor()
    private var timer: Timer?
    private var busy = false
    private var previous: [SneakContentType: Double] = [:]
    private var eventMonitors: [Any] = []
    private var keyType: SneakContentType?
    private var keyUntil = 0.0
    private var keySequence = 0
    private var sampledSequence = 0
    private var wasInControlCenter = false
    private var lastPointer: NSPoint?
    nonisolated static func enabled(_ type: SneakContentType) -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "systemHUDEnabled") as? Bool ?? true else { return false }
        let key: String
        switch type { case .volume: key = "systemHUDVolume"; case .brightness: key = "systemHUDBrightness"; case .backlight: key = "systemHUDBacklight"; default: return false }
        return defaults.object(forKey: key) as? Bool ?? true
    }
    func start() {
        guard timer == nil else { return }
        if let token = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.mediaKey(event) }
        }) { eventMonitors.append(token) }
        if let token = NSEvent.addLocalMonitorForEvents(matching: .systemDefined, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.mediaKey(event) }; return event
        }) { eventMonitors.append(token) }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in Task { @MainActor in await self?.poll() } }
        timer.tolerance = 0.015; RunLoop.main.add(timer, forMode: .common); self.timer = timer
    }
    private func mediaKey(_ event: NSEvent) {
        guard event.subtype.rawValue == 8, (event.data1 >> 8) & 0xff == 0xA else { return }
        let type: SneakContentType
        switch (event.data1 >> 16) & 0xffff {
        case 0, 1, 7: type = .volume
        case 2, 3: type = event.modifierFlags.contains(.command) ? .backlight : .brightness
        case 21, 22: type = .backlight
        default: return
        }
        guard Self.enabled(type) else { return }
        keyType = type; keyUntil = ProcessInfo.processInfo.systemUptime + 0.35; keySequence += 1
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(20))
            await poll()
        }
    }
    private func pointerInControlCenter() -> Bool {
        guard let point = CGEvent(source: nil)?.location,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        for window in windows {
            guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), rect.contains(point),
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t else { continue }
            let owner = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            if owner == "com.apple.controlcenter" || owner == "com.apple.systemuiserver" { return true }
            // The first real window under the pointer obscures lower windows.
            if (window[kCGWindowLayer as String] as? Int ?? 0) == 0 { return false }
        }
        return false
    }
    private func poll() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        let manualKey = ProcessInfo.processInfo.systemUptime < keyUntil
        let sequence = keySequence
        let pointer = NSEvent.mouseLocation
        let moved = lastPointer != pointer; lastPointer = pointer
        guard manualKey || moved || wasInControlCenter || CGEventSource.buttonState(.combinedSessionState, button: .left) else { return }
        let controlCenter = pointerInControlCenter()
        let manualDrag = controlCenter && wasInControlCenter && CGEventSource.buttonState(.combinedSessionState, button: .left)
        wasInControlCenter = controlCenter
        guard manualKey || controlCenter else { return }
        let kinds: [SneakContentType] = manualKey ? [keyType ?? .volume] : [.volume, .brightness, .backlight]
        for type in kinds where Self.enabled(type) {
            let value: Double?
            switch type {
            case .volume:
                value = VolumeManager.shared.levelForHUD().map(Double.init)
            case .brightness: value = await XPCHelperClient.shared.currentScreenBrightness().map(Double.init)
            case .backlight: value = await XPCHelperClient.shared.currentKeyboardBrightness().map(Double.init)
            default: value = nil
            }
            guard let value, value.isFinite else { continue }
            let level = min(1, max(0, value))
            let old = previous.updateValue(level, forKey: type)
            let changed = old.map { abs($0 - level) >= 0.002 } ?? false
            if (manualKey && (sequence != sampledSequence || changed)) || (manualDrag && changed) {
                BoringViewCoordinator.shared.toggleSneakPeek(status: true, type: type, value: CGFloat(level))
            }
        }
        if manualKey { sampledSequence = sequence }
    }
}
