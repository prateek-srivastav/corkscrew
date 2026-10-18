import GameCore
import SwiftUI

/// A page of the Library: every game, one place's games, or a game.
indirect enum LibraryPage: Hashable {
    /// Every game: the Steam library and the programs in all bottles.
    case all
    case bottle(Bottle.ID)
    /// Games whose bottle was deleted.
    case noBottle
    /// A game's page, opened from `from`.
    case game(Game.ID, from: LibraryPage)
}

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigator.self) private var navigator
    let openSetup: () -> Void

    var body: some View {
        let page = navigator.route.library
        // The container animates, so the page that leaves stays while the new one comes in.
        ZStack {
            Group {
                if case .game(let id, let from) = page, let game = model.game(id: id) {
                    GamePage(game: game, backTitle: title(of: from)) { navigator.goUp(to: from) }
                } else if case .game(_, let from) = page {
                    // Removed, or gone from the Steam library.
                    gamesPage(from)
                } else {
                    gamesPage(page)
                }
            }
            .id(page)
            .transition(PageTransition(navigator: navigator))
        }
        .animation(.smooth(duration: 0.35), value: page)
    }

    /// The new page fades in over the old one (`CoverTransition`): another place rises a little;
    /// inside a place, a game's page comes in from the right and Back from the left. It reads the
    /// move when it runs, not when the page was made.
    private struct PageTransition: Transition {
        let navigator: Navigator

        func body(content: Content, phase: TransitionPhase) -> some View {
            let offset = switch navigator.move {
            case .push: CGSize(width: 90, height: 0)
            case .pop: CGSize(width: -90, height: 0)
            case .place: CGSize(width: 0, height: 8)
            }
            content.cover(phase, from: offset, opaque: true)
        }
    }

    private func gamesPage(_ page: LibraryPage) -> some View {
        let scope: GamesPage.Scope = switch page {
        case .bottle(let id): model.bottles.first { $0.id == id }.map(GamesPage.Scope.bottle) ?? .all
        case .noBottle: .noBottle
        case .all, .game: .all
        }
        let shown: LibraryPage = switch scope {
        case .all: .all
        case .bottle(let bottle): .bottle(bottle.id)
        case .noBottle: .noBottle
        }
        return GamesPage(scope: scope, openSetup: openSetup) { navigator.go(library: .game($0.id, from: shown)) }
    }

    private func title(of page: LibraryPage) -> String {
        switch page {
        case .all, .game: "Library"
        case .bottle(let id): model.bottles.first { $0.id == id }?.name ?? "Library"
        case .noBottle: "No Bottle"
        }
    }
}

/// A page of games: every game (the Library), or one place's. The Steam bottle shows the
/// signed-in account's Steam library and nothing else; other bottles take any Windows program.
private struct GamesPage: View {
    enum Scope {
        case all
        case bottle(Bottle)
        /// Games whose bottle was deleted.
        case noBottle
    }

    @Environment(AppModel.self) private var model
    let scope: Scope
    let openSetup: () -> Void
    let openGame: (Game) -> Void
    @State private var isDropTargeted = false
    @State private var query = ""
    /// The carousel's game.
    @State private var shown: Game.ID?

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 22, alignment: .top)]

    private var bottle: Bottle? {
        if case .bottle(let bottle) = scope { return bottle }
        return nil
    }

    private var isSteam: Bool { bottle?.role == .steam }
    private var isAll: Bool {
        if case .all = scope { return true }
        return false
    }

    private var title: String {
        switch scope {
        case .all: "Library"
        case .bottle(let bottle): bottle.name
        case .noBottle: "No Bottle"
        }
    }

    /// The Steam bottle's games while signed in; every program in another bottle.
    private var games: [Game] {
        switch scope {
        case .all: return model.allGames
        case .noBottle: return model.games.filter { game in !model.bottles.contains { $0.id == game.bottleID } }
        case .bottle(let bottle):
            if isSteam { return model.steamAccount == nil ? [] : model.steamGames }
            return model.games.filter { $0.bottleID == bottle.id }
        }
    }

    /// "Run once" programs running in this place.
    private var running: [Game] {
        model.transientSessions.map(\.game).filter { game in
            switch scope {
            case .all: true
            case .bottle(let bottle): game.bottleID == bottle.id
            case .noBottle: false
            }
        }
    }

    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        let games = games
        let featured = featuredGames(in: games)
        let found = isSearching ? games.filter { $0.name.localizedStandardContains(query.trimmingCharacters(in: .whitespaces)) } : games
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .top) {
                    HeroBackdrop(game: isSearching ? nil : featured.first { $0.id == shown } ?? featured.first,
                                 tint: Theme.tint(for: bottle))
                    VStack(alignment: .leading, spacing: 0) {
                        Color.clear.frame(height: FloatingBar.height)
                        if isSearching {
                            Text(title).font(.largeTitle.bold()).padding(.top, 28)
                        } else {
                            Spacer(minLength: 24)
                            if featured.isEmpty {
                                if isSteam { steamHero } else { emptyHero(hasLaunchers: !games.isEmpty) }
                            } else {
                                GameCarousel(games: featured, current: $shown, open: openGame)
                            }
                        }
                    }
                    .padding(.horizontal, 40)
                    .padding(.top, 20)
                    .padding(.bottom, 28)
                }
                .frame(height: isSearching ? nil : 460)
                .animation(.snappy(duration: 0.3), value: isSearching)

                VStack(alignment: .leading, spacing: 32) {
                    if isSearching && found.isEmpty {
                        Text("No games match “\(query.trimmingCharacters(in: .whitespaces))”.")
                            .font(.title3).foregroundStyle(.secondary)
                    }
                    if !running.isEmpty && !isSearching {
                        shelf("Running now") { cards(running, showsBottle: isAll) }
                    }
                    content(found)
                }
                .animation(.snappy(duration: 0.25), value: found.map(\.id))
                .padding(.horizontal, 40)
                .padding(.top, 8)
                .padding(.bottom, 48)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        // Outside the scroll view, so it stays put and typing in the search field never loses it.
        .floatingBar { topBar }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: Theme.cornerRadius).strokeBorder(.white.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .background(.white.opacity(0.04), in: .rect(cornerRadius: Theme.cornerRadius))
                    .padding(14)
                    .allowsHitTesting(false)
            }
        }
        // Programs go to other bottles; the Steam bottle only has Steam's games. On the Library
        // page, the Open sheet asks which bottle.
        .dropDestination(for: URL.self) { urls, _ in
            model.open(urls, in: bottle)
            return true
        } isTargeted: { isDropTargeted = $0 && !isSteam && model.isSetUp }
    }

    /// The carousel: installed games, the ones played last first (at most 8); else what there is.
    private func featuredGames(in games: [Game]) -> [Game] {
        let installed = games.filter { model.installState(of: $0) == .installed && !isStoreClient($0) }
        let played = installed.sorted { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }
        return Array((played.isEmpty ? games.filter { !isStoreClient($0) } : played).prefix(8))
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            if let bottle { BottleSummary(bottle: bottle) }
            Spacer(minLength: 0)
            SearchField(text: $query, prompt: isAll ? "Search all games" : "Search \(title)")
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
            } else if bottle != nil || isAll {
                Button("Add Program…", systemImage: "plus") { model.addProgram(in: bottle) }
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

    /// `hasLaunchers`: the place has only launchers (a Steam of its own), which the carousel leaves out.
    @ViewBuilder
    private func emptyHero(hasLaunchers: Bool) -> some View {
        if isAll && !model.isReady {
            heroMessage(model.isSettingUp ? "Setting up Corkscrew…" : "Finish setting up Corkscrew",
                        "Setup gets Wine, Steam, and two protected places for other Windows programs.") {
                Button("Open Settings", systemImage: "sparkles", action: openSetup).buttonStyle(.prominentPill)
            }
        } else if isAll {
            heroMessage("No games yet", "Sign in to Steam, or drop a Windows program (.exe), installer (.msi) or downloaded game (.zip, .rar, .iso) here.") {
                if let steam = model.launcherBottle, model.hasSteam(in: steam) {
                    BusyButton("Open Steam", systemImage: "arrow.up.forward.app", busyTitle: "Opening…",
                               isBusy: model.isPending(.openSteam)) { model.openSteam() }
                        .buttonStyle(.prominentPill)
                }
                Button("Add Program…", systemImage: "plus") { model.addProgram() }
                    .buttonStyle(.pill)
                    .disabled(!model.isSetUp)
            }
        } else {
            heroMessage(hasLaunchers ? "No games yet" : bottle.map { "No programs in \($0.name)" } ?? "No programs",
                        hasLaunchers ? "Get games with a launcher below, or drop a Windows program (.exe) or downloaded game (.zip, .rar, .iso) here."
                                     : "Drop a Windows program (.exe), installer (.msi) or downloaded game (.zip, .rar, .iso) here, or add one.") {
                if bottle != nil {
                    Button("Add Program…", systemImage: "plus") { model.addProgram(in: bottle) }
                        .buttonStyle(.prominentPill)
                        .disabled(!model.isSetUp)
                }
            }
        }
    }

    private func heroMessage(_ title: String, _ message: String, @ViewBuilder action: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.largeTitle.bold())
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
            shelf(isSteam || isAll ? "Installed" : "Programs") { cards(installed, showsBottle: isAll) }
        }
        if !notDownloaded.isEmpty {
            shelf(isSteam || isAll ? "Not Installed" : "Not Downloaded") { cards(notDownloaded, showsBottle: isAll) }
        }
    }

    private func cards(_ games: [Game], showsBottle: Bool = false) -> some View {
        ForEach(games) { game in
            GameCard(game: game, isSelected: false, showsBottle: showsBottle)
                .onTapGesture { openGame(game) }
                .contextMenu { menu(for: game) }
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
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
        // Steam's games come from the account's library.
        if model.bottle(for: game)?.role != .steam, model.games.contains(where: { $0.id == game.id }) {
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
                Chip(title: bottle.kind == .isolated ? "Protected" : "Standard",
                     systemImage: bottle.kind == .isolated ? "lock.shield" : "shippingbox",
                     tint: bottle.kind == .isolated ? Theme.isolated : .secondary)
                Chip(title: online ? "Internet on" : "Offline", systemImage: online ? "wifi" : "wifi.slash",
                     tint: online ? Theme.online : .secondary)
            }
            if model.runningBottles.contains(bottle.id) {
                // No endless effect: it kept the app redrawing for the whole game (~45% CPU plus
                // WindowServer compositing, measured 2026-10-17).
                Chip(title: "Running", systemImage: "circle.fill", tint: Theme.running)
                    .transition(.scale.combined(with: .opacity))
            }
        }
    }
}

/// The featured game's art behind the top of the page, fading into the background.
struct HeroBackdrop: View {
    let game: Game?
    /// The glow at the top right when there's no art: the place's colour.
    var tint: Color = .accentColor

    var body: some View {
        // The art fills the hero without setting its size.
        Theme.background
            .overlay {
                if let game {
                    SteamArt(game: game, kind: .hero) { IconGlow(game: game, size: 520) }
                        .id(game.id)
                        .transition(CoverTransition())
                } else {
                    RadialGradient(colors: [tint.opacity(0.32), .clear], center: .topTrailing, startRadius: 40, endRadius: 700)
                        .transition(CoverTransition())
                }
            }
            .clipped()
        .overlay {
            LinearGradient(stops: [.init(color: .black.opacity(0.6), location: 0), .init(color: .black.opacity(0.15), location: 0.55),
                                   .init(color: .clear, location: 1)],
                           startPoint: .leading, endPoint: .trailing)
        }
        .overlay {
            LinearGradient(stops: [.init(color: .black.opacity(0.3), location: 0), .init(color: .clear, location: 0.25),
                                   .init(color: .clear, location: 0.55), .init(color: Theme.background, location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
        .gesture(WindowDragGesture())
        // Pulled down past the top of the page, the art grows up to the window's top edge, so no
        // dark gap opens above it.
        .visualEffect { content, proxy in
            let pull = max(0, proxy.frame(in: .scrollView).minY)
            return content.scaleEffect(1 + pull / max(proxy.size.height, 1), anchor: .bottom)
        }
    }
}

/// A program's icon, blown up and blurred: the backdrop for games without Steam art.
struct IconGlow: View {
    let game: Game
    var size: CGFloat

    /// The icon is blurred this small, then scaled up: it looks the same as a blur at full size,
    /// for a small part of the GPU work (the hero's blur was 86 points).
    private static let blurredSize: CGFloat = 64

    var body: some View {
        LinearGradient(colors: [Color(white: 0.16), Color(white: 0.07)], startPoint: .topTrailing, endPoint: .bottomLeading)
            .overlay {
                GameIcon(game: game, size: Self.blurredSize)
                    .blur(radius: Self.blurredSize / 6)
                    .saturation(1.6)
                    // Room for the blur's edge, then one small layer that the scale only stretches.
                    .padding(Self.blurredSize / 3)
                    .drawingGroup()
                    .scaleEffect(size / Self.blurredSize)
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
                if advancedMode, let showSettings {
                    Button("Settings", systemImage: "slider.horizontal.3", action: showSettings)
                        .buttonStyle(.pill)
                }
                moreMenu(state: state, isActive: isActive)
                if let session {
                    HStack(spacing: 6) {
                        if isActive { Circle().fill(Theme.running).frame(width: 8, height: 8) }
                        Text(session.status.text).lineLimit(2)
                    }
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                } else if isActive {
                    // Started from Steam's own window.
                    HStack(spacing: 6) {
                        Circle().fill(Theme.running).frame(width: 8, height: 8)
                        Text("Running")
                    }
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                }
            }

            if state != .installed {
                Label(state == .downloading
                      ? "Downloading in Steam. It's ready to play once Steam finishes."
                      : "Not installed. Steam's page for it has the Install button.",
                      systemImage: "arrow.down.circle")
                    .font(.body).foregroundStyle(.secondary)
            }
            ForEach(session?.notes ?? [], id: \.self) { note in
                Label(note, systemImage: "info.circle").font(.body).foregroundStyle(.secondary)
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
                .clipShape(.rect(cornerRadius: Theme.cornerRadius))
                .saturation(state == .installed ? 1 : 0)
                .opacity(state == .installed ? 1 : 0.55)
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.cornerRadius)
                        .strokeBorder(isSelected ? Color.white : Theme.stroke, lineWidth: isSelected ? 2.5 : 1)
                }
                .overlay(alignment: .topLeading) {
                    if let busy = busyTitle {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text(busy)
                        }
                        .font(.subheadline.weight(.bold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: .capsule)
                        .padding(8)
                    } else if model.isRunning(game) {
                        Label("Running", systemImage: "circle.fill")
                            .font(.subheadline.weight(.bold))
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
                                .frame(width: Theme.controlHeight, height: Theme.controlHeight)
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
                Text(game.name).font(.body.weight(.semibold)).lineLimit(1)
                Text(subtitle(state)).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
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
