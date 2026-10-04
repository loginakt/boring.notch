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

extension View {
    /// `ignoresMomentum` drops the trackpad's post-lift glide so one swipe is measured by finger travel alone.
    /// `topEdgeCatch` also handles scrolls macOS routes elsewhere while the pointer is within that many
    /// points of the window's top edge (e.g. tucked behind the camera housing).
    func panGesture(direction: PanDirection, threshold: CGFloat = 4, ignoresMomentum: Bool = false, topEdgeCatch: CGFloat? = nil, action: @escaping (CGFloat, NSEvent.Phase) -> Void) -> some View {
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
            .background(ScrollMonitor(direction: direction, threshold: threshold, ignoresMomentum: ignoresMomentum, topEdgeCatch: topEdgeCatch, action: action))
    }
}

private struct ScrollMonitor: NSViewRepresentable {
    let direction: PanDirection
    let threshold: CGFloat
    let ignoresMomentum: Bool
    let topEdgeCatch: CGFloat?
    let action: (CGFloat, NSEvent.Phase) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.installMonitor(on: view)
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.removeMonitor() }

    func makeCoordinator() -> Coordinator { 
        Coordinator(direction: direction, threshold: threshold, ignoresMomentum: ignoresMomentum, topEdgeCatch: topEdgeCatch, action: action)
    }

    @MainActor final class Coordinator: NSObject {
        private let direction: PanDirection
        private let threshold: CGFloat
        private let ignoresMomentum: Bool
        private let topEdgeCatch: CGFloat?
        private let action: (CGFloat, NSEvent.Phase) -> Void
        private var monitor: Any?
        private var globalMonitor: Any?
        private var accumulated: CGFloat = 0
        private var active = false
            private var endTask: Task<Void, Never>?
        private let noiseThreshold: CGFloat = 0.2

        init(direction: PanDirection, threshold: CGFloat, ignoresMomentum: Bool, topEdgeCatch: CGFloat?, action: @escaping (CGFloat, NSEvent.Phase) -> Void) {
            self.direction = direction
            self.threshold = threshold
            self.ignoresMomentum = ignoresMomentum
            self.topEdgeCatch = topEdgeCatch
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
            if let topEdgeCatch {
                // Events this window receives go through the local monitor above; this only sees
                // ones delivered to other apps, so nothing is counted twice.
                globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel]) { [weak self, weak view] event in
                    guard let self, let window = view?.window, window.isVisible else { return }
                    let pointer = NSEvent.mouseLocation
                    let frame = window.frame
                    guard pointer.x >= frame.minX, pointer.x <= frame.maxX,
                          pointer.y <= frame.maxY, pointer.y >= frame.maxY - topEdgeCatch
                    else { return }
                    self.handleScroll(event)
                }
            }
        }

        func removeMonitor() {
            if let monitor = monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            if let globalMonitor {
                NSEvent.removeMonitor(globalMonitor)
                self.globalMonitor = nil
            }
            accumulated = 0
            active = false
            endTask?.cancel()
            endTask = nil
        }

        private func handleScroll(_ event: NSEvent) {
            if ignoresMomentum && !event.momentumPhase.isEmpty { return }
            PanGestureState.lastScrollWasTrackpad = event.hasPreciseScrollingDeltas

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

/// Facts about the most recent scroll gesture that the pan callbacks don't carry.
@MainActor
enum PanGestureState {
    /// False for a mouse wheel, whose coarse steps make distance-based gestures unreliable.
    static var lastScrollWasTrackpad = true
}

/// Picks the tab a horizontal swipe lands on. Kept free of UI so it can be tested.
enum SwipeTabStepper {
    /// Index of the destination tab, or nil when the swipe would not move (already at that end).
    /// `toEnd` jumps to the last tab (forward) or the first (backward).
    static func targetIndex(current: Int, count: Int, forward: Bool, toEnd: Bool) -> Int? {
        guard count > 0, (0..<count).contains(current) else { return nil }
        let target: Int
        if toEnd {
            target = forward ? count - 1 : 0
        } else {
            target = min(max(current + (forward ? 1 : -1), 0), count - 1)
        }
        return target == current ? nil : target
    }
}
