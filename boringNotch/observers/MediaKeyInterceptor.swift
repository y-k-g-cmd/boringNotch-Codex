//
//  MediaKeyInterceptor.swift
//  boringNotch
//
//  Created by JeanLouis on 21/08/2025.

import Foundation
import AppKit
import os.log
import ApplicationServices
import IOKit
import Defaults

private let kSystemDefinedEventType = CGEventType(rawValue: 14)!

final class MediaKeyInterceptor: NSObject, NotchMediaKeyReceiver {
    static let shared = MediaKeyInterceptor()

    private enum NXKeyType: Int { case soundUp = 0, soundDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7 }

    private var eventTap: CFMachPort? = nil
    private var runLoopSource: CFRunLoopSource? = nil
    private let volumeStep: Float = 1.0 / 16.0
    private let brightnessStep: Float = 1.0 / 16.0

    private override init() { super.init() }

    private var helperConnection: NSXPCConnection?
    private var heartbeat: Timer?

    func isAccessibilityAuthorized() async -> Bool {
        await XPCHelperClient.shared.isAccessibilityAuthorized()
    }

    func start(requireAccessibility: Bool = true, promptIfNeeded: Bool = false) {
        guard helperConnection == nil else { return }
        let connection = NSXPCConnection(serviceName: "\(Bundle.main.bundleIdentifier!).BoringNotchXPCHelper")
        connection.remoteObjectInterface = NSXPCInterface(with: BoringNotchXPCHelperProtocol.self)
        connection.exportedInterface = NSXPCInterface(with: NotchMediaKeyReceiver.self)
        connection.exportedObject = self
        connection.interruptionHandler = { [weak self] in
            DispatchQueue.main.async { self?.stop() }
        }
        connection.invalidationHandler = { [weak self] in
            DispatchQueue.main.async { self?.stop() }
        }
        helperConnection = connection
        connection.resume()
        refreshMediaLease()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refreshMediaLease() }
        heartbeat = timer
        RunLoop.main.add(timer, forMode: .common)
        if promptIfNeeded {
            Task { if !(await self.isAccessibilityAuthorized()) { self.requestAccessibilityAuthorization() } }
        }
    }

    private func refreshMediaLease() {
        guard let service = helperConnection?.remoteObjectProxyWithErrorHandler({ _ in }) as? BoringNotchXPCHelperProtocol else { return }
        service.configureMediaKeys(SystemHUDMonitor.enabled(.volume), brightness: SystemHUDMonitor.enabled(.brightness),
                                   backlight: SystemHUDMonitor.enabled(.backlight)) { enabled in
            UserDefaults.standard.set(enabled, forKey: "mediaKeyInterceptionActive")
        }
    }

    func stop() {
        heartbeat?.invalidate(); heartbeat = nil
        let connection = helperConnection; helperConnection = nil
        (connection?.remoteObjectProxy as? BoringNotchXPCHelperProtocol)?.stopMediaKeys()
        connection?.interruptionHandler = nil; connection?.invalidationHandler = nil
        connection?.invalidate()
        UserDefaults.standard.set(false, forKey: "mediaKeyInterceptionActive")
    }

    func receiveMediaKey(_ data: Int, flags: UInt) {
        // No ordinary keyboard text is forwarded. Reuse the existing adjustment logic
        // locally without posting a synthetic event to the system.
        DispatchQueue.main.async {
            guard self.helperConnection != nil,
                  let event = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                      modifierFlags: NSEvent.ModifierFlags(rawValue: flags), timestamp: 0,
                      windowNumber: 0, context: nil, subtype: 8, data1: data, data2: 0),
                  let cgEvent = event.cgEvent else { return }
            _ = self.handleSystemDefined(event: cgEvent)
        }
    }

    func requestAccessibilityAuthorization() {
        XPCHelperClient.shared.requestAccessibilityAuthorization()
        // macOS may suppress a repeated prompt. Always provide a visible route
        // to the permission page; the user still grants access in System Settings.
        DispatchQueue.main.async {
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                guard error != nil else { return }
                DispatchQueue.main.async {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
                }
            }
        }
    }

    func ensureAccessibilityAuthorization(promptIfNeeded: Bool = false) async -> Bool {
        let granted = await isAccessibilityAuthorized()
        if promptIfNeeded && !granted { requestAccessibilityAuthorization() }
        return granted
    }


    private func handleSystemDefined(event cgEvent: CGEvent) -> Unmanaged<CGEvent>? {
        guard let nsEvent = NSEvent(cgEvent: cgEvent), nsEvent.type == .systemDefined, nsEvent.subtype.rawValue == 8 else {
            return Unmanaged.passUnretained(cgEvent)
        }
        let data1 = nsEvent.data1
        let keyCode = (data1 & 0xFFFF_0000) >> 16
        let keyFlags = (data1 & 0x0000_FFFF)
        let stateByte = (keyFlags & 0xFF00) >> 8
        // 0xA = key down, 0xB = key up for media (systemDefined subtype 8) events.
        // Only handle the key-down event to avoid duplicate handling.
        let isKeyDown = (stateByte == 0xA)

        guard isKeyDown else { return Unmanaged.passUnretained(cgEvent) }
        guard let nx = NXKeyType(rawValue: keyCode) else {
                return Unmanaged.passUnretained(cgEvent)
            }
        // Inspect modifier flags to support option/shift/command behaviors
        let flags = nsEvent.modifierFlags
        let optionDown = flags.contains(.option)
        let shiftDown = flags.contains(.shift)
        let commandDown = flags.contains(.command)
        let category: SneakContentType = (nx == .soundUp || nx == .soundDown || nx == .mute)
            ? .volume : commandDown ? .backlight : .brightness
        guard SystemHUDMonitor.enabled(category) else { return Unmanaged.passUnretained(cgEvent) }

        // Read configured action for Option alone presses
        let optionAction = Defaults[.optionKeyAction]

        // Determine step multiplier: Option+Shift -> quarter step (1/64)
        let stepDivisor: Float = (optionDown && shiftDown) ? 4.0 : 1.0

        switch nx {
        case .soundUp:
            // Option + media: either show settings, show HUD only, or do nothing
            if optionDown && !shiftDown {
                switch optionAction {
                case .openSettings:
                    openSystemSettings(for: nx)
                    return nil
                case .showHUD:
                    Task { @MainActor in
                        let v = VolumeManager.shared.rawVolume
                        BoringViewCoordinator.shared.toggleSneakPeek(status: true, type: .volume, value: CGFloat(v))
                    }
                    return nil
                case .none:
                    return nil
                }
            }

            // Use the high-level API which also shows the HUD immediately with the target value
            Task { @MainActor in
                VolumeManager.shared.increase(stepDivisor: stepDivisor)
            }
            return nil
        case .soundDown:
            if optionDown && !shiftDown {
                switch optionAction {
                case .openSettings:
                    openSystemSettings(for: nx)
                    return nil
                case .showHUD:
                    Task { @MainActor in
                        let v = VolumeManager.shared.rawVolume
                        BoringViewCoordinator.shared.toggleSneakPeek(status: true, type: .volume, value: CGFloat(v))
                    }
                    return nil
                case .none:
                    return nil
                }
            }

            Task { @MainActor in
                VolumeManager.shared.decrease(stepDivisor: stepDivisor)
            }
            return nil
        case .mute:
            if optionDown && !shiftDown {
                switch optionAction {
                case .openSettings:
                    openSystemSettings(for: nx)
                    return nil
                case .showHUD:
                    Task { @MainActor in
                        let v = VolumeManager.shared.rawVolume
                        BoringViewCoordinator.shared.toggleSneakPeek(status: true, type: .volume, value: CGFloat(v))
                    }
                    return nil
                case .none:
                    return nil
                }
            }

            Task { @MainActor in
                VolumeManager.shared.toggleMuteAction()
            }
            return nil
        case .brightnessUp:
            if optionDown && !shiftDown {
               if optionDown && !shiftDown {
                    switch optionAction {
                    case .openSettings:
                        if commandDown {
                            openKeyboardSettings()

                        } else {
                            openSystemSettings(for: nx)
                        }
                        return nil
                    case .showHUD:
                        if commandDown {
                            Task { @MainActor in
                                let v = KeyboardBacklightManager.shared.rawBrightness
                                BoringViewCoordinator.shared.toggleSneakPeek(status: true, type: .backlight, value: CGFloat(v))
                            }
                        } else {
                            Task { @MainActor in
                                let v = BrightnessManager.shared.rawBrightness
                                BoringViewCoordinator.shared.toggleSneakPeek(status: true, type: .brightness, value: CGFloat(v))
                            }
                        }
                        return nil
                    case .none:
                        return nil
                    }
                }
            }

        let delta = brightnessStep / stepDivisor
        if commandDown {
            Task { @MainActor in
                KeyboardBacklightManager.shared.setRelative(delta: delta)
            }
        } else {
            Task { @MainActor in
                BrightnessManager.shared.setRelative(delta: delta)
            }
        }
        return nil

        case .brightnessDown:
            if optionDown && !shiftDown {
               if optionDown && !shiftDown {
                    switch optionAction {
                    case .openSettings:
                        if commandDown {
                            openKeyboardSettings()

                        } else {
                            openSystemSettings(for: nx)
                        }
                        return nil
                    case .showHUD:
                        if commandDown {
                            Task { @MainActor in
                                let v = KeyboardBacklightManager.shared.rawBrightness
                                BoringViewCoordinator.shared.toggleSneakPeek(status: true, type: .backlight, value: CGFloat(v))
                            }
                        } else {
                            Task { @MainActor in
                                let v = BrightnessManager.shared.rawBrightness
                                BoringViewCoordinator.shared.toggleSneakPeek(status: true, type: .brightness, value: CGFloat(v))
                            }
                        }
                        return nil
                    case .none:
                        return nil
                    }
                }
            }

            let delta = -(brightnessStep / stepDivisor)
            if commandDown {
                Task { @MainActor in
                    KeyboardBacklightManager.shared.setRelative(delta: delta)
                }
            } else {
                Task { @MainActor in
                    BrightnessManager.shared.setRelative(delta: delta)
                }
            }
            return nil
        }
    }

    private func openSystemSettings(for key: NXKeyType) {
        var urlString: String?
        switch key {
        case .soundUp, .soundDown, .mute:
            urlString = "x-apple.systempreferences:com.apple.preference.sound"
        case .brightnessUp, .brightnessDown:
            // Apple opens Displays for brightness keys
            urlString = "x-apple.systempreferences:com.apple.preference.displays"
        }

        guard let s = urlString, let url = URL(string: s) else { return }
        DispatchQueue.main.async {
            NSWorkspace.shared.open(url)
        }
    }

    private func openKeyboardSettings() {
        let urlString = "x-apple.systempreferences:com.apple.preference.keyboard"
        guard let url = URL(string: urlString) else { return }
        DispatchQueue.main.async {
            NSWorkspace.shared.open(url)
        }
    }

}
