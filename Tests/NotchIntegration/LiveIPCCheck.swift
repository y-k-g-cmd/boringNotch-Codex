import Foundation

@main
struct LiveIPCCheck {
    static func main() {
        let done = DispatchSemaphore(value: 0)
        let transport = CodexIPCTransport { event in
            switch event {
            case .session(let session, _):
                print("PASS: live desktop snapshot parsed; activity=\(session.activity.rawValue)")
                done.signal()
            default: break
            }
        }
        transport.start()
        let result = done.wait(timeout: .now() + 12)
        transport.stop()
        if result == .timedOut {
            print("FAIL: no live snapshot within 12 seconds")
            exit(1)
        }
    }
}
