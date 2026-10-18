import AppKit
import Combine

@main
struct NotchStreamChecks {
    @MainActor static func main() async {
        let monitor = CodexMonitor()
        monitor.receive(.connection(true, "测试连接"))
        var task = CodexSession(threadID: "00000000-0000-4000-8000-000000000011", hostID: "local", title: "测试", activity: .running, turnID: "t", summary: "", updatedAt: Date())
        monitor.receive(.session(task, baseline: true))
        var shellUpdates = 0
        var listUpdates = 0
        var emptyLists = 0
        let shell = monitor.$notchState.dropFirst().sink { _ in shellUpdates += 1 }
        let list = monitor.$sessions.dropFirst().sink { sessions in
            listUpdates += 1
            if sessions.isEmpty { emptyLists += 1 }
        }
        for i in 0..<100 {
            task.summary = "流式更新 \(i)"
            task.updatedAt = Date(timeIntervalSince1970: Double(i))
            monitor.receive(.session(task, baseline: false))
        }
        precondition(shellUpdates == 0, "streaming text must not invalidate the notch shell")
        precondition(listUpdates == 100 && emptyLists == 0, "each update publishes one complete list")
        precondition(monitor.sessions.first?.summary == "流式更新 99", "card keeps receiving latest text")
        task.activity = .needsInput
        monitor.receive(.session(task, baseline: false))
        precondition(shellUpdates == 1 && monitor.notchState.attentionCount == 1, "attention changes reach shell once")
        for _ in 0..<40 where monitor.reminderSequence == 0 {
            try? await Task.sleep(for: .milliseconds(50))
        }
        precondition(monitor.notchState.reminderSequence == 1 && shellUpdates == 2, "reminder sequence reaches shell after coalescing")
        monitor.receive(.connection(false, "测试断开"))
        precondition(shellUpdates == 3 && !monitor.notchState.connected, "disconnect reaches shell")
        withExtendedLifetime((shell, list)) {}
        print("PASS: 6 live-monitor checks; 100 text updates, 0 shell invalidations, 0 transient empty lists")
    }
}
