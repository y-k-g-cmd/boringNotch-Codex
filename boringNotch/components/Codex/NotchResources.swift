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

struct QuotaFailurePolicy {
    private(set) var reported = false
    mutating func result(success: Bool, connected: Bool, enabled: Bool) -> Bool {
        if success { reported = false; return false }
        guard connected, enabled, !reported else { return false }
        reported = true
        return true
    }
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
@MainActor final class NotchResources: NSObject, ObservableObject {
    static let shared = NotchResources()
    @Published private(set) var cpu: Double?
    @Published private(set) var windows: [NotchQuotaWindow] = []
    @Published private(set) var updated: Date?
    @Published private(set) var usageError: String?
    @Published private(set) var loading = false
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var memoryUsed: Double?
    @Published private(set) var memoryPressure: Int?
    @Published private(set) var justUpdated = false
    private var quotaDiagnosticActive = false
    private var quotaDiagnosticEvents: [[String: Any]] = []
    private var quotaDiagnosticStart = Date()
    private var quotaDiagnosticObservation: AnyCancellable?
    func recordQuotaDiagnostic(_ event: String) {
        guard quotaDiagnosticActive else { return }
        quotaDiagnosticEvents.append(["event": event, "elapsed": Date().timeIntervalSince(quotaDiagnosticStart), "connected": CodexMonitor.shared.connected])
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let report: [String: Any] = ["test": "quota-warning-once", "events": quotaDiagnosticEvents]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("NotchQuotaWarningTest.json"), options: .atomic)
        }
    }
    private func runQuotaDiagnosticIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("--test-quota-warning-once") else { return }
        Task { @MainActor in
            // Wait for the normal connection and real in-flight quota read to finish.
            let deadline = Date().addingTimeInterval(90)
            while (!CodexMonitor.shared.connected || loading) && Date() < deadline {
                try? await Task.sleep(for: .milliseconds(250))
            }
            quotaDiagnosticStart = Date(); quotaDiagnosticActive = true
            guard CodexMonitor.shared.connected, !loading, usageEnabled, warningEnabled else {
                recordQuotaDiagnostic("blocked_not_connected_or_disabled"); quotaDiagnosticActive = false; return
            }
            let previousError = usageError
            let previousPolicy = failurePolicy
            let previousUpdatedFeedback = justUpdated
            failurePolicy = QuotaFailurePolicy()
            quotaDiagnosticObservation = CodexMonitor.shared.$connected.sink { [weak self] _ in
                self?.recordQuotaDiagnostic("connection_observed")
            }
            recordQuotaDiagnostic("started")
            defer {
                usageError = previousError; failurePolicy = previousPolicy; justUpdated = previousUpdatedFeedback
                recordQuotaDiagnostic("restored")
                quotaDiagnosticObservation = nil; quotaDiagnosticActive = false
            }
            @MainActor func fail(_ number: Int) {
                guard CodexMonitor.shared.connected else { recordQuotaDiagnostic("aborted_connection_changed"); return }
                let token = UUID(); requestToken = token
                recordQuotaDiagnostic("injected_failure_\(number)")
                finish(token: token, data: nil, error: "模拟额度读取失败（一次性诊断）")
            }
            fail(1)
            let showDeadline = Date().addingTimeInterval(30)
            while !quotaDiagnosticEvents.contains(where: { $0["event"] as? String == "presented" }) && Date() < showDeadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard quotaDiagnosticEvents.contains(where: { $0["event"] as? String == "presented" }) else { recordQuotaDiagnostic("failed_no_presentation"); return }
            try? await Task.sleep(for: .seconds(1))
            fail(2)
            let closeDeadline = Date().addingTimeInterval(warningSeconds + 20)
            while !quotaDiagnosticEvents.contains(where: { $0["event"] as? String == "closed" }) && Date() < closeDeadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard quotaDiagnosticEvents.contains(where: { $0["event"] as? String == "closed" }) else { recordQuotaDiagnostic("incomplete_hover_or_interaction_held_open"); return }
            try? await Task.sleep(for: .seconds(1))
            fail(3)
            try? await Task.sleep(for: .seconds(3))
            recordQuotaDiagnostic("finished")
        }
    }

    private var failurePolicy = QuotaFailurePolicy()
    private let popover = NSPopover()
    private var pressureSource: DispatchSourceMemoryPressure?
    static let quotaWarning = Notification.Name("NotchQuotaReadFailure")
    var warningEnabled: Bool { UserDefaults.standard.object(forKey: "notchQuotaWarnings") as? Bool ?? true }
    var warningSeconds: Double { bounded("notchQuotaWarningSeconds", fallback: 6, range: 3...30) }
    var pressureLabel: String {
        switch memoryPressure {
        case 1: return text("内存压力：正常", "Pressure: normal")
        case 2: return text("内存压力：偏高", "Pressure: elevated")
        case 4: return text("内存压力：高", "Pressure: high")
        default: return text("内存压力：待采样", "Pressure: pending")
        }
    }
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
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let source else { return }
            Task { @MainActor in self?.memoryPressure = source.data.contains(.critical) ? 4 : source.data.contains(.warning) ? 2 : 1 }
        }
        pressureSource = source; source.resume()
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.awake = false }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.awake = true; self?.sample.previous = nil; self?.cpuHistory = []; self?.lastUsage = .distantPast }
        })
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer.tolerance = 0.04; RunLoop.main.add(timer, forMode: .common); self.timer = timer
        tick()
        runQuotaDiagnosticIfRequested()
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
            status.button?.target = self; status.button?.action = #selector(togglePanel)
            item = status
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
            if let cpu { cpuHistory.append(cpu); if cpuHistory.count > 30 { cpuHistory.removeFirst(cpuHistory.count - 30) } }
            sampleMemory()
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
        guard usageEnabled, !loading, !quotaDiagnosticActive else { return }
        loading = true; justUpdated = false; lastUsage = Date()
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
        if let data, let payload = try? JSONDecoder().decode(Payload.self, from: data), !payload.windows.isEmpty,
           payload.windows.allSatisfy({ $0.usedPercent.isFinite && (0...100).contains($0.usedPercent) && $0.minutes.isFinite && $0.minutes > 0 && $0.minutes <= 52560000 && ($0.resetsAt?.isFinite ?? true) }) {
            windows = payload.windows; updated = Date(); usageError = nil; justUpdated = true
            _ = failurePolicy.result(success: true, connected: false, enabled: warningEnabled)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard self?.requestToken == nil else { return }
                self?.justUpdated = false
            }
        } else {
            justUpdated = false
            usageError = error ?? "用量暂不可用"
            if failurePolicy.result(success: false, connected: CodexMonitor.shared.connected, enabled: warningEnabled && usageEnabled) {
                recordQuotaDiagnostic("notification_posted")
                NotificationCenter.default.post(name: Self.quotaWarning, object: nil)
            }
        }
    }
    @objc private func togglePanel() {
        guard let button = item?.button else { return }
        if popover.isShown { popover.performClose(nil); return }
        popover.behavior = .transient
        let controller = NSHostingController(rootView: ResourcePanel(resources: self))
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller
        popover.contentSize = controller.view.fittingSize
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
    func openCodex() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") { NSWorkspace.shared.open(url) }
        else if let url = URL(string: "codex://") { NSWorkspace.shared.open(url) }
    }
    func openSettings() { popover.performClose(nil); SettingsWindowController.shared.showWindow() }
    private func sampleMemory() {
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        if result == KERN_SUCCESS {
            memoryUsed = min(Double(ProcessInfo.processInfo.physicalMemory), Double(UInt64(info.active_count) + UInt64(info.wire_count) + UInt64(info.compressor_page_count)) * Double(vm_kernel_page_size))
        } else { memoryUsed = nil }
        var level: Int32 = 0; var size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 && [1, 2, 4].contains(level) { memoryPressure = Int(level) }
    }
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

struct ResourceRefreshButton: View {
    @ObservedObject var resources = NotchResources.shared
    var body: some View {
        Group {
            if resources.loading {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small).tint(.cyan)
                    Text(resources.text("正在刷新…", "Refreshing…")).foregroundStyle(.white)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.cyan.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel(resources.text("正在刷新，请稍候", "Refreshing, please wait"))
            } else {
                Button { resources.refreshUsage() } label: {
                    Label(resources.usageError != nil ? resources.text("刷新失败 · 重试", "Failed · Retry") : resources.justUpdated ? resources.text("已更新", "Updated") : resources.text("刷新", "Refresh"), systemImage: resources.justUpdated ? "checkmark.circle.fill" : "arrow.clockwise")
                }.buttonStyle(.bordered)
            }
        }.font(.system(size: 12, weight: .medium))
    }
}

struct ResourcePanel: View {
    @ObservedObject var resources = NotchResources.shared
    @AppStorage("notchUsageUsed") private var used = false
    @AppStorage("notchUsageEnabled") private var usage = true
    @AppStorage("notchRunnerEnabled") private var runner = true
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(resources.text("系统与用量", "System & usage")).font(.system(size: 19, weight: .semibold))
                    Text("boringNotch").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { resources.openSettings() } label: { Image(systemName: "gearshape").frame(width: 28, height: 28) }
                    .buttonStyle(.plain).help(resources.text("设置", "Settings"))
            }
            if runner {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack { ResourceRunnerPreview().frame(width: 24, height: 16); Text("CPU").foregroundStyle(.secondary) }
                        Text(resources.cpu.map { "\(Int($0.rounded()))%" } ?? "—").font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
                        CPUTrend(values: resources.cpuHistory).stroke(.cyan, style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round)).frame(height: 34)
                        Text(resources.text("最近一分钟", "Last minute")).font(.caption2).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).frame(height: 132, alignment: .top).padding(12).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 10) {
                        Label(resources.text("内存", "Memory"), systemImage: "memorychip").foregroundStyle(.secondary)
                        Text(resources.memoryUsed.map { String(format: "%.1f", $0 / 1_073_741_824) + " GB" } ?? "—").font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text(resources.text("共 ", "of ") + String(format: "%.0f GB", Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824)).font(.caption).foregroundStyle(.secondary)
                        ResourceMeter(value: (resources.memoryUsed ?? 0) / Double(ProcessInfo.processInfo.physicalMemory), color: .mint).frame(height: 5)
                        Text(resources.pressureLabel).font(.caption2).foregroundStyle(resources.memoryPressure == 4 ? .red : resources.memoryPressure == 2 ? .orange : .secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).frame(height: 132, alignment: .top).padding(12).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
                }
            }
            if usage {
                HStack { Text("Codex").font(.headline); Spacer(); ResourceRefreshButton(resources: resources) }
                Picker(resources.text("额度显示", "Quota display"), selection: $used) {
                    Text(resources.text("剩余", "Remaining")).tag(false)
                    Text(resources.text("已用", "Used")).tag(true)
                }.pickerStyle(.segmented).labelsHidden()
                if resources.usageError != nil {
                    Label(resources.text("读取失败 · 以下为上次成功数据", "Read failed · Last successful data"), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                if resources.windows.isEmpty {
                    Text(resources.loading ? resources.text("正在获取额度，请稍候…", "Fetching quota…") : resources.text("暂无额度数据", "No quota data"))
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 20)
                } else {
                    ScrollView {
                        VStack(spacing: 10) {
                            ForEach(Array(resources.windows.enumerated()), id: \.offset) { _, window in quotaCard(window) }
                        }
                    }.frame(height: CGFloat(min(resources.windows.count, 2)) * 108 + CGFloat(max(0, min(resources.windows.count, 2) - 1)) * 10).scrollIndicators(.hidden)
                }
                Text((resources.updated.map { resources.text("更新于 ", "Updated ") + $0.formatted(date: .omitted, time: .standard) } ?? resources.text("尚未成功更新", "Not updated yet")) + " · " + resources.text("每 \(Int(resources.usageInterval / 60)) 分钟刷新", "Every \(Int(resources.usageInterval / 60)) min"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Button(resources.text("打开 Codex", "Open Codex")) { resources.openCodex() }
                Spacer()
                Button(resources.text("活动监视器", "Activity Monitor")) { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")) }
            }.buttonStyle(.plain).font(.system(size: 12, weight: .medium))
        }.padding(18).frame(width: 370).background(Color(nsColor: .windowBackgroundColor))
            .preferredColorScheme(.dark)
    }
    private func quotaCard(_ window: NotchQuotaWindow) -> some View {
        let amount = used ? Int(window.usedPercent.rounded(.up)) : window.remaining
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(window.minutes == 10080 ? resources.text("每周额度", "Weekly quota") : resources.text("\(window.label) 额度", "\(window.label) quota")).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Text("\(amount)%").font(.system(size: 23, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            ResourceMeter(value: Double(amount) / 100, color: window.remaining <= 10 ? .orange : .cyan).frame(height: 5)
            if let reset = window.resetsAt {
                let date = Date(timeIntervalSince1970: reset)
                Text(resources.text("重置 ", "Resets ") + date.formatted(.relative(presentation: .numeric)))
                    .font(.caption).foregroundStyle(.secondary)
                    .help(date.formatted(date: .complete, time: .shortened))
            } else { Text(resources.text("重置时间未知", "Reset time unavailable")).font(.caption).foregroundStyle(.secondary) }
        }.padding(12).frame(height: 108).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct ResourceMeter: View {
    let value: Double
    let color: Color
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.09))
                Capsule().fill(color).frame(width: geometry.size.width * max(0, min(1, value)))
            }
        }
    }
}

struct CPUTrend: Shape {
    var values: [Double]
    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1 else { return path }
        for (index, value) in values.enumerated() {
            let point = CGPoint(x: rect.width * Double(index) / Double(values.count - 1), y: rect.height * (1 - max(0, min(100, value)) / 100))
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}

private struct ResourceRunnerPreview: NSViewRepresentable {
    func makeNSView(context: Context) -> NotchRunnerIconView { NotchRunnerIconView(frame: NSRect(x: 0, y: 0, width: 24, height: 16)) }
    func updateNSView(_ view: NotchRunnerIconView, context: Context) {
        view.update(framesPerSecond: min(24, 2 + (NotchResources.shared.cpu ?? 0) * 0.25), flipped: UserDefaults.standard.bool(forKey: "notchRunnerFlipped"), reducedMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }
}

struct QuotaWarningCard: View {
    @ObservedObject private var resources = NotchResources.shared
    var close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(resources.text("无法读取 Codex 额度", "Unable to read Codex quota"), systemImage: "exclamationmark.triangle.fill")
                .font(.headline).foregroundStyle(.orange)
            Text(resources.text("可能出现连接或登录异常，请检查 Codex。", "There may be a connection or sign-in problem. Check Codex."))
                .font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(2)
            HStack {
                ResourceRefreshButton(resources: resources)
                Button(resources.text("打开 Codex", "Open Codex")) { resources.openCodex() }.buttonStyle(.bordered)
                Spacer()
                Button(action: close) { Image(systemName: "xmark").frame(width: 26, height: 26) }.buttonStyle(.plain).help(resources.text("关闭", "Close"))
            }
        }.padding(12).environment(\.colorScheme, .dark)
        .onChange(of: resources.usageError) { if resources.usageError == nil { close() } }
    }
}
