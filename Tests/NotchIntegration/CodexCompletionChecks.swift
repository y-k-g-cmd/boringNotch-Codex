import AppKit

@main struct CodexCompletionChecks {
    @MainActor static func checkSubagents() {
        let childSources: [[String: Any]] = [
            ["parentThreadId": "parent"],
            ["source": ["subAgent": ["thread_spawn": ["parent_thread_id": "parent"]]]],
            ["source": ["subAgent": "review"]],
            ["source": "subAgentCompact"]
        ]
        for state in childSources {
            precondition(CodexSession.parse(state, threadID: "child", hostID: "local").isSubagent, "lineage metadata identifies child")
        }
        let rootStates: [[String: Any]] = [[:], ["title": "Codex 会话"], ["forkedFromId": "other"], ["parentThreadId": NSNull()], ["source": "appServer"], ["source": ["subAgent": NSNull()]]]
        for state in rootStates {
            precondition(!CodexSession.parse(state, threadID: "root", hostID: "local").isSubagent, "title and ordinary fork are not child metadata")
        }
        let monitor = CodexMonitor()
        monitor.receive(.connection(true, "测试"))
        var child = CodexSession(threadID: "child", hostID: "local", title: "Codex 会话", activity: .running, turnID: "c1", summary: "", updatedAt: Date(), isSubagent: true)
        monitor.receive(.session(child, baseline: true))
        precondition(!monitor.hasRelevantTasks && !monitor.notchState.hasRunning, "child alone cannot select or occupy the compact notch")
        child.activity = .completed
        monitor.receive(.session(child, baseline: false))
        monitor.beginReminderPresentation()
        precondition(monitor.unread.isEmpty && !monitor.hasBadge && monitor.completionHighlights.isEmpty && monitor.completionFocus == nil, "child completion has no alert, flash, unread or focus")
        for activity in [CodexActivity.needsApproval, .needsInput] {
            child.activity = activity
            monitor.receive(.session(child, baseline: false))
            precondition(!monitor.reminderNeedsAttention && monitor.attentionCount == 0 && monitor.notchState.attentionCount == 0 && !monitor.hasBadge, "child waiting cannot hold the reminder open")
        }
        let shell = CodexNotchState(sessions: [child], connected: true, unread: [child.id], reminderSequence: 0)
        precondition(!shell.hasRelevantTasks && !shell.hasRunning && shell.attentionCount == 0, "stale child unread cannot occupy shell")
        var parent = CodexSession(threadID: "parent", hostID: "local", title: "Codex 会话", activity: .running, turnID: "p1", summary: "", updatedAt: .distantPast)
        monitor.receive(.session(parent, baseline: true))
        parent.activity = .completed
        monitor.receive(.session(parent, baseline: false))
        monitor.beginReminderPresentation()
        precondition(monitor.completionFocus?.sessionID == parent.id && monitor.completionHighlights[parent.id] != nil && monitor.unread.contains(parent.id), "root reminders remain unchanged")
        precondition(monitor.sessions.first?.id == parent.id && monitor.sessions.contains { $0.id == child.id }, "root precedes children; children stay manually browsable")
        child.activity = .running; child.turnID = "c2"
        monitor.receive(.session(child, baseline: false))
        child.activity = .completed
        monitor.receive(.session(child, baseline: false))
        precondition(monitor.completionFocus?.sessionID == parent.id && monitor.completionHighlights[child.id] == nil, "child completion cannot steal root focus")
        let late = CodexMonitor()
        parent.activity = .running
        late.receive(.session(parent, baseline: true))
        parent.activity = .completed
        late.receive(.session(parent, baseline: false))
        late.beginReminderPresentation()
        parent.isSubagent = true
        late.receive(.session(parent, baseline: false))
        precondition(late.unread.isEmpty && late.completionHighlights.isEmpty && late.completionFocus == nil && !late.hasBadge, "late child metadata retracts existing child alerts")
        print("PASS: subagent metadata, reminder exclusion, root preservation, late lineage cleanup and manual task ordering")
    }

    @MainActor static func checkDelayedSubagentReminder() async {
        let monitor = CodexMonitor()
        let saved = monitor.remindersEnabled
        monitor.remindersEnabled = true
        defer { monitor.remindersEnabled = saved }
        monitor.receive(.connection(true, "测试"))
        var root = CodexSession(threadID: "queued-root", hostID: "local", title: "Root", activity: .running, turnID: "p1", summary: "", updatedAt: Date())
        monitor.receive(.session(root, baseline: true))
        root.activity = .completed; monitor.receive(.session(root, baseline: false))
        try? await Task.sleep(for: .milliseconds(650))
        precondition(monitor.reminderSequence == 1, "root reminder fires normally")
        var child = CodexSession(threadID: "late-child", hostID: "local", title: "Child", activity: .running, turnID: "c1", summary: "", updatedAt: Date())
        monitor.receive(.session(child, baseline: true))
        child.activity = .completed; monitor.receive(.session(child, baseline: false))
        child.isSubagent = true; monitor.receive(.session(child, baseline: false))
        try? await Task.sleep(for: .milliseconds(650))
        precondition(monitor.reminderSequence == 1, "queued child cannot reannounce old unread root")
        root.turnID = "p2"; root.activity = .running; monitor.receive(.session(root, baseline: false))
        root.activity = .completed; monitor.receive(.session(root, baseline: false))
        child.isSubagent = false; child.turnID = "c2"; child.activity = .running; monitor.receive(.session(child, baseline: false))
        child.activity = .completed; monitor.receive(.session(child, baseline: false))
        child.isSubagent = true; monitor.receive(.session(child, baseline: false))
        try? await Task.sleep(for: .milliseconds(650))
        precondition(monitor.reminderSequence == 2 && !monitor.unread.contains(child.id), "retract child without losing coalesced root reminder")
        print("PASS: delayed child cancellation, no old-root reannouncement, coalesced root reminder retained")
    }

    @MainActor static func main() async {
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
        let active = CodexNotchState()
        let paused = m.notchState
        precondition(paused.enteredRetryPause(from: active), "first retry timeout closes the automatic page")
        precondition(!paused.enteredRetryPause(from: paused), "replayed paused snapshot must allow manual navigation")
        var changedPaused = paused
        changedPaused.reminderSequence += 1
        precondition(!changedPaused.enteredRetryPause(from: paused), "unrelated updates cannot close a manually opened paused page")
        precondition(!active.enteredRetryPause(from: paused), "reconnecting does not close the page")
        precondition(paused.enteredRetryPause(from: active), "a later retry window can pause again")
        checkSubagents()
        await checkDelayedSubagentReminder()
        print("PASS: 18 completion/pause/preference checks")
    }
}
