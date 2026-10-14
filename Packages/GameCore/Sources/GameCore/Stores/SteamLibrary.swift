import Foundation

/// The Steam account signed in inside a bottle and the games in its library, read from Steam's own
/// files: nothing is asked of Valve's servers.
extension Steam {
    public struct Account: Equatable, Sendable {
        public var steamID: String
        public var accountName: String
        public var personaName: String
        /// Steam signs in by itself next time ("Remember me").
        public var remembersSignIn: Bool
    }

    /// The account Steam last signed in with, from `config/loginusers.vdf`; nil after signing out.
    public static func account(steamRoot: URL) -> Account? {
        guard let text = try? String(contentsOf: steamRoot.appending(path: "config/loginusers.vdf"), encoding: .utf8) else { return nil }
        let users = KeyValues.parse(text).block("users")?.blocks ?? []
        guard let (steamID, user) = users.first(where: { $0.value.value("MostRecent") == "1" }) ?? (users.count == 1 ? users.first : nil)
        else { return nil }
        return Account(steamID: steamID, accountName: user.value("AccountName") ?? "", personaName: user.value("PersonaName") ?? "",
                       remembersSignIn: user.value("RememberPassword") == "1" && user.value("AllowAutoLogin") != "0")
    }

    /// A game in the account's library, installed or not.
    public struct LibraryGame: Equatable, Sendable {
        public var appID: String
        public var name: String
    }

    /// The games in the library, by name. Steam keeps art for every app in the library under
    /// `appcache/librarycache` (a folder per app, or `<id>_<art>` files in older versions), and
    /// `appcache/appinfo.vdf` says which apps are games, leaving out tools, servers and soundtracks.
    public static func libraryGames(steamRoot: URL) -> [LibraryGame] {
        let cache = steamRoot.appending(path: "appcache/librarycache", directoryHint: .isDirectory)
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? []
        let ids = Set(entries.compactMap { entry -> UInt32? in UInt32(entry.prefix { $0.isNumber }) })
        guard !ids.isEmpty,
              let data = try? Data(contentsOf: steamRoot.appending(path: "appcache/appinfo.vdf"), options: .mappedIfSafe),
              let apps = try? SteamAppInfo.read(data, appIDs: ids)
        else { return [] }
        return apps.compactMap { id, common in
            guard common.value("type")?.lowercased() == "game" else { return nil }
            return LibraryGame(appID: String(id), name: common.value("name") ?? "App \(id)")
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// A library entry that starts the game through Steam (`-silent -applaunch`) with its tested
    /// settings, or `profile` when it has none.
    public static func entry(appID: String, name: String, bottleID: UUID, steamRoot: URL,
                             profile: GameProfile = GameProfile(), program: URL? = nil) -> Game {
        var profile = testedProfiles[appID] ?? profile
        profile.arguments = clientArguments + [silentArgument, "-applaunch", appID]
        return Game(name: name, executable: steamRoot.appending(path: "steam.exe"), bottleID: bottleID, profile: profile,
                    store: StoreItem(store: store, appID: appID), iconSource: program)
    }
}

/// Valve's KeyValues text format: quoted keys, each with a quoted value or a `{ … }` block.
struct KeyValues {
    var values: [(key: String, value: String)] = []
    var blocks: [(key: String, value: KeyValues)] = []

    /// Keys match without regard to case, as Steam reads them.
    func value(_ key: String) -> String? { values.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value }
    func block(_ key: String) -> KeyValues? { blocks.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value }

    static func parse(_ text: String) -> KeyValues {
        var tokens = Tokens(text: Array(text.unicodeScalars))
        return parseBlock(&tokens)
    }

    private static func parseBlock(_ tokens: inout Tokens) -> KeyValues {
        var result = KeyValues()
        while let key = tokens.next() {
            if key == .close { break }
            guard case .string(let name) = key, let next = tokens.next() else { break }
            switch next {
            case .open: result.blocks.append((name, parseBlock(&tokens)))
            case .string(let value): result.values.append((name, value))
            case .close: return result
            }
        }
        return result
    }

    private enum Token: Equatable {
        case string(String)
        case open
        case close
    }

    private struct Tokens {
        let text: [Unicode.Scalar]
        var index = 0

        mutating func next() -> Token? {
            while index < text.count {
                let c = text[index]
                if c.properties.isWhitespace {
                    index += 1
                } else if c == "/", index + 1 < text.count, text[index + 1] == "/" {
                    while index < text.count, text[index] != "\n" { index += 1 }
                } else {
                    break
                }
            }
            guard index < text.count else { return nil }
            let c = text[index]
            index += 1
            switch c {
            case "{": return .open
            case "}": return .close
            case "\"":
                var value = String.UnicodeScalarView()
                while index < text.count, text[index] != "\"" {
                    if text[index] == "\\", index + 1 < text.count {
                        index += 1
                        switch text[index] {
                        case "n": value.append("\n")
                        case "t": value.append("\t")
                        default: value.append(text[index])
                        }
                    } else {
                        value.append(text[index])
                    }
                    index += 1
                }
                index += 1
                return .string(String(value))
            default:
                var value = String.UnicodeScalarView([c])
                while index < text.count, !text[index].properties.isWhitespace, !["{", "}", "\""].contains(text[index]) {
                    value.append(text[index])
                    index += 1
                }
                return .string(String(value))
            }
        }
    }
}

/// Steam's `appcache/appinfo.vdf`: binary KeyValues for every app the client knows. Versions 27
/// and 28 spell out keys; 29 keeps them in a string table at the end of the file.
enum SteamAppInfo {
    struct FormatError: Error, CustomStringConvertible {
        let description: String
    }

    /// The `appinfo/common` values (name, type, …) of the apps in `appIDs` that the file has.
    static func read(_ data: Data, appIDs: Set<UInt32>) throws -> [UInt32: KeyValues] {
        var reader = Reader(data: data)
        let magic = try reader.uint32()
        guard [0x0756_4427, 0x0756_4428, 0x0756_4429].contains(magic) else {
            throw FormatError(description: "appinfo.vdf has an unknown format (\(String(magic, radix: 16)))")
        }
        _ = try reader.uint32() // universe
        var strings: [String]?
        if magic == 0x0756_4429 {
            var table = Reader(data: data, offset: Int(try reader.int64()))
            strings = try (0..<table.uint32()).map { _ in try table.cString() }
        }
        var apps: [UInt32: KeyValues] = [:]
        while reader.offset < data.count {
            let appID = try reader.uint32()
            if appID == 0 { break }
            let size = Int(try reader.uint32())
            let end = reader.offset + size
            if appIDs.contains(appID) {
                // Info state, last updated, PICS token, SHA-1, change number, then (28 and later) the
                // binary data's SHA-1.
                reader.offset += 4 + 4 + 8 + 20 + 4 + (magic >= 0x0756_4428 ? 20 : 0)
                let info = try parseBinary(&reader, strings: strings)
                apps[appID] = info.block("appinfo")?.block("common") ?? KeyValues()
            }
            reader.offset = end
        }
        return apps
    }

    private static func parseBinary(_ reader: inout Reader, strings: [String]?) throws -> KeyValues {
        var result = KeyValues()
        while true {
            let type = try reader.uint8()
            if type == 8 || type == 11 { return result }
            let key: String
            if let strings {
                let index = Int(try reader.uint32())
                guard index < strings.count else { throw FormatError(description: "appinfo.vdf names a missing key") }
                key = strings[index]
            } else {
                key = try reader.cString()
            }
            switch type {
            case 0: result.blocks.append((key, try parseBinary(&reader, strings: strings)))
            case 1: result.values.append((key, try reader.cString()))
            case 2: result.values.append((key, String(Int32(bitPattern: try reader.uint32()))))
            case 3, 4, 6: reader.offset += 4
            case 7, 10: reader.offset += 8
            default: throw FormatError(description: "appinfo.vdf has an unknown value type \(type)")
            }
        }
    }

    private struct Reader {
        let data: Data
        var offset = 0

        private mutating func bytes(_ count: Int) throws -> Data {
            guard offset >= 0, offset + count <= data.count else { throw FormatError(description: "appinfo.vdf ends early") }
            defer { offset += count }
            let start = data.startIndex + offset
            return data[start..<start + count]
        }

        mutating func uint8() throws -> UInt8 { try bytes(1).first! }

        mutating func uint32() throws -> UInt32 {
            try bytes(4).reversed().reduce(0) { $0 << 8 | UInt32($1) }
        }

        mutating func int64() throws -> Int64 {
            Int64(bitPattern: try bytes(8).reversed().reduce(0) { $0 << 8 | UInt64($1) })
        }

        mutating func cString() throws -> String {
            let start = data.startIndex + offset
            guard let end = data[start...].firstIndex(of: 0) else { throw FormatError(description: "appinfo.vdf ends early") }
            offset += end - start + 1
            return String(decoding: data[start..<end], as: UTF8.self)
        }
    }
}
