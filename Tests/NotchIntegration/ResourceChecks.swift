import AppKit
import Darwin

@main struct ResourceChecks {
    @MainActor static func main() {
        var cpu = NotchCPUSample()
        precondition(cpu.percentage([100, 100, 100, 100]) == nil)
        precondition(abs(cpu.percentage([125, 125, 150, 100])! - 50) < 0.001)
        precondition(cpu.percentage([125, 125, 150, 100]) == nil)
        cpu.previous = [UInt32.max - 5, 0, UInt32.max - 5, 0]
        precondition(abs(cpu.percentage([4, 0, 4, 0])! - 50) < 0.001)
        let quota = NotchQuotaWindow(usedPercent: 30.2, minutes: 10080, resetsAt: nil)
        precondition(quota.remaining == 69 && quota.label == "7d")
        print("PASS: CPU baseline, idle delta, counter wraparound, quota display")
    }
}
