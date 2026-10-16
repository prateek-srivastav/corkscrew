import Foundation

/// God of War (2018) fills its G-buffer after a depth prepass, with an EQUAL depth test. On Metal the
/// two passes don't always compute bit-identical positions, so pixels fail the test and show as white
/// specks on Kratos and Atreus, under D3DMetal, DXMT, DXVK and WineD3D alike (macgamingdb reports).
/// `tools/depth-equal-fix` is a d3d11.dll that turns EQUAL into GREATER_EQUAL (the game uses reverse
/// Z) and hands everything else to the backend's d3d11 (DXMT or D3DMetal). The launch puts it next to
/// the game, with the backend's d3d11.dll beside it, and takes both away on other backends.
public enum DepthEqualFix {
    /// Lowercased executable names of the games that need it. The shim is 64-bit, like these games.
    static let executables: Set<String> = [GodOfWarSettings.executable]
    static let module = "d3d11"
    static let shimName = "\(module).dll"
    /// Backends the shim can wrap, best first: Auto's pick. Both ship d3d11.dll as a Wine builtin,
    /// which Wine maps from WINEDLLPATH in place of the copy next to the game. D3DMetal is faster, and
    /// on DXMT God of War's brightness pumps dark and bright on its own (2026-10-15).
    static let preferredBackends: [GraphicsBackend] = [.d3dmetal, .dxmt]
    /// The backend's d3d11.dll, under the name the shim loads.
    static let backendName = "corkscrew_d3d11.dll"
    /// The name before D3DMetal support; removed when found.
    static let oldBackendNames = ["corkscrew_dxmt_d3d11.dll"]
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

    /// Copies the shim and the backend's 64-bit d3d11.dll (`backend`: its WINEDLLPATH folder) next to
    /// the game, replacing older copies (a new app, backend version or backend). True when a file was
    /// copied.
    @discardableResult
    static func install(shim: URL, backend: URL, nextTo executable: URL) throws -> Bool {
        let fm = FileManager.default
        let folder = executable.deletingLastPathComponent()
        var copied = false
        for name in oldBackendNames where fm.fileExists(atPath: folder.appending(path: name).path) {
            try fm.removeItem(at: folder.appending(path: name))
            copied = true
        }
        for (source, name) in [(shim, shimName), (backend.appending(path: "x86_64-windows/d3d11.dll"), backendName)] {
            let target = folder.appending(path: name)
            guard !fm.contentsEqual(atPath: source.path, andPath: target.path) else { continue }
            try? fm.removeItem(at: target)
            try fm.copyItem(at: source, to: target)
            copied = true
        }
        return copied
    }

    /// Takes the shim and the backend's copy out of the game folder, so another backend gets the
    /// game's d3d11 calls. True when something was removed.
    @discardableResult
    static func remove(nextTo executable: URL) throws -> Bool {
        let fm = FileManager.default
        let folder = executable.deletingLastPathComponent()
        let copies = ([backendName] + oldBackendNames).map { folder.appending(path: $0) }
            .filter { fm.fileExists(atPath: $0.path) }
        guard !copies.isEmpty else { return false }
        let shim = folder.appending(path: shimName)
        if fm.fileExists(atPath: shim.path), isOurs(shim) { try fm.removeItem(at: shim) }
        for copy in copies { try fm.removeItem(at: copy) }
        return true
    }
}
