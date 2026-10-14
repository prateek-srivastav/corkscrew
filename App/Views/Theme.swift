import GameCore
import SwiftUI

/// The app's look: a dark game launcher with soft cards, pill buttons and a sidebar of places.
enum Theme {
    static let background = Color(red: 0.055, green: 0.058, blue: 0.066)
    static let panel = Color(red: 0.085, green: 0.088, blue: 0.098)
    static let surface = Color.white.opacity(0.055)
    static let surfaceHover = Color.white.opacity(0.09)
    static let stroke = Color.white.opacity(0.08)
    static let isolated = Color.orange
    static let running = Color.green
    static let online = Color.green
    /// Steam's blue, from its logo.
    static let steam = Color(red: 0.10, green: 0.60, blue: 1.0)

    /// A sidebar place's colour, also the glow of its page: the Library white, Steam blue, Offline
    /// Games orange, Online Games green, other bottles grey.
    static func tint(for bottle: Bottle?) -> Color {
        switch bottle?.role {
        case nil: bottle == nil ? .white : .gray
        case .steam: steam
        case .sandbox: isolated
        case .sandboxOnline: online
        }
    }

    /// The Advanced mode default: shows each game's launch settings and logs, and the runtime tools.
    static let advancedModeKey = "AdvancedMode"
}

/// A small uppercase heading above a group, like "GAMES" or "NOT DOWNLOADED".
struct SectionLabel: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(1.2)
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
            .background(Theme.surface, in: .rect(cornerRadius: 18))
            .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.stroke) }
    }
}

/// A capsule with an icon and a few words: a bottle's kind, internet or state.
struct Chip: View {
    let title: String
    let systemImage: String
    var tint: Color = .secondary

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.medium))
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
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isBusy) private var isBusy
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .foregroundStyle(prominent ? Color.black : destructive ? Color.red : Color.primary)
            .background {
                if prominent {
                    Capsule().fill(.white.opacity(configuration.isPressed ? 0.8 : isHovering ? 0.92 : 1))
                } else if isHovering || configuration.isPressed {
                    Capsule().fill(.white.opacity(configuration.isPressed ? 0.14 : 0.08))
                }
            }
            .glassEffect(prominent ? .identity : destructive ? .regular.tint(.red.opacity(0.18)) : .regular, in: .capsule)
            // A busy button stays readable: it says what it's doing.
            .opacity(isEnabled ? 1 : isBusy ? 0.75 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .contentShape(.capsule)
            .onHover { isHovering = $0 }
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
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
    var size: CGFloat = 34
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(.system(size: size * 0.4, weight: .semibold))
            .frame(width: size, height: size)
            .background { if isHovering || configuration.isPressed { Circle().fill(.white.opacity(configuration.isPressed ? 0.14 : 0.08)) } }
            .glassEffect(.regular, in: .circle)
            .contentShape(.circle)
            .onHover { isHovering = $0 }
    }
}

extension View {
    /// A page's large title with its actions on the right.
    func pageHeader(_ title: String, subtitle: String? = nil, @ViewBuilder actions: () -> some View = { EmptyView() }) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.system(size: 34, weight: .bold))
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
                            .buttonStyle(CircleButtonStyle(size: 28))
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

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
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
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .overlay { if isFocused { Capsule().strokeBorder(.white.opacity(0.35)) } }
        .glassEffect(.regular, in: .capsule)
        .background {
            Button("Search") { isFocused = true }
                .keyboardShortcut("f")
                .opacity(0)
                .accessibilityHidden(true)
        }
    }
}

/// A page's top bar that stays in place while the page scrolls under it. The bar has no
/// background: its glass search field and buttons float on the page.
enum FloatingBar {
    /// The bar's height; a page leaves this much space at its top for it.
    static let height: CGFloat = 36
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
                .padding(.horizontal, 40)
                .padding(.top, 20)
                .ignoresSafeArea(.container, edges: .top)
            }
    }
}

extension View {
    /// Fades the view in and lifts it a little the first time it shows; `delay` staggers a row.
    func appearEffect(delay: Double = 0) -> some View {
        modifier(AppearEffect(delay: delay))
    }
}

private struct AppearEffect: ViewModifier {
    let delay: Double
    @State private var isShown = false

    func body(content: Content) -> some View {
        content
            .opacity(isShown ? 1 : 0)
            .offset(y: isShown ? 0 : 10)
            .onAppear {
                withAnimation(.easeOut(duration: 0.35).delay(delay)) { isShown = true }
            }
    }
}
