//
//  PanGesture.swift
//  boringNotch
//
//  Created by Richard Kunkli on 21/08/2024.
//

import AppKit
import SwiftUI

enum PanDirection {
    case left, right, up, down

    var isHorizontal: Bool { self == .left || self == .right }
    var sign: CGFloat { (self == .right || self == .down) ? 1 : -1 }

    func signed(from translation: CGSize) -> CGFloat { (isHorizontal ? translation.width : translation.height) * sign }
    func signed(deltaX: CGFloat, deltaY: CGFloat) -> CGFloat { (isHorizontal ? deltaX : deltaY) * sign }
}

/// One page per physical gesture, with axis locking and no momentum repeats.
struct PageSwipeAccumulator {
    private var x: CGFloat = 0
    private var y: CGFloat = 0
    private var vertical = false
    private(set) var claimed = false
    private var fired = false
    mutating func reset() { self = PageSwipeAccumulator() }
    mutating func update(dx: CGFloat, dy: CGFloat) -> Int? {
        guard !vertical, !fired else { return nil }
        x += dx; y += dy
        if abs(y) > 10 && abs(y) > abs(x) * 1.5 { vertical = true; return nil }
        if abs(x) > 12 && abs(x) > abs(y) * 1.5 { claimed = true }
        guard claimed, abs(x) >= 40 else { return nil }
        fired = true
        return x < 0 ? 1 : -1
    }
}

/// Resolve the whole gesture from its starting position. Never switch owners mid-swipe.
struct PageSwipeRouting {
    static func switchesPage(at point: CGPoint, excludingTaskRegions: Bool, taskRegions: [CGRect]) -> Bool {
        !excludingTaskRegions || !taskRegions.contains { $0.contains(point) }
    }
}

private final class TaskSwipeRegionView: NSView {}
private struct TaskSwipeRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { TaskSwipeRegionView() }
    func updateNSView(_ view: NSView, context: Context) {}
}
private func taskSwipeRegions(in view: NSView) -> [CGRect] {
    if view is TaskSwipeRegionView, !view.isHidden {
        return [view.convert(view.bounds, to: nil)]
    }
    return view.subviews.flatMap { taskSwipeRegions(in: $0) }
}

extension View {
    func taskSwipeRegion() -> some View { background(TaskSwipeRegion().allowsHitTesting(false)) }
    func pageSwipe(enabled: Bool, excludingTaskRegions: Bool = false, action: @escaping (Int) -> Void) -> some View {
        background(PageSwipeMonitor(enabled: enabled, excludingTaskRegions: excludingTaskRegions, action: action))
    }
}

private struct PageSwipeMonitor: NSViewRepresentable {
    let enabled: Bool
    let excludingTaskRegions: Bool
    let action: (Int) -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.install(view)
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.enabled = enabled
        context.coordinator.excludingTaskRegions = excludingTaskRegions
        context.coordinator.action = action
        if !enabled { context.coordinator.swipe.reset() }
    }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.remove() }
    @MainActor final class Coordinator {
        var enabled = false
        var excludingTaskRegions = false
        private var acceptsGesture = false
        var action: (Int) -> Void = { _ in }
        var swipe = PageSwipeAccumulator()
        private var monitor: Any?
        func install(_ view: NSView) {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self, weak view] event in
                guard let self, let view, self.enabled, event.window === view.window,
                      view.bounds.contains(view.convert(event.locationInWindow, from: nil)),
                      event.hasPreciseScrollingDeltas else { return event }
                guard event.momentumPhase.isEmpty else { return event }
                if event.phase.contains(.began) {
                    self.swipe.reset()
                    let regions = view.window?.contentView.map { taskSwipeRegions(in: $0) } ?? []
                    self.acceptsGesture = PageSwipeRouting.switchesPage(at: event.locationInWindow, excludingTaskRegions: self.excludingTaskRegions, taskRegions: regions)
                }
                guard self.acceptsGesture else { return event }
                if event.phase.contains(.ended) || event.phase.contains(.cancelled) { self.swipe.reset(); return event }
                guard !event.phase.isEmpty else { return event }
                let direction: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
                if let step = self.swipe.update(dx: event.scrollingDeltaX * direction, dy: event.scrollingDeltaY * direction) {
                    self.action(step)
                }
                return self.swipe.claimed ? nil : event
            }
        }
        func remove() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    }
}

extension View {
    func panGesture(direction: PanDirection, threshold: CGFloat = 4, action: @escaping (CGFloat, NSEvent.Phase) -> Void) -> some View {
        self
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let s = direction.signed(from: value.translation)
                        guard s > 0, s.magnitude >= threshold else { return }
                        action(s.magnitude, .changed)
                    }
                    .onEnded { _ in action(0, .ended) }
            )
            .background(ScrollMonitor(direction: direction, threshold: threshold, action: action))
    }
}

private struct ScrollMonitor: NSViewRepresentable {
    let direction: PanDirection
    let threshold: CGFloat
    let action: (CGFloat, NSEvent.Phase) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.installMonitor(on: view)
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.removeMonitor() }

    func makeCoordinator() -> Coordinator { 
        Coordinator(direction: direction, threshold: threshold, action: action) 
    }

    @MainActor final class Coordinator: NSObject {
        private let direction: PanDirection
        private let threshold: CGFloat
        private let action: (CGFloat, NSEvent.Phase) -> Void
        private var monitor: Any?
        private var accumulated: CGFloat = 0
        private var active = false
            private var endTask: Task<Void, Never>?
        private let noiseThreshold: CGFloat = 0.2

        init(direction: PanDirection, threshold: CGFloat, action: @escaping (CGFloat, NSEvent.Phase) -> Void) {
            self.direction = direction
            self.threshold = threshold
            self.action = action
        }

        private func scheduleEndTimeout() {
            // Cancel any existing scheduled end and schedule a new one.
            endTask?.cancel()
            endTask = Task { @MainActor in
                // If no new scroll event arrives within this window, consider the gesture ended.
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                if active {
                    action(accumulated.magnitude, .ended)
                } else {
                    action(0, .ended)
                }
                active = false
                accumulated = 0
            }
        }

        func installMonitor(on view: NSView) {
            removeMonitor()
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self, weak view] event in
                guard let self = self, event.window === view?.window else { return event }
                self.handleScroll(event)
                return event
            }
        }

        func removeMonitor() {
            if let monitor = monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            accumulated = 0
            active = false
            endTask?.cancel()
            endTask = nil
        }

        private func handleScroll(_ event: NSEvent) {
            if event.phase == .ended || event.momentumPhase == .ended {
                if active {
                    action(accumulated.magnitude, .ended)
                } else {
                    action(0, .ended)
                }
                active = false
                accumulated = 0
                return
            }

            // Only consider scroll events that are primarily along the configured axis.
            let absDX = abs(event.scrollingDeltaX)
            let absDY = abs(event.scrollingDeltaY)
            // Require the movement along the gesture axis to be at least 1.5x the orthogonal axis.
            let axisDominanceFactor: CGFloat = 1.5
            let isAxisDominant: Bool = direction.isHorizontal ? (absDX >= axisDominanceFactor * absDY) : (absDY >= axisDominanceFactor * absDX)
            guard isAxisDominant else { return }

            // Scale non-precise (mouse wheel) scrolling deltas so they feel similar to
            // trackpad gestures.
            let raw = direction.signed(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY)
            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 8
            let s = raw * scale
            guard s.magnitude > noiseThreshold else { return }
            accumulated = s > 0 ? accumulated + s : 0

            if !active && accumulated >= threshold {
                active = true
                action(accumulated.magnitude, .began)
            } else if active {
                action(accumulated.magnitude, .changed)
            }
            // Schedule a timeout to end the gesture if no further scroll events arrive.
            scheduleEndTimeout()
        }
    }
}
