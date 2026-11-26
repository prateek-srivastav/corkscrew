import AppKit
import GameCore
import SwiftUI

/// Asks once about a bottle made before Corkscrew kept the Windows folders inside: its games save into
/// the Mac's Documents among the user's files. Look for Files lists what changed there (only then
/// may macOS ask to let Corkscrew in); Keep in Corkscrew copies the ticked items in; Keep Linked
/// leaves it as it is; Later (✕ or Esc) asks at the next start. Short on purpose: the bottle's page
/// says the rest.
struct BottleFoldersSheet: View {
    @Environment(AppModel.self) private var model
    let choice: AppModel.FolderChoice
    @State private var ticked: Set<URL> = []
    @State private var isLooking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetHeader(
                systemImage: "folder.fill", tint: .accentColor,
                title: "Keep \(choice.bottle.name)'s game saves in Corkscrew?",
                message: "Its games save into your Mac's Documents, among your own files.",
                closeHelp: "Ask again next time")

            if let scan = choice.scan { found(scan) }

            HStack {
                Button("Keep Linked") { Task { await model.linkFoldersToMac(choice.bottle) } }
                Spacer()
                if let scan = choice.scan {
                    Button("Keep in Corkscrew") {
                        let items = scan.items.filter { ticked.contains($0.url) }
                        Task { await model.keepFoldersInside(choice.bottle, copying: items) }
                    }
                    .buttonStyle(.prominentPill)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!scan.unreadable.isEmpty)
                } else {
                    BusyButton("Look for Files", busyTitle: "Looking…", isBusy: isLooking) {
                        isLooking = true
                        Task {
                            await model.lookForFiles()
                            ticked = Set(model.folderChoice?.scan?.items.filter(\.isSuggested).map(\.url) ?? [])
                            isLooking = false
                        }
                    }
                    .buttonStyle(.prominentPill)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    @ViewBuilder
    private func found(_ scan: BottleFolders.Scan) -> some View {
        if !scan.unreadable.isEmpty {
            Label("Corkscrew can't read your Documents. Allow it in System Settings → Privacy & Security → Files and Folders.",
                  systemImage: "exclamationmark.triangle")
                .font(.body).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        } else if scan.items.isEmpty {
            Text("Nothing to copy.").font(.body).foregroundStyle(.secondary)
        } else {
            Text("Tick what to copy. The originals stay.").font(.body)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(scan.items) { item in row(item) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)
            .padding(10)
            .background(Theme.surface, in: .rect(cornerRadius: 8))
        }
    }

    private func row(_ item: BottleFolders.Item) -> some View {
        Toggle(isOn: Binding(get: { ticked.contains(item.url) },
                             set: { if $0 { ticked.insert(item.url) } else { ticked.remove(item.url) } })) {
            HStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path)).resizable().frame(width: 18, height: 18)
                Text(item.url.lastPathComponent).lineLimit(1)
                if item.isSuggested {
                    Text("likely a game's").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Show in Finder")
            }
        }
        .toggleStyle(.checkbox)
    }
}
