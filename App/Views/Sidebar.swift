import AppKit
import GameCore
import SwiftUI

/// The column on the left: the Library with every game, Steam, the two protected bottles (and any
/// others the user made), Add Program and Setup. The column takes the open place's colour, faded
/// and grainy; the page lies over it.
struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigator.self) private var navigator
    @AppStorage(Theme.advancedModeKey) private var advancedMode = false
    /// The selection slides from place to place.
    @Namespace private var selection

    static let width: CGFloat = 232

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
                .padding(.horizontal, 12)
            }
            .scrollIndicators(.never)

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
                section(.setup, title: "Setup", systemImage: "gearshape.fill", needsAttention: !model.isReady)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
        // Clears the window's close, minimize and zoom buttons.
        .padding(.top, 52)
        .padding(.bottom, 14)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(Color.clear.contentShape(.rect).gesture(WindowDragGesture()))
        // Reaches under the page's round corners, so they show the sidebar, not the window's black.
        .background(alignment: .leading) {
            SidebarBackdrop(tint: openTint)
                .frame(width: Self.width + Theme.windowCornerRadius)
                .allowsHitTesting(false)
                .animation(.smooth(duration: 0.5), value: openTint)
        }
        .ignoresSafeArea(.container, edges: .top)
        .environment(\.sidebarSelection, selection)
        .animation(.snappy(duration: 0.3), value: navigator.route.place)
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

    private func header(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.bold))
            .tracking(1)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 8)
            .padding(.top, 16)
            .padding(.bottom, 4)
    }

    private func games(_ count: Int) -> String { count == 1 ? "1 game" : "\(count) games" }
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
    @Environment(\.sidebarSelection) private var selection
    @State private var isHovering = false
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
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.callout.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                    if let subtitle {
                        subtitle.font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background {
                if isSelected {
                    highlight
                } else if isHovering {
                    RoundedRectangle(cornerRadius: 10).fill(Theme.surfaceHover)
                }
            }
            .contentShape(.rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .onChange(of: isSelected) { if isSelected { opened += 1 } }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Plain Liquid Glass: the column around it already has the place's colour.
    @ViewBuilder
    private var highlight: some View {
        let glass = Color.clear.glassEffect(.regular, in: .rect(cornerRadius: 10))
        if let selection {
            glass.matchedGeometryEffect(id: "selection", in: selection)
        } else {
            glass
        }
    }

    private var tile: some View {
        ZStack {
            switch icon {
            case .symbol(let name):
                RoundedRectangle(cornerRadius: 8).fill(isSelected ? tint : Theme.surface)
                Image(systemName: name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isSelected ? (tint == .white ? Color.black : Color.white) : tint)
                    .symbolEffect(.bounce, value: opened)
            case .image(let image):
                RoundedRectangle(cornerRadius: 8).fill(isSelected ? tint.opacity(0.35) : Theme.surface)
                Image(nsImage: image).resizable().interpolation(.high).frame(width: 24, height: 24)
                    .scaleEffect(isSelected ? 1.08 : 1)
            }
        }
        .frame(width: 32, height: 32)
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

extension EnvironmentValues {
    /// The sidebar's namespace for the sliding selection.
    @Entry var sidebarSelection: Namespace.ID?
}
