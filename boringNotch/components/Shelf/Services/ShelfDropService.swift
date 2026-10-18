import AppKit
import Foundation
import UniformTypeIdentifiers

struct ShelfDropResult {
    var items: [ShelfItem] = []
    var failures: [String] = []
}

struct ShelfDropService {
    static func items(from providers: [NSItemProvider]) async -> [ShelfItem] {
        await importItems(from: providers).items
    }

    static func importItems(from providers: [NSItemProvider]) async -> ShelfDropResult {
        var result = ShelfDropResult()
        for provider in providers {
            do {
                if let item = try await processProvider(provider) { result.items.append(item) }
                else { result.failures.append("无法读取拖入内容") }
            } catch { result.failures.append(error.localizedDescription) }
        }
        return result
    }

    private static func processProvider(_ provider: NSItemProvider) async throws -> ShelfItem? {
        if let bookmark = try await provider.extractFileBookmark() {
            return await ShelfItem(kind: .file(bookmark: bookmark), isTemporary: false)
        }
        if let url = await provider.extractURL() {
            if url.isFileURL {
                return await ShelfItem(kind: .file(bookmark: try Bookmark(url: url).data), isTemporary: false)
            }
            return await ShelfItem(kind: .link(url: url), isTemporary: false)
        }
        if let text = await provider.extractText() {
            return await ShelfItem(kind: .text(string: text), isTemporary: false)
        }
        if let data = await provider.loadData(),
           let url = await TemporaryFileStorageService.shared.createTempFile(for: .data(data, suggestedName: provider.suggestedName)) {
            return await ShelfItem(kind: .file(bookmark: try Bookmark(url: url).data), isTemporary: true)
        }
        if let url = await provider.extractItem() {
            return await ShelfItem(kind: .file(bookmark: try Bookmark(url: url).data), isTemporary: false)
        }
        return nil
    }
}
