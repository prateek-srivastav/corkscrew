import GameCore
import SwiftUI

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Game.ID?
    @State private var isDropTargeted = false
    /// The bottle tab shown (a bottle id, or "none" for games whose bottle is gone), kept between launches.
    @AppStorage("LibraryBottleTab") private var tabID = ""

    private let columns = [GridItem(.adaptive(minimum: 132, maximum: 170), spacing: 16, alignment: .top)]

    var body: some View {
        let tab = currentTab
        VStack(spacing: 0) {
            if tabs.count > 0 {
                BottleTabs(tabs: tabs, selection: tab?.id) { tabID = $0 }
                Divider()
            }
            ScrollView {
                if !model.transientSessions.isEmpty {
                    section("Running now") {
                        ForEach(model.transientSessions, id: \.game.id) { session in
                            GameCard(game: session.game, isSelected: false, showsBottle: true)
                                .contextMenu { Button("Stop") { model.stop(session.game) } }
                        }
                    }
                }
                if let tab {
                    tabContent(tab)
                } else {
                    ContentUnavailableView {
                        Label("No games yet", systemImage: "gamecontroller")
                    } description: {
                        Text("Drop a Windows program (.exe) or installer (.msi) here, open one from Finder, or add one.")
                    } actions: {
                        Button("Add Program…") { model.open(Pickers.programs()) }
                            .disabled(!model.isSetUp)
                    }
                    .padding(.top, 60)
                }
            }
        }
        .background(isDropTargeted ? Color.accentColor.opacity(0.08) : .clear)
        .dropDestination(for: URL.self) { urls, _ in
            model.open(urls, in: currentTab?.bottle)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem {
                Button("Add Program…", systemImage: "plus") { model.open(Pickers.programs(), in: currentTab?.bottle) }
                    .disabled(!model.isSetUp)
            }
        }
        .onChange(of: tab?.id) { selection = nil }
        .inspector(isPresented: Binding(get: { selectedGame != nil }, set: { if !$0 { selection = nil } })) {
            if let game = selectedGame {
                GameDetailView(game: game).id(game.id)
                    .inspectorColumnWidth(min: 320, ideal: 380, max: 520)
                    .inspectorCloseButton { selection = nil }
            }
        }
    }

    private var selectedGame: Game? { model.games.first { $0.id == selection } }

    /// One tab per bottle, in the Bottles list's order; games whose bottle is gone get the last one.
    private var tabs: [BottleTab] {
        var result = model.bottles.map { bottle in
            BottleTab(id: bottle.id.uuidString, bottle: bottle, games: model.games.filter { $0.bottleID == bottle.id })
        }
        let known = Set(model.bottles.map(\.id))
        let orphans = model.games.filter { !known.contains($0.bottleID) }
        if !orphans.isEmpty { result.append(BottleTab(id: "none", bottle: nil, games: orphans)) }
        return result
    }

    /// The chosen tab, else the first with games, else the first.
    private var currentTab: BottleTab? {
        let tabs = tabs
        return tabs.first { $0.id == tabID } ?? tabs.first { !$0.games.isEmpty } ?? tabs.first
    }

    @ViewBuilder
    private func tabContent(_ tab: BottleTab) -> some View {
        let installed = tab.games.filter { model.installState(of: $0) == .installed }
        let notDownloaded = tab.games.filter { model.installState(of: $0) != .installed }
        VStack(alignment: .leading, spacing: 12) {
            if let bottle = tab.bottle { BottleSummary(bottle: bottle) }
            if tab.games.isEmpty {
                ContentUnavailableView {
                    Label("No games in \(tab.bottle?.name ?? "this bottle")", systemImage: "gamecontroller")
                } description: {
                    Text("Drop a Windows program (.exe) or installer (.msi) here, or add one.")
                } actions: {
                    Button("Add Program…") { model.open(Pickers.programs(), in: tab.bottle) }
                }
                .padding(.top, 40)
            }
            if !installed.isEmpty {
                LazyVGrid(columns: columns, spacing: 18) { cards(installed) }
            }
            if !notDownloaded.isEmpty {
                Text("Not Downloaded").font(.subheadline).foregroundStyle(.secondary)
                LazyVGrid(columns: columns, spacing: 18) { cards(notDownloaded) }
            }
        }
        .padding(20)
    }

    private func cards(_ games: [Game]) -> some View {
        ForEach(games) { game in
            GameCard(game: game, isSelected: selection == game.id)
                .onTapGesture(count: 2) { model.play(game) }
                .onTapGesture { selection = selection == game.id ? nil : game.id }
                .contextMenu { menu(for: game) }
        }
    }

    private func section(_ title: String?, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title { Text(title).font(.headline).foregroundStyle(.secondary) }
            LazyVGrid(columns: columns, spacing: 18, content: content)
        }
        .padding(20)
    }

    @ViewBuilder
    private func menu(for game: Game) -> some View {
        if model.session(for: game)?.isActive == true {
            Button("Stop") { model.stop(game) }
        } else if model.installState(of: game) != .installed {
            Button("Open in Steam") { model.openInSteam(game) }
        } else {
            Button("Play") { model.play(game) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([game.iconSource ?? game.executable]) }
        }
        Divider()
        Button("Remove from Library", role: .destructive) {
            if selection == game.id { selection = nil }
            model.remove(game)
        }
    }
}

private struct BottleTab: Identifiable {
    let id: String
    /// Nil for games whose bottle is gone.
    let bottle: Bottle?
    let games: [Game]
}

/// Standard bottles aren't sandboxed, so they always have the internet.
private func isOnline(_ bottle: Bottle) -> Bool { bottle.kind == .standard || bottle.isolation.allowNetwork }

/// The bottle tabs above the games, scrolling sideways when there are many.
private struct BottleTabs: View {
    @Environment(AppModel.self) private var model
    let tabs: [BottleTab]
    let selection: String?
    let select: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tabs) { tab in
                    Button { select(tab.id) } label: { label(tab, isSelected: tab.id == selection) }
                        .buttonStyle(.plain)
                        .help(help(tab))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private func label(_ tab: BottleTab, isSelected: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: tab.bottle?.kind == .isolated ? "lock.shield.fill" : "shippingbox.fill")
                .foregroundStyle(tab.bottle?.kind == .isolated ? Color.orange : Color.accentColor)
            Text(tab.bottle?.name ?? "No Bottle").fontWeight(isSelected ? .semibold : .regular)
            Text("\(tab.games.count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            if let bottle = tab.bottle {
                let online = isOnline(bottle)
                Image(systemName: online ? "wifi" : "wifi.slash").font(.caption)
                    .foregroundStyle(online && bottle.kind == .isolated ? Color.orange : .secondary)
                if model.runningBottles.contains(bottle.id) { Circle().fill(.green).frame(width: 7, height: 7) }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(.quaternary.opacity(0.5)), in: .capsule)
        .overlay { Capsule().strokeBorder(isSelected ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1) }
        .contentShape(.capsule)
    }

    private func help(_ tab: BottleTab) -> String {
        guard let bottle = tab.bottle else { return "Games whose bottle was deleted" }
        return (bottle.kind == .isolated ? "Isolated" : "Standard") + ", " + (isOnline(bottle) ? "internet on" : "offline")
            + (model.runningBottles.contains(bottle.id) ? ", running" : "")
    }
}

/// The shown bottle's kind, internet and state, above its games.
private struct BottleSummary: View {
    @Environment(AppModel.self) private var model
    let bottle: Bottle

    var body: some View {
        let online = isOnline(bottle)
        HStack(spacing: 12) {
            Label(bottle.kind == .isolated ? "Isolated" : "Standard",
                  systemImage: bottle.kind == .isolated ? "lock.shield" : "shippingbox")
            Label(online ? "Internet on" : "Offline", systemImage: online ? "wifi" : "wifi.slash")
                .foregroundStyle(online && bottle.kind == .isolated ? Color.orange : .secondary)
            if model.runningBottles.contains(bottle.id) {
                Label("Running", systemImage: "circle.fill").foregroundStyle(.green)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

struct GameCard: View {
    @Environment(AppModel.self) private var model
    let game: Game
    let isSelected: Bool
    /// Outside a bottle's section ("Running now"), the card names the bottle.
    var showsBottle = false
    @State private var isHovering = false

    var body: some View {
        let session = model.session(for: game)
        let state = model.installState(of: game)
        VStack(spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                GameIcon(game: game, size: 72)
                    .saturation(state == .installed ? 1 : 0)
                    .opacity(state == .installed ? 1 : 0.5)
                    .padding(14)
                    .frame(maxWidth: .infinity)
                    .background(.quaternary.opacity(isSelected ? 1 : 0.5), in: .rect(cornerRadius: 14))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14).strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
                    }
                if session?.isActive == true {
                    Circle().fill(.green).frame(width: 12, height: 12).padding(8).help(session?.status.text ?? "")
                } else if isHovering {
                    Button { model.play(game) } label: {
                        Image(systemName: state == .installed ? "play.fill" : "arrow.down").padding(6)
                    }
                    .buttonStyle(.borderedProminent)
                    .clipShape(.circle)
                    .padding(6)
                    .help(state == .installed ? "Play" : "Open its page in Steam to download it")
                }
            }
            VStack(spacing: 2) {
                Text(game.name).font(.callout.weight(.medium)).lineLimit(2).multilineTextAlignment(.center)
                Text(subtitle(state))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .contentShape(.rect)
        .onHover { isHovering = $0 }
    }

    private func subtitle(_ state: Steam.InstallState) -> String {
        switch state {
        // The bottle shows in the section header.
        case .installed:
            showsBottle ? model.bottle(for: game)?.name ?? "No bottle"
                : game.store?.store != Steam.store ? "Program" : game.store?.appID == nil ? "Launcher" : "Steam"
        case .downloading: "Downloading in Steam"
        case .notInstalled: game.store?.appID.map(Steam.isTested(appID:)) == true ? "Tested · Get it on Steam" : "Not downloaded"
        }
    }
}
