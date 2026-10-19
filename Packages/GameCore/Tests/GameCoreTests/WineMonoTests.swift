import Foundation
import Testing
@testable import GameCore

struct WineMonoTests {
    @Test func linksTheRuntimesMonoAndKeepsARealInstall() throws {
        try withTempDir { root in
            let fm = FileManager.default
            let prefix = root.appending(path: "prefix")
            let (old, runtime) = (root.appending(path: "old-runtime"), root.appending(path: "runtime"))
            let link = prefix.appending(path: "drive_c/windows/mono/mono-2.0").path

            // Nothing before wineboot made the prefix, nor for a runtime without Wine Mono.
            try old.appending(path: "share/wine/mono/wine-mono-10.4.1/bin").makeDirectory()
            try WineMono.link(prefix: prefix, runtime: old)
            #expect(!fm.fileExists(atPath: prefix.path))
            try prefix.appending(path: "drive_c/windows").makeDirectory()
            try WineMono.link(prefix: prefix, runtime: runtime)
            #expect(!fm.fileExists(atPath: prefix.appending(path: "drive_c/windows/mono").path))

            try runtime.appending(path: "share/wine/mono/wine-mono-10.4.1/bin").makeDirectory()
            try WineMono.link(prefix: prefix, runtime: old)
            try WineMono.link(prefix: prefix, runtime: runtime)
            #expect(try fm.destinationOfSymbolicLink(atPath: link) == WineMono.folder(in: runtime)?.path)
            try WineMono.link(prefix: prefix, runtime: runtime)
            #expect(try fm.destinationOfSymbolicLink(atPath: link) == WineMono.folder(in: runtime)?.path)

            // Mono installed from its own installer.
            try fm.removeItem(atPath: link)
            try URL(fileURLWithPath: link).appending(path: "bin/libmono-2.0-x86_64.dll").write("MZ")
            try WineMono.link(prefix: prefix, runtime: runtime)
            #expect((try? fm.destinationOfSymbolicLink(atPath: link)) == nil)
            #expect(fm.fileExists(atPath: URL(fileURLWithPath: link).appending(path: "bin/libmono-2.0-x86_64.dll").path))
        }
    }
}
