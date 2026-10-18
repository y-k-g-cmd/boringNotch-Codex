import AppKit
import SwiftUI

@main
struct RenderCodex {
    @MainActor static func main() throws {
        let monitor = CodexMonitor()
        monitor.receive(.connection(true, "已连接 Codex"))
        for (index, activity) in [CodexActivity.needsApproval, .completed, .running].enumerated() {
            let session = CodexSession(threadID: UUID().uuidString, hostID: "local",
                title: ["整合文件收纳功能", "生成实验分析报告", "检查模型训练结果"][index],
                activity: activity, turnID: "preview-\(index)",
                summary: ["需要你批准访问项目目录", "报告已生成，校验通过。", "正在核对实验输出…"][index], updatedAt: Date())
            monitor.receive(.session(session, baseline: true))
        }
        let view = CodexView(monitor: monitor)
            .padding(16).frame(width: 640, height: 190)
            .background(.black).environment(\.colorScheme, .dark)
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 640, height: 190)
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            fatalError("Could not create preview bitmap")
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            fatalError("Could not encode preview")
        }
        try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        print("Rendered actual CodexView with sample data")
    }
}
