import AppKit
import SwiftUI

/// Where the window is (rail page and Library page) and where it has been, for Back and Forward:
/// a two-finger swipe, ⌘[ and ⌘].
@Observable
final class Navigator {
    struct Route: Hashable {
        var section: SidebarItem
        var library: LibraryPage = .overview
    }

    private(set) var route: Route
    private var backStack: [Route] = []
    private var forwardStack: [Route] = []

    init(_ route: Route = Route(section: .library)) { self.route = route }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    func go(_ route: Route) {
        guard route != self.route else { return }
        backStack.append(self.route)
        forwardStack.removeAll()
        self.route = route
    }

    func go(_ section: SidebarItem) { go(Route(section: section)) }
    func go(library page: LibraryPage) { go(Route(section: .library, library: page)) }

    /// A page's own Back button: the same as Back when that's where the user came from, so Forward
    /// still returns.
    func goUp(to page: LibraryPage) {
        let target = Route(section: .library, library: page)
        if backStack.last == target { back() } else { go(target) }
    }

    func back() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(route)
        route = previous
    }

    func forward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(route)
        route = next
    }

    /// Starts over at `route`, without history (the first launch sends the user to Setup).
    func reset(to route: Route) {
        backStack.removeAll()
        forwardStack.removeAll()
        self.route = route
    }
}

extension View {
    /// Back and Forward with a two-finger swipe on the trackpad (fingers to the right go back, as in
    /// Safari), except over something that scrolls sideways itself.
    func swipeNavigation(_ navigator: Navigator) -> some View {
        modifier(SwipeNavigation(navigator: navigator))
    }
}

private struct SwipeNavigation: ViewModifier {
    let navigator: Navigator
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard monitor == nil else { return }
                let tracker = SwipeTracker()
                monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                    switch tracker.track(event) {
                    case .back: navigator.back()
                    case .forward: navigator.forward()
                    case nil: break
                    }
                    return event
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }
}

/// Adds up one trackpad gesture's sideways movement and decides, once, whether it was a swipe.
@MainActor
final class SwipeTracker {
    enum Swipe { case back, forward }

    /// How far the fingers move sideways, in points, before it counts.
    static let distance: CGFloat = 90

    private var dx: CGFloat = 0
    private var dy: CGFloat = 0
    private var decided = false
    private var ignored = false

    func track(_ event: NSEvent) -> Swipe? {
        // Mice (no phases), the momentum after lifting the fingers and swipes over a sheet don't count.
        guard event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty,
              event.window?.isSheet != true, event.window?.attachedSheet == nil else { return nil }
        if event.phase.contains(.began) {
            dx = 0
            dy = 0
            decided = false
            ignored = Self.scrollsSideways(at: event)
        }
        guard !decided, !ignored, event.phase.contains(.changed) || event.phase.contains(.began) else { return nil }
        // Positive when the fingers move right, whatever the scroll direction setting.
        dx += event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
        dy += abs(event.scrollingDeltaY)
        guard abs(dx) >= Self.distance, abs(dx) > dy * 2 else { return nil }
        decided = true
        return dx > 0 ? .back : .forward
    }

    /// Whether the pointer is over a scroll view that can scroll sideways (a row of screenshots).
    private static func scrollsSideways(at event: NSEvent) -> Bool {
        guard let window = event.window, let content = window.contentView,
              var view = content.hitTest(content.convert(event.locationInWindow, from: nil)) else { return false }
        while let parent = view.superview {
            if let scroll = view as? NSScrollView, let document = scroll.documentView,
               document.frame.width > scroll.contentView.bounds.width + 1 {
                return true
            }
            view = parent
        }
        return false
    }
}
