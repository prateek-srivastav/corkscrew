import AppKit
import SwiftUI

/// Where the window is (sidebar place and Library page) and where it has been in that place, for
/// Back and Forward: a two-finger swipe, ⌘[ and ⌘]. History stays inside one place (the Library,
/// Steam, a bottle, Setup…): opening another place from the sidebar starts its history over.
@Observable
final class Navigator {
    struct Route: Hashable {
        var section: SidebarItem
        var library: LibraryPage = .all
    }

    /// A sideways scroll view on screen: where it is (window points, top-left origin) and whether
    /// it's scrolled to either end.
    /// How the last change moved: into a page of the same place (in from the right), back up
    /// (in from the left), or to another place.
    enum Move { case push, pop, place }

    struct SideScroll {
        var frame: CGRect = .zero
        var atStart = true
        var atEnd = true
    }

    private(set) var route: Route
    private(set) var move: Move = .place
    private var backStack: [Route] = []
    private var forwardStack: [Route] = []
    @ObservationIgnored var sideScrolls: [UUID: SideScroll] = [:]

    init(_ route: Route = Route(section: .library)) { self.route = route }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    func go(_ route: Route) {
        guard route != self.route else { return }
        if route.place == self.route.place {
            backStack.append(self.route)
            // Into a game's page, or up to the place's own page.
            move = if case .game = route.library { .push } else { .pop }
        } else {
            backStack.removeAll()
            move = .place
        }
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
        move = .pop
        route = previous
    }

    func forward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(route)
        move = .push
        route = next
    }

    /// Leaves a section for the Library if it's open (Bottles, when Advanced mode turns off).
    func remove(_ section: SidebarItem) {
        guard route.section == section else { return }
        reset(to: Route(section: .library))
    }

    /// Starts over at `route`, without history (the first launch sends the user to Setup).
    func reset(to route: Route) {
        backStack.removeAll()
        forwardStack.removeAll()
        move = .place
        self.route = route
    }
}

extension Navigator.Route {
    /// The sidebar place the route is in.
    var place: Navigator.Route {
        section == .library ? Navigator.Route(section: .library, library: library.place) : Navigator.Route(section: section)
    }
}

extension LibraryPage {
    /// The page a game's page was opened from; other pages are their own.
    var place: LibraryPage {
        if case .game(_, let from) = self { return from.place }
        return self
    }
}

extension View {
    /// Back and Forward with a two-finger swipe on the trackpad (fingers to the right go back, as in
    /// Safari). Over something that scrolls sideways, only once it's at the end the swipe goes to.
    func swipeNavigation(_ navigator: Navigator) -> some View {
        modifier(SwipeNavigation(navigator: navigator))
    }

    /// Marks a sideways scroll view, so a swipe over it scrolls it until it's at the end.
    func swipesScrollFirst() -> some View {
        modifier(SideScrollReporter())
    }
}

private struct SideScrollReporter: ViewModifier {
    @Environment(Navigator.self) private var navigator
    @State private var id = UUID()

    private struct Ends: Equatable {
        var atStart: Bool
        var atEnd: Bool
    }

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Ends.self) { geometry in
                Ends(atStart: geometry.visibleRect.minX <= 1,
                     atEnd: geometry.visibleRect.maxX >= geometry.contentSize.width - 1)
            } action: { _, ends in
                navigator.sideScrolls[id, default: .init()].atStart = ends.atStart
                navigator.sideScrolls[id, default: .init()].atEnd = ends.atEnd
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                navigator.sideScrolls[id, default: .init()].frame = frame
            }
            .onDisappear { navigator.sideScrolls[id] = nil }
    }
}

private struct SwipeNavigation: ViewModifier {
    let navigator: Navigator
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard monitor == nil else { return }
                let tracker = SwipeTracker { [navigator] point in
                    navigator.sideScrolls.values.first { $0.frame.contains(point) }
                }
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

    /// The sideways scroll view at a point in the window, if any.
    private let sideScroll: (CGPoint) -> Navigator.SideScroll?
    private var dx: CGFloat = 0
    private var dy: CGFloat = 0
    private var decided = false
    /// Where the swipe started over a sideways scroll view: Back only if it was at its start then,
    /// Forward only if it was at its end, so scrolling to the end doesn't also leave the page.
    private var startScroll: Navigator.SideScroll?

    init(sideScroll: @escaping (CGPoint) -> Navigator.SideScroll?) {
        self.sideScroll = sideScroll
    }

    func track(_ event: NSEvent) -> Swipe? {
        // Mice (no phases), the momentum after lifting the fingers and swipes over a sheet don't count.
        guard event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty,
              event.window?.isSheet != true, event.window?.attachedSheet == nil else { return nil }
        if event.phase.contains(.began) {
            dx = 0
            dy = 0
            decided = false
            startScroll = Self.point(of: event).flatMap(sideScroll)
        }
        guard !decided, event.phase.contains(.changed) || event.phase.contains(.began) else { return nil }
        // Positive when the fingers move right, whatever the scroll direction setting.
        dx += event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
        dy += abs(event.scrollingDeltaY)
        guard abs(dx) >= Self.distance, abs(dx) > dy * 2 else { return nil }
        decided = true
        let swipe: Swipe = dx > 0 ? .back : .forward
        if let startScroll, !(swipe == .back ? startScroll.atStart : startScroll.atEnd) { return nil }
        return swipe
    }

    /// The pointer in SwiftUI's global space: window points from the top left.
    private static func point(of event: NSEvent) -> CGPoint? {
        guard let content = event.window?.contentView else { return nil }
        let point = content.convert(event.locationInWindow, from: nil)
        return CGPoint(x: point.x, y: content.isFlipped ? point.y : content.bounds.height - point.y)
    }
}
