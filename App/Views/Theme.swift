import SwiftUI

/// The app's look: a dark game launcher with soft cards, pill buttons and an icon rail.
enum Theme {
    static let background = Color(red: 0.055, green: 0.058, blue: 0.066)
    static let panel = Color(red: 0.085, green: 0.088, blue: 0.098)
    static let surface = Color.white.opacity(0.055)
    static let surfaceHover = Color.white.opacity(0.09)
    static let stroke = Color.white.opacity(0.08)
    static let isolated = Color.orange
    static let running = Color.green
    static let online = Color.green

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
            .background(.ultraThinMaterial, in: .capsule)
            .overlay { Capsule().strokeBorder(Theme.stroke) }
    }
}

/// Capsule buttons: white for the main action (Play), translucent for the rest.
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
            .background(background(isPressed: configuration.isPressed), in: .capsule)
            .overlay { Capsule().strokeBorder(prominent ? .clear : Theme.stroke) }
            // A busy button stays readable: it says what it's doing.
            .opacity(isEnabled ? 1 : isBusy ? 0.75 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .contentShape(.capsule)
            .onHover { isHovering = $0 }
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }

    private func background(isPressed: Bool) -> AnyShapeStyle {
        if prominent { return AnyShapeStyle(Color.white.opacity(isPressed ? 0.8 : isHovering ? 0.92 : 1)) }
        return isHovering || isPressed ? AnyShapeStyle(Color.white.opacity(0.16)) : AnyShapeStyle(.ultraThinMaterial)
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
            .background(isHovering || configuration.isPressed ? AnyShapeStyle(Color.white.opacity(0.16)) : AnyShapeStyle(.ultraThinMaterial),
                        in: .circle)
            .overlay { Circle().strokeBorder(Theme.stroke) }
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
