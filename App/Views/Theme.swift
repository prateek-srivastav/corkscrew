import GameCore
import SwiftUI

/// The app's look: a dark game launcher with soft cards, pill buttons and a sidebar of places.
enum Theme {
    // Close to macOS's own dark windows (about 12% white). Darker read as a dim screen at low
    // display brightness, where other apps looked fine.
    static let background = Color(red: 0.105, green: 0.108, blue: 0.118)
    static let panel = Color(red: 0.14, green: 0.143, blue: 0.155)
    static let surface = Color.white.opacity(0.07)
    static let surfaceHover = Color.white.opacity(0.11)
    static let stroke = Color.white.opacity(0.1)
    static let isolated = Color.orange
    static let running = Color.green
    static let online = Color.green
    /// Steam's blue, from its logo.
    static let steam = Color(red: 0.10, green: 0.60, blue: 1.0)
    /// The Library: every game. The wine red of the app icon (#70002a).
    static let library = Color(red: 0x70 / 255, green: 0x00 / 255, blue: 0x2a / 255)
    /// One height for every button and the search field, so they all line up.
    static let controlHeight: CGFloat = 34
    /// The icons in buttons and the search field.
    static let controlIconSize: CGFloat = 15
    /// The window's corner radius (macOS 26, no toolbar); the page's left corners match it.
    static let windowCornerRadius: CGFloat = 16
    /// The one corner radius for cards, rows, art and panels: the window's, and about the radius
    /// of the capsules (search field, pill buttons), so every round corner in the app looks the same.
    /// A shape inside another, close to its edge, takes `cornerRadius - inset` (concentric).
    static let cornerRadius: CGFloat = windowCornerRadius

    /// A sidebar place's colour, also the glow of its page: the Library wine red, Steam blue, Offline
    /// Programs orange, Online Programs green, other bottles grey.
    static func tint(for bottle: Bottle?) -> Color {
        switch bottle?.role {
        case nil: bottle == nil ? library : .gray
        case .steam: steam
        case .sandbox: isolated
        case .sandboxOnline: online
        }
    }

    /// The Advanced mode default: shows each game's launch settings and logs, and the runtime tools.
    static let advancedModeKey = "AdvancedMode"
    /// The default that collapses the sidebar to its icons (it's open by default).
    static let sidebarCollapsedKey = "SidebarCollapsed"
}

/// A heading above a group, like "Installed" or "Not Installed".
struct SectionLabel: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        // A macOS section heading (System Settings): 13 pt bold, not in capitals.
        Text(title)
            .font(.headline)
            .foregroundStyle(.secondary)
    }
}

/// A rounded, softly lit block of content.
struct Card<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.surface, in: .rect(cornerRadius: Theme.cornerRadius))
            .overlay { RoundedRectangle(cornerRadius: Theme.cornerRadius).strokeBorder(Theme.stroke) }
    }
}

/// A capsule with an icon and a few words: a bottle's kind, internet or state.
struct Chip: View {
    let title: String
    let systemImage: String
    var tint: Color = .secondary

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .glassEffect(.regular, in: .capsule)
    }
}

/// Capsule buttons: white for the main action (Play), Liquid Glass for the rest (tinted red when
/// they stop something).
struct PillButtonStyle: ButtonStyle {
    var prominent = false
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        PillButton(configuration: configuration, prominent: prominent, destructive: destructive)
    }
}

/// The pill's look. A view of its own: SwiftUI keeps `@State` (the hover) only in a view, not in
/// a button style.
private struct PillButton: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    let destructive: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isBusy) private var isBusy
    @State private var isHovering = false

    var body: some View {
        configuration.label
            // A macOS button's 13 pt; the main action a little bolder.
            .font(.body.weight(prominent ? .semibold : .medium))
            .labelStyle(PillLabelStyle())
            .padding(.horizontal, 16)
            .frame(height: Theme.controlHeight)
            .foregroundStyle(prominent ? Color.black : destructive ? Color.red : Color.primary)
            .background {
                if prominent {
                    Capsule().fill(.white.opacity(configuration.isPressed ? 0.8 : isHovering ? 0.9 : 1))
                } else if isEnabled && (isHovering || configuration.isPressed) {
                    Capsule().fill(.white.opacity(configuration.isPressed ? 0.16 : 0.1))
                }
            }
            // Interactive glass lights up under the pointer and gives when pressed.
            .glassEffect(prominent ? .identity : (destructive ? Glass.regular.tint(.red.opacity(0.18)) : .regular).interactive(isEnabled),
                         in: .capsule)
            // A busy button stays readable: it says what it's doing.
            .opacity(isEnabled ? 1 : isBusy ? 0.75 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.96 : isHovering && isEnabled ? 1.02 : 1)
            .contentShape(.capsule)
            .onHover { isHovering = $0 }
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

/// A pill's icon and title; the icon a little larger than the text.
private struct PillLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: Theme.controlIconSize, weight: .semibold))
            configuration.title
        }
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    static var pill: PillButtonStyle { PillButtonStyle() }
    static var prominentPill: PillButtonStyle { PillButtonStyle(prominent: true) }
    static var destructivePill: PillButtonStyle { PillButtonStyle(destructive: true) }
}

extension EnvironmentValues {
    /// Set by `BusyButton` while its work runs.
    @Entry var isBusy = false
    /// The sidebar shows only its icons: its rows hide their names.
    @Entry var isSidebarCollapsed = false
}

/// A button whose work takes a while. While `isBusy`, it shows a spinner and `busyTitle`
/// ("Opening…") and can't be pressed.
struct BusyButton: View {
    let title: String
    let systemImage: String?
    let busyTitle: String
    let isBusy: Bool
    let action: () -> Void

    init(_ title: String, systemImage: String? = nil, busyTitle: String, isBusy: Bool, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.busyTitle = busyTitle
        self.isBusy = isBusy
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            if isBusy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text(busyTitle)
                }
            } else if let systemImage {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
        }
        .disabled(isBusy)
        .environment(\.isBusy, isBusy)
    }
}

/// A menu item for work that takes a while: while `isBusy`, it says `busyTitle` and can't be chosen.
func busyItem(_ title: String, _ busyTitle: String, _ isBusy: Bool, action: @escaping () -> Void) -> some View {
    Button(isBusy ? busyTitle : title, action: action).disabled(isBusy)
}

/// A round icon-only button, for "…" menus and the panel's close button.
struct CircleButtonStyle: ButtonStyle {
    var size = Theme.controlHeight

    func makeBody(configuration: Configuration) -> some View {
        CircleButton(configuration: configuration, size: size)
    }
}

/// The round button's look, a view of its own for its hover state (see `PillButton`).
private struct CircleButton: View {
    let configuration: ButtonStyleConfiguration
    let size: CGFloat
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(.system(size: Theme.controlIconSize + 1, weight: .semibold))
            .frame(width: size, height: size)
            .background {
                if isEnabled && (isHovering || configuration.isPressed) {
                    Circle().fill(.white.opacity(configuration.isPressed ? 0.16 : 0.1))
                }
            }
            .glassEffect(.regular.interactive(isEnabled), in: .circle)
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.94 : isHovering && isEnabled ? 1.04 : 1)
            .contentShape(.circle)
            .onHover { isHovering = $0 }
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

/// Moves its content to `x`, one frame at a time. SwiftUI calls an animatable modifier on every
/// frame of an animation, so Liquid Glass inside gets a real new place each frame. (Glass doesn't
/// follow SwiftUI's own position animation: it jumped to the end.)
struct GlassFollowingOffset: ViewModifier, Animatable {
    var x: CGFloat
    var animatableData: CGFloat {
        get { x }
        set { x = newValue }
    }

    func body(content: Content) -> some View {
        content.padding(.leading, x)
    }
}

extension View {
    /// A page's large title with its actions on the right.
    func pageHeader(_ title: String, subtitle: String? = nil, @ViewBuilder actions: () -> some View = { EmptyView() }) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.largeTitle.bold())
                    if let subtitle { Text(subtitle).foregroundStyle(.secondary) }
                }
                Spacer()
                HStack(spacing: 8) { actions() }
            }
            self
        }
    }

    /// A panel that slides in from the right edge, with a close button that Esc presses too.
    func sidePanel(isPresented: Bool, title: String, width: CGFloat = 380, close: @escaping () -> Void,
                   @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 0) {
            frame(maxWidth: .infinity, maxHeight: .infinity)
            if isPresented {
                VStack(spacing: 0) {
                    HStack {
                        Text(title).font(.headline).lineLimit(1)
                        Spacer()
                        Button("Close", systemImage: "xmark", action: close)
                            .buttonStyle(CircleButtonStyle())
                            .keyboardShortcut(.cancelAction)
                            .help("Close (Esc)")
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 14)
                    .padding(.bottom, 4)
                    content()
                }
                .frame(width: width)
                .frame(maxHeight: .infinity)
                .background(Theme.panel.ignoresSafeArea())
                .overlay(alignment: .leading) { Rectangle().fill(Theme.stroke).frame(width: 1).ignoresSafeArea() }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: isPresented)
    }

    /// Grouped forms on the dark panels, without their own grey backdrop.
    func panelForm() -> some View {
        formStyle(.grouped).scrollContentBackground(.hidden)
    }
}

/// A Liquid Glass search field for a page's top bar. ⌘F puts the cursor in it, Esc clears it.
struct SearchField: View {
    @Binding var text: String
    let prompt: String
    @FocusState private var isFocused: Bool
    /// The field's frame in the window, to tell a click outside it.
    @State private var frame = CGRect.zero
    @State private var clickMonitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: Theme.controlIconSize)).foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .focusEffectDisabled()
                .focused($isFocused)
                .frame(width: 170)
                .onKeyPress(.escape) {
                    text = ""
                    isFocused = false
                    return .handled
                }
            if !text.isEmpty {
                Button("Clear", systemImage: "xmark.circle.fill") { text = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.body)
        .padding(.horizontal, 12)
        .frame(height: Theme.controlHeight)
        // A click anywhere on the capsule, not only on the text, starts typing.
        .background { Color.clear.contentShape(.capsule).onTapGesture { isFocused = true } }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
        .onChange(of: isFocused) { _, focused in focused ? watchClicks() : stopWatchingClicks() }
        .onDisappear { stopWatchingClicks() }
        .overlay { if isFocused { Capsule().strokeBorder(.white.opacity(0.35)) } }
        .glassEffect(.regular, in: .capsule)
        .background {
            Button("Search") { isFocused = true }
                .keyboardShortcut("f")
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    /// A text field keeps the keyboard after a click elsewhere in the window; while typing, a
    /// click outside the field ends it, as in Finder's or Music's search field.
    private func watchClicks() {
        stopWatchingClicks()
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            if let view = event.window?.contentView {
                var point = view.convert(event.locationInWindow, from: nil)
                if !view.isFlipped { point.y = view.bounds.height - point.y }
                if !frame.contains(point) { isFocused = false }
            }
            return event
        }
    }

    private func stopWatchingClicks() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }
}

/// A page's top bar that stays in place while the page scrolls under it. The bar has no
/// background: its glass search field and buttons float on the page.
enum FloatingBar {
    /// The bar's height; a page leaves this much space at its top for it.
    static let height = Theme.controlHeight
    /// The bar's distance from the window's top edge: on the window buttons' line (see `TopBar`).
    static let top = TopBar.centerY - height / 2
    /// The bar's left edge: right of the sidebar button, which is on every page (see `SidebarToggle`).
    static let leading = SidebarToggle.leading + SidebarToggle.size + 12
}

extension View {
    /// Pins `bar` over the top of this scroll view (see `FloatingBar`).
    func floatingBar(@ViewBuilder _ bar: () -> some View) -> some View {
        modifier(FloatingBarModifier(bar: bar()))
    }
}

private struct FloatingBarModifier<Bar: View>: ViewModifier {
    let bar: Bar
    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                GlassEffectContainer(spacing: 12) {
                    bar.frame(height: FloatingBar.height)
                }
                .padding(.leading, FloatingBar.leading)
                .padding(.trailing, Sidebar.inset)
                .padding(.top, FloatingBar.top)
                .ignoresSafeArea(.container, edges: .top)
            }
    }
}

/// The new view fades in over the old one, which stays in place until it's covered, so nothing
/// dark shows between the two (two views fading at once let the window's black through).
struct CoverTransition: Transition {
    /// Where the new view comes in from.
    var offset: CGSize = .zero
    /// Gives the views the window's background, for pages that are partly see-through.
    var opaque = false

    func body(content: Content, phase: TransitionPhase) -> some View {
        content.cover(phase, from: offset, opaque: opaque)
    }
}

extension View {
    /// How a view looks at a `CoverTransition` phase.
    func cover(_ phase: TransitionPhase, from offset: CGSize = .zero, opaque: Bool = false) -> some View {
        background(opaque ? Theme.background : .clear)
            // The old view changes a hair, so it stays until the animation ends.
            .opacity(phase.value < 0 ? 0 : phase.value > 0 ? 0.99 : 1)
            .offset(phase.value < 0 ? offset : .zero)
            .zIndex(phase.value > 0 ? 0 : 1)
    }
}
