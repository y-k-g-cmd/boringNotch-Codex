import AppKit
import SwiftUI

// Manual UI fixture: no transport is started and no real Codex task can be changed.
final class InteractionPreviewPanel: NSPanel, CodexInputWindow {
    var codexInputEnabled = false
    override var canBecomeKey: Bool { codexInputEnabled }
}
struct InteractionPreviewContent: View {
    @ObservedObject var monitor: CodexMonitor
    @State private var approval = false
    @State private var taskList = false
    @AppStorage("codexTaskNavigation") private var navigation = "region"
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("交互检查 · 模拟数据，不连接 Codex").font(.caption)
                Toggle("审批示例", isOn: $approval)
                Toggle("任务列表", isOn: $taskList)
                Picker("浏览方式", selection: $navigation) { Text("按区域").tag("region"); Text("双指切页").tag("pages") }.frame(width: 130)
                Button("关闭预览") { NSApp.terminate(nil) }
            }.font(.system(size: 11)).controlSize(.small)
            CodexView(monitor: monitor).frame(width: 600, height: 142).id(approval)
        }
        .padding(12).background(.black).foregroundStyle(.white).environment(\.colorScheme, .dark)
        .onAppear { load() }.onChange(of: approval) { load() }.onChange(of: taskList) { load() }
    }
    private func load() {
        for session in monitor.sessions { monitor.receive(.removed(session.id)) }
        if taskList {
            monitor.receive(.connection(true, "模拟连接（不发送操作）"))
            for i in 1...6 {
                monitor.receive(.session(CodexSession(threadID: "preview-\(i)", hostID: "local", title: "模拟任务 \(i)", activity: .completed, turnID: "t", summary: "仅检查浏览操作，不连接真实任务", updatedAt: Date(timeIntervalSince1970: Double(100 - i))), baseline: true))
            }
            return
        }
        let params: [String: Any] = approval
            ? ["threadId": "preview", "command": "echo 'Hello'", "cwd": "/tmp/example", "reason": "运行示例命令"]
            : ["threadId": "preview", "questions": [["id": "choice", "question": "请选择一个选项", "options": ["A", "B", "C", "D"].map { ["label": $0, "description": ""] }]]]
        let request: [String: Any] = ["id": "preview-request", "method": approval ? "item/commandExecution/requestApproval" : "item/tool/requestUserInput", "params": params]
        let state: [String: Any] = ["title": "请求处理界面示例", "requests": [request], "threadRuntimeStatus": ["type": "active", "activeFlags": [approval ? "waitingOnApproval" : "waitingOnUserInput"]]]
        monitor.receive(.connection(true, "模拟连接（不发送操作）"))
        monitor.receive(.session(CodexSession.parse(state, threadID: "preview", hostID: "local", ownerClientID: "preview-owner"), baseline: true))
    }
}
@main struct InteractionPreview {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let panel = InteractionPreviewPanel(contentRect: NSRect(x: 0, y: 0, width: 624, height: 190), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .black
        panel.contentView = NSHostingView(rootView: InteractionPreviewContent(monitor: CodexMonitor()))
        panel.center(); panel.orderFrontRegardless()
        NSApp.run()
    }
}
