import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ShelfView: View {
    @EnvironmentObject var vm: BoringViewModel
    @StateObject private var shelf = ShelfStateViewModel.shared
    @StateObject private var selection = ShelfSelectionModel.shared
    @StateObject private var quickLookService = QuickLookService()
    @AppStorage("shelfActiveZone") private var activeZone: ShelfZone = .copy
    @AppStorage("shelfShowQuickShare") private var showQuickShare = true
    @AppStorage("shelfCopyFirst") private var copyFirst = true
    @State private var targetedZone: ShelfZone?
    @State private var mainTargeted = false
    private let dropTypes: [UTType] = [ShelfInternalTransfer.type, .fileURL, .url, .utf8PlainText, .plainText, .data]

    var body: some View {
        HStack(spacing: 12) {
            if showQuickShare {
                FileShareView()
                    .aspectRatio(1, contentMode: .fit)
                    .environmentObject(vm)
            }
            VStack(spacing: 8) {
                HStack(spacing: 16) {
                    ForEach(copyFirst ? [ShelfZone.copy, .cut] : [.cut, .copy], id: \.self) { zone in
                        Button {
                            activeZone = zone
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: zone.symbol)
                                Text(zone.title)
                                Text("\(shelf.items(in: zone).count)")
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 4)
                                Image(systemName: activeZone == zone ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(activeZone == zone ? .white : .white.opacity(0.25))
                            }
                            .font(.system(size: 12, weight: activeZone == zone ? .semibold : .medium, design: .rounded))
                            .padding(.horizontal, 12)
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .background(targetedZone == zone ? Color.accentColor.opacity(0.25)
                                        : activeZone == zone ? Color.white.opacity(0.12) : Color.white.opacity(0.025), in: Capsule())
                            .overlay {
                                Capsule().strokeBorder(targetedZone == zone ? Color.accentColor
                                    : activeZone == zone ? Color.white.opacity(0.8) : Color.white.opacity(0.16),
                                    lineWidth: activeZone == zone || targetedZone == zone ? 1.5 : 1)
                            }
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(zone.title)，\(shelf.items(in: zone).count) 项")
                        .accessibilityAddTraits(activeZone == zone ? .isSelected : [])
                        .help("点击切换，或将文件直接拖到这里加入\(zone.title)")
                        .onDrop(of: dropTypes, isTargeted: zoneTarget(zone)) { providers in
                            accept(providers, into: zone)
                        }
                        .overlay {
                            ShelfZoneDragDestination(isTargeted: zoneTarget(zone), activate: { activeZone = zone }, receiveExternal: { providers in
                                    guard !providers.isEmpty else { return false }
                                    shelf.load(providers, into: zone)
                                    vm.dropEvent = true
                                    DispatchQueue.main.async { activeZone = zone }
                                    return true
                            }) { ids in
                                    guard shelf.transfer(ids, into: zone) else { return false }
                                    vm.dropEvent = true
                                    // Defer the page change until AppKit finishes the source session.
                                    DispatchQueue.main.async { activeZone = zone }
                                    return true
                            }
                        }
                    }

                }
                RoundedRectangle(cornerRadius: 16)
                    .stroke((vm.dragDetectorTargeting || vm.generalDropTargeting) ? Color.accentColor.opacity(0.9) : Color.white.opacity(0.1),
                            style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [8]))
                    .overlay {
                        if shelf.items(in: activeZone).isEmpty {
                            VStack(spacing: 6) {
                                Image(systemName: activeZone.symbol)
                                    .font(.title3).foregroundStyle(.secondary)
                                Text(activeZone == .cut ? "拖入文件或文件夹" : "拖入文件、图片或文字")
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                Text(activeZone.hint).font(.system(size: 10)).foregroundStyle(.secondary)
                                if let message = shelf.importMessage {
                                    Text(message).font(.system(size: 9)).foregroundStyle(shelf.importFailed ? Color.orange : Color.secondary).lineLimit(2)
                                }
                            }
                        } else {
                            ScrollView(.horizontal) {
                                HStack(spacing: 8) {
                                    ForEach(shelf.items(in: activeZone)) { item in
                                        ShelfItemView(item: item)
                                            .environmentObject(quickLookService)
                                    }
                                }
                                .padding(.horizontal, 8)
                            }
                            .scrollIndicators(.never)
                            .overlay(alignment: .bottom) {
                                if shelf.importFailed, let message = shelf.importMessage {
                                    Text(message).font(.system(size: 9)).foregroundStyle(.orange).lineLimit(2)
                                        .padding(4).background(.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 4))
                                }
                            }
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { selection.clear() }
                    .onDrop(of: dropTypes, isTargeted: mainTarget) { providers in
                        accept(providers, into: activeZone)
                    }
                    .background {
                        // Track the main area's geometry without covering file drag sources.
                        ShelfZoneDragDestination(isTargeted: mainTarget, activate: {}, receiveExternal: { providers in
                            guard !providers.isEmpty else { return false }
                            shelf.load(providers, into: activeZone)
                            vm.dropEvent = true
                            return true
                        }, capturesMouse: false) { ids in
                            shelf.transfer(ids, into: activeZone)
                        }
                    }
            }
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .onReceive(NotificationCenter.default.publisher(for: .shelfDragDidFinish)) { _ in
            targetedZone = nil
            mainTargeted = false
        }
        .onChange(of: activeZone) { selection.clear() }
        .onChange(of: selection.selectedIDs) { updateQuickLookSelection() }
        .onAppear { shelf.refreshBookmarks() }
        .quickLookPresenter(using: quickLookService)
    }

    private func zoneTarget(_ zone: ShelfZone) -> Binding<Bool> {
        Binding(get: { targetedZone == zone }, set: { targeted in
            if targeted { targetedZone = zone }
            else if targetedZone == zone { targetedZone = nil }
            vm.dragDetectorTargeting = targetedZone != nil || mainTargeted
            if targeted { ShelfInternalDropRouter.shared.update(at: NSEvent.mouseLocation, external: !selection.isDragging) }
        })
    }

    private var mainTarget: Binding<Bool> {
        Binding(get: { mainTargeted }, set: { targeted in
            mainTargeted = targeted
            vm.dragDetectorTargeting = targeted || targetedZone != nil
            if targeted { ShelfInternalDropRouter.shared.update(at: NSEvent.mouseLocation, external: !selection.isDragging) }
        })
    }

    private func accept(_ providers: [NSItemProvider], into zone: ShelfZone) -> Bool {
        guard shelf.acceptDrop(providers, into: zone) else { return false }
        vm.dropEvent = true
        activeZone = zone
        return true
    }

    private func updateQuickLookSelection() {
        guard quickLookService.isQuickLookOpen else { return }
        let urls = selection.selectedItems(in: shelf.items(in: activeZone)).compactMap(\.URL)
        if !urls.isEmpty { quickLookService.updateSelection(urls: urls) }
    }
}

/// Internal drags originate in AppKit. Read their reference payload synchronously,
/// before the source ends, and consume the drop at the exact zone header.
private struct ShelfZoneDragDestination: NSViewRepresentable {
    @Binding var isTargeted: Bool
    var activate: () -> Void
    var receiveExternal: ([NSItemProvider]) -> Bool
    var capturesMouse = true
    var receive: (Set<UUID>) -> Bool

    func makeNSView(context: Context) -> Destination {
        let view = Destination()
        view.capturesMouse = capturesMouse
        view.registerForDraggedTypes([NSPasteboard.PasteboardType(ShelfInternalTransfer.type.identifier)])
        return view
    }

    func updateNSView(_ view: Destination, context: Context) {
        view.targeted = { isTargeted = $0 }
        view.activate = activate
        view.receive = receive
        view.receiveExternal = receiveExternal
        view.registerSourceTarget()
    }

    static func dismantleNSView(_ view: Destination, coordinator: ()) {
        ShelfInternalDropRouter.shared.unregister(view.targetID)
    }

    final class Destination: NSView {
        var targeted: (Bool) -> Void = { _ in }
        var capturesMouse = true
        override func hitTest(_ point: NSPoint) -> NSView? {
            capturesMouse ? super.hitTest(point) : nil
        }
        var activate: () -> Void = {}
        var receiveExternal: ([NSItemProvider]) -> Bool = { _ in false }
        let targetID = UUID()
        func registerSourceTarget() {
            ShelfInternalDropRouter.shared.register(targetID, target: .init(frame: { [weak self] in
                guard let self, let window = self.window, window.isVisible,
                      !self.isHiddenOrHasHiddenAncestor, self.bounds.width > 0, self.bounds.height > 0 else { return nil }
                return window.convertToScreen(self.convert(self.bounds, to: nil))
            }, highlight: { [weak self] in self?.targeted($0) }, receive: { [weak self] in self?.receive($0) ?? false },
               receiveExternal: { [weak self] in self?.receiveExternal($0) ?? false }))
        }
        private var loggedFrame = NSRect.zero
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { activate() }
        override func layout() {
            super.layout()
            if let window {
                let screenFrame = window.convertToScreen(convert(bounds, to: nil))
                if screenFrame != loggedFrame {
                    loggedFrame = screenFrame
                    ShelfDragDiagnostics.record("zone-frame \(NSStringFromRect(screenFrame))")
                }
            }
        }
        var receive: (Set<UUID>) -> Bool = { _ in false }

        private func ids(_ sender: NSDraggingInfo) -> Set<UUID>? {
            let selection = ShelfSelectionModel.shared
            guard sender.draggingSource != nil, let token = selection.dragToken else { return nil }
            let transfers = (sender.draggingPasteboard.pasteboardItems ?? []).compactMap { item -> ShelfInternalTransfer? in
                guard let data = item.data(forType: NSPasteboard.PasteboardType(ShelfInternalTransfer.type.identifier)) else { return nil }
                return try? JSONDecoder().decode(ShelfInternalTransfer.self, from: data)
            }
            return ShelfInternalTransfer.validatedIDs(transfers, token: token, allowed: selection.draggedIDs)
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            let valid = ids(sender) != nil
            ShelfDragDiagnostics.record("zone-enter valid=\(valid) bounds=\(NSStringFromRect(bounds))")
            targeted(valid)
            return valid ? .copy : []
        }
        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            let valid = ids(sender) != nil
            targeted(valid)
            return valid ? .copy : []
        }
        override func draggingExited(_ sender: NSDraggingInfo?) { targeted(false) }
        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { ids(sender) != nil }
        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            defer { targeted(false) }
            guard let ids = ids(sender) else {
                ShelfDragDiagnostics.record("zone-drop invalid")
                return false
            }
            let accepted = receive(ids)
            ShelfDragDiagnostics.record("zone-drop accepted=\(accepted) count=\(ids.count)")
            return accepted
        }
    }
}
