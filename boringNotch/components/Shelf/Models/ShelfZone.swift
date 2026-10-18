import Foundation

/// Staging changes only intent; Finder performs the actual filesystem operation.
enum ShelfZone: String, Codable, CaseIterable, Sendable {
    case cut, copy
    var title: String { self == .cut ? "剪切区" : "复制区" }
    var symbol: String { self == .cut ? "scissors" : "doc.on.doc" }
    var hint: String { self == .cut ? "拖出后移动原文件" : "拖出复制，保留原文件" }
    func removesReference(afterMove: Bool) -> Bool { self == .cut && afterMove }
}
