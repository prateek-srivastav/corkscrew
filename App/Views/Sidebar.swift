import AppKit
import GameCore
import SwiftUI

/// The column on the left: the Library with every game, Steam, the two protected bottles (and any
/// others the user made), Add Program and Setup. The column takes the open place's colour, faded
/// and grainy; the page lies over it. Collapsed, it shows only the icons.
struct Sidebar: View {
    /// From ContentView, so the sidebar changes in the same animation as the page.
    let isCollapsed: Bool
    @Environment(AppModel.self) private var model
    @Environment(Navigator.self) private var navigator
    @AppStorage(Theme.advancedModeKey) private var advancedMode = false

    static let width: CGFloat = 232
    /// The open sidebar's margin around its rows; the floating bar keeps it at the window's right edge too.
    static let inset: CGFloat = 12
    /// Collapsed: the window's close, minimize and zoom buttons fit with the same margin on both
    /// sides, and the icons sit under their middle.
    static let collapsedWidth = TopBar.windowButtonsWidth + 2 * TopBar.windowButtonsLeading

    private var width: CGFloat { isCollapsed ? Self.collapsedWidth : Self.width }

    var body: some View {
        let others = model.bottles.filter { $0.role == nil }
        let orphans = model.games.filter { game in !model.bottles.contains { $0.id == game.bottleID } }
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    place(.all, title: "Library", icon: .symbol("square.grid.2x2.fill"), tint: Theme.tint(for: nil)) {
                        Text(games(model.allGames.count))
                    }
                    if let steam = model.launcherBottle {
                        header("Launchers")
                        place(.bottle(steam.id), title: steam.name, icon: steamIcon, tint: Theme.tint(for: steam)) { steamStatus(steam) }
                    }
                    let protected = [Bottle.Role.sandbox, .sandboxOnline].compactMap(model.bottle(role:))
                    if !protected.isEmpty {
                        header("Protected")
                            .help("Programs here can't see your files or other apps.")
                        ForEach(protected) { bottlePlace($0) }
                    }
                    if !others.isEmpty || !orphans.isEmpty {
                        header("Other Bottles")
                        ForEach(others) { bottlePlace($0) }
                        if !orphans.isEmpty {
                            place(.noBottle, title: "No Bottle", icon: .symbol("questionmark.folder.fill"), tint: .gray) {
                                Text(games(orphans.count))
                            }
                        }
                    }
                }
                .padding(.horizontal, isCollapsed ? (Self.collapsedWidth - SidebarRow.collapsedSize) / 2 : Self.inset)
            }
            .scrollIndicators(.never)
            // The selection is drawn outside the scroll view; with room for every place, it stays put.
            .scrollBounceBehavior(.basedOnSize)

            VStack(alignment: .leading, spacing: 4) {
                Rectangle().fill(Theme.stroke).frame(height: 1).padding(.horizontal, 6).padding(.bottom, 8)
                SidebarRow(title: "Add Program…", icon: .symbol("plus"), tint: .white, isSelected: false) {
                    model.open(Pickers.programs())
                }
                .disabled(!model.isSetUp)
                .help("Add Program… (⌘O)")
                if advancedMode {
                    section(.bottles, title: "Bottles", systemImage: "shippingbox.fill")
                }
                section(.setup, title: "Settings", systemImage: "gearshape.fill", needsAttention: !model.isReady)
            }
            .padding(.horizontal, isCollapsed ? (Self.collapsedWidth - SidebarRow.collapsedSize) / 2 : Self.inset)
            .padding(.top, 8)
        }
        .environment(\.isSidebarCollapsed, isCollapsed)
        // One piece of glass under the open place, like the search field's, that slides to the next.
        .backgroundPreferenceValue(SelectedRowKey.self) { selected in
            GeometryReader { proxy in
                if let selected {
                    Color.clear
                        .glassEffect(glass(tint: selected.tint), in: .rect(cornerRadius: SidebarRow.radius(isCollapsed: isCollapsed)))
                        // Placed frame by frame, so the glass slides with the selection and grows and
                        // shrinks with the sidebar (see `GlassFollowingOffset`).
                        .modifier(GlassFrame(rect: proxy[selected.bounds]))
                        .transition(.opacity)
                }
            }
        }
        // Clears the window's close, minimize and zoom buttons.
        .padding(.top, TopBar.bottom + 14)
        .padding(.bottom, 14)
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .background(Color.clear.contentShape(.rect).gesture(WindowDragGesture()))
        // Reaches under the page's round corners, so they show the sidebar, not the window's black.
        .background(alignment: .leading) {
            SidebarBackdrop(tint: openTint)
                .frame(width: width + Theme.windowCornerRadius)
                .allowsHitTesting(false)
                .animation(.smooth(duration: 0.5), value: openTint)
        }
        .ignoresSafeArea(.container, edges: .top)
        // The selection's glass slides from place to place (Setup and Bottles are places here too).
        .animation(.spring(duration: 0.4, bounce: 0.25), value: navigator.route.place)
    }

    /// Open, the selection is plain glass (the row's tile has the colour). Collapsed, the icons have
    /// no tiles, so the glass takes the place's colour; for Setup and Bottles it is white with a black
    /// glyph, as their tile is when open (plain glass looks like every other icon on glass).
    private func glass(tint: Color) -> Glass {
        guard isCollapsed else { return .regular.interactive() }
        return .regular.tint(tint == .white ? .white.opacity(0.85) : tint.opacity(0.6)).interactive()
    }

    /// The colour of the open place; white for the pages that aren't places (Setup, Bottles).
    private var openTint: Color {
        guard navigator.route.section == .library else { return .white }
        switch navigator.route.library.place {
        case .bottle(let id): return Theme.tint(for: model.bottles.first { $0.id == id })
        case .noBottle: return .gray
        case .all, .game: return Theme.library
        }
    }

    private func isOpen(_ page: LibraryPage) -> Bool {
        navigator.route.section == .library && navigator.route.library.place == page
    }

    private func place(_ page: LibraryPage, title: String, icon: SidebarRow.Icon, tint: Color,
                       @ViewBuilder subtitle: () -> some View) -> some View {
        SidebarRow(title: title, icon: icon, tint: tint, isSelected: isOpen(page), subtitle: AnyView(subtitle())) {
            navigator.go(library: page)
        }
    }

    private func bottlePlace(_ bottle: Bottle) -> some View {
        let online = bottle.kind == .standard || bottle.isolation.allowNetwork
        let icon: SidebarRow.Icon = switch bottle.role {
        case .sandbox: .symbol("lock.shield.fill")
        case .sandboxOnline: .symbol("globe")
        default: .symbol(bottle.kind == .isolated ? "lock.shield.fill" : "shippingbox.fill")
        }
        return place(.bottle(bottle.id), title: bottle.name, icon: icon, tint: Theme.tint(for: bottle)) {
            HStack(spacing: 4) {
                if model.runningBottles.contains(bottle.id) {
                    Text("Running").foregroundStyle(Theme.running)
                } else {
                    Image(systemName: online ? "wifi" : "wifi.slash")
                    Text(online ? "Internet on" : "No internet")
                }
            }
            .foregroundStyle(online ? Theme.online : .secondary)
        }
    }

    private func section(_ section: SidebarItem, title: String, systemImage: String, needsAttention: Bool = false) -> some View {
        SidebarRow(title: title, icon: .symbol(systemImage), tint: .white, isSelected: navigator.route.section == section,
                   needsAttention: needsAttention) {
            navigator.go(section)
        }
    }

    private var steamIcon: SidebarRow.Icon {
        if let client = model.steamClient, let icon = model.icon(for: client) { return .image(icon) }
        return .symbol("gamecontroller.fill")
    }

    @ViewBuilder
    private func steamStatus(_ steam: Bottle) -> some View {
        if model.steamRunning.contains(steam.id) {
            Text("Running").foregroundStyle(Theme.running)
        } else if model.steamInstalls.contains(steam.id) {
            Text("Installing…")
        } else if !model.hasSteam(in: steam) {
            Text("Not installed")
        } else if model.steamAccount == nil {
            Text("Not signed in")
        } else {
            Text(games(model.steamGames.count))
        }
    }

    @ViewBuilder
    private func header(_ title: String) -> some View {
        if isCollapsed {
            // No room for the words: a short line between the groups.
            Rectangle().fill(Theme.stroke).frame(width: 20, height: 1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        } else {
            // As macOS's own sidebars (Finder, System Settings): 11 pt semibold, not in capitals.
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)
                .padding(.top, 16)
                .padding(.bottom, 4)
        }
    }

    private func games(_ count: Int) -> String { count == 1 ? "1 game" : "\(count) games" }
}

/// Collapses the sidebar to its icons and opens it again. It is on the page, at its top left, on
/// the window buttons' line, with the sidebar open or collapsed.
struct SidebarToggle: View {
    @Binding var isCollapsed: Bool

    static let size = Theme.controlHeight
    /// From the page's left edge.
    static let leading: CGFloat = 16
    /// From the window's top edge: on the window buttons' line.
    static let top = TopBar.centerY - size / 2

    var body: some View {
        // A glass circle like the page's other buttons.
        // One label in both states: a label that changed would fade out where the button was and in
        // where it goes, instead of moving with the page.
        Button { isCollapsed.toggle() } label: { Image(systemName: "sidebar.left") }
            .accessibilityLabel(isCollapsed ? "Expand Sidebar" : "Collapse Sidebar")
            .buttonStyle(CircleButtonStyle())
            .help(isCollapsed ? "Expand Sidebar (⌃⌘S)" : "Collapse Sidebar (⌃⌘S)")
            .padding(.leading, Self.leading)
            .padding(.top, Self.top)
    }
}

/// One place in the sidebar: its icon on a tile, its name and a line of state. Open, the row and
/// the tile take the place's colour.
struct SidebarRow: View {
    enum Icon {
        case symbol(String)
        case image(NSImage)
    }

    let title: String
    let icon: Icon
    let tint: Color
    let isSelected: Bool
    var needsAttention = false
    var subtitle: AnyView?
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isSidebarCollapsed) private var isCollapsed
    @State private var isHovering = false
    /// The space around the tile, inside the row's round corners.
    private static let inset: CGFloat = 5
    /// A collapsed row: the icon alone, as large as the app's other buttons.
    static let collapsedSize = Theme.controlHeight
    /// Concentric with the row's corners.
    private static let tileRadius = Theme.cornerRadius - inset
    /// The row's corners. Collapsed, the icon's glass is a rounded square like the open sidebar's
    /// tiles; with the app's radius, a 34 pt square would be a circle.
    static func radius(isCollapsed: Bool) -> CGFloat { isCollapsed ? tileRadius : Theme.cornerRadius }
    /// Counts the times the row was opened, to bounce its icon each time.
    @State private var opened = 0

    init(title: String, icon: Icon, tint: Color, isSelected: Bool, needsAttention: Bool = false, subtitle: AnyView? = nil,
         action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.tint = tint
        self.isSelected = isSelected
        self.needsAttention = needsAttention
        self.subtitle = subtitle
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                tile
                if !isCollapsed {
                    VStack(alignment: .leading, spacing: 1) {
                        // The name as System Settings' sidebar has it: the 13 pt body font, regular weight.
                        Text(title).font(.body).foregroundStyle(.primary).lineLimit(1)
                        if let subtitle {
                            subtitle.font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .transition(.opacity)
                    Spacer(minLength: 0)
                }
            }
            .padding(.leading, isCollapsed ? 0 : Self.inset + 1)
            .padding(.trailing, isCollapsed ? 0 : 12)
            .padding(.vertical, isCollapsed ? 0 : Self.inset)
            .background {
                if isHovering && !isSelected { RoundedRectangle(cornerRadius: Self.radius(isCollapsed: isCollapsed)).fill(Theme.surfaceHover) }
            }
            // The sidebar draws the selection's glass here (see `Sidebar`).
            .anchorPreference(key: SelectedRowKey.self, value: .bounds) { isSelected ? SelectedRow(bounds: $0, tint: tint) : nil }
            .contentShape(.rect(cornerRadius: Self.radius(isCollapsed: isCollapsed)))
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .onChange(of: isSelected) { if isSelected { opened += 1 } }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        // Collapsed, the name shows when the pointer rests on the icon.
        .help(isCollapsed ? title : "")
    }

    private var tile: some View {
        ZStack {
            switch icon {
            // Collapsed, each icon is on glass, like the app's round buttons; the open place's glass is
            // the sidebar's sliding one (see `Sidebar`).
            case .symbol(let name):
                RoundedRectangle(cornerRadius: Self.tileRadius).fill(isCollapsed ? .clear : isSelected ? tint : Theme.surface)
                Image(systemName: name)
                    .font(.system(size: isCollapsed ? 18 : 16, weight: .semibold))
                    .foregroundStyle(isSelected ? (tint == .white ? Color.black : Color.white) : tint)
                    .symbolEffect(.bounce, value: opened)
            case .image(let image):
                RoundedRectangle(cornerRadius: Self.tileRadius).fill(isCollapsed ? .clear : isSelected ? tint.opacity(0.35) : Theme.surface)
                Image(nsImage: image).resizable().interpolation(.high).frame(width: isCollapsed ? 24 : 26, height: isCollapsed ? 24 : 26)
                    .scaleEffect(isSelected ? 1.08 : 1)
            }
        }
        .frame(width: isCollapsed ? Self.collapsedSize : 32, height: isCollapsed ? Self.collapsedSize : 32)
        .glassEffect(isCollapsed && !isSelected ? .regular : .identity, in: .rect(cornerRadius: Self.tileRadius))
        .overlay(alignment: .topTrailing) {
            if needsAttention { Circle().fill(.red).frame(width: 9, height: 9).offset(x: 3, y: -3) }
        }
    }
}

/// The sidebar's backdrop: the window's own dark, washed from the top with the open place's
/// colour, with a fine grain.
private struct SidebarBackdrop: View {
    let tint: Color

    var body: some View {
        ZStack {
            LinearGradient(colors: [tint.opacity(tint == .white ? 0.07 : 0.2), tint.opacity(tint == .white ? 0.02 : 0.05)],
                           startPoint: .top, endPoint: .bottom)
            Grain().opacity(0.06).blendMode(.plusLighter)
        }
    }
}

/// Fine film grain: the same specks every time, so it doesn't shimmer when the view redraws.
private struct Grain: View {
    var body: some View {
        Canvas { context, size in
            var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
            func next() -> Double {
                seed &+= 0x9E37_79B9_7F4A_7C15
                var z = seed
                z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
                z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
                return Double(z ^ (z >> 31)) / Double(UInt64.max)
            }
            for _ in 0..<Int(size.width * size.height / 14) {
                let rect = CGRect(x: next() * size.width, y: next() * size.height, width: 1, height: 1)
                context.fill(Path(rect), with: .color(.white.opacity(next())))
            }
        }
    }
}

/// Gives its content the size and place of `rect`, one frame at a time (see `GlassFollowingOffset`).
private struct GlassFrame: ViewModifier, Animatable {
    var rect: CGRect
    var animatableData: CGRect.AnimatableData {
        get { rect.animatableData }
        set { rect.animatableData = newValue }
    }

    func body(content: Content) -> some View {
        content
            .frame(width: rect.width, height: rect.height)
            .padding(.leading, rect.minX)
            .padding(.top, rect.minY)
    }
}

/// The sidebar's selected row: where the sidebar puts its glass, and the place's colour.
private struct SelectedRow {
    let bounds: Anchor<CGRect>
    let tint: Color
}

private struct SelectedRowKey: PreferenceKey {
    static let defaultValue: SelectedRow? = nil
    static func reduce(value: inout SelectedRow?, nextValue: () -> SelectedRow?) { value = value ?? nextValue() }
}
