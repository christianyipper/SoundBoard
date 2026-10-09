import AppKit
import SwiftUI

/// Pages between the Files, Gamesheet and Call views like a phone's home screens: a two-finger
/// horizontal trackpad (or Magic Mouse) swipe anywhere over the pager — header included — drags
/// the current page with the fingers and reveals its neighbor, then springs to whichever page is
/// showing more (or the way a quick flick was heading). Picking a mode some other way (the
/// hotkey bar's segmented picker) slides to it the same way. Swipes that start over a horizontally
/// scrollable area (the sound grid's folder tab strip) scroll that instead, and mostly-vertical
/// swipes scroll the page as usual.
struct MainModePager<Header: View, Page: View>: View {
    @Binding var mode: MainMode
    @ViewBuilder var header: () -> Header
    @ViewBuilder var page: (MainMode) -> Page

    /// The page fully on screen when nothing is moving.
    @State private var shownMode: MainMode
    /// The page sliding in beside `shownMode`, mid-swipe or mid-animation.
    @State private var incomingMode: MainMode?
    /// How far `shownMode` is pushed horizontally; `incomingMode` sits a page-width beside it.
    @State private var offset: CGFloat = 0
    /// Finger travel this swipe, before edge resistance is applied.
    @State private var swipeTravel: CGFloat = 0
    @State private var isSettling = false
    @State private var pageWidth: CGFloat = 0

    /// Share of the page width a swipe must cover to change pages when released slowly.
    private let commitFraction: CGFloat = 0.3
    /// Per-event finger travel (points) at release that counts as a flick.
    private let flickSpeed: CGFloat = 6
    /// How much of the finger travel moves the page when there's no page in that direction.
    private let edgeResistance: CGFloat = 0.25

    init(mode: Binding<MainMode>, @ViewBuilder header: @escaping () -> Header, @ViewBuilder page: @escaping (MainMode) -> Page) {
        _mode = mode
        self.header = header
        self.page = page
        _shownMode = State(initialValue: mode.wrappedValue)
    }

    var body: some View {
        VStack(spacing: 0) {
            header()

            GeometryReader { geometry in
                ZStack {
                    ForEach(visibleModes, id: \.self) { pageMode in
                        page(pageMode)
                            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                            .offset(x: pageOffset(for: pageMode, width: geometry.size.width))
                            .transition(.identity)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                .clipped()
                .onAppear { pageWidth = geometry.size.width }
                .onChange(of: geometry.size.width) { _, width in pageWidth = width }
            }
        }
        .background(
            HorizontalSwipeCatcher(
                onBegan: beginSwipe,
                onChanged: updateSwipe,
                onEnded: endSwipe
            )
        )
        .onChange(of: mode) { _, newMode in
            // Swipes set `mode` themselves once they commit; anything else changing it (the
            // picker) slides there. Mid-slide changes are picked up when the slide finishes.
            guard !isSettling, incomingMode == nil, newMode != shownMode else { return }
            slide(to: newMode)
        }
    }

    // MARK: - Layout

    private var visibleModes: [MainMode] {
        [shownMode] + (incomingMode.map { [$0] } ?? [])
    }

    /// +1 when `target` sits to the right of the shown page, -1 when to the left.
    private func direction(to target: MainMode) -> CGFloat {
        index(of: target) > index(of: shownMode) ? 1 : -1
    }

    private func index(of mode: MainMode) -> Int {
        MainMode.allCases.firstIndex(of: mode) ?? 0
    }

    private func pageOffset(for pageMode: MainMode, width: CGFloat) -> CGFloat {
        pageMode == shownMode ? offset : offset + direction(to: pageMode) * width
    }

    // MARK: - Swiping

    private func beginSwipe() -> Bool {
        guard !isSettling, incomingMode == nil, pageWidth > 0 else { return false }
        swipeTravel = 0
        return true
    }

    /// Content follows the fingers: moving them left (negative travel) pulls in the next page.
    private func updateSwipe(_ delta: CGFloat) {
        swipeTravel += delta
        let modes = MainMode.allCases
        let neighborIndex = index(of: shownMode) + (swipeTravel < 0 ? 1 : -1)
        if swipeTravel != 0, modes.indices.contains(neighborIndex) {
            incomingMode = modes[neighborIndex]
            offset = max(-pageWidth, min(pageWidth, swipeTravel))
        } else {
            incomingMode = nil
            offset = swipeTravel * edgeResistance
        }
    }

    private func endSwipe(_ releaseSpeed: CGFloat) {
        guard let incomingMode else {
            settle(offset: 0) {}
            return
        }
        let heading = -direction(to: incomingMode)
        let isFarEnough = abs(offset) > pageWidth * commitFraction
        let isFlick = releaseSpeed * heading > flickSpeed
        let isFlickBack = releaseSpeed * heading < -flickSpeed
        if (isFarEnough || isFlick) && !isFlickBack {
            mode = incomingMode
            settle(offset: heading * pageWidth) { finish(at: incomingMode) }
        } else {
            settle(offset: 0) { self.incomingMode = nil }
        }
    }

    // MARK: - Animating

    /// Slides straight to `target` (e.g. Files → Call without passing through Gamesheet).
    private func slide(to target: MainMode) {
        guard pageWidth > 0 else {
            shownMode = target
            return
        }
        isSettling = true
        incomingMode = target
        offset = 0
        // Let the incoming page appear in its off-screen spot before animating it in.
        DispatchQueue.main.async {
            settle(offset: -direction(to: target) * pageWidth) { finish(at: target) }
        }
    }

    private func settle(offset target: CGFloat, completion: @escaping () -> Void) {
        isSettling = true
        withAnimation(DesignSystem.Motion.pageSlide) {
            offset = target
        } completion: {
            completion()
            isSettling = false
            if incomingMode == nil, mode != shownMode {
                slide(to: mode)
            }
        }
    }

    /// Makes `target` the shown page in place, without animating the reset offset.
    private func finish(at target: MainMode) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            shownMode = target
            incomingMode = nil
            offset = 0
        }
    }
}

/// Invisible view that reports two-finger horizontal scroll gestures over its bounds. Gestures
/// are watched with a local event monitor (so they're seen even over buttons and scroll views),
/// locked to an axis after a few points of travel, and only claimed — swallowed, along with their
/// momentum — when mostly horizontal, `onBegan` agrees, and they didn't start over something that
/// scrolls horizontally itself. Classic mouse wheels (no gesture phases) are ignored.
private struct HorizontalSwipeCatcher: NSViewRepresentable {
    var onBegan: () -> Bool
    var onChanged: (CGFloat) -> Void
    /// Called with the last event's horizontal travel, as a rough release speed.
    var onEnded: (CGFloat) -> Void

    func makeNSView(context: Context) -> SwipeCatcherView {
        let view = SwipeCatcherView()
        view.handlers = self
        return view
    }

    func updateNSView(_ view: SwipeCatcherView, context: Context) {
        view.handlers = self
    }

    static func dismantleNSView(_ view: SwipeCatcherView, coordinator: ()) {
        view.removeMonitor()
    }

    final class SwipeCatcherView: NSView {
        private enum GestureState {
            case idle
            /// Not yet sure which way the fingers are going; travel so far.
            case deciding(dx: CGFloat, dy: CGFloat)
            case swiping(lastDelta: CGFloat)
            /// Someone else's gesture (vertical, outside, or over a horizontal scroller).
            case ignoring
        }

        var handlers: HorizontalSwipeCatcher?
        private var monitor: Any?
        private var state = GestureState.idle
        private var isSwallowingMomentum = false

        /// Travel needed before deciding the gesture's axis.
        private let axisLockDistance: CGFloat = 8
        /// How much more horizontal than vertical travel counts as a horizontal swipe.
        private let horizontalBias: CGFloat = 1.5

        // Never take clicks or drags from the views on top.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard event.window === window else { return event }

            if !event.momentumPhase.isEmpty {
                guard isSwallowingMomentum else { return event }
                if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) {
                    isSwallowingMomentum = false
                }
                return nil
            }

            let phase = event.phase
            if phase.contains(.mayBegin) || phase.contains(.began) {
                isSwallowingMomentum = false
                state = startsHere(event) ? .deciding(dx: 0, dy: 0) : .ignoring
                return event
            }

            if phase.contains(.changed) {
                return handleChange(event)
            }

            if phase.contains(.ended) || phase.contains(.cancelled) {
                defer { state = .idle }
                guard case .swiping(let lastDelta) = state else { return event }
                isSwallowingMomentum = true
                handlers?.onEnded(phase.contains(.cancelled) ? 0 : lastDelta)
                return nil
            }

            return event
        }

        private func handleChange(_ event: NSEvent) -> NSEvent? {
            let dx = event.scrollingDeltaX
            switch state {
            case .deciding(let totalX, let totalY):
                let x = totalX + dx
                let y = totalY + event.scrollingDeltaY
                guard hypot(x, y) >= axisLockDistance else {
                    state = .deciding(dx: x, dy: y)
                    return event
                }
                guard abs(x) > abs(y) * horizontalBias, handlers?.onBegan() == true else {
                    state = .ignoring
                    return event
                }
                state = .swiping(lastDelta: dx)
                handlers?.onChanged(x)
                return nil
            case .swiping:
                state = .swiping(lastDelta: dx)
                handlers?.onChanged(dx)
                return nil
            case .idle, .ignoring:
                return event
            }
        }

        /// Whether a gesture starting at `event` is ours: over this view, and not over something
        /// that scrolls sideways on its own.
        private func startsHere(_ event: NSEvent) -> Bool {
            guard event.hasPreciseScrollingDeltas,
                  bounds.contains(convert(event.locationInWindow, from: nil))
            else { return false }
            guard let hit = window?.contentView?.hitTest(event.locationInWindow) else { return true }
            let overHorizontalScroller = sequence(first: hit, next: \.superview)
                .compactMap { $0 as? NSScrollView }
                .contains { scrollView in
                    guard let documentView = scrollView.documentView else { return false }
                    return documentView.frame.width > scrollView.contentView.bounds.width + 1
                }
            return !overHorizontalScroller
        }
    }
}
