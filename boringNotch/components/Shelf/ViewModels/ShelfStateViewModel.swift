//
//  ShelfStateViewModel.swift
//  boringNotch
//
//  Created by Alexander on 2025-10-09.

import Foundation
import AppKit

@MainActor
final class ShelfStateViewModel: ObservableObject {
    static let shared = ShelfStateViewModel()

    @Published private(set) var items: [ShelfItem] = [] {
        didSet { ShelfPersistenceService.shared.save(items) }
    }

    @Published var isLoading: Bool = false
    @Published private(set) var importMessage: String?
    @Published private(set) var importFailed = false

    var isEmpty: Bool { items.isEmpty }

    // Queue for deferred bookmark updates to avoid publishing during view updates
    private var pendingBookmarkUpdates: [ShelfItem.ID: Data] = [:]
    private var updateTask: Task<Void, Never>?
    private var importFeedbackTask: Task<Void, Never>?

    private init() {
        items = ShelfPersistenceService.shared.load()
    }


    func add(_ newItems: [ShelfItem]) {
        guard !newItems.isEmpty else { return }
        var merged = items
        // Deduplicate by identityKey while preserving order (existing first)
        var seen: Set<String> = Set(merged.map { $0.identityKey })
        for it in newItems {
            let key = it.identityKey
            if !seen.contains(key) {
                merged.append(it)
                seen.insert(key)
            }
        }
        items = merged
    }

    func remove(_ item: ShelfItem) {
        clearImportFeedback()
        item.cleanupStoredData()
        items.removeAll { $0.id == item.id }
    }

    func updateBookmark(for item: ShelfItem, bookmark: Data) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        if case .file = items[idx].kind {
            items[idx].kind = .file(bookmark: bookmark)
        }
    }

    private func scheduleDeferredBookmarkUpdate(for item: ShelfItem, bookmark: Data) {
        pendingBookmarkUpdates[item.id] = bookmark
        
        // Cancel existing task and schedule a new one
        updateTask?.cancel()
        updateTask = Task { @MainActor [weak self] in
            await Task.yield()
            
            guard let self = self else { return }
            
            for (itemID, bookmarkData) in self.pendingBookmarkUpdates {
                if let idx = self.items.firstIndex(where: { $0.id == itemID }),
                   case .file = self.items[idx].kind {
                    self.items[idx].kind = .file(bookmark: bookmarkData)
                }
            }
            
            self.pendingBookmarkUpdates.removeAll()
        }
    }


    func items(in zone: ShelfZone) -> [ShelfItem] { items.filter { $0.zone == zone } }

    func setZone(_ zone: ShelfZone, for ids: Set<UUID>) {
        items = items.map { item in
            var item = item
            if ids.contains(item.id), zone == .copy || item.canMoveOriginal {
                item.zone = zone
            }
            return item
        }
        ShelfSelectionModel.shared.clear()
    }

    @discardableResult
    func transfer(_ ids: Set<UUID>, into zone: ShelfZone) -> Bool {
        let live = items.filter { ids.contains($0.id) }
        guard !ids.isEmpty, live.count == ids.count else { return false }
        clearImportFeedback()
        guard zone == .copy || live.allSatisfy(\.canMoveOriginal) else {
            importFailed = true
            importMessage = "剪切区只接收原始文件或文件夹"
            return false
        }
        setZone(zone, for: ids)
        return true
    }

    @discardableResult
    func acceptDrop(_ providers: [NSItemProvider], into zone: ShelfZone) -> Bool {
        guard !providers.isEmpty else { return false }
        let selection = ShelfSelectionModel.shared
        if providers.contains(where: { $0.hasItemConformingToTypeIdentifier(ShelfInternalTransfer.type.identifier) }) {
            guard selection.isDragging, let token = selection.dragToken else { return false }
            let router = ShelfInternalDropRouter.shared
            router.update(at: NSEvent.mouseLocation)
            if router.hasTarget {
                return router.finish(at: NSEvent.mouseLocation, token: token, ids: selection.draggedIDs)
            }
            // Capture the active session before AppKit calls the source's ended callback.
            let allowed = selection.draggedIDs
            Task { [weak self] in
                guard let ids = await ShelfInternalTransfer.loadIDs(from: providers, token: token, allowed: allowed), let self else { return }
                let live = self.items.filter { ids.contains($0.id) }
                guard live.count == ids.count else { return }
                clearImportFeedback()
                guard zone == .copy || live.allSatisfy(\.canMoveOriginal) else {
                    importFailed = true
                    importMessage = "剪切区只接收原始文件或文件夹"
                    return
                }
                setZone(zone, for: ids)
            }
            return true
        }
        guard !selection.isDragging else { return false }
        load(providers, into: zone)
        return true
    }

    func load(_ providers: [NSItemProvider], into zone: ShelfZone = .copy) {
        guard !providers.isEmpty else { return }
        clearImportFeedback()
        isLoading = true
        importMessage = "正在收纳…"
        importFailed = false
        Task { [weak self] in
            let result = await ShelfDropService.importItems(from: providers)
            let dropped = result.items
            await MainActor.run {
                let accepted = dropped.compactMap { item -> ShelfItem? in
                    guard zone == .copy || item.canMoveOriginal else { return nil }
                    var item = item
                    item.zone = zone
                    return item
                }
                // Re-dropping a file into the other zone changes its intended operation.
                let keys = Set(accepted.map(\.identityKey))
                if let self {
                    let ids = Set(self.items.filter { keys.contains($0.identityKey) }.map(\.id))
                    self.setZone(zone, for: ids)
                    self.add(accepted)
                }
                self?.isLoading = false
                let failures = result.failures.count + dropped.count - accepted.count
                self?.importFailed = failures > 0
                if failures > 0 {
                    self?.importMessage = "已收纳 \(accepted.count) 项，\(failures) 项失败：" + (result.failures.first ?? "剪切区只接收原始文件或文件夹")
                } else {
                    self?.importMessage = "本次已收纳 \(accepted.count) 项"
                    self?.importFeedbackTask = Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(3))
                        guard !Task.isCancelled else { return }
                        self?.importMessage = nil
                    }
                }
            }
        }
    }

    private func clearImportFeedback() {
        importFeedbackTask?.cancel()
        importFeedbackTask = nil
        importMessage = nil
        importFailed = false
    }

    func refreshBookmarks() {
        // An unavailable bookmark may need permission again after a custom build.
        // Keep the record so a temporary access failure cannot erase the user's shelf.
        for item in items {
            if case .file = item.kind { _ = resolveFileURL(for: item) }
        }
    }


    func resolveFileURL(for item: ShelfItem) -> URL? {
        guard case .file(let bookmarkData) = item.kind else { return nil }
        let bookmark = Bookmark(data: bookmarkData)
        let result = bookmark.resolve()
        if let refreshed = result.refreshedData, refreshed != bookmarkData {
            NSLog("Bookmark for \(item) stale; refreshing")
            scheduleDeferredBookmarkUpdate(for: item, bookmark: refreshed)
        }
        return result.url
    }

    func resolveAndUpdateBookmark(for item: ShelfItem) -> URL? {
        guard case .file(let bookmarkData) = item.kind else { return nil }
        let bookmark = Bookmark(data: bookmarkData)
        let result = bookmark.resolve()
        if let refreshed = result.refreshedData, refreshed != bookmarkData {
            NSLog("Bookmark for \(item) stale; refreshing")
            updateBookmark(for: item, bookmark: refreshed)
        }
        return result.url
    }

    func resolveFileURLs(for items: [ShelfItem]) -> [URL] {
        var urls: [URL] = []
        for it in items {
            if let u = resolveFileURL(for: it) { urls.append(u) }
        }
        return urls
    }
}
