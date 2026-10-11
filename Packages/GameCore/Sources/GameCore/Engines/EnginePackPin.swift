// Written by scripts/package-engine.sh; don't edit by hand.

import Foundation

extension EnginePack {
    /// The engine pack this version of the app downloads on first launch.
    public static let current = EnginePack(
        version: "26.3.0-3",
        url: URL(string: "https://github.com/Prateek-Srivastav/corkscrew/releases/download/runtime-26.3.0-3/corkscrew-engine-26.3.0-3.tar.xz")!,
        sha256: "c38898c00b0274befccbd58c83f789156c5ce05575c20b775dddce525a292318",
        size: 319368836
    )
}
