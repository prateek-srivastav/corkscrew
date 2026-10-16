import AppKit
import GameCore
import SwiftUI
import UniformTypeIdentifiers

@main
struct CorkscrewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared
    @State private var navigator = Navigator()
    @AppStorage(Theme.advancedModeKey) private var advancedMode = false
    @AppStorage(Theme.sidebarCollapsedKey) private var isSidebarCollapsed = false

    var body: some Scene {
        Window("Corkscrew", id: "main") {
            ContentView()
                .environment(model)
                .environment(navigator)
                .frame(minWidth: 1080, minHeight: 620)
        }
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .defaultSize(width: 1340, height: 820)
        .commands {
            CommandGroup(before: .sidebar) {
                Button(isSidebarCollapsed ? "Expand Sidebar" : "Collapse Sidebar") { isSidebarCollapsed.toggle() }
                    .keyboardShortcut("s", modifiers: [.control, .command])
                Divider()
                Button("Back") { navigator.back() }
                    .keyboardShortcut("[")
                    .disabled(!navigator.canGoBack)
                Button("Forward") { navigator.forward() }
                    .keyboardShortcut("]")
                    .disabled(!navigator.canGoForward)
                Divider()
            }
            CommandGroup(after: .toolbar) {
                Toggle("Advanced Mode", isOn: $advancedMode)
                    .keyboardShortcut("a", modifiers: [.command, .option])
            }
            CommandGroup(replacing: .appInfo) {
                Button("About Corkscrew") { AboutPanel.show() }
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { navigator.go(.setup) }
                    .keyboardShortcut(",")
            }
            CommandGroup(after: .newItem) {
                Button("Add Program…") { model.open(Pickers.programs()) }
                    .keyboardShortcut("o")
            }
        }
    }
}

/// Finder's Open With and double-clicks arrive here, also when they launch the app.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        AppModel.shared.open(urls)
        NSApp.activate()
    }

    /// Games keep running when the window closes; quitting the app doesn't stop them either.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // macOS takes a second or two to set a file panel up, during which the app can't respond:
        // do it while the app opens rather than on the first Add Program click.
        Pickers.prepare()
        #if DEBUG
        WindowSnapshots.startIfRequested()
        // Development aid: `-DebugSetUp YES` starts the one-click setup, to test it without clicking.
        if UserDefaults.standard.bool(forKey: "DebugSetUp") { AppModel.shared.setUp() }
        #endif
    }
}

#if DEBUG
/// Development aid: with `-DebugSnapshotPath <file.png>` the app saves its main window there every
/// two seconds, so the UI can be checked without Screen Recording permission.
enum WindowSnapshots {
    static func startIfRequested() {
        guard let path = UserDefaults.standard.string(forKey: "DebugSnapshotPath") else { return }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let window = NSApp.windows.first(where: { $0.isVisible && $0.level == .normal }),
                      let view = window.contentView?.superview ?? window.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                // Sheets are separate windows; save the front one next to it.
                if let sheet = window.attachedSheet, let content = sheet.contentView,
                   let sheetRep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                    content.cacheDisplay(in: content.bounds, to: sheetRep)
                    try? sheetRep.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: (path as NSString).deletingPathExtension + "-sheet.png"))
                }
            }
        }
    }
}
#endif

/// The About panel, with the license notice the GPL asks an interactive program to show.
enum AboutPanel {
    static let source = URL(string: "https://github.com/Prateek-Srivastav/corkscrew")!

    static func show() {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.labelColor, .paragraphStyle: style,
        ]
        let credits = NSMutableAttributedString(string: """
            Runs Windows games on Apple Silicon Macs.

            Corkscrew is free software under the GNU General Public License, version 3 or later, \
            and comes with no warranty. Source code:

            """, attributes: body)
        var link = body
        link[.link] = source
        credits.append(NSAttributedString(string: source.absoluteString, attributes: link))
        credits.append(NSAttributedString(string: """


            Uses Wine, DXMT, DXVK, MoltenVK and other open-source components under their own licenses. \
            D3DMetal is Apple's, from the Game Porting Toolkit, under Apple's license for non-commercial use.
            """, attributes: body))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate()
    }
}

/// Open panels for the few files the app asks for.
enum Pickers {
    static func programs() -> [URL] {
        let panel = configured("Choose Windows programs (.exe), installers (.msi), or a downloaded game (.zip, .rar, .7z, .iso).",
                               types: [.init("com.microsoft.windows-executable"), .init("com.microsoft.msi")].compactMap { $0 }
                                   + ["zip", "rar", "7z", "iso", "001", "tar", "gz", "tgz", "xz", "bz2"].compactMap { UTType(filenameExtension: $0) },
                               multiple: true)
        return panel.runModal() == .OK ? panel.urls : []
    }

    static func folder(_ message: String) -> URL? {
        let panel = configured(message, folders: true)
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func file(_ message: String, extensions: [String], in directory: URL? = nil) -> URL? {
        let panel = configured(message, types: extensions.compactMap { UTType(filenameExtension: $0) }, in: directory)
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Sets the panel up now, so the first pick needn't wait for it.
    static func prepare() { _ = shared }

    /// One panel for every pick. macOS sets a new panel up in a separate process, and the app waits
    /// for it (over a second at times); a panel used before opens at once.
    private static let shared = NSOpenPanel()

    private static func configured(_ message: String, types: [UTType] = [], folders: Bool = false, multiple: Bool = false,
                                   in directory: URL? = nil) -> NSOpenPanel {
        let panel = shared
        panel.message = message
        panel.allowedContentTypes = types
        panel.canChooseFiles = !folders
        panel.canChooseDirectories = folders
        panel.allowsMultipleSelection = multiple
        if let directory { panel.directoryURL = directory }
        return panel
    }
}
