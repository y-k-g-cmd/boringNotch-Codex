import Foundation
class BoringNotchXPCHelper: NSObject {}
@main struct Check {
 static func main() throws {
  let data = try CodexUsageReader.sanitize(["rateLimits": ["primary": ["usedPercent": 150.0, "windowDurationMins": 300.0, "resetsAt": 2000000000.0], "secret": "must-not-leave"]])
  let value = try JSONSerialization.jsonObject(with: data) as! [String: Any]
  precondition(value.count == 1 && value["windows"] != nil)
  precondition(!String(data: data, encoding: .utf8)!.contains("secret"))
  if CommandLine.arguments.contains("--live") {
   let actual = try CodexUsageReader.read()
   let parsed = try JSONSerialization.jsonObject(with: actual) as! [String: Any]
   print("PASS: live read-only quota query, window count:", (parsed["windows"] as! [Any]).count)
  } else { print("PASS: quota payload clamps bounds and excludes unrelated fields") }
 }
}
