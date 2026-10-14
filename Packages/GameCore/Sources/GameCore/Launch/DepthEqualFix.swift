import Foundation

/// God of War (2018) fills its G-buffer after a depth prepass, with an EQUAL depth test. On Metal the
/// two passes don't always compute bit-identical positions, so pixels fail the test and show as white
/// specks on Kratos and Atreus, under D3DMetal, DXMT, DXVK and WineD3D alike (macgamingdb reports).
/// `tools/depth-equal-fix` is a d3d11.dll that turns EQUAL into GREATER_EQUAL (the game uses reverse
/// Z) and hands everything else to DXMT. The launch puts it next to the game, with DXMT's d3d11.dll
/// beside it, and takes both away when the game runs on another backend.
public enum DepthEqualFix {
    /// Lowercased executable names of the games that need it. The shim is 64-bit, like these games.
    static let executables: Set<String> = [GodOfWarSettings.executable]
    static let module = "d3d11"
    static let shimName = "\(module).dll"
    /// DXMT's d3d11.dll, under the name the shim loads.
    static let dxmtName = "corkscrew_dxmt_d3d11.dll"
    /// In the shim's log lines; tells our d3d11.dll from one the game or a mod (ReShade) ships.
    static let marker = Data("Corkscrew depth-equal fix".utf8)

    public static func applies(to executable: URL) -> Bool {
        executables.contains(executable.lastPathComponent.lowercased())
    }

    /// False when the game folder holds a d3d11.dll of its own, which the shim would replace.
    static func canInstall(nextTo executable: URL) -> Bool {
        let shim = executable.deletingLastPathComponent().appending(path: shimName)
        return !FileManager.default.fileExists(atPath: shim.path) || isOurs(shim)
    }

    static func isOurs(_ file: URL) -> Bool {
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return false }
        return data.range(of: marker) != nil
    }

    /// Copies the shim and DXMT's 64-bit d3d11.dll next to the game, replacing older copies (a new
    /// app or DXMT version). True when a file was copied.
    @discardableResult
    static func install(shim: URL, dxmt: URL, nextTo executable: URL) throws -> Bool {
        let fm = FileManager.default
        let folder = executable.deletingLastPathComponent()
        var copied = false
        for (source, name) in [(shim, shimName), (dxmt.appending(path: "x86_64-windows/d3d11.dll"), dxmtName)] {
            let target = folder.appending(path: name)
            guard !fm.contentsEqual(atPath: source.path, andPath: target.path) else { continue }
            try? fm.removeItem(at: target)
            try fm.copyItem(at: source, to: target)
            copied = true
        }
        return copied
    }

    /// Takes the shim and DXMT's copy out of the game folder, so another backend gets the game's
    /// d3d11 calls. True when something was removed.
    @discardableResult
    static func remove(nextTo executable: URL) throws -> Bool {
        let fm = FileManager.default
        let folder = executable.deletingLastPathComponent()
        let dxmt = folder.appending(path: dxmtName)
        guard fm.fileExists(atPath: dxmt.path) else { return false }
        let shim = folder.appending(path: shimName)
        if fm.fileExists(atPath: shim.path), isOurs(shim) { try fm.removeItem(at: shim) }
        try fm.removeItem(at: dxmt)
        return true
    }
}
