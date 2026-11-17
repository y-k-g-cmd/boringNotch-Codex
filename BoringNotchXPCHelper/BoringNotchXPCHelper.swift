//
//  BoringNotchXPCHelper.swift
//  BoringNotchXPCHelper
//
//  Created by Alexander on 2025-11-16.
//

import Foundation
import AppKit
import Darwin
import ApplicationServices
import IOKit
import CoreGraphics
import CoreServices

class BoringNotchXPCHelper: NSObject, BoringNotchXPCHelperProtocol {
    let booksServer = RemoteBooksServer()
    @objc func booksRemote(_ action: String, with reply: @escaping (Data) -> Void) {
        booksServer.control(action, reply: reply)
    }
    weak var mediaConnection: NSXPCConnection?
    private var mediaTap: CFMachPort?
    private var mediaSource: CFRunLoopSource?
    private var mediaCategories = (false, false, false)
    private var mediaLease = Date.distantPast
    private var mediaWatchdog: Timer?

    @objc func configureMediaKeys(_ volume: Bool, brightness: Bool, backlight: Bool, with reply: @escaping (Bool) -> Void) {
        NotchMediaEventLoop.perform {
            self.mediaCategories = (volume, brightness, backlight)
            self.mediaLease = Date().addingTimeInterval(3)
            guard volume || brightness || backlight else { self.stopMediaKeysOnEventLoop(); reply(false); return }
            guard AXIsProcessTrusted(), self.mediaConnection != nil else { self.stopMediaKeysOnEventLoop(); reply(false); return }
            if self.mediaTap == nil {
                let type = CGEventType(rawValue: 14)!
                self.mediaTap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
                    options: .defaultTap, eventsOfInterest: CGEventMask(1 << type.rawValue),
                    callback: { _, type, event, info in
                        guard let info else { return Unmanaged.passUnretained(event) }
                        let owner = Unmanaged<BoringNotchXPCHelper>.fromOpaque(info).takeUnretainedValue()
                        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                            if Date() < owner.mediaLease, let tap = owner.mediaTap { CGEvent.tapEnable(tap: tap, enable: true) }
                            return Unmanaged.passUnretained(event)
                        }
                        guard Date() < owner.mediaLease,
                              let receiver = owner.mediaConnection?.remoteObjectProxyWithErrorHandler({ _ in
                                  owner.stopMediaKeys()
                              }) as? NotchMediaKeyReceiver,
                              let key = NSEvent(cgEvent: event), key.subtype.rawValue == 8 else {
                            return Unmanaged.passUnretained(event)
                        }
                        let code = (key.data1 >> 16) & 0xffff
                        let enabled: Bool
                        switch code {
                        case 0, 1, 7: enabled = owner.mediaCategories.0
                        case 2, 3: enabled = key.modifierFlags.contains(.command) ? owner.mediaCategories.2 : owner.mediaCategories.1
                        default: enabled = false
                        }
                        guard enabled else { return Unmanaged.passUnretained(event) }
                        // Forward only supported media-key down events; suppress matching key up too.
                        if (key.data1 >> 8) & 0xff == 0xA {
                            receiver.receiveMediaKey(key.data1, flags: key.modifierFlags.rawValue)
                        }
                        return nil
                    }, userInfo: Unmanaged.passUnretained(self).toOpaque())
                if let tap = self.mediaTap {
                    self.mediaSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
                    if let source = self.mediaSource { CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes) }
                    CGEvent.tapEnable(tap: tap, enable: true)
                    self.mediaWatchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                        guard let self else { return }
                        if Date() >= self.mediaLease { self.stopMediaKeysOnEventLoop() }
                    }
                }
            }
            reply(self.mediaTap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false)
        }
    }

    @objc func stopMediaKeys() {
        NotchMediaEventLoop.perform { self.stopMediaKeysOnEventLoop() }
    }
    private func stopMediaKeysOnEventLoop() {
        if let tap = mediaTap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source = mediaSource { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes) }
        mediaWatchdog?.invalidate(); mediaWatchdog = nil
        mediaSource = nil; mediaTap = nil; mediaLease = .distantPast
    }

    @objc func openCodexStatusSocket(with reply: @escaping (FileHandle?, Int32) -> Void) {
        // No caller-supplied path, commands, or data. The existing helper is unsandboxed.
        guard let user = getpwuid(getuid()), let directory = user.pointee.pw_dir else {
            reply(nil, ENOENT); return
        }
        let path = String(cString: directory) + "/.codex/ipc/ipc.sock"
        var info = stat()
        guard lstat(path, &info) == 0 else { reply(nil, errno); return }
        guard info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFSOCK else {
            reply(nil, EACCES); return
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { reply(nil, errno); return }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(fd); reply(nil, ENAMETOOLONG); return
        }
        withUnsafeMutableBytes(of: &address.sun_path) { target in
            bytes.withUnsafeBytes { target.copyBytes(from: $0) }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { let code = errno; Darwin.close(fd); reply(nil, code); return }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        reply(handle, 0)
    }

    
    @objc func isAccessibilityAuthorized(with reply: @escaping (Bool) -> Void) {
        reply(AXIsProcessTrusted())
    }

    @objc func requestAccessibilityAuthorization() {
        let options: CFDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    @objc func ensureAccessibilityAuthorization(_ promptIfNeeded: Bool, with reply: @escaping (Bool) -> Void) {
        if AXIsProcessTrusted() {
            reply(true)
            return
        }

        if promptIfNeeded {
            let options: CFDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            reply(AXIsProcessTrusted())
        }
    }
    
    private class KeyboardBrightnessClient {
        private static let keyboardID: UInt64 = 1
        private var clientInstance: NSObject?
        private let getSelector = NSSelectorFromString("brightnessForKeyboard:")
        private let setSelector = NSSelectorFromString("setBrightness:forKeyboard:")

        init() {
            var loaded = false
            let bundlePaths = [
                "/System/Library/PrivateFrameworks/CoreBrightness.framework",
                "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness"
            ]
            for path in bundlePaths where !loaded {
                if let bundle = Bundle(path: path) {
                    loaded = bundle.load()
                }
            }
            if loaded, let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type {
                clientInstance = cls.init()
            }
        }

        var isAvailable: Bool { clientInstance != nil }

        func currentBrightness() -> Float? {
            guard let clientInstance,
                  let fn: BrightnessGetter = methodIMP(on: clientInstance, selector: getSelector, as: BrightnessGetter.self)
            else { return nil }
            return fn(clientInstance, getSelector, Self.keyboardID)
        }

        func setBrightness(_ value: Float) -> Bool {
            guard let clientInstance,
                  let fn: BrightnessSetter = methodIMP(on: clientInstance, selector: setSelector, as: BrightnessSetter.self)
            else { return false }
            return fn(clientInstance, setSelector, value, Self.keyboardID).boolValue
        }

        private typealias BrightnessGetter = @convention(c) (NSObject, Selector, UInt64) -> Float
        private typealias BrightnessSetter = @convention(c) (NSObject, Selector, Float, UInt64) -> ObjCBool

        private func methodIMP<T>(on object: NSObject, selector: Selector, as type: T.Type) -> T? {
            guard let cls = object_getClass(object),
                  let method = class_getInstanceMethod(cls, selector)
            else { return nil }
            let imp = method_getImplementation(method)
            return unsafeBitCast(imp, to: type)
        }
    }

    private static let keyboardClient = KeyboardBrightnessClient()

    @objc func isKeyboardBrightnessAvailable(with reply: @escaping (Bool) -> Void) {
        reply(Self.keyboardClient.isAvailable)
    }

    @objc func currentKeyboardBrightness(with reply: @escaping (NSNumber?) -> Void) {
        reply(Self.keyboardClient.currentBrightness().map { NSNumber(value: $0) })
    }

    @objc func setKeyboardBrightness(_ value: Float, with reply: @escaping (Bool) -> Void) {
        reply(Self.keyboardClient.setBrightness(value))
    }
    // MARK: - Screen Brightness (moved from client app into helper)

    @objc func isScreenBrightnessAvailable(with reply: @escaping (Bool) -> Void) {
        var b: Float = 0
        reply(displayServicesGetBrightness(displayID: CGMainDisplayID(), out: &b) || ioServiceFor(displayID: CGMainDisplayID()) != nil)
    }

    @objc func currentScreenBrightness(with reply: @escaping (NSNumber?) -> Void) {
        var b: Float = 0
        if displayServicesGetBrightness(displayID: CGMainDisplayID(), out: &b) {
            reply(NSNumber(value: b))
            return
        }
        if let io = ioServiceFor(displayID: CGMainDisplayID()) {
            var level: Float = 0
            if IODisplayGetFloatParameter(io, 0, kIODisplayBrightnessKey as CFString, &level) == kIOReturnSuccess {
                IOObjectRelease(io)
                reply(NSNumber(value: level))
                return
            }
            IOObjectRelease(io)
        }
        reply(nil)
    }

    @objc func setScreenBrightness(_ value: Float, with reply: @escaping (Bool) -> Void) {
        let clamped = max(0, min(1, value))
        if displayServicesSetBrightness(displayID: CGMainDisplayID(), value: clamped) {
            reply(true)
            return
        }
        if let io = ioServiceFor(displayID: CGMainDisplayID()) {
            let ok = IODisplaySetFloatParameter(io, 0, kIODisplayBrightnessKey as CFString, clamped) == kIOReturnSuccess
            IOObjectRelease(io)
            reply(ok)
            return
        }
        reply(false)
    }

    // MARK: - Private helpers for DisplayServices / IOKit access
    private func displayServicesGetBrightness(displayID: CGDirectDisplayID, out: inout Float) -> Bool {
        guard let sym = dlsym(DisplayServicesHandle.handle, "DisplayServicesGetBrightness") else { return false }
        typealias Fn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
        let fn = unsafeBitCast(sym, to: Fn.self)
        var tmp: Float = 0
        let r = fn(displayID, &tmp)
        if r == 0 { out = tmp; return true }
        return false
    }

    private func displayServicesSetBrightness(displayID: CGDirectDisplayID, value: Float) -> Bool {
        guard let sym = dlsym(DisplayServicesHandle.handle, "DisplayServicesSetBrightness") else { return false }
        typealias Fn = @convention(c) (CGDirectDisplayID, Float) -> Int32
        let fn = unsafeBitCast(sym, to: Fn.self)
        return fn(displayID, value) == 0
    }

    private func ioServiceFor(displayID: CGDirectDisplayID) -> io_service_t? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &iterator) == kIOReturnSuccess else { return nil }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            let info = IODisplayCreateInfoDictionary(service, 0).takeRetainedValue() as NSDictionary
            if let vendorID = info[kDisplayVendorID] as? UInt32,
               let productID = info[kDisplayProductID] as? UInt32,
               vendorID == CGDisplayVendorNumber(displayID),
               productID == CGDisplayModelNumber(displayID) {
                return service
            }
            IOObjectRelease(service)
        }
        return nil
    }

    // MARK: - Helper handle for private framework
    private enum DisplayServicesHandle {
        static let handle: UnsafeMutableRawPointer? = {
            let paths = [
                "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
                "/System/Library/PrivateFrameworks/DisplayServices.framework/Versions/Current/DisplayServices"
            ]
            for p in paths {
                if let h = dlopen(p, RTLD_LAZY) { return h }
            }
            return nil
        }()
    }
}

// XPC services dispatch requests without running the main CFRunLoop. Event taps
// need a continuously serviced run loop, independent of XPC or quota operations.
private enum NotchMediaEventLoop {
    private static let loop: CFRunLoop = {
        let ready = DispatchSemaphore(value: 0)
        var result: CFRunLoop!
        let thread = Thread {
            result = CFRunLoopGetCurrent()
            let keepAlive = Timer(timeInterval: 3600, repeats: true) { _ in }
            RunLoop.current.add(keepAlive, forMode: .default)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "boringNotch.media-keys"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        return result
    }()

    static func perform(_ action: @escaping () -> Void) {
        let runLoop = loop
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, action)
        CFRunLoopWakeUp(runLoop)
    }
}

// User-initiated lookup only: no clipboard access, key simulation or background text capture.
extension BoringNotchXPCHelper {
    @objc func selectedDictionaryText(_ pid: Int32, with reply: @escaping (String, Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard AXIsProcessTrusted() else { reply("", false); return }
            guard pid > 0 else { reply("", true); return }
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.5)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
                  let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { reply("", true); return }
            let focused = value as! AXUIElement
            AXUIElementSetMessagingTimeout(focused, 0.5)
            var subrole: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(focused, kAXSubroleAttribute as CFString, &subrole)
            guard (subrole as? String) != "AXSecureTextField" else { reply("", true); return }
            var selected: CFTypeRef?
            guard AXUIElementCopyAttributeValue(focused, kAXSelectedTextAttribute as CFString, &selected) == .success,
                  let text = selected as? String else { reply("", true); return }
            let word = text.trimmingCharacters(in: .whitespacesAndNewlines)
            reply(word.count <= 200 ? word : "", true)
        }
    }

    @objc func dictionaryDefinition(_ word: String, with reply: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let clean = word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, clean.count <= 200 else { reply(nil); return }
            let text = clean as CFString
            let definition = DCSCopyTextDefinition(nil, text, CFRange(location: 0, length: CFStringGetLength(text)))?.takeRetainedValue()
            reply(definition.map { String(($0 as String).prefix(24000)) })
        }
    }
}
