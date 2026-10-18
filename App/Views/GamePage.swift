import AppKit
import GameCore
import SwiftUI

/// One game: its art, Play, and what Steam's store says about it (for a program in another
/// bottle, the Steam game it matches).
struct GamePage: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Theme.advancedModeKey) private var advancedMode = false
    let game: Game
    /// The name of the page Back goes to.
    let backTitle: String
    let back: () -> Void
    @State private var details: SteamStore.Details?
    @State private var isLoading = true
    @State private var showsSettings = false
    @State private var screenshot: URL?
    @State private var uninstallPlan: AppModel.UninstallPlan?
    @State private var isPlanningUninstall = false

    private var inLibrary: Bool { model.games.contains { $0.id == game.id } }
    private var isSteamBottle: Bool { model.bottle(for: game)?.role == .steam }

    /// Steam games through Steam; programs in other bottles by deleting their folder.
    private var uninstall: (() -> Void)? {
        if game.store?.appID != nil {
            return model.installState(of: game) == .installed ? { model.uninstallInSteam(game) } : nil
        }
        return isSteamBottle || !inLibrary ? nil : { planUninstall() }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .top) {
                    HeroBackdrop(game: game, tint: model.bottle(for: game).map(Theme.tint) ?? .gray)
                    VStack(alignment: .leading, spacing: 0) {
                        Color.clear.frame(height: FloatingBar.height)
                        Spacer(minLength: 24)
                        GameHero(game: game,
                                 showSettings: inLibrary ? { showsSettings = true } : nil,
                                 remove: isSteamBottle || !inLibrary ? nil : { remove() },
                                 uninstall: uninstall)
                    }
                    .padding(.horizontal, 40)
                    .padding(.top, 20)
                    .padding(.bottom, 28)
                }
                .frame(height: 500)

                about
                    .padding(.horizontal, 40)
                    .padding(.top, 8)
                    .padding(.bottom, 48)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .floatingBar { topBar }
        .overlay { if let screenshot { enlarged(screenshot) } }
        .sidePanel(isPresented: advancedMode && showsSettings && inLibrary, title: "Game Settings", close: { showsSettings = false }) {
            GameDetailView(game: game)
        }
        .task(id: game.id) {
            details = await model.storeDetails(for: game)
            isLoading = false
        }
        .alert(uninstallTitle, isPresented: Binding(get: { uninstallPlan != nil }, set: { if !$0 { uninstallPlan = nil } }),
               presenting: uninstallPlan) { plan in
            Button("Uninstall", role: .destructive) { model.uninstall(plan) }
            Button("Cancel", role: .cancel) {}
        } message: { plan in
            Text("Deletes \(ByteCountFormatter.string(fromByteCount: plan.size, countStyle: .file)) for good.")
        }
    }

    private func planUninstall() {
        guard !isPlanningUninstall else { return }
        isPlanningUninstall = true
        Task {
            uninstallPlan = await model.uninstallPlan(for: game)
            isPlanningUninstall = false
        }
    }

    /// Names the other library entries the uninstall deletes too, so the message stays one line.
    private var uninstallTitle: String {
        "Uninstall \(([game] + (uninstallPlan?.others ?? [])).map(\.name).formatted(.list(type: .and)))?"
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button(backTitle, systemImage: "chevron.left", action: back)
                .buttonStyle(.pill)
                .help("Back to \(backTitle)")
            Spacer(minLength: 0)
            if let appID = details?.appID, let url = URL(string: "https://store.steampowered.com/app/\(appID)") {
                Link(destination: url) { Label("Store Page", systemImage: "safari") }
                    .buttonStyle(.pill)
                    .help("Open the game's Steam store page in your browser")
            }
        }
    }

    @ViewBuilder
    private var about: some View {
        if let details {
            VStack(alignment: .leading, spacing: 32) {
                HStack(alignment: .top, spacing: 40) {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionLabel("About")
                        Text(details.summary.isEmpty ? "Steam has no description for it." : details.summary)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: 640, alignment: .leading)
                        if details.name.caseInsensitiveCompare(game.name) != .orderedSame {
                            Text("On Steam as “\(details.name)”.").font(.body).foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            info("Developer", details.developers.joined(separator: ", "))
                            info("Publisher", details.publishers.joined(separator: ", "))
                            info("Released", details.releaseDate ?? "")
                            info("Genres", details.genres.joined(separator: ", "))
                        }
                    }
                    .frame(width: 300)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if !details.screenshots.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        SectionLabel("Screenshots")
                        ScrollView(.horizontal) {
                            LazyHStack(spacing: 14) {
                                ForEach(details.screenshots, id: \.self) { url in
                                    // 1920×1080 decoded is 8 MB; a tile needs 640×360 pixels.
                                    StoreImage(url: url, maxPixelSize: 640)
                                        .frame(width: 320, height: 180)
                                        .clipShape(.rect(cornerRadius: Theme.cornerRadius))
                                        .overlay { RoundedRectangle(cornerRadius: Theme.cornerRadius).strokeBorder(Theme.stroke) }
                                        .contentShape(.rect)
                                        .onTapGesture { withAnimation(.snappy) { screenshot = url } }
                                }
                            }
                            .padding(.bottom, 8)
                        }
                        .scrollIndicators(.hidden)
                        .swipesScrollFirst()
                    }
                }
            }
        } else if isLoading {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Getting details from Steam…").foregroundStyle(.secondary)
            }
        } else {
            Text(game.store?.appID == nil
                 ? "Corkscrew couldn't match this program to a game in the Steam store, so there are no details for it."
                 : "Steam's store didn't answer. Details show once you're online.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func info(_ title: String, _ value: String) -> some View {
        if !value.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline).foregroundStyle(.secondary)
                Text(value).font(.body.weight(.medium)).textSelection(.enabled)
            }
        }
    }

    private func enlarged(_ url: URL) -> some View {
        ZStack {
            Color.black.opacity(0.85).ignoresSafeArea()
            StoreImage(url: url, contentMode: .fit)
                .clipShape(.rect(cornerRadius: Theme.cornerRadius))
                .padding(60)
        }
        .contentShape(.rect)
        .onTapGesture { withAnimation(.snappy) { screenshot = nil } }
        .onKeyPress(.escape) {
            screenshot = nil
            return .handled
        }
        .transition(.opacity)
    }

    private func remove() {
        back()
        model.remove(game)
    }
}

/// A picture from Steam's store, kept in the store cache.
struct StoreImage: View {
    @Environment(AppModel.self) private var model
    let url: URL
    var contentMode: ContentMode = .fill
    /// Decodes it this small (longest side, in pixels); nil: at full size.
    var maxPixelSize: Int?
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: contentMode)
            } else {
                Theme.surface.overlay { ProgressView().controlSize(.small) }
            }
        }
        .task(id: url) {
            let cache = model.storeCache
            let url = url
            guard let data = await Task.detached(priority: .utility, operation: { await SteamStore.image(at: url, cache: cache) }).value
            else { return image = nil }
            image = if let maxPixelSize { await SteamArtwork.downsampled(data, maxPixelSize: maxPixelSize)?.image } else { NSImage(data: data) }
        }
    }
}
