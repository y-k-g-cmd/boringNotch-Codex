import Foundation
import AppKit

@main
struct ShelfChecks {
    @MainActor static func main() async throws {
        precondition(NSItemProvider.fileURL(from: "/tmp/a b.txt" as NSString)?.path == "/tmp/a b.txt")
        precondition(NSItemProvider.fileURL(from: Data("file:///tmp/a%20b.txt\n".utf8) as NSData)?.path == "/tmp/a b.txt")
        precondition(NSItemProvider.fileURL(from: URL(string: "https://example.com")! as NSURL) == nil)
        let failed = await ShelfDropService.importItems(from: [NSItemProvider(object: URL(fileURLWithPath: "/nonexistent/notch-dnd-check.txt") as NSURL)])
        precondition(failed.items.isEmpty && failed.failures.count == 1, "failed file imports must be reported")
        let dragToken = UUID(), dragID = UUID()
        let transfer = ShelfInternalTransfer(token: dragToken, itemID: dragID)
        let payload = try JSONEncoder().encode(transfer)
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: ShelfInternalTransfer.type.identifier, visibility: .all) { done in done(payload, nil); return nil }
        let transferred = await ShelfInternalTransfer.loadIDs(from: [provider], token: dragToken, allowed: [dragID])
        precondition(transferred == [dragID], "internal provider must carry references")
        precondition(ShelfInternalTransfer.validatedIDs([transfer], token: UUID(), allowed: [dragID]) == nil, "reject old drag sessions")
        precondition(ShelfInternalTransfer.validatedIDs([transfer], token: dragToken, allowed: []) == nil, "reject foreign IDs")
        let selection = ShelfSelectionModel.shared
        selection.prepareDrag(token: dragToken, ids: [dragID]); selection.beginDrag()
        selection.endDrag()
        precondition(!selection.isDragging && selection.dragToken == nil && selection.draggedIDs.isEmpty, "drag end clears transient state")
        print("PASS: internal transfer payload, stale/foreign rejection, drag cleanup")
        let router = ShelfInternalDropRouter()
        let targetID = UUID()
        var highlighted = false, received: Set<UUID> = [], receives = 0
        var mounted = true
        router.register(targetID, target: .init(frame: { mounted ? NSRect(x: 818, y: 882, width: 206, height: 34) : nil }, highlight: { highlighted = $0 }, receive: { received = $0; receives += 1; return true }))
        router.begin()
        router.update(at: NSPoint(x: 874.6, y: 895.4))
        precondition(highlighted && router.hasTarget)
        precondition(router.finish(at: NSPoint(x: 874.6, y: 895.4), token: dragToken, ids: [dragID]))
        precondition(received == [dragID] && receives == 1)
        precondition(router.finish(at: NSPoint(x: 874.6, y: 895.4), token: dragToken, ids: [dragID]) && receives == 1, "source completion must not apply a handled drop twice")
        router.begin(); router.update(at: NSPoint(x: 500, y: 500))
        precondition(!highlighted && !router.finish(at: NSPoint(x: 500, y: 500), token: UUID(), ids: [dragID]))
        mounted = false
        router.update(at: NSPoint(x: 874.6, y: 895.4))
        precondition(!router.hasTarget, "unmounted or hidden zones must not receive a transfer")
        router.unregister(targetID)
        print("PASS: recorded drop coordinates route once; outside and unmounted zones rejected")

        let legacy = Data("""
        [{"id":"00000000-0000-0000-0000-000000000001","kind":{"type":"text","value":"keep me"},"isTemporary":false}]
        """.utf8)
        let old = try JSONDecoder().decode([ShelfItem].self, from: legacy)
        precondition(old.count == 1 && old[0].zone == .copy)
        precondition(!old[0].canMoveOriginal)
        let roundtrip = try JSONDecoder().decode([ShelfItem].self, from: JSONEncoder().encode(old))
        precondition(roundtrip == old)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notch-shelf-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("source.txt")
        try Data("original".utf8).write(to: file)
        let textDrop = await ShelfDropService.items(from: [NSItemProvider(object: "saved text" as NSString)])
        precondition(textDrop.count == 1 && textDrop[0].zone == .copy && !textDrop[0].canMoveOriginal)
        let bookmark: Bookmark
        do { bookmark = try Bookmark(url: file) }
        catch {
            let contents = try Data(contentsOf: file)
            precondition(contents == Data("original".utf8))
            print("PASS: legacy migration, persistence roundtrip, text drop, source file unchanged")
            print("SKIP: security-scoped file/folder staging requires the signed app; ScopedBookmarksAgent is unavailable in this command sandbox")
            return
        }
        let item = ShelfItem(kind: .file(bookmark: bookmark.data), zone: .cut)
        precondition(item.canMoveOriginal)
        precondition(Bookmark(data: bookmark.data).resolveURL()?.standardizedFileURL == file.standardizedFileURL)
        precondition(FileManager.default.fileExists(atPath: file.path))
        let tempItem = ShelfItem(kind: .file(bookmark: bookmark.data), isTemporary: true)
        precondition(!tempItem.canMoveOriginal)
        let providers = [NSItemProvider(object: file as NSURL), NSItemProvider(object: directory as NSURL)]
        let staged = await ShelfDropService.items(from: providers)
        precondition(staged.count == 2, "file and folder drops must be accepted")
        precondition(staged.allSatisfy { $0.canMoveOriginal })
        let contents = try Data(contentsOf: file)
        precondition(contents == Data("original".utf8), "staging must not move/change the source")
        let encoded = try JSONEncoder().encode([item])
        let decoded = try JSONDecoder().decode([ShelfItem].self, from: encoded)
        precondition(decoded.first?.zone == .cut)
        print("PASS: legacy migration, persistence roundtrip, file/folder staging, original contents preserved, temporary-file move protection")
    }
}
