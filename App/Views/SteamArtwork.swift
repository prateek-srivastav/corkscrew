import AppKit
import GameCore
import SwiftUI

/// A game's library art: what Steam already keeps in the bottle's Steam folder
/// (`appcache/librarycache`), else Steam's store (for games Steam hasn't cached art for, and for
/// programs in other bottles that match a Steam game).
enum SteamArtwork {
    enum Kind: String {
        case hero = "library_hero.jpg"
        case cover = "library_600x900.jpg"
        case logo = "logo.png"
        case header = "header.jpg"

        /// Newer Steam calls the cover `library_capsule.jpg`.
        var fileNames: [String] { self == .cover ? [rawValue, "library_capsule.jpg"] : [rawValue] }
        var storeArt: SteamStore.Art { SteamStore.Art(rawValue: rawValue)! }
    }

    /// Found art only: Steam may fetch missing art later, so a miss is looked up again next time.
    private static var cache: [String: NSImage] = [:]

    static func key(_ kind: Kind, _ game: Game) -> String { "\(game.storeKey ?? game.id.uuidString) \(kind.rawValue)" }

    static func cached(_ kind: Kind, for game: Game) -> NSImage? { cache[key(kind, game)] }

    static func load(_ kind: Kind, for game: Game, model: AppModel) async -> NSImage? {
        let key = key(kind, game)
        if let image = cache[key] { return image }
        var data: Data?
        if let appID = game.store?.appID, let bottle = model.bottle(for: game) {
            data = await local(kind, appID: appID, prefix: BottleLocation(bottleID: bottle.id, paths: model.paths).prefix)
        }
        if data == nil {
            data = await fromStore(kind, for: game, model: model)
        }
        guard let image = data.flatMap(NSImage.init(data:)) else { return nil }
        cache[key] = image
        return image
    }

    private static func local(_ kind: Kind, appID: String, prefix: URL) async -> Data? {
        let names = kind.fileNames
        return await Task.detached(priority: .utility) { () -> Data? in
            guard let steam = Steam.root(inPrefix: prefix) else { return nil }
            let cache = steam.appending(path: "appcache/librarycache", directoryHint: .isDirectory)
            // Older Steam keeps flat "<id>_<name>" files; newer Steam a folder per game, with the art
            // in it or (newest) in a subfolder named by its hash.
            let folder = cache.appending(path: appID, directoryHint: .isDirectory)
            let subfolders = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            let candidates = names.flatMap { name in
                [folder.appending(path: name), cache.appending(path: "\(appID)_\(name)")] + subfolders.map { $0.appending(path: name) }
            }
            return candidates.lazy.compactMap { try? Data(contentsOf: $0) }.first
        }.value
    }

    /// Newer games have no hero at the usual address: their store page's backdrop stands in.
    private static func fromStore(_ kind: Kind, for game: Game, model: AppModel) async -> Data? {
        guard let appID = await model.steamAppID(for: game) else { return nil }
        let cache = model.storeCache
        let art = kind.storeArt
        if let data = await Task.detached(priority: .utility, operation: { await SteamStore.art(art, appID: appID, cache: cache) }).value {
            return data
        }
        guard kind == .hero || kind == .header, let details = await model.storeDetails(for: game),
              let url = kind == .hero ? details.backgroundImage : details.headerImage else { return nil }
        return await Task.detached(priority: .utility) { await SteamStore.image(at: url, cache: cache) }.value
    }
}

/// A game's Steam art, or `fallback` when Steam has none (programs added by hand, Steam itself).
struct SteamArt<Fallback: View>: View {
    @Environment(AppModel.self) private var model
    let game: Game
    let kind: SteamArtwork.Kind
    var contentMode: ContentMode = .fill
    /// Limits the art (a logo), not the fallback.
    var maxSize: CGSize?
    @ViewBuilder var fallback: () -> Fallback
    @State private var image: NSImage?

    init(game: Game, kind: SteamArtwork.Kind, contentMode: ContentMode = .fill, maxSize: CGSize? = nil,
         @ViewBuilder fallback: @escaping () -> Fallback) {
        self.game = game
        self.kind = kind
        self.contentMode = contentMode
        self.maxSize = maxSize
        self.fallback = fallback
        _image = State(initialValue: SteamArtwork.cached(kind, for: game))
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: contentMode)
                    .frame(maxWidth: maxSize?.width, maxHeight: maxSize?.height, alignment: .leading)
            } else {
                fallback()
            }
        }
        .task(id: SteamArtwork.key(kind, game)) {
            image = await SteamArtwork.load(kind, for: game, model: model)
        }
    }
}
