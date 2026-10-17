import SwiftUI

/// A launch log, following new output while the launch runs.
struct LogView: View {
    let file: URL
    let isLive: Bool
    @State private var text = ""
    @State private var tail: Tail?
    @Environment(\.controlActiveState) private var activeState

    /// Logs can grow large (verbose Wine output); only the end is shown.
    private static let tailBytes = 256 * 1024

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                Text(text.isEmpty ? " " : text)
                    .font(.system(.subheadline, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                Color.clear.frame(height: 1).id("end")
            }
            .background(.background.secondary, in: .rect(cornerRadius: Theme.cornerRadius))
            .swipesScrollFirst()
            // Not while the game (or any other app) is in front: the log catches up after.
            .task(id: "\(file.path) \(isLive) \(activeState == .inactive)") {
                if tail?.file != file {
                    tail = Tail(file: file, limit: Self.tailBytes)
                    text = ""
                }
                repeat {
                    if let latest = tail?.read() {
                        text = latest
                        proxy.scrollTo("end", anchor: .bottom)
                    }
                    guard isLive, activeState != .inactive else { break }
                    try? await Task.sleep(for: .seconds(1))
                } while !Task.isCancelled
            }
        }
    }

    /// The end of a growing file. Each read takes only the bytes written since the last one, so a
    /// running game's log costs nothing while it's quiet.
    struct Tail {
        let file: URL
        let limit: Int
        private var offset: UInt64 = 0
        private var shown = Data()
        private var cut = false

        init(file: URL, limit: Int) {
            self.file = file
            self.limit = limit
        }

        /// The text to show, or nil when nothing changed.
        mutating func read() -> String? {
            guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            if size < offset { (offset, shown, cut) = (0, Data(), false) }   // the file started over
            guard size > offset else { return nil }
            let start = max(offset, size > UInt64(limit) ? size - UInt64(limit) : 0)
            if start > offset { (shown, cut) = (Data(), true) }
            try? handle.seek(toOffset: start)
            shown.append((try? handle.readToEnd()) ?? Data())
            offset = size
            // Trims a quarter at a time, at a line start, so it doesn't trim on every read.
            if shown.count > limit + limit / 4 {
                let from = shown.index(shown.endIndex, offsetBy: -limit)
                shown = Data(shown[(shown[from...].firstIndex(of: UInt8(ascii: "\n")).map { $0 + 1 } ?? from)...])
                cut = true
            }
            let content = String(decoding: shown, as: UTF8.self)
            return cut ? "… (earlier output not shown)\n" + content : content
        }
    }
}
