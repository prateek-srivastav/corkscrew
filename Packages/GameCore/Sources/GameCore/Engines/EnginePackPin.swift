// Written by scripts/package-engine.sh; don't edit by hand.

import Foundation

extension EnginePack {
    /// The engine pack this version of the app downloads on first launch.
    public static let current = EnginePack(
        version: "26.3.0-5",
        url: URL(string: "https://github.com/prateek-srivastav/corkscrew/releases/download/runtime-26.3.0-5/corkscrew-engine-26.3.0-5.tar.xz")!,
        sha256: "100e6e4ad3e2d4f495e905aaffa22570ece6a1ddc16abfa33985cc8212479d64",
        size: 319485640
    )
}
