// Written by scripts/package-engine.sh; don't edit by hand.

import Foundation

extension EnginePack {
    /// The engine pack this version of the app downloads on first launch.
    public static let current = EnginePack(
        version: "26.3.0-7",
        url: URL(string: "https://github.com/prateek-srivastav/corkscrew/releases/download/runtime-26.3.0-7/corkscrew-engine-26.3.0-7.tar.xz")!,
        sha256: "6f87c1ccd6b68e39966a7fca9f0c7ab22dd8a60ec3fc2dc69ed4727ae49eeb7d",
        size: 174103624
    )
}
