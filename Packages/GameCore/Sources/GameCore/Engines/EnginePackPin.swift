// Written by scripts/package-engine.sh; don't edit by hand.

import Foundation

extension EnginePack {
    /// The engine pack this version of the app downloads on first launch.
    public static let current = EnginePack(
        version: "26.3.0-4",
        url: URL(string: "https://github.com/Prateek-Srivastav/corkscrew/releases/download/runtime-26.3.0-4/corkscrew-engine-26.3.0-4.tar.xz")!,
        sha256: "fae100d5af8b873a25fbf12dbe4dc605d267dcb29b0bc6ed3678a7a913d4b374",
        size: 319488144
    )
}
