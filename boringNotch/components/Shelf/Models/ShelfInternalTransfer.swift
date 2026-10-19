import Foundation
import AppKit
import UniformTypeIdentifiers

/// References only. Internal zone changes never copy or move filesystem contents.
struct ShelfInternalTransfer: Codable {
    static let type = UTType(exportedAs: "theboringteam.boringnotch.shelf-transfer", conformingTo: .data)
    let token: UUID
    let itemID: UUID

    static func validatedIDs(_ transfers: [Self], token: UUID, allowed: Set<UUID>) -> Set<UUID>? {
        guard !transfers.isEmpty, transfers.allSatisfy({ $0.token == token && allowed.contains($0.itemID) }) else { return nil }
        return Set(transfers.map(\.itemID))
    }

    static func loadIDs(from providers: [NSItemProvider], token: UUID, allowed: Set<UUID>) async -> Set<UUID>? {
        var transfers: [Self] = []
        for provider in providers {
            let data: Data? = await withCheckedContinuation { continuation in
                provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in continuation.resume(returning: data) }
            }
            guard let data, let value = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
            transfers.append(value)
        }
        return validatedIDs(transfers, token: token, allowed: allowed)
    }
}

extension Notification.Name {
    static let shelfDragDidFinish = Notification.Name("com.boringNotch.shelfDragDidFinish")
}

/// Local, bounded event diagnostics. No file paths, contents or credentials.
@MainActor enum ShelfDragDiagnostics {
    static func record(_ event: String) {
        guard let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let url = directory.appendingPathComponent("ShelfDragDiagnostics.log")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let line = "\(Date().timeIntervalSince1970) \(event)\n"
        var data = (try? Data(contentsOf: url)) ?? Data()
        if data.count > 32768 { data = Data() }
        data.append(Data(line.utf8))
        try? data.write(to: url, options: .atomic)
    }
}

/// SwiftUI's hosting drop region may own an AppKit source's destination events.
/// Route local shelf sessions using live native header bounds instead.
@MainActor final class ShelfInternalDropRouter {
    static let shared = ShelfInternalDropRouter()
    struct Target {
        var frame: () -> NSRect?
        var highlight: (Bool) -> Void
        var receive: (Set<UUID>) -> Bool
        var receiveExternal: (([NSItemProvider]) -> Bool)? = nil
    }
    private var targets: [UUID: Target] = [:]
    private var hovered: UUID?
    private var consumedToken: UUID?
    private let feedback: @MainActor () -> Void

    init(feedback: @escaping @MainActor () -> Void = { NotchHapticFeedback.perform() }) {
        self.feedback = feedback
    }

    func register(_ id: UUID, target: Target) { targets[id] = target }
    func unregister(_ id: UUID) { targets.removeValue(forKey: id); if hovered == id { hovered = nil } }
    func begin() { consumedToken = nil; clearHighlight() }
    func update(at point: NSPoint, external: Bool = false, announce: Bool = true) {
        let next = targets.first {
            (!external || $0.value.receiveExternal != nil) && $0.value.frame()?.contains(point) == true
        }?.key
        guard next != hovered else { return }
        hovered = next
        if next != nil, announce { feedback() }
        for (id, target) in targets { target.highlight(id == next) }
        ShelfDragDiagnostics.record("source-target inside=\(next != nil)")
    }
    @discardableResult func finish(at point: NSPoint, token: UUID, ids: Set<UUID>) -> Bool {
        if consumedToken == token { return true }
        update(at: point, announce: false)
        guard let hovered, let target = targets[hovered], !ids.isEmpty else { return false }
        let accepted = target.receive(ids)
        if accepted { consumedToken = token }
        ShelfDragDiagnostics.record("source-transfer accepted=\(accepted) count=\(ids.count)")
        return accepted
    }
    /// Finder events can be owned by the outer SwiftUI hosting view. Resolve the
    /// exact native header at release rather than falling back to the active zone.
    /// nil means no header; false means a header rejected the drop (do not fall back).
    func finishExternal(at point: NSPoint, providers: [NSItemProvider]) -> Bool? {
        guard !providers.isEmpty,
              !providers.contains(where: { $0.hasItemConformingToTypeIdentifier(ShelfInternalTransfer.type.identifier) }) else { return false }
        update(at: point, external: true, announce: false)
        defer { clearHighlight() }
        guard let hovered, let receive = targets[hovered]?.receiveExternal else { return nil }
        return receive(providers)
    }

    var hasTarget: Bool { hovered != nil }
    func clearHighlight() {
        hovered = nil
        for target in targets.values { target.highlight(false) }
    }
}
