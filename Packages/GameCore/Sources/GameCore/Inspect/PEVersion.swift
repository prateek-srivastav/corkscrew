import Foundation

extension PEFile {
    /// The program's description in its version resource (`FileDescription`), the name Windows'
    /// Task Manager shows for it: "Rockstar Games Launcher" for `Launcher.exe`. Nil when it has none.
    public static func fileDescription(contentsOf url: URL) throws -> String? {
        try fileDescription(in: Data(contentsOf: url, options: .alwaysMapped))
    }

    static func fileDescription(in data: Data) throws -> String? {
        let image = try Headers(data: data).image
        guard let directory = image.directory(2), let root = image.fileOffset(ofRVA: directory.rva) else { return nil }
        let resources = ResourceTree(image: image, base: root)
        guard let versions = resources.subdirectory(in: root, id: ResourceTree.version),
              let entry = resources.entries(in: versions).first,
              let block = resources.firstData(of: entry) else { return nil }
        let r = image.reader
        let info = r.data.subdata(in: r.range(block.offset, block.count))
        // A String entry: length, value length (in UTF-16 units, with the 0), type, the key, then
        // the value at the next 32-bit boundary from the block's start.
        let key = Data("FileDescription\0".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
        guard let found = info.range(of: key), found.lowerBound >= 6 else { return nil }
        let length = Int(info[found.lowerBound - 4]) | Int(info[found.lowerBound - 3]) << 8
        var index = (found.upperBound + 3) / 4 * 4
        var units: [UInt16] = []
        while units.count < min(length, 256), index + 1 < info.count {
            let unit = UInt16(info[index]) | UInt16(info[index + 1]) << 8
            if unit == 0 { break }
            units.append(unit)
            index += 2
        }
        let text = String(decoding: units, as: UTF16.self).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }
}
