import Foundation

/// Notices when Red Dead Redemption 2's graphics settings went down: the game rewrites `system.xml`
/// when it quits, with whatever its menu was left at, and resets it to Safe Mode's after a launch
/// that didn't shut down cleanly.
///
/// The settings are compared with the kept ones: the ones Corkscrew last put in place or the player
/// kept (`keptSettings`), or the tested ones (`rdr2TestedSettings`) before there are any. Only the
/// game's quality levels are compared (`<name>kSettingLevel_…</name>`), which it orders Low, Medium,
/// High, Ultra; switches and numbers say nothing of better or worse on their own.
extension RockstarLauncher {
    /// A quality level that's lower than in the kept settings.
    public struct SettingDrop: Equatable, Sendable {
        /// The game's name for it (`textureQuality`).
        public let name: String
        public let kept: String
        public let now: String

        /// "Texture quality: Ultra → High".
        public var text: String { "\(Self.label(name)): \(kept) → \(now)" }

        /// `textureQuality` → "Texture quality", `POMQuality` → "POM quality", `ssao` → "SSAO".
        static func label(_ name: String) -> String {
            // A short name alone is an abbreviation.
            if name.count <= 4, name == name.lowercased() { return name.uppercased() }
            // Acronyms stay whole ("POM"), other words start at a capital.
            let words = name.matches(of: /[A-Z]{2,}(?![a-z])|[A-Z]?[a-z]+|\d+/).map { word in
                word.output.count > 1 && word.output.allSatisfy(\.isUppercase) ? String(word.output) : word.output.lowercased()
            }
            let joined = words.joined(separator: " ")
            return joined.prefix(1).uppercased() + joined.dropFirst()
        }
    }

    static let levelPrefix = "kSettingLevel_"
    static let levels = ["Low", "Medium", "High", "Ultra"]

    /// Where the kept settings are: in the bottle's folder, next to `prefix`.
    static func keptSettings(prefix: URL) -> URL {
        prefix.deletingLastPathComponent().appending(path: "rdr2-kept-settings.xml")
    }

    /// The quality levels, in the file's order: `("textureQuality", "Ultra")`.
    static func levelSettings(in text: String) -> [(name: String, level: String)] {
        text.matches(of: /<(\w+)>kSettingLevel_(\w+)<\//).map { (String($0.output.1), String($0.output.2)) }
    }

    /// The levels in `now` that are lower than in `kept`. Settings missing from either, or at a level
    /// the game added since, aren't compared.
    static func drops(from kept: String, to now: String) -> [SettingDrop] {
        let keptLevels = Dictionary(levelSettings(in: kept).map { ($0.name, $0.level) }, uniquingKeysWith: { first, _ in first })
        return levelSettings(in: now).compactMap { setting in
            guard let keptLevel = keptLevels[setting.name],
                  let keptRank = levels.firstIndex(of: keptLevel),
                  let rank = levels.firstIndex(of: setting.level), rank < keptRank else { return nil }
            return SettingDrop(name: setting.name, kept: keptLevel, now: setting.level)
        }
    }

    /// The levels that went down since the kept settings. Run while the game isn't running: it
    /// writes its settings when it quits.
    public static func settingDrops(prefix: URL) -> [SettingDrop] {
        guard let (now, kept) = currentAndKeptSettings(prefix: prefix) else { return [] }
        return drops(from: kept, to: now)
    }

    /// When the player raised levels and lowered none, makes the game's settings the kept ones, so
    /// later drops are measured from them. Returns whether it did.
    @discardableResult
    public static func keepRaisedSettings(prefix: URL) throws -> Bool {
        guard let (now, kept) = currentAndKeptSettings(prefix: prefix), drops(from: kept, to: now).isEmpty,
              levelSettings(in: now).map(\.level) != levelSettings(in: kept).map(\.level) else { return false }
        try now.write(to: keptSettings(prefix: prefix), atomically: true, encoding: .utf8)
        return true
    }

    /// The game's settings, and the kept ones (the tested ones before any are kept). Nil before the
    /// game first wrote its settings.
    private static func currentAndKeptSettings(prefix: URL) -> (now: String, kept: String)? {
        guard let now = try? String(contentsOf: rdr2Settings(prefix: prefix), encoding: .utf8) else { return nil }
        return (now, (try? String(contentsOf: keptSettings(prefix: prefix), encoding: .utf8)) ?? rdr2TestedSettings)
    }

    /// Settings a restore doesn't decide: sized to each Mac's desktop (`fitWindow`), or the file's own.
    static let notTested: Set<String> = ["version", "configSource", "screenWidth", "screenHeight", "screenWidthWindowed",
                                         "screenHeightWindowed", "resolutionIndex", "resolutionIndexWindowed"]

    /// Every setting in `text` by name: `<name value="…" />` and `<name>…</name>`.
    static func allSettings(in text: String) -> [String: String] {
        let values = text.matches(of: /<(\w+) value="([^"]*)" \/>/).map { (String($0.output.1), String($0.output.2)) }
        let texts = text.matches(of: /<(\w+)>([^<\r\n]*)<\/(\w+)>/).filter { $0.output.1 == $0.output.3 }
            .map { (String($0.output.1), String($0.output.2)) }
        return Dictionary(values + texts, uniquingKeysWith: { first, _ in first })
    }

    /// Whether the game's settings are the tested ones, so a restore would change nothing. Lines
    /// about the Mac aren't in the tested settings, so they aren't compared either.
    public static func hasTestedSettings(prefix: URL) -> Bool {
        guard let now = try? String(contentsOf: rdr2Settings(prefix: prefix), encoding: .utf8) else { return false }
        return isTested(now)
    }

    static func isTested(_ text: String) -> Bool {
        let now = allSettings(in: text)
        return allSettings(in: rdr2TestedSettings).allSatisfy { notTested.contains($0.key) || now[$0.key] == $0.value }
    }

    /// Makes the game's settings the kept ones, for lower settings the player chose.
    public static func keepSettings(prefix: URL) throws {
        let now = try String(contentsOf: rdr2Settings(prefix: prefix), encoding: .utf8)
        try now.write(to: keptSettings(prefix: prefix), atomically: true, encoding: .utf8)
    }

    /// Puts back the kept settings, keeping the replaced ones as `system.xml.bak`. Before there are
    /// kept ones, the tested ones at `desktop`'s size (`restoreTestedSettings`).
    public static func restoreKeptSettings(prefix: URL, desktop: (width: Int, height: Int)?) throws {
        guard let kept = try? String(contentsOf: keptSettings(prefix: prefix), encoding: .utf8) else {
            return try restoreTestedSettings(prefix: prefix, desktop: desktop)
        }
        try replaceSettings(prefix: prefix, with: kept)
    }

    /// Writes `text` as the game's settings, keeping the ones it replaces as `system.xml.bak`, and
    /// their lines about this Mac (`withMachineLines`).
    static func replaceSettings(prefix: URL, with text: String) throws {
        let file = rdr2Settings(prefix: prefix)
        let fm = FileManager.default
        var text = text
        if fm.fileExists(atPath: file.path) {
            if let old = try? String(contentsOf: file, encoding: .utf8) { text = withMachineLines(of: old, in: text) }
            let backup = file.appendingPathExtension("bak")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: file, to: backup)
        } else {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    /// What the game writes about the Mac it runs on, which the tested settings leave out: the
    /// display's refresh rate and the GPU's name (D3DMetal's "AMD Compatibility Mode"). Settings
    /// without the GPU's name are, to the game, a new GPU's: it replaces them with its defaults for
    /// one, 1280×720 at the lowest preset without DLSS. That happened after each restore from
    /// 2026-10-29 to 31, while settings with the name kept their quality.
    static let refreshRateNames = ["refreshRateIndex", "refreshRateNumerator", "refreshRateDenominator"]
    static let gpuName = "videoCardDescription"

    /// `text` with the lines about this Mac from `old` that it lacks: the refresh rate before
    /// `<windowed …/>` and the GPU's name after `</video>`, where the game writes them.
    static func withMachineLines(of old: String, in text: String) -> String {
        // A line without its break: the game ends lines with \r\n, which Swift takes as one
        // character, so a pattern ending in \n doesn't match there.
        func line(containing pattern: String, in text: String) -> Range<String.Index>? {
            text.range(of: #"[ \t]*"# + pattern + #"[^\r\n]*"#, options: .regularExpression)
        }
        func indent(of range: Range<String.Index>, in text: String) -> String {
            String(text[range].prefix(while: { $0 == " " || $0 == "\t" }))
        }
        var text = text
        let refresh = refreshRateNames.filter { settingValue($0, in: text) == nil }
            .compactMap { name in line(containing: "<\(name) value=", in: old).map { old[$0].trimmingCharacters(in: .whitespaces) } }
        if !refresh.isEmpty, let windowed = line(containing: "<windowed value=", in: text) {
            let pad = indent(of: windowed, in: text)
            text.insert(contentsOf: refresh.map { pad + $0 + "\n" }.joined(), at: windowed.lowerBound)
        }
        if !text.contains("<\(gpuName)>"), let name = line(containing: "<\(gpuName)>", in: old).map({ old[$0].trimmingCharacters(in: .whitespaces) }),
           let video = line(containing: "</video>", in: text) {
            text.insert(contentsOf: "\n" + indent(of: video, in: text) + name, at: video.upperBound)
        }
        return text
    }
}
