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
        var feedbacks = 0
        NotchHapticFeedback.perform(enabled: false) { feedbacks += 1 }
        precondition(feedbacks == 0, "disabled haptics must stay silent")
        NotchHapticFeedback.perform(enabled: true) { feedbacks += 1 }
        precondition(feedbacks == 1, "one enabled action requests one native feedback")
        print("PASS: haptic preference gate and single feedback request")
        let router = ShelfInternalDropRouter(feedback: {})
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

        let externalRouter = ShelfInternalDropRouter(feedback: {})
        let copyHeader = UUID(), cutHeader = UUID()
        var copyFrame: NSRect? = NSRect(x: 20, y: 200, width: 180, height: 34)
        var cutFrame: NSRect? = NSRect(x: 220, y: 200, width: 180, height: 34)
        var copyTargeted = false, cutTargeted = false
        var destinations: [ShelfZone] = [], batchSizes: [Int] = []
        externalRouter.register(copyHeader, target: .init(frame: { copyFrame }, highlight: { copyTargeted = $0 }, receive: { _ in false }, receiveExternal: { providers in destinations.append(.copy); batchSizes.append(providers.count); return true }))
        externalRouter.register(cutHeader, target: .init(frame: { cutFrame }, highlight: { cutTargeted = $0 }, receive: { _ in false }, receiveExternal: { providers in destinations.append(.cut); batchSizes.append(providers.count); return true }))
        let finderProviders = [NSItemProvider(object: URL(fileURLWithPath: "/tmp/finder-one.txt") as NSURL), NSItemProvider(object: URL(fileURLWithPath: "/tmp/finder-two.txt") as NSURL)]
        externalRouter.update(at: NSPoint(x: 250, y: 215), external: true)
        precondition(cutTargeted && !copyTargeted, "Finder hover highlights the actual cut header")
        precondition(externalRouter.finishExternal(at: NSPoint(x: 250, y: 215), providers: finderProviders) == true)
        precondition(destinations == [.cut] && batchSizes == [2], "route one batch to the pointer's header regardless of active zone")
        precondition(!cutTargeted && !copyTargeted, "release clears header highlights")
        swap(&copyFrame, &cutFrame)
        precondition(externalRouter.finishExternal(at: NSPoint(x: 250, y: 215), providers: finderProviders) == true)
        precondition(destinations == [.cut, .copy], "custom header order uses live frames")
        copyFrame = nil
        precondition(externalRouter.finishExternal(at: NSPoint(x: 250, y: 215), providers: finderProviders) == nil, "hidden header cannot receive Finder files")
        precondition(externalRouter.finishExternal(at: NSPoint(x: 500, y: 10), providers: finderProviders) == nil, "main shelf area retains its normal fallback")
        precondition(externalRouter.finishExternal(at: NSPoint(x: 40, y: 215), providers: [provider]) == false, "internal transfers cannot enter external import path")
        externalRouter.register(cutHeader, target: .init(frame: { cutFrame }, highlight: { _ in }, receive: { _ in false }, receiveExternal: { _ in false }))
        precondition(externalRouter.finishExternal(at: NSPoint(x: 40, y: 215), providers: finderProviders) == false, "rejected header drops must not fall back into the active zone")
        print("PASS: Finder header routing, hover, batch, reordered/hidden frames, fallback and internal isolation")

        var entryPulses = 0
        let hoverRouter = ShelfInternalDropRouter(feedback: { entryPulses += 1 })
        hoverRouter.register(UUID(), target: .init(frame: { NSRect(x: 0, y: 0, width: 100, height: 30) }, highlight: { _ in }, receive: { _ in true }, receiveExternal: { _ in true }))
        hoverRouter.register(UUID(), target: .init(frame: { NSRect(x: 120, y: 0, width: 100, height: 30) }, highlight: { _ in }, receive: { _ in true }, receiveExternal: { _ in true }))
        hoverRouter.update(at: NSPoint(x: 10, y: 10), external: true)
        hoverRouter.update(at: NSPoint(x: 20, y: 10), external: true)
        precondition(entryPulses == 1, "one pulse on entry; movement within the same region stays silent")
        hoverRouter.update(at: NSPoint(x: 130, y: 10), external: true)
        precondition(entryPulses == 2, "switching targets announces the new target once")
        hoverRouter.update(at: NSPoint(x: 300, y: 10), external: true)
        hoverRouter.update(at: NSPoint(x: 130, y: 10), external: true)
        precondition(entryPulses == 3, "leaving and reentering re-arms feedback")
        precondition(hoverRouter.finishExternal(at: NSPoint(x: 130, y: 10), providers: finderProviders) == true)
        precondition(entryPulses == 3, "release does not add a completion pulse")
        precondition(hoverRouter.finishExternal(at: NSPoint(x: 10, y: 10), providers: finderProviders) == true)
        precondition(entryPulses == 3, "a drop-only callback must not manufacture an entry pulse")
        hoverRouter.begin()
        hoverRouter.update(at: NSPoint(x: 10, y: 10))
        hoverRouter.update(at: NSPoint(x: 20, y: 10))
        precondition(entryPulses == 4, "internal drags use the same entry gate")
        precondition(hoverRouter.finish(at: NSPoint(x: 20, y: 10), token: UUID(), ids: [dragID]))
        precondition(entryPulses == 4, "internal completion stays silent too")
        print("PASS: hover-entry haptics, same-region deduplication, target changes, reentry, silent completion")

        precondition(ShelfDropCompletion.shouldReset(importRevision: 10, currentRevision: 10, mouseIsDown: false, internalDragIsActive: false), "failed or successful import clears the completed external drag")
        precondition(ShelfDropCompletion.shouldReset(importRevision: 10, currentRevision: 10, mouseIsDown: true, internalDragIsActive: false), "same-session completion cleans up even if the last mouse sample is stale")
        precondition(!ShelfDropCompletion.shouldReset(importRevision: 10, currentRevision: 11, mouseIsDown: true, internalDragIsActive: false), "late import cannot clear a newer Finder drag")
        precondition(!ShelfDropCompletion.shouldReset(importRevision: 10, currentRevision: 10, mouseIsDown: false, internalDragIsActive: true), "import callback cannot clear an internal source session")
        precondition(ShelfDropCompletion.shouldReset(importRevision: 10, currentRevision: 11, mouseIsDown: false, internalDragIsActive: false), "no active drag allows clearing any stale highlight")
        print("PASS: completed import cleanup, stale mouse sample, newer external/internal drag protection")

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
