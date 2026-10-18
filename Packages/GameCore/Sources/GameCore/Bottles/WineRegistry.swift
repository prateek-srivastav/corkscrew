import Foundation

/// Read-only access to a prefix's registry files (`user.reg`, `system.reg`).
///
/// The files are what wineserver last saved, which can lag its in-memory registry by a few seconds
/// while the bottle runs. Writes always go through `wine reg`, never through these files.
public enum WineRegistry {
    /// The raw data of value `name` under `key` (e.g. `Software\Wine\Mac Driver`): the text between
    /// the quotes for strings, `dword:0000001` and the like for everything else. Names and keys
    /// compare case-insensitively, as in Windows.
    public static func value(_ name: String, inKey key: String, file: URL) -> String? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return value(name, inKey: key, text: text)
    }

    static func value(_ name: String, inKey key: String, text: String) -> String? {
        // Section headers escape backslashes: [Software\\Wine\\Mac Driver] 1791375602
        let header = "[" + key.replacingOccurrences(of: #"\"#, with: #"\\"#).lowercased() + "]"
        let wanted = "\"" + name.lowercased() + "\"="
        var inKey = false
        for line in text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("[") {
                inKey = line.lowercased().hasPrefix(header)
            } else if inKey, line.lowercased().hasPrefix(wanted) {
                let data = line.dropFirst(wanted.count)
                return data.hasPrefix("\"") && data.hasSuffix("\"") && data.count >= 2
                    ? String(data.dropFirst().dropLast()) : String(data)
            }
        }
        return nil
    }

    /// The keys directly under `key`, by name, with their string values: names lowercased, data
    /// unescaped (`C:\\Games` → `C:\Games`). Other values (dwords, binary) are left out.
    static func subkeys(of key: String, text: String) -> [String: [String: String]] {
        let parent = key.lowercased() + #"\"#
        var found: [String: [String: String]] = [:]
        var current: String?
        for line in text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("["), let end = line.lastIndex(of: "]") {
                let name = unescaped(line[line.index(after: line.startIndex)..<end])
                current = name.lowercased().hasPrefix(parent) && !name.dropFirst(parent.count).contains(#"\"#)
                    ? String(name.dropFirst(parent.count)) : nil
                if let current { found[current] = [:] }
            } else if let current, line.hasPrefix("\""), let split = line.range(of: "\"=\""), line.hasSuffix("\"") {
                let name = unescaped(line[line.index(after: line.startIndex)..<split.lowerBound])
                found[current]?[name.lowercased()] = unescaped(line[split.upperBound..<line.index(before: line.endIndex)])
            }
        }
        return found
    }

    /// Undoes the escapes Wine writes in `.reg` files: `\\`, `\"`, `\n`, `\t` and `\xNNNN`.
    static func unescaped(_ text: Substring) -> String {
        var result = ""
        var rest = text[...]
        while let backslash = rest.firstIndex(of: "\\") {
            result += rest[..<backslash]
            rest = rest[rest.index(after: backslash)...]
            guard let next = rest.first else { return result + "\\" }
            rest = rest.dropFirst()
            switch next {
            case "n": result += "\n"
            case "t": result += "\t"
            case "x":
                let hex = rest.prefix(4).prefix { $0.isHexDigit }
                if let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) {
                    result.unicodeScalars.append(scalar)
                    rest = rest.dropFirst(hex.count)
                } else {
                    result += "x"
                }
            default: result.append(next)
            }
        }
        return result + rest
    }

    /// Wine's own reading of an on/off string option (`IS_OPTION_TRUE` in winemac.drv).
    static func isTrue(_ data: String?) -> Bool {
        guard let first = data?.first else { return false }
        return "yYtT1".contains(first)
    }
}
