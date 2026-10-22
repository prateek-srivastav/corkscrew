// Written by scripts/package-engine.sh; don't edit by hand.

import Foundation

extension EnginePack {
    /// The engine pack this version of the app downloads on first launch.
    public static let current = EnginePack(
        version: "26.3.0-8",
        url: URL(string: "https://github.com/prateek-srivastav/corkscrew/releases/download/runtime-26.3.0-8/corkscrew-engine-26.3.0-8.tar.xz")!,
        sha256: "b7558a2b928f05464c6fb9caef6bccca2bf4b94adf922c13aba26419f0b9ff89",
        size: 174150148
    )
}
