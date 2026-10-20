import AppKit
import SwiftUI

/// The line at the top of the window: the window's close, minimize and zoom buttons, the sidebar
/// button and each page's top bar (search, Add Program…) are centred on it.
enum TopBar {
    /// The line's distance from the window's top edge.
    static let centerY: CGFloat = 27
    /// The close button's left edge: in line with the sidebar's icons.
    static let windowButtonsLeading: CGFloat = 18
    /// From the close button's left edge to the zoom button's right edge (macOS 26 and 27).
    static let windowButtonsWidth: CGFloat = 60
    /// The bottom of the buttons on the line; content starts under it.
    static let bottom = centerY + Theme.controlHeight / 2
}

/// With keyboard navigation on (System Settings ▸ Keyboard), macOS gives the window's first button
/// focus when the window opens, so its focus line shows before a key is pressed. This takes that
/// focus away once; the first Tab focuses the first button as usual.
struct NoFocusAtOpen: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ClearingView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class ClearingView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard let window, NSApp.isFullKeyboardAccessEnabled else { return }
            NotificationCenter.default.addObserver(self, selector: #selector(clear), name: NSWindow.didBecomeKeyNotification, object: window)
        }

        @objc private func clear() {
            NotificationCenter.default.removeObserver(self)
            // After SwiftUI has put the focus on its first button.
            DispatchQueue.main.async { [weak self] in self?.window?.makeFirstResponder(nil) }
        }
    }
}

/// Moves the window's close, minimize and zoom buttons onto `TopBar`'s line. AppKit puts them
/// back after a resize, full screen or a focus change, so they move again after each.
struct WindowButtonsPlacement: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { PlacingView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class PlacingView: NSView {
        private static let events: [Notification.Name] = [
            NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification, NSWindow.didExitFullScreenNotification,
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.didChangeScreenNotification,
        ]

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard let window else { return }
            for name in Self.events {
                NotificationCenter.default.addObserver(self, selector: #selector(place), name: name, object: window)
            }
            place()
            // Also after SwiftUI's first layout of the window.
            DispatchQueue.main.async { [weak self] in self?.place() }
        }

        @objc private func place() {
            guard let window, !window.styleMask.contains(.fullScreen),
                  let close = window.standardWindowButton(.closeButton),
                  let minimize = window.standardWindowButton(.miniaturizeButton),
                  let zoom = window.standardWindowButton(.zoomButton),
                  let titlebar = close.superview, let container = titlebar.superview, let frameView = container.superview
            else { return }
            // The title bar grows so that its middle is the line; the buttons sit in its middle.
            let height = TopBar.centerY * 2
            container.frame = NSRect(x: container.frame.minX, y: frameView.isFlipped ? 0 : frameView.bounds.height - height,
                                     width: container.frame.width, height: height)
            titlebar.frame = container.bounds
            // AppKit's own spacing between the buttons.
            let spacing = minimize.frame.minX - close.frame.minX
            for (index, button) in [close, minimize, zoom].enumerated() {
                button.setFrameOrigin(NSPoint(x: TopBar.windowButtonsLeading + CGFloat(index) * spacing,
                                              y: (titlebar.bounds.height - button.frame.height) / 2))
            }
        }
    }
}
