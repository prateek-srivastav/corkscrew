import GameCore
import SwiftUI

/// Where the Library is: the overview of launchers and bottles, or one of them.
enum LibraryPage: Hashable {
    case overview
    case bottle(Bottle.ID)
    /// Games whose bottle was deleted.
    case noBottle
    /// A game's page, opened from its bottle's page (nil: No Bottle).
    case game(Game.ID, bottle: Bottle.ID?)
}

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigator.self) private var navigator
    let openSetup: () -> Void

    private var page: LibraryPage { navigator.route.library }

    var body: some View {
        Group {
            switch page {
            case .overview:
                LibraryOverview(open: { navigator.go(library: $0) }, openSetup: openSetup)
            case .bottle(let id):
                if let bottle = model.bottles.first(where: { $0.id == id }) {
                    bottlePage(bottle)
                } else {
                    LibraryOverview(open: { navigator.go(library: $0) }, openSetup: openSetup)
                }
            case .noBottle:
                bottlePage(nil)
            case .game(let id, let bottleID):
                let from = bottleID.flatMap { id in model.bottles.first { $0.id == id } }
                if let game = model.game(id: id) {
                    GamePage(game: game, backTitle: from?.name ?? "No Bottle") { navigator.goUp(to: from.map { .bottle($0.id) } ?? .noBottle) }
                } else {
                    // Removed, or gone from the Steam library.
                    bottlePage(from)
                }
            }
        }
        .id(page)
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.2), value: page)
    }

    private func back() { navigator.goUp(to: .overview) }

    private func bottlePage(_ bottle: Bottle?) -> some View {
        BottlePage(bottle: bottle, back: back, openSetup: openSetup) { navigator.go(library: .game($0.id, bottle: bottle?.id)) }
    }
}

/// Every launcher and bottle as a card: Steam, the two sandboxes, then the bottles the user made.
private struct LibraryOverview: View {
    @Environment(AppModel.self) private var model
    let open: (LibraryPage) -> Void
    let openSetup: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 280, maximum: 420), spacing: 18, alignment: .top)]
    private let gameColumns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 22, alignment: .top)]

    var body: some View {
        let others = model.bottles.filter { $0.role == nil }
        let orphans = model.games.filter { game in !model.bottles.contains { $0.id == game.bottleID } }
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                if !model.isReady {
                    setUpCard
                }
                if !model.transientSessions.isEmpty {
                    section("Running now") {
                        LazyVGrid(columns: gameColumns, alignment: .leading, spacing: 26) {
                            ForEach(model.transientSessions, id: \.game.id) { session in
                                GameCard(game: session.game, isSelected: false, showsBottle: true)
                                    .contextMenu {
                                        busyItem("Stop", "Stopping…", model.isPending(.stop(session.game.id))) { model.stop(session.game) }
                                    }
                            }
                        }
                    }
                }
                if let launcher = model.launcherBottle {
                    section("Launchers") {
                        SteamCard(bottle: launcher) { open(.bottle(launcher.id)) }
                    }
                }
                let sandboxes = [Bottle.Role.sandbox, .sandboxOnline].compactMap(model.bottle(role:))
                if !sandboxes.isEmpty {
                    section("Sandboxes") { bottleGrid(sandboxes) }
                }
                if !others.isEmpty || !orphans.isEmpty {
                    section("Other Bottles") {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                            ForEach(others) { bottle in
                                Button { open(.bottle(bottle.id)) } label: { BottleCard(bottle: bottle) }
                                    .buttonStyle(.plain)
                            }
                            if !orphans.isEmpty {
                                Button { open(.noBottle) } label: {
                                    HubCard(systemImage: "questionmark.folder", title: "No Bottle",
                                            detail: "\(count(orphans.count)) whose bottle was deleted", tint: .secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .pageHeader("Library")
            .padding(.horizontal, 40)
            .padding(.top, 52)
            .padding(.bottom, 48)
        }
        .ignoresSafeArea(.container, edges: .top)
        .background { Color.clear.contentShape(.rect).gesture(WindowDragGesture()) }
    }

    private var setUpCard: some View {
        Card(padding: 22) {
            HStack(spacing: 16) {
                Image(systemName: "sparkles").font(.title2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.isSettingUp ? "Setting up Corkscrew…" : "Finish setting up Corkscrew").font(.headline)
                    Text("Setup gets Wine, the Steam bottle with Steam, and two sandboxes for other programs.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open Setup", action: openSetup).buttonStyle(.prominentPill)
            }
        }
    }

    private func bottleGrid(_ bottles: [Bottle]) -> some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
            ForEach(bottles) { bottle in
                Button { open(.bottle(bottle.id)) } label: { BottleCard(bottle: bottle) }
                    .buttonStyle(.plain)
            }
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel(title)
            content()
        }
    }
}

private func count(_ programs: Int) -> String { programs == 1 ? "1 program" : "\(programs) programs" }

/// Steam: its own icon on Steam's colours, the account, covers of the games played last, and
/// Open Steam / Quit Steam right on the card. The rest of the card opens Steam's page.
private struct SteamCard: View {
    @Environment(AppModel.self) private var model
    let bottle: Bottle
    let open: () -> Void
    @State private var isHovering = false

    /// Steam's navy, from its own window.
    static let colors = [Color(red: 0.09, green: 0.16, blue: 0.25), Color(red: 0.06, green: 0.09, blue: 0.15)]

    var body: some View {
        let games = model.steamAccount == nil ? [] : model.steamGames
        let recent = Array(games.filter { model.installState(of: $0) == .installed }
            .sorted { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }.prefix(4))
        let isRunning = model.steamRunning.contains(bottle.id)
        HStack(spacing: 24) {
            steamIcon
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("Steam").font(.system(size: 34, weight: .heavy))
                    if isRunning { Chip(title: "Running", systemImage: "circle.fill", tint: Theme.running) }
                }
                Text(status(games: games)).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 10) {
                    if model.hasSteam(in: bottle) {
                        BusyButton("Open Steam", systemImage: "arrow.up.forward.app", busyTitle: "Opening…",
                                   isBusy: model.isPending(.openSteam)) { model.openSteam() }
                            .buttonStyle(.prominentPill)
                    }
                    if isRunning || model.isPending(.quitSteam) {
                        BusyButton("Quit Steam", systemImage: "stop.fill", busyTitle: "Quitting…", isBusy: model.isPending(.quitSteam)) {
                            model.quitSteam()
                        }
                        .buttonStyle(.destructivePill)
                    }
                }
                .padding(.top, 8)
            }
            Spacer(minLength: 0)
            // The games played last, fanned out.
            ZStack {
                ForEach(Array(recent.enumerated().reversed()), id: \.element.id) { offset, game in
                    SteamArt(game: game, kind: .cover) { Theme.surface }
                        .frame(width: 84, height: 126)
                        .clipShape(.rect(cornerRadius: 10))
                        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.stroke) }
                        .shadow(color: .black.opacity(0.5), radius: 8, y: 4)
                        .rotationEffect(.degrees(Double(offset) * 6 - 4))
                        .offset(x: CGFloat(offset) * -38)
                }
            }
            .padding(.trailing, 8)
            Image(systemName: "chevron.right").font(.title3.weight(.semibold)).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(height: 200)
        .background {
            LinearGradient(colors: Self.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay(alignment: .leading) {
                    // The icon's glow behind it.
                    steamIcon.scaleEffect(2.2).blur(radius: 40).opacity(0.45).offset(x: 20)
                }
        }
        .clipShape(.rect(cornerRadius: 20))
        .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(isHovering ? Color.white.opacity(0.3) : Theme.stroke) }
        .contentShape(.rect(cornerRadius: 20))
        .onTapGesture(perform: open)
        .onHover { isHovering = $0 }
        .animation(.snappy(duration: 0.2), value: isHovering)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Open Steam's Page", open)
    }

    /// Steam's own icon, from its program in the bottle.
    @ViewBuilder
    private var steamIcon: some View {
        if let client = model.steamClient, let icon = model.icon(for: client) {
            Image(nsImage: icon).resizable().interpolation(.high).frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
        } else {
            Image(systemName: "gamecontroller.fill").font(.system(size: 54)).frame(width: 96, height: 96)
        }
    }

    private func status(games: [Game]) -> String {
        if model.steamInstalls.contains(bottle.id) { return "Installing Steam…" }
        guard model.hasSteam(in: bottle) else { return "Steam isn't installed yet" }
        guard let account = model.steamAccount else { return "Not signed in" }
        let name = account.personaName.isEmpty ? account.accountName : account.personaName
        return "Signed in as \(name) · " + (games.count == 1 ? "1 game" : "\(games.count) games")
    }
}

/// A sandbox or another bottle: its kind, internet and how many programs it has.
private struct BottleCard: View {
    @Environment(AppModel.self) private var model
    let bottle: Bottle

    var body: some View {
        let online = isOnline(bottle)
        let programs = model.games.filter { $0.bottleID == bottle.id }.count
        HubCard(systemImage: bottle.kind == .isolated ? "lock.shield.fill" : "shippingbox.fill", title: bottle.name,
                // The icon tells isolated (lock) from standard (box).
                detail: [online ? "Internet on" : "Offline", count(programs)].joined(separator: " · "),
                tint: bottle.kind == .isolated ? Theme.isolated : .primary,
                isRunning: model.runningBottles.contains(bottle.id))
    }
}

private struct HubCard: View {
    let systemImage: String
    let title: String
    let detail: String
    var tint: Color = .primary
    var isRunning = false
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 48, height: 48)
                .background(Theme.surface, in: .rect(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(.headline).lineLimit(1)
                    if isRunning { Circle().fill(Theme.running).frame(width: 7, height: 7) }
                }
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").foregroundStyle(.secondary)
        }
        .padding(16)
        .background(isHovering ? Theme.surfaceHover : Theme.surface, in: .rect(cornerRadius: 18))
        .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.stroke) }
        .contentShape(.rect(cornerRadius: 18))
        .onHover { isHovering = $0 }
    }
}

/// One bottle's games. The Steam bottle shows the signed-in account's Steam library and nothing
/// else; other bottles take any Windows program.
private struct BottlePage: View {
    @Environment(AppModel.self) private var model
    /// Nil for games whose bottle was deleted.
    let bottle: Bottle?
    let back: () -> Void
    let openSetup: () -> Void
    let openGame: (Game) -> Void
    @State private var isDropTargeted = false

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 22, alignment: .top)]

    private var isSteam: Bool { bottle?.role == .steam }

    /// The Steam bottle's games while signed in; every program in another bottle.
    private var games: [Game] {
        if isSteam { return model.steamAccount == nil ? [] : model.steamGames }
        guard let bottle else { return model.games.filter { game in !model.bottles.contains { $0.id == game.bottleID } } }
        return model.games.filter { $0.bottleID == bottle.id }
    }

    var body: some View {
        let games = games
        let featured = featuredGames(in: games)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Group {
                    if featured.isEmpty {
                        ZStack(alignment: .top) {
                            HeroBackdrop(game: nil)
                            VStack(alignment: .leading, spacing: 0) {
                                topBar
                                Spacer(minLength: 24)
                                if isSteam { steamHero } else { emptyHero }
                            }
                            .padding(.horizontal, 40)
                            .padding(.top, 20)
                            .padding(.bottom, 28)
                        }
                    } else {
                        GameCarousel(games: featured, open: openGame) { topBar }
                    }
                }
                .frame(height: 460)

                VStack(alignment: .leading, spacing: 32) { content(games) }
                    .padding(.horizontal, 40)
                    .padding(.top, 8)
                    .padding(.bottom, 48)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .background(.white.opacity(0.04), in: .rect(cornerRadius: 22))
                    .padding(14)
                    .allowsHitTesting(false)
            }
        }
        // Programs go to other bottles; the Steam bottle only has Steam's games.
        .dropDestination(for: URL.self) { urls, _ in
            model.open(urls, in: bottle)
            return true
        } isTargeted: { isDropTargeted = $0 && !isSteam }
    }

    /// The carousel: installed games, the ones played last first (at most 8); else what there is.
    private func featuredGames(in games: [Game]) -> [Game] {
        let installed = games.filter { model.installState(of: $0) == .installed && !isStoreClient($0) }
        let played = installed.sorted { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }
        return Array((played.isEmpty ? games.filter { !isStoreClient($0) } : played).prefix(8))
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button("Library", systemImage: "chevron.left", action: back)
                .buttonStyle(.pill)
                .help("Back to the Library")
            if let bottle { BottleSummary(bottle: bottle) }
            Spacer(minLength: 0)
            if isSteam {
                // Signed out, the page's own Open Steam button is enough.
                if let bottle, model.hasSteam(in: bottle), model.steamAccount != nil {
                    BusyButton("Open Steam", systemImage: "arrow.up.forward.app", busyTitle: "Opening…",
                               isBusy: model.isPending(.openSteam)) { model.openSteam() }
                        .buttonStyle(.pill)
                }
                if let bottle, model.steamRunning.contains(bottle.id) || model.isPending(.quitSteam) {
                    BusyButton("Quit Steam", systemImage: "stop.fill", busyTitle: "Quitting…", isBusy: model.isPending(.quitSteam)) {
                        model.quitSteam()
                    }
                    .buttonStyle(.destructivePill)
                }
            } else if bottle != nil {
                Button("Add Program…", systemImage: "plus") { model.open(Pickers.programs(), in: bottle) }
                    .buttonStyle(.pill)
                    .disabled(!model.isSetUp)
            }
        }
    }

    /// The Steam bottle without games to show: Steam isn't there, nobody is signed in, or the
    /// library is empty.
    @ViewBuilder
    private var steamHero: some View {
        if let bottle, model.steamInstalls.contains(bottle.id) {
            heroMessage("Installing Steam", "Steam downloads about 240 MB the first time. Then open it and sign in.") {
                ProgressView().controlSize(.small)
            }
        } else if let bottle, !model.hasSteam(in: bottle) {
            heroMessage("Steam isn't installed", "Setup installs Steam into this bottle. Then sign in, and your Steam library shows here.") {
                BusyButton("Install Steam", systemImage: "arrow.down.circle.fill", busyTitle: "Installing…",
                           isBusy: model.steamInstalls.contains(bottle.id)) { Task { await model.installSteam(into: bottle) } }
                    .buttonStyle(.prominentPill)
                    .disabled(model.activity != nil || !model.isSetUp)
            }
        } else if model.steamAccount == nil {
            heroMessage("Sign in to Steam", "Open Steam and sign in. The games in your Steam library then show here.") {
                BusyButton("Open Steam", systemImage: "person.crop.circle", busyTitle: "Opening…",
                           isBusy: model.isPending(.openSteam)) { model.openSteam() }
                    .buttonStyle(.prominentPill)
            }
        } else {
            heroMessage("No games yet", "Steam is still loading your library, or it has no games. Get games in Steam and they show here.") {
                BusyButton("Open Steam", systemImage: "arrow.up.forward.app", busyTitle: "Opening…",
                           isBusy: model.isPending(.openSteam)) { model.openSteam() }
                    .buttonStyle(.prominentPill)
            }
        }
    }

    private var emptyHero: some View {
        heroMessage(bottle.map { "No programs in \($0.name)" } ?? "No programs",
                    "Drop a Windows program (.exe) or installer (.msi) here, open one from Finder, or add one.") {
            if bottle != nil {
                Button("Add Program…", systemImage: "plus") { model.open(Pickers.programs(), in: bottle) }
                    .buttonStyle(.prominentPill)
                    .disabled(!model.isSetUp)
            }
        }
    }

    private func heroMessage(_ title: String, _ message: String, @ViewBuilder action: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel(bottle?.name ?? "No Bottle")
            Text(title).font(.system(size: 46, weight: .heavy))
            Text(message)
                .font(.title3).foregroundStyle(.secondary)
                .frame(maxWidth: 520, alignment: .leading)
            HStack(spacing: 12) { action() }.padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func content(_ games: [Game]) -> some View {
        let installed = games.filter { model.installState(of: $0) == .installed && !(isSteam && isStoreClient($0)) }
        let notDownloaded = games.filter { model.installState(of: $0) != .installed }
        if !installed.isEmpty {
            shelf(isSteam ? "Installed" : "Programs") { cards(installed) }
        }
        if !notDownloaded.isEmpty {
            shelf(isSteam ? "Not Installed" : "Not Downloaded") { cards(notDownloaded) }
        }
    }

    private func cards(_ games: [Game]) -> some View {
        ForEach(games) { game in
            GameCard(game: game, isSelected: false)
                .onTapGesture { openGame(game) }
                .contextMenu { menu(for: game) }
        }
    }

    private func shelf(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionLabel(title)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 26, content: content)
        }
    }

    @ViewBuilder
    private func menu(for game: Game) -> some View {
        if model.isRunning(game) {
            busyItem("Stop", "Stopping…", model.isPending(.stop(game.id))) { model.stop(game) }
        } else if model.installState(of: game) != .installed {
            busyItem("Open in Steam", "Opening…", model.isPending(.steamPage(game.id))) { model.openInSteam(game) }
        } else {
            busyItem("Play", "Starting…", model.isPending(.launch(game.id))) { model.play(game) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([game.iconSource ?? game.executable]) }
        }
        if !isSteam {
            Divider()
            Button("Remove from Library", role: .destructive) { remove(game) }
        }
    }

    private func remove(_ game: Game) {
        model.remove(game)
    }
}

/// Standard bottles aren't sandboxed, so they always have the internet.
private func isOnline(_ bottle: Bottle) -> Bool { bottle.kind == .standard || bottle.isolation.allowNetwork }

/// Steam itself, as opposed to a game installed through it.
private func isStoreClient(_ game: Game) -> Bool { game.store != nil && game.store?.appID == nil }

/// The shown bottle's kind, internet and state, next to its games.
private struct BottleSummary: View {
    @Environment(AppModel.self) private var model
    let bottle: Bottle

    var body: some View {
        let online = isOnline(bottle)
        HStack(spacing: 8) {
            // A launcher's bottle is always standard and online; the chips only matter for bottles.
            if bottle.role != .steam {
                Chip(title: bottle.kind == .isolated ? "Isolated" : "Standard",
                     systemImage: bottle.kind == .isolated ? "lock.shield" : "shippingbox",
                     tint: bottle.kind == .isolated ? Theme.isolated : .secondary)
                Chip(title: online ? "Internet on" : "Offline", systemImage: online ? "wifi" : "wifi.slash",
                     tint: online ? Theme.online : .secondary)
            }
            if model.runningBottles.contains(bottle.id) {
                Chip(title: "Running", systemImage: "circle.fill", tint: Theme.running)
            }
        }
    }
}

/// The featured game's art behind the top of the page, fading into the background.
struct HeroBackdrop: View {
    let game: Game?

    var body: some View {
        // The art fills the hero without setting its size.
        Theme.background
            .overlay {
                if let game {
                    SteamArt(game: game, kind: .hero) { IconGlow(game: game, size: 520) }
                        .id(game.id)
                        .transition(.opacity)
                } else {
                    RadialGradient(colors: [Color.accentColor.opacity(0.35), .clear], center: .topTrailing, startRadius: 40, endRadius: 700)
                }
            }
            .clipped()
        .overlay {
            LinearGradient(stops: [.init(color: .black.opacity(0.8), location: 0), .init(color: .black.opacity(0.25), location: 0.55),
                                   .init(color: .clear, location: 1)],
                           startPoint: .leading, endPoint: .trailing)
        }
        .overlay {
            LinearGradient(stops: [.init(color: .black.opacity(0.45), location: 0), .init(color: .clear, location: 0.25),
                                   .init(color: .clear, location: 0.55), .init(color: Theme.background, location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
        .gesture(WindowDragGesture())
    }
}

/// A program's icon, blown up and blurred: the backdrop for games without Steam art.
struct IconGlow: View {
    let game: Game
    var size: CGFloat

    var body: some View {
        LinearGradient(colors: [Color(white: 0.16), Color(white: 0.07)], startPoint: .topTrailing, endPoint: .bottomLeading)
            .overlay {
                GameIcon(game: game, size: size)
                    .blur(radius: size / 6)
                    .saturation(1.6)
                    .opacity(0.6)
            }
            .clipped()
    }
}

/// The featured game: its name or logo, Play, and how the launch is going.
struct GameHero: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Theme.advancedModeKey) private var advancedMode = false
    let game: Game
    /// Nil when the game has no settings to change (a Steam game that isn't installed yet).
    let showSettings: (() -> Void)?
    /// Nil on the Steam page, which lists the account's library as it is.
    let remove: (() -> Void)?
    /// In the carousel: opens the game's page (its name and a Details button lead there).
    var openDetails: (() -> Void)? = nil

    var body: some View {
        let session = model.session(for: game)
        let isActive = model.isRunning(game)
        let state = model.installState(of: game)
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                if model.bottle(for: game)?.kind == .isolated { Image(systemName: "lock.shield.fill").foregroundStyle(Theme.isolated) }
                SectionLabel([model.bottle(for: game)?.name ?? "No bottle", subtitle(state)].joined(separator: " · "))
            }
            SteamArt(game: game, kind: .logo, contentMode: .fit, maxSize: CGSize(width: 440, height: 130)) {
                Text(game.name)
                    .font(.system(size: 52, weight: .heavy))
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .shadow(color: .black.opacity(0.5), radius: 12)
            }
            .frame(maxWidth: 560, alignment: .leading)
            .contentShape(.rect)
            .onTapGesture { openDetails?() }

            HStack(spacing: 10) {
                if model.isPending(.launch(game.id)) {
                    // Until its window shows: a launch takes a while (Steam may update first).
                    BusyButton("Play", busyTitle: "Starting…", isBusy: true) {}
                        .buttonStyle(.prominentPill)
                }
                if isActive {
                    BusyButton("Stop", systemImage: "stop.fill", busyTitle: "Stopping…", isBusy: model.isPending(.stop(game.id))) {
                        model.stop(game)
                    }
                    .buttonStyle(.destructivePill)
                } else if state != .installed {
                    BusyButton("Open in Steam", systemImage: "arrow.down.circle.fill", busyTitle: "Opening…",
                               isBusy: model.isPending(.steamPage(game.id))) { model.openInSteam(game) }
                        .buttonStyle(.prominentPill)
                } else {
                    BusyButton("Play", systemImage: "play.fill", busyTitle: "Starting…", isBusy: false) { model.play(game) }
                        .buttonStyle(.prominentPill)
                }
                if let openDetails {
                    Button("Details", systemImage: "info.circle", action: openDetails)
                        .buttonStyle(.pill)
                }
                if advancedMode, let showSettings {
                    Button("Settings", systemImage: "slider.horizontal.3", action: showSettings)
                        .buttonStyle(.pill)
                }
                if openDetails == nil { moreMenu(state: state, isActive: isActive) }
                if let session {
                    HStack(spacing: 6) {
                        if isActive { Circle().fill(Theme.running).frame(width: 8, height: 8) }
                        Text(session.status.text).lineLimit(2)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                } else if isActive {
                    // Started from Steam's own window.
                    HStack(spacing: 6) {
                        Circle().fill(Theme.running).frame(width: 8, height: 8)
                        Text("Running")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                }
            }

            if state != .installed {
                Label(state == .downloading
                      ? "Downloading in Steam. It's ready to play once Steam finishes."
                      : "Not installed. Steam's page for it has the Install button.",
                      systemImage: "arrow.down.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(session?.notes ?? [], id: \.self) { note in
                Label(note, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 640, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func moreMenu(state: Steam.InstallState, isActive: Bool) -> some View {
        Menu {
            Button("Show Program in Finder") { NSWorkspace.shared.activateFileViewerSelecting([game.iconSource ?? game.executable]) }
                .disabled(state != .installed)
            if let remove {
                Divider()
                Button("Remove from Library", role: .destructive, action: remove)
                    .disabled(isActive)
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.button)
        .buttonStyle(CircleButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func subtitle(_ state: Steam.InstallState) -> String {
        switch state {
        case .installed: game.store?.store != Steam.store ? "Program" : game.store?.appID == nil ? "Launcher" : "Steam"
        case .downloading: "Downloading in Steam"
        case .notInstalled: "Not installed"
        }
    }
}

struct GameCard: View {
    @Environment(AppModel.self) private var model
    let game: Game
    let isSelected: Bool
    /// Outside a bottle's page ("Running now"), the card names the bottle.
    var showsBottle = false
    @State private var isHovering = false

    /// What the card's game is busy with, from a button here or on the hero.
    private var busyTitle: String? {
        if model.isPending(.launch(game.id)) { return "Starting…" }
        if model.isPending(.steamPage(game.id)) { return "Opening…" }
        if model.isPending(.stop(game.id)) { return "Stopping…" }
        return nil
    }

    var body: some View {
        let session = model.session(for: game)
        let state = model.installState(of: game)
        VStack(alignment: .leading, spacing: 10) {
            Color.clear
                .aspectRatio(2 / 3, contentMode: .fit)
                .overlay {
                    SteamArt(game: game, kind: .cover) {
                        ZStack {
                            IconGlow(game: game, size: 200)
                            GameIcon(game: game, size: 76).shadow(color: .black.opacity(0.4), radius: 10, y: 4)
                        }
                    }
                }
                .clipShape(.rect(cornerRadius: 16))
                .saturation(state == .installed ? 1 : 0)
                .opacity(state == .installed ? 1 : 0.55)
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(isSelected ? Color.white : Theme.stroke, lineWidth: isSelected ? 2.5 : 1)
                }
                .overlay(alignment: .topLeading) {
                    if let busy = busyTitle {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text(busy)
                        }
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: .capsule)
                        .padding(8)
                    } else if model.isRunning(game) {
                        Label("Running", systemImage: "circle.fill")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Theme.running)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.ultraThinMaterial, in: .capsule)
                            .padding(8)
                            .help(session?.status.text ?? "")
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if isHovering, !model.isRunning(game), busyTitle == nil {
                        Button { model.play(game) } label: {
                            Image(systemName: state == .installed ? "play.fill" : "arrow.down")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.black)
                                .frame(width: 38, height: 38)
                                .background(.white, in: .circle)
                                .shadow(color: .black.opacity(0.4), radius: 8, y: 3)
                        }
                        .buttonStyle(.plain)
                        .padding(10)
                        .help(state == .installed ? "Play" : "Open its page in Steam to download it")
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
                .shadow(color: .black.opacity(isHovering ? 0.5 : 0.25), radius: isHovering ? 18 : 8, y: isHovering ? 10 : 4)
                .scaleEffect(isHovering ? 1.03 : 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(game.name).font(.callout.weight(.semibold)).lineLimit(1)
                Text(subtitle(state)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 2)
        }
        .contentShape(.rect)
        .onHover { isHovering = $0 }
        .animation(.snappy(duration: 0.2), value: isHovering)
    }

    private func subtitle(_ state: Steam.InstallState) -> String {
        switch state {
        // The page names the bottle.
        case .installed:
            showsBottle ? model.bottle(for: game)?.name ?? "No bottle"
                : game.store?.store != Steam.store ? "Program" : game.store?.appID == nil ? "Launcher" : "Steam"
        case .downloading: "Downloading in Steam"
        case .notInstalled: game.store?.appID.map(Steam.isTested(appID:)) == true ? "Tested · Not installed" : "Not installed"
        }
    }
}
