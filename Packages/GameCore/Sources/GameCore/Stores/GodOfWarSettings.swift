import Foundation

/// God of War (2018)'s `settings.ini`, which the game reads from its own folder (`.\settings.ini`).
enum GodOfWarSettings {
    static let appID = "1593500"
    /// Lowercased, as `DepthEqualFix` matches it.
    static let executable = "gow.exe"

    static func isGame(_ executable: URL) -> Bool { executable.lastPathComponent.lowercased() == Self.executable }

    static func settingsFile(installFolder: URL) -> URL { installFolder.appending(path: "settings.ini") }

    /// As tested on a 14" MacBook Pro (M4, 16 GB) with `DepthEqualFix` on DXMT, then on D3DMetal
    /// (2026-10-15): Ultra preset and textures, High occlusion, the rest Original, Borderless at the
    /// 1512×982 desktop, no upscaling, HDR off, Film Grain 0. No white specks on the characters. Written only before the
    /// game's first launch, so a player's own settings are never replaced.
    ///
    /// Left out so the game fills it in for each Mac: `VideoDevice`, the adapter's name.
    ///
    /// To update: copy `settings.ini` from the game folder in a bottle where the new settings were
    /// tested, and leave out the same line.
    static let testedSettings = """
        [Settings]
        Monitor=0
        DisplayMode=Borderless        ; Values: Windowed, Borderless
        WindowLeft=0
        WindowTop=0
        WindowWidth=1512
        WindowHeight=982
        AspectRatio=Auto
        Vsync=Off                     ; Values: Off, On
        MotionBlur=10                 ; Range: 0 - 10
        FilmGrain=0                   ; Range: 0 - 10
        DLSSQuality=Off               ; Values: Off, UltraPerformance, Performance, Balanced, Quality, UltraQuality
        FSRQuality=Off                ; Values: Off, Performance, Balanced, Quality, UltraQuality
        RenderScale=100               ; Values: Off, 50, 55, 60, 65, 70, 75, 80, 85, 90, 95, 100
        Brightness=50                 ; Range: 0 - 100
        HDR=Off                       ; Values: Off, On
        HDRBrightness=50              ; Range: 0 - 100
        HDRContrast=1.400             ; Range: 0.8 - 1.8
        LatencyMarkers=Off            ; Values: Off, On
        LatencyEnable=Off             ; Values: Off, On
        LatencyBoost=Off              ; Values: Off, On
        LatencyFlash=Off              ; Values: Off, On
        LatencyStats=On               ; Values: Off, On
        Preset=Ultra                  ; Values: Low, Original, High, Ultra, Custom
        TextureQuality=Ultra          ; Values: Min, Low, Original, High, Ultra
        FilterQuality=Original        ; Values: Min, Low, Original, High, Ultra
        ModelQuality=Original         ; Values: Original, High, Ultra
        ShadowQuality=Original        ; Values: Low, Original, High, Ultra
        AtmosphereQuality=Original    ; Values: Low, Original, High, Ultra
        ReflectionQuality=Original    ; Values: Disable, Original, High, Ultra, UltraPlus
        OcclusionQuality=High         ; Values: Disable, Original, High, Ultra, UltraPlus

        """

    static let note = "Wrote God of War's tested settings for its first launch (Ultra preset, HDR off, no film grain)."

    /// Writes `testedSettings` (with the game's Windows line endings) when the game has no settings
    /// yet. Returns whether it wrote them.
    @discardableResult
    static func apply(installFolder: URL) throws -> Bool {
        let file = settingsFile(installFolder: installFolder)
        guard !FileManager.default.fileExists(atPath: file.path) else { return false }
        try Data(testedSettings.replacingOccurrences(of: "\n", with: "\r\n").utf8).write(to: file)
        return true
    }
}
