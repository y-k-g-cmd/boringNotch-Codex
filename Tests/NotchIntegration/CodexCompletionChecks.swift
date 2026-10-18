import AppKit

@main struct CodexCompletionChecks {
    @MainActor static func main() {
        let m = CodexMonitor()
        let key = "codexCompletionReminderDuration"
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.removeObject(forKey: key)
        precondition(m.completionReminderSeconds == 6, "default reminder time")
        UserDefaults.standard.set(24.0, forKey: key)
        precondition(m.completionReminderSeconds == 24, "running monitor picks up settings changes")
        UserDefaults.standard.set(9.0, forKey: key)
        precondition(m.completionReminderSeconds == 9, "running monitor does not cache the old duration")
        m.receive(.connection(true, "测试"))
        var task = CodexSession(threadID: "00000000-0000-4000-8000-000000000021", hostID: "local", title: "任务", activity: .running, turnID: "t1", summary: "", updatedAt: Date())
        var history = task
        history = CodexSession(threadID: "00000000-0000-4000-8000-000000000022", hostID: "local", title: "旧任务", activity: .completed, turnID: "old", summary: "旧结果", updatedAt: .distantPast)
        m.receive(.session(history, baseline: true))
        m.receive(.session(task, baseline: true))
        m.beginReminderPresentation()
        precondition(m.completionHighlights.isEmpty, "historical completion must not flash")
        task.activity = .completed
        m.receive(.session(task, baseline: false))
        precondition(m.completionHighlights.isEmpty, "defer flashing until the notch is presented")
        m.beginReminderPresentation()
        precondition(m.completionHighlights.count == 1 && m.completionHighlights[task.id] != nil, "only the newly completed task flashes")
        precondition(m.completionFocus?.sessionID == task.id, "scroll to the matching task")
        let token = m.completionHighlights[task.id]!.id
        m.receive(.session(task, baseline: false))
        m.beginReminderPresentation()
        precondition(m.completionHighlights[task.id]?.id == token, "duplicate updates must not restart flashing")
        m.markCompletedRead()
        precondition(m.completionHighlights.isEmpty && !m.hasUnreadCompleted, "read button ends completion highlighting")
        task.activity = .running
        task.turnID = "t2"
        m.receive(.session(task, baseline: false))
        task.activity = .completed
        m.receive(.session(task, baseline: false))
        m.beginReminderPresentation()
        precondition(m.completionHighlights[task.id]?.id != token, "new turn gets its own flash")
        m.receive(.retryPaused)
        m.start()
        precondition(m.retryPaused && !m.connected, "appearance cannot restart a paused connection")
        precondition(m.notchState.retryPaused && !m.notchState.hasRelevantTasks && !m.hasRelevantTasks && !m.notchState.hasRunning && m.notchState.attentionCount == 0, "paused retries must hide retained Codex tasks from the shell")
        precondition(!m.sessions.isEmpty, "pause preserves task history for manual reconnect")
        print("PASS: 13 completion/pause/preference checks")
    }
}
