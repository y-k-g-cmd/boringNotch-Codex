import AppKit
import Combine
import SwiftUI
import Darwin
import QuartzCore

struct NotchQuotaWindow: Decodable {
    let usedPercent: Double
    let minutes: Double
    let resetsAt: Double?
    var remaining: Int { Int(max(0, min(100, 100 - usedPercent)).rounded(.down)) }
    var label: String { minutes >= 1440 ? "\(Int(minutes / 1440))d" : minutes >= 60 ? "\(Int(minutes / 60))h" : "\(Int(minutes))m" }
}

struct NotchCPUSample {
    var previous: [UInt32]?
    mutating func percentage(_ ticks: [UInt32]) -> Double? {
        guard ticks.count == 4 else { return nil }
        defer { previous = ticks }
        guard let previous else { return nil }
        let changes = zip(ticks, previous).map { UInt64($0 &- $1) }
        let total = changes.reduce(0, +)
        guard total > 0 else { return nil }
        return Double(total - changes[Int(CPU_STATE_IDLE)]) / Double(total) * 100
    }
}

/// One in-process menu-bar item; no RunCat/usage app dependency.
/// Cat artwork: RunCat Neo, Copyright 2026 Kyome22, Apache-2.0.
/// See THIRD_PARTY_LICENSES.
@MainActor final class NotchResources: NSObject, ObservableObject, NSMenuDelegate {
    static let shared = NotchResources()
    @Published private(set) var cpu: Double?
    @Published private(set) var windows: [NotchQuotaWindow] = []
    @Published private(set) var updated: Date?
    @Published private(set) var usageError: String?
    @Published private(set) var loading = false
    private var item: NSStatusItem?
    private var timer: Timer?
    private var sample = NotchCPUSample()
    private var lastCPU = Date.distantPast
    private var lastUsage = Date.distantPast
    private let runnerIcon = NotchRunnerIconView(frame: .zero)
    var menuEnabled: Bool { UserDefaults.standard.object(forKey: "notchResourceMenu") as? Bool ?? true }
    var showCPU: Bool { UserDefaults.standard.object(forKey: "notchRunnerCPU") as? Bool ?? true }
    var usedDisplay: Bool { UserDefaults.standard.bool(forKey: "notchUsageUsed") }
    var usageInterval: Double { bounded("notchUsageInterval", fallback: 300, range: 60...900) }
    private func bounded(_ key: String, fallback: Double, range: ClosedRange<Double>) -> Double {
        let value = UserDefaults.standard.object(forKey: key) as? Double ?? fallback
        return value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
    }
    private var connection: NSXPCConnection?
    private var requestToken: UUID?
    private var awake = true
    private var observers: [NSObjectProtocol] = []
    private var menuVisible = false
    private var started = false
    var runnerEnabled: Bool { UserDefaults.standard.object(forKey: "notchRunnerEnabled") as? Bool ?? true }
    var usageEnabled: Bool { UserDefaults.standard.object(forKey: "notchUsageEnabled") as? Bool ?? true }
    var isChinese: Bool { (UserDefaults.standard.string(forKey: "settingsLanguage") ?? "zh-Hans").hasPrefix("zh") }
    func text(_ zh: String, _ en: String) -> String { isChinese ? zh : en }
    var quotaSummary: String {
        guard !windows.isEmpty else { return loading ? text("用量…", "Usage…") : text("用量 --", "Usage --") }
        return windows.map { "\($0.label) \(usedDisplay ? Int($0.usedPercent.rounded(.up)) : $0.remaining)%" }.joined(separator: " · ") + (usageError == nil ? "" : " ⚠")
    }
    func start() {
        guard !started else { return }; started = true
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.awake = false }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.awake = true; self?.sample.previous = nil; self?.lastUsage = .distantPast }
        })
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer.tolerance = 0.04; RunLoop.main.add(timer, forMode: .common); self.timer = timer
        tick()
    }
    private func tick() {
        guard awake else { return }
        guard runnerEnabled || usageEnabled else {
            if let item { NSStatusBar.system.removeStatusItem(item); self.item = nil }
            if loading { requestToken = nil; connection?.invalidate(); connection = nil; loading = false }
            lastUsage = .distantPast
            return
        }
        if !menuEnabled, let item { NSStatusBar.system.removeStatusItem(item); self.item = nil }
        if menuEnabled && item == nil {
            let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            status.button?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            let menu = NSMenu(); menu.delegate = self; status.menu = menu; item = status
        }
        if runnerEnabled && Date().timeIntervalSince(lastCPU) >= 2 {
            lastCPU = Date()
            var info = host_cpu_load_info(); var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
            let host = mach_host_self()
            let result = withUnsafeMutablePointer(to: &info) { p in
                p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count) }
            }
            mach_port_deallocate(mach_task_self_, host)
            if result == KERN_SUCCESS { cpu = sample.percentage([info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3]) }
            else { cpu = nil }
        }
        if usageEnabled && !loading && Date().timeIntervalSince(lastUsage) >= usageInterval { refreshUsage() }
        guard !menuVisible, menuEnabled else { return }
        if let button = item?.button {
            let width = bounded("notchRunnerSize", fallback: 26, range: 20...32)
            let size = NSSize(width: width, height: width * 18 / 28)
            if runnerEnabled {
                if button.image?.size != size {
                    button.image = NSImage(size: size, flipped: false) { _ in true }
                }
                button.imagePosition = .imageLeading
                if runnerIcon.superview !== button { runnerIcon.removeFromSuperview(); button.addSubview(runnerIcon) }
                runnerIcon.isHidden = false
                let imageRect = button.cell?.imageRect(forBounds: button.bounds) ?? NSRect(origin: .zero, size: size)
                runnerIcon.frame = imageRect
                let fps = min(bounded("notchRunnerFPS", fallback: 24, range: 12...30), (2 + (cpu ?? 0) * 0.25) * bounded("notchRunnerSpeed", fallback: 1, range: 0.4...2.5))
                runnerIcon.update(framesPerSecond: fps, flipped: UserDefaults.standard.bool(forKey: "notchRunnerFlipped"), reducedMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            } else { button.image = nil; runnerIcon.isHidden = true }
        }
        var parts: [String] = []
        if runnerEnabled && showCPU { parts.append(cpu.map { "\(Int($0.rounded()))%" } ?? "--%") }
        if usageEnabled { parts.append(quotaSummary) }
        let title = parts.joined(separator: "  ")
        if item?.button?.title != title { item?.button?.title = title }
        item?.button?.toolTip = text("CPU 负载 · Codex 额度，点击查看详情", "CPU load · Codex quota. Click for details.")
        item?.button?.setAccessibilityLabel(item?.button?.toolTip)
    }
    func refreshUsage() {
        guard usageEnabled, !loading else { return }
        loading = true; lastUsage = Date()
        let token = UUID(); requestToken = token
        let connection = NSXPCConnection(serviceName: "\(Bundle.main.bundleIdentifier ?? "io.github.y-k-g-cmd.boringnotchcodex").BoringNotchXPCHelper")
        self.connection = connection
        connection.remoteObjectInterface = NSXPCInterface(with: BoringNotchXPCHelperProtocol.self)
        connection.resume()
        let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] _ in
            Task { @MainActor in self?.finish(token: token, data: nil, error: "用量服务不可用") }
        } as? BoringNotchXPCHelperProtocol
        proxy?.readCodexUsage { [weak self] data, error in
            Task { @MainActor in self?.finish(token: token, data: data, error: error) }
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(25))
            self?.finish(token: token, data: nil, error: "用量读取超时")
        }
    }
    private func finish(token: UUID, data: Data?, error: String?) {
        guard requestToken == token else { return }
        requestToken = nil; connection?.invalidate(); connection = nil; loading = false
        struct Payload: Decodable { let windows: [NotchQuotaWindow] }
        if let data, let payload = try? JSONDecoder().decode(Payload.self, from: data), !payload.windows.isEmpty {
            windows = payload.windows; updated = Date(); usageError = nil
        } else { usageError = error ?? "用量暂不可用" }
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func line(_ title: String) { let row = NSMenuItem(title: title, action: nil, keyEquivalent: ""); menu.addItem(row) }
        line("boringNotch · " + text("系统与用量", "System & usage"))
        if runnerEnabled { line("CPU  " + (cpu.map { "\(Int($0.rounded()))%" } ?? "--")) }
        menu.addItem(.separator())
        if usageEnabled {
            for window in windows {
                line("Codex \(window.label) · " + text("剩余", "remaining") + " \(window.remaining)%")
                if let reset = window.resetsAt { line(text("重置：", "Resets: ") + Date(timeIntervalSince1970: reset).formatted(date: .abbreviated, time: .shortened)) }
            }
            if let updated { line(text("更新：", "Updated: ") + updated.formatted(date: .omitted, time: .standard)) }
            if usageError != nil { line(text("更新失败；已有数值为上次结果", "Refresh failed; showing last successful result")) }
            let refresh = NSMenuItem(title: loading ? text("正在刷新…", "Refreshing…") : text("刷新用量", "Refresh usage"), action: #selector(refreshClicked), keyEquivalent: "")
            refresh.target = self; refresh.isEnabled = !loading; menu.addItem(refresh)
        }
        line(text("设置 → Codex 可调整外观与刷新间隔", "Settings → Codex for appearance and refresh interval"))
    }
    func menuWillOpen(_ menu: NSMenu) { menuVisible = true }
    func menuDidClose(_ menu: NSMenu) { menuVisible = false }
    @objc private func refreshClicked() { refreshUsage() }
    static func cat(frame: Int) -> NSImage {
        let image = NSImage(named: "NotchRunCatFrame\(frame % 5)")?.copy() as? NSImage
            ?? NSImage(systemSymbolName: "cat.fill", accessibilityDescription: "Cat") ?? NSImage()
        image.isTemplate = true
        return image
    }
}

struct NotchResourceBadge: View {
    @ObservedObject private var resources = NotchResources.shared
    @AppStorage("notchUsageEnabled") private var usage = true
    @AppStorage("notchRunnerEnabled") private var runner = true
    @AppStorage("notchResourceCard") private var showCard = true
    var body: some View {
        HStack(spacing: 6) {
            if runner && showCard { Image(nsImage: NotchResources.cat(frame: 0)).resizable().frame(width: 20, height: 15)
                Text(resources.cpu.map { "\(Int($0.rounded()))%" } ?? "--%") }
            if usage && showCard { Text(resources.quotaSummary).foregroundStyle(.secondary) }
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .lineLimit(1).help(resources.text("CPU · Codex 额度（详情见菜单栏）", "CPU · Codex quota (details in menu bar)"))
    }
}


/// Contents animation is rendered by Core Animation, not repeated status-button
/// repaints. Changing speed preserves the current phase, like RunCat Neo.
@MainActor private final class NotchRunnerIconView: NSView {
    private let silhouette = CALayer()
    private let alphaMask = CALayer()
    private var currentSpeed: Float = -1
    private var reduced = false
    private lazy var frames: [CGImage] = (0..<5).compactMap { NotchResources.cat(frame: $0).cgImage(forProposedRect: nil, context: nil, hints: nil) }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        silhouette.mask = alphaMask; layer?.addSublayer(silhouette)
        alphaMask.contentsGravity = .resizeAspect
        alphaMask.contentsScale = 2
        updateColor()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        silhouette.frame = bounds; alphaMask.frame = bounds
        CATransaction.commit()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateColor() }
    private func updateColor() { effectiveAppearance.performAsCurrentDrawingAppearance { silhouette.backgroundColor = NSColor.labelColor.cgColor } }
    func update(framesPerSecond: Double, flipped: Bool, reducedMotion: Bool) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        silhouette.transform = CATransform3DMakeScale(flipped ? -1 : 1, 1, 1)
        if reducedMotion {
            alphaMask.removeAnimation(forKey: "running"); alphaMask.contents = frames.first; reduced = true
        } else {
            if reduced || alphaMask.animation(forKey: "running") == nil {
                let animation = CAKeyframeAnimation(keyPath: "contents")
                animation.values = frames; animation.calculationMode = .discrete
                animation.duration = 2.5; animation.repeatCount = .infinity; animation.isRemovedOnCompletion = false
                alphaMask.speed = 1; alphaMask.timeOffset = 0; alphaMask.beginTime = 0
                alphaMask.add(animation, forKey: "running"); currentSpeed = -1; reduced = false
            }
            let speed = Float(max(0.2, framesPerSecond / 2))
            if abs(speed - currentSpeed) > 0.01 {
                let now = CACurrentMediaTime()
                alphaMask.timeOffset = alphaMask.convertTime(now, from: nil)
                alphaMask.beginTime = now; alphaMask.speed = speed; currentSpeed = speed
            }
        }
        CATransaction.commit()
    }
}
