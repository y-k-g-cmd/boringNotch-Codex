import Foundation

@main
struct CoreChecks {
    static func main() throws {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message)
            checks += 1
        }
        let id = "00000000-0000-4000-8000-000000000001"
        func session(_ status: String, flags: [String] = [], turn: String = "t1", runtime: String = "idle") -> CodexSession {
            CodexSession.parse([
                "title": "Test", "updatedAt": 100.0,
                "threadRuntimeStatus": ["type": runtime, "activeFlags": flags],
                "turns": [["turnId": turn, "status": status, "turnStartedAtMs": 100.0,
                           "items": [["type": "agentMessage", "text": "Done"]]]]
            ], threadID: id, hostID: "local")
        }
        expect(session("completed").activity == .completed, "explicit success")
        expect(session("failed").activity == .failed, "failure isn't completion")
        expect(session("interrupted").activity == .interrupted, "interruption isn't completion")
        expect(session("inProgress").activity == .running, "running turn")
        expect(session("completed", runtime: "active").activity == .running, "runtime active takes precedence")
        expect(session("inProgress", flags: ["waitingOnApproval"]).activity == .needsApproval, "approval flag")
        expect(session("inProgress", flags: ["waitingOnUserInput"]).activity == .needsInput, "input flag")
        let canonical = CodexSession.parse([
            "turns": [], "threadRuntimeStatus": ["type": "idle"],
            "turnHistory": ["kind": "canonical", "history": ["entitiesByKey": [
                "older": ["turnId": "old", "status": "completed", "turnStartedAtMs": 1.0],
                "newer": ["turnId": "new", "status": "failed", "turnStartedAtMs": 2.0]
            ]]]
        ], threadID: id, hostID: "local")
        expect(canonical.activity == .failed && canonical.turnID == "new", "canonical history uses latest turn")
        let legacyTurns = CodexSession.parse(["turns": [
            ["turnId": "old", "status": "completed"], ["turnId": "new", "status": "inProgress"]
        ]], threadID: id, hostID: "local")
        expect(legacyTurns.activity == .running && legacyTurns.turnID == "new", "legacy history uses last turn")
        expect(CodexSession.parse(["threadRuntimeStatus": ["type": "idle"]], threadID: id, hostID: "local").activity == .idle, "idle without turn is not completion")
        expect(CodexSession.parse([:], threadID: id, hostID: "local").activity == .unknown, "unknown schema never implies success")
        var policy = CodexReminderPolicy()
        expect(!policy.observe(session("completed"), baseline: true), "startup is quiet")
        expect(!policy.observe(session("inProgress", turn: "t2")), "running is quiet")
        expect(policy.observe(session("completed", turn: "t2")), "new completion")
        expect(!policy.observe(session("completed", turn: "t2")), "dedup completion")
        expect(!policy.observe(session("inProgress", turn: "t3")), "new turn")
        expect(policy.observe(session("inProgress", flags: ["waitingOnApproval"], turn: "t3")), "waiting reminder")
        expect(!policy.observe(session("inProgress", flags: ["waitingOnApproval"], turn: "t3")), "dedup waiting")
        expect(!policy.observe(session("inProgress", turn: "t3")), "approval resolved")
        expect(policy.observe(session("inProgress", flags: ["waitingOnApproval"], turn: "t3")), "second approval same turn")
        expect(!policy.observe(session("failed", turn: "t3")), "failed turn never completed reminder")
        var reconnect = CodexReminderPolicy()
        expect(reconnect.observe(session("inProgress", flags: ["waitingOnUserInput"]), baseline: true), "pending input at connect")
        expect(!reconnect.observe(session("inProgress", flags: ["waitingOnUserInput"]), baseline: true), "reconnect doesn't repeat waiting")
        _ = reconnect.observe(session("inProgress", turn: "t4"))
        expect(!reconnect.observe(session("completed", turn: "t4"), baseline: true), "missed completion after reconnect stays quiet")

        let original: [String: Any] = ["a": [1, 2], "nested": ["x": "before"]]
        let result = try CodexStatePatch.apply([
            ["op": "add", "path": ["a", 1], "value": 9],
            ["op": "replace", "path": ["nested", "x"], "value": "after"],
            ["op": "remove", "path": ["a", 0]]
        ], to: original) as! [String: Any]
        expect(result["a"] as? [Int] == [9, 2], "array insert/remove")
        expect((result["nested"] as? [String: String])?["x"] == "after", "nested patch")
        do {
            _ = try CodexStatePatch.apply([["op": "replace", "path": ["a", 20], "value": 0]], to: original)
            preconditionFailure("bad path accepted")
        } catch { checks += 1 }
        expect(original["a"] as? [Int] == [1, 2], "failed patches never mutate baseline")
        expect(!ShelfZone.cut.removesReference(afterMove: false), "cancel/copy keeps cut reference")
        expect(ShelfZone.cut.removesReference(afterMove: true), "confirmed move removes cut reference")
        expect(!ShelfZone.copy.removesReference(afterMove: true), "copy zone always reusable")
        expect(try! JSONDecoder().decode(ShelfZone.self, from: Data("\"cut\"".utf8)) == .cut, "zone persistence")
        expect(NotchDefaultContent.choose(isPlaying: true, hasCodex: true) == .media, "music wins when both exist")
        expect(NotchDefaultContent.choose(isPlaying: true, hasCodex: false) == .media, "music alone")
        expect(NotchDefaultContent.choose(isPlaying: false, hasCodex: true) == .codex, "Codex alone")
        expect(NotchDefaultContent.choose(isPlaying: false, hasCodex: false) == .fallback, "idle preserves existing preferences")
        var retryWindow = CodexReconnectWindow(now: 100)
        expect(retryWindow.canAttempt(at: 100), "retry begins immediately")
        expect(retryWindow.canAttempt(at: 399.9), "retry continues before five minutes")
        expect(!retryWindow.canAttempt(at: 400), "retry stops at exactly five minutes")
        expect(!retryWindow.canAttempt(at: 900), "expired window remains paused")
        retryWindow.disconnectedAfterSuccess(at: 1000, connectedFor: 0.1)
        precondition(!retryWindow.canAttempt(at: 1000), "brief handshake cannot renew expired retry budget")
        retryWindow.disconnectedAfterSuccess(at: 1000, connectedFor: 20)
        expect(retryWindow.remaining(at: 1000) == 300, "disconnect after success grants a fresh window")
        expect(!retryWindow.canAttempt(at: 1300), "new failed window also expires")
        print("PASS: \(checks) core checks")
    }
}
