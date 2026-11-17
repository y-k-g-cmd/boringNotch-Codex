import Foundation
import ApplicationServices
precondition(!RemoteBooksServer.desktopIsKnownUnavailable(nil))
precondition(!RemoteBooksServer.desktopIsKnownUnavailable([:]))
precondition(!RemoteBooksServer.desktopIsKnownUnavailable([kCGSessionOnConsoleKey as String: true]))
precondition(RemoteBooksServer.desktopIsKnownUnavailable([kCGSessionOnConsoleKey as String: false]))
precondition(RemoteBooksServer.desktopIsKnownUnavailable(["CGSSessionScreenIsLocked": true]))
precondition(RemoteBooksServer.isBooksApplication("com.apple.iBooksX"))
precondition(RemoteBooksServer.isBooksApplication("com.apple.iBooks"))
precondition(!RemoteBooksServer.isBooksApplication("com.apple.finder"))
precondition(!RemoteBooksServer.isBooksApplication(nil))
let mockQueue = DispatchQueue(label: "books.test")
var count = 0
let page = CommandLine.arguments.count > 1 ? try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])) : Data("<html>remote-test</html>".utf8)
let server = RemoteBooksServer(html: page) { direction, done in
    mockQueue.asyncAfter(deadline: .now() + 0.2) {
        count += 1
        done(true, "mock-\(count)-\(direction)")
    }
}
var announced = false
server.control("start") { _ in }
let timer = DispatchSource.makeTimerSource(queue: .global())
timer.schedule(deadline: .now() + 0.1, repeating: 1)
timer.setEventHandler {
    server.control("renew") { data in
        guard !announced, let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              value["state"] as? String != "starting" else { return }
        announced = true
        // Private pipe consumed only by the test; never recorded in artifacts.
        print(String(data: data, encoding: .utf8)!); fflush(stdout)
    }
}
timer.resume()
DispatchQueue.global().async {
    while let command = readLine() {
        if command == "pause" { timer.cancel(); print("paused"); fflush(stdout); continue }
        server.control(command) { data in
            print(String(data: data, encoding: .utf8)!); fflush(stdout)
        }
    }
    exit(0)
}
dispatchMain()
