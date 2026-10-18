import Foundation

final class EventCount: @unchecked Sendable {
    private let lock = NSLock()
    private var failures = 0
    func failed() { lock.lock(); failures += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return failures }
}
@main struct CodexReconnectChecks {
    static func main() {
        let home = URL(fileURLWithPath: "/private/tmp/notch-absent-\(UUID().uuidString)")
        let count = EventCount()
        let paused = DispatchSemaphore(value: 0)
        let transport = CodexIPCTransport(home: home, retryTimeout: 0.12) { event in
            switch event {
            case .retryPaused: paused.signal()
            case .connection(false, _): count.failed()
            default: break
            }
        }
        let start = Date()
        transport.start()
        precondition(paused.wait(timeout: .now() + 2) == .success, "retry budget must terminate the worker")
        precondition(Date().timeIntervalSince(start) < 1.5 && count.count > 0, "short test budget is respected")
        let failures = count.count
        Thread.sleep(forTimeInterval: 0.1)
        precondition(count.count == failures, "no automatic attempts after pause")
        let pausedAgain = DispatchSemaphore(value: 0)
        let retry = CodexIPCTransport(home: home, retryTimeout: 0.05) { event in
            if case .retryPaused = event { pausedAgain.signal() }
            if case .connection(false, _) = event { count.failed() }
        }
        retry.start()
        precondition(pausedAgain.wait(timeout: .now() + 2) == .success && count.count > failures, "a fresh manual retry receives a new budget")
        transport.stop(); retry.stop()
        print("PASS: 4 actual retry-worker checks (shortened clock budget)")
    }
}
