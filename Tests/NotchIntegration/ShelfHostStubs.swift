// Only the unrelated notch host and share tile are substituted for isolated Shelf typechecking.
// All shelf models, persistence, drag source, selection, views, menus and services use production code.
import SwiftUI
import AppKit

@MainActor final class BoringViewModel: ObservableObject {
    @Published var dragDetectorTargeting = false
    @Published var generalDropTargeting = false
    @Published var dropEvent = false
    let animation = Animation.spring(response: 0.42, dampingFraction: 0.8)
}
struct FileShareView: View {
    var body: some View { Color.clear }
}
