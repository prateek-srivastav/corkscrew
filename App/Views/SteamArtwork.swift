import AppKit
import GameCore
import ImageIO
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

        /// The longest side, in pixels, the app draws the art at (on a Retina screen). Store heroes
        /// can be 3840×1240: 19 MB once decoded, for a backdrop that is seldom wider than 2560 px.
        var maxPixelSize: Int {
            switch self {
            case .hero: 2560
            case .cover: 600   // cards are at most 190 × 285 pt
            case .logo: 960    // shown at most 440 × 150 pt
            case .header: 920
            }
        }
    }

    /// Found art only: Steam may fetch missing art later, so a miss is looked up again next time.
    /// Bounded, and emptied when a game starts or the Mac runs short of memory: art stays decoded in
    /// memory, and a page that shows it again reads it from disk in a few milliseconds.
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 96 << 20
        return cache
    }()

    static func key(_ kind: Kind, _ game: Game) -> String { "\(game.storeKey ?? game.id.uuidString) \(kind.rawValue)" }

    static func cached(_ kind: Kind, for game: Game) -> NSImage? { cache.object(forKey: key(kind, game) as NSString) }

    /// Gives the memory back while a game runs; pages on screen keep the art they show.
    static func purge() { cache.removeAllObjects() }

    static func load(_ kind: Kind, for game: Game, model: AppModel) async -> NSImage? {
        let key = key(kind, game) as NSString
        if let image = cache.object(forKey: key) { return image }
        guard let data = await data(kind, for: game, model: model),
              let (image, bytes) = await downsampled(data, maxPixelSize: kind.maxPixelSize) else { return nil }
        cache.setObject(image, forKey: key, cost: bytes)
        return image
    }

    /// Decodes a picture off the main thread, at most `maxPixelSize` on its longest side; with its
    /// size in memory.
    static func downsampled(_ data: Data, maxPixelSize: Int) async -> (image: NSImage, bytes: Int)? {
        guard let decoded = await Task.detached(priority: .utility, operation: { decode(data, maxPixelSize: maxPixelSize) }).value
        else { return nil }
        let image = decoded.image
        return (NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)), image.bytesPerRow * image.height)
    }

    /// Fetches art the store has for the game into the store's disk cache, without decoding it.
    static func prefetch(_ kind: Kind, for game: Game, model: AppModel) async {
        if cached(kind, for: game) == nil { _ = await data(kind, for: game, model: model) }
    }

    private static func data(_ kind: Kind, for game: Game, model: AppModel) async -> Data? {
        if let appID = game.store?.appID, let bottle = model.bottle(for: game),
           let data = await local(kind, appID: appID, prefix: BottleLocation(bottleID: bottle.id, paths: model.paths).prefix) {
            return data
        }
        return await fromStore(kind, for: game, model: model)
    }

    nonisolated private struct Decoded: @unchecked Sendable { let image: CGImage }

    /// Decodes the art now, at most `maxPixelSize` on its longest side, so drawing it costs nothing
    /// more and its memory is known.
    nonisolated private static func decode(_ data: Data, maxPixelSize: Int) -> Decoded? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map(Decoded.init)
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
