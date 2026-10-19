import Foundation

/// Whether Wine fakes display mode changes: `HKCU\Software\Wine\X11 Driver\EmulateModeset`, which
/// win32u reads for every driver despite the name.
///
/// Direct3D's exclusive full screen can ask for the back buffer's size (often 1920×1080), which a
/// Mac rarely has in points with Retina mode off. D3DMetal sizes the window to it anyway, so the game
/// shows zoomed in and cropped. With emulation the display stays as it is and Wine scales the window
/// to fit. Stock win32u offers no emulated mode larger than the desktop; ours goes up to the panel's
/// pixel size (scripts/build-runtime.sh), so Retina-off bottles get emulation only with our runtime.
/// With Retina mode on, emulation draws the frame 66 points too low, so it stays off there.
enum ModeEmulation {
    static let key = #"Software\Wine\X11 Driver"#
    static let name = "EmulateModeset"
    /// A message in our win32u patch; older runtimes don't have it.
    static let marker = "Corkscrew: emulated modes"

    /// The bottle's saved setting; a missing value means off.
    static func isEnabled(prefix: URL) -> Bool {
        WineRegistry.isTrue(WineRegistry.value(name, inKey: key, file: prefix.appending(path: "user.reg")))
    }

    /// The `wine` arguments that store the setting.
    static func command(enabled: Bool) -> [String] {
        ["reg", "add", "HKCU\\" + key, "/v", name, "/t", "REG_SZ", "/d", enabled ? "y" : "n", "/f"]
    }

    /// Whether this runtime's win32u offers emulated modes larger than the desktop.
    static func isAvailable(in engine: Engine) -> Bool {
        let win32u = engine.root.appending(path: "lib/wine/x86_64-unix/win32u.so")
        guard let binary = try? Data(contentsOf: win32u, options: .alwaysMapped) else { return false }
        return binary.range(of: Data(marker.utf8)) != nil
    }

    /// The setting a bottle with this Retina mode should have; nil leaves it as it is.
    static func wanted(retinaMode: Bool, engine: Engine) -> Bool? {
        if retinaMode { return false }
        return isAvailable(in: engine) ? true : nil
    }
}
