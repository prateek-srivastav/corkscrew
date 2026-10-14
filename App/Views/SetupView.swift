import GameCore
import SwiftUI

/// First-run setup, and where runtimes and graphics components are managed later.
struct SetupView: View {
    @Environment(AppModel.self) private var model
    @State private var archiveSHA256 = ""
    @State private var isCreatingBottle = false
    @AppStorage(Theme.advancedModeKey) private var advancedMode = false

    static let gameportingToolkitPage = URL(string: "https://developer.apple.com/games/game-porting-toolkit/")!

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Card(padding: 24) {
                    VStack(alignment: .leading, spacing: 20) {
                        status
                        HStack(spacing: 12) {
                            step(1, "Rosetta", systemImage: "cpu", done: model.hasRosetta)
                            step(2, "Wine and graphics", systemImage: "wineglass", done: !model.runtimes.isEmpty)
                            step(3, "Steam", systemImage: "gamecontroller", done: model.hasSteam)
                            step(4, "Protected Games", systemImage: "lock.shield",
                                 done: model.bottle(role: .sandbox) != nil && model.bottle(role: .sandboxOnline) != nil)
                        }
                    }
                }

                Card {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Advanced mode").font(.headline)
                            Text("Corkscrew picks tested settings for each game. Turn this on to change them: graphics, "
                                 + "overlays, arguments and launch logs. Setup then also shows what's installed, the bottles "
                                 + "and data folders, and lets you add your own runtimes and components.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("Advanced mode", isOn: $advancedMode)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                }

                if advancedMode {
                    HStack(alignment: .top, spacing: 18) {
                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionLabel("Installed")
                            ForEach(model.runtimes, id: \.id) { runtime in
                                LabeledContent(runtime.id, value: [runtime.architecture.rawValue, runtime.moltenVK.map { "MoltenVK \($0)" }]
                                    .compactMap { $0 }.joined(separator: " · "))
                            }
                            ForEach(model.components, id: \.self) { Text($0) }
                            if model.runtimes.isEmpty && model.components.isEmpty {
                                Text("Nothing yet.").foregroundStyle(.secondary)
                            }
                        }
                    }
                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionLabel("Bottles")
                            ForEach(model.bottles) { bottle in
                                Label(bottle.name, systemImage: bottle.kind == .isolated ? "lock.shield" : "shippingbox")
                            }
                            VStack(alignment: .leading, spacing: 8) {
                                if let launcher = model.launcherBottle, !model.hasSteam, !model.isSettingUp {
                                    BusyButton("Install Steam into “\(launcher.name)”", busyTitle: "Installing Steam…",
                                               isBusy: model.steamInstalls.contains(launcher.id)) { Task { await model.installSteam(into: launcher) } }
                                        .disabled(model.activity != nil)
                                }
                                BusyButton("New Bottle…", busyTitle: "Creating…", isBusy: model.isPending(.createBottle)) { isCreatingBottle = true }
                                    .disabled(model.runtimes.isEmpty)
                                BusyButton("Add Existing Bottle…", busyTitle: "Adding…", isBusy: model.isPending(.importBottle)) {
                                    if let folder = Pickers.folder("Choose a bottle folder (it holds bottle.json and prefix).") {
                                        model.importBottle(from: folder)
                                    }
                                }
                            }
                            .buttonStyle(.pill)
                            .padding(.top, 4)
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)

                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionLabel("Data")
                        LabeledContent("Bottles and runtimes") { pathButton(model.paths.supportRoot) }
                        LabeledContent("Logs") { pathButton(model.paths.logsRoot) }
                    }
                }

                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionLabel("Your own runtimes and components")
                            HStack(spacing: 8) {
                                BusyButton("Add Runtime Folder…", busyTitle: "Adding…", isBusy: model.isPending(.addRuntime)) {
                                    if let folder = Pickers.folder("Choose a runtime built on this Mac (build/runtime/winecx-…).") {
                                        model.installRuntime(folder: folder)
                                    }
                                }
                                BusyButton("Add Components Folder…", busyTitle: "Adding…", isBusy: model.isPending(.addComponents)) {
                                    if let folder = Pickers.folder("Choose the folder install-components.sh filled (build/components).") {
                                        model.importComponents(from: folder)
                                    }
                                }
                                BusyButton("Import Game Porting Toolkit…", busyTitle: "Importing…", isBusy: model.isPending(.importToolkit)) {
                                    if let dmg = Pickers.file("Choose Apple's Game Porting Toolkit disk image (Game_Porting_Toolkit_<version>.dmg).",
                                                              extensions: ["dmg"]) {
                                        model.importGPTK(dmg: dmg)
                                    }
                                }
                            }
                            .buttonStyle(.pill)
                            HStack {
                                TextField("Archive SHA-256", text: $archiveSHA256, prompt: Text("Archive SHA-256 (64 hex characters)"))
                                    .font(.system(.body, design: .monospaced))
                                    .textFieldStyle(.roundedBorder)
                                BusyButton("Install Archive…", busyTitle: "Installing…", isBusy: model.isPending(.addRuntime)) {
                                    if let archive = Pickers.file("Choose a runtime archive.", extensions: ["xz", "gz", "zst", "tar"]) {
                                        model.installRuntime(archive: archive, sha256: archiveSHA256)
                                    }
                                }
                                .buttonStyle(.pill)
                                .disabled(archiveSHA256.trimmingCharacters(in: .whitespaces).count != 64)
                            }
                            Text("D3DMetal 3.0 comes with the runtime. To try another version, download it from Apple's Game Porting Toolkit page and import its disk image.")
                                .font(.caption).foregroundStyle(.secondary)
                            Link("Game Porting Toolkit at Apple", destination: Self.gameportingToolkitPage)
                                .font(.caption)
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(.snappy, value: advancedMode)
            .pageHeader("Setup", subtitle: "Corkscrew runs Windows games with Wine.")
            .padding(.horizontal, 40)
            .padding(.top, 52)
            .padding(.bottom, 40)
        }
        .ignoresSafeArea(.container, edges: .top)
        .sheet(isPresented: $isCreatingBottle) { NewBottleSheet() }
    }

    @ViewBuilder
    private var status: some View {
        Text("One click sets up everything: Rosetta if your Mac needs it, Wine with its graphics translators "
             + "(D3DMetal, DXMT and DXVK), a Steam bottle (a Windows drive) with Steam, and two protected places "
             + "for other games, which can't see your files: Offline Games, without internet, and Online Games.")
            .foregroundStyle(.secondary)
        if model.isSettingUp {
            HStack(spacing: 12) {
                if let progress = model.enginePackProgress {
                    ProgressView(value: progress.fraction) {
                        Text(progress.step == .downloading
                             ? "\(progress.title) of \(ByteCountFormatter.string(fromByteCount: AppModel.enginePack.size, countStyle: .file))"
                             : progress.title)
                    }
                } else {
                    ProgressView().controlSize(.small)
                    Text(model.activity ?? "Setting up…").lineLimit(2)
                }
                Spacer()
                Button("Cancel") { model.cancelSetUp() }.buttonStyle(.pill)
            }
        } else if !model.isReady {
            HStack(spacing: 14) {
                Button("Set Up Corkscrew", systemImage: "sparkles") { model.setUp() }
                    .buttonStyle(.prominentPill)
                    .controlSize(.large)
                    .disabled(model.activity != nil)
                Text((AppModel.bundledEnginePack != nil
                      ? "Wine comes with the app. Steam is downloaded, and updates itself the first time it opens. "
                      : "Downloads \(ByteCountFormatter.string(fromByteCount: AppModel.enginePack.size, countStyle: .file)) for Wine; Steam updates itself the first time it opens. ")
                     + "If Rosetta isn't installed yet, macOS asks for your password once.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Label("Ready. Open Steam from the Library and sign in: your Steam games show there.", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)
        }
    }

    private func step(_ number: Int, _ title: String, systemImage: String, done: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: systemImage).font(.title3)
                Spacer()
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(done ? Color.green : Color.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Step \(number)").font(.caption).foregroundStyle(.secondary)
                Text(title).font(.callout.weight(.semibold)).lineLimit(1)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(done ? Color.green.opacity(0.1) : Theme.surface, in: .rect(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(done ? Color.green.opacity(0.3) : Theme.stroke) }
    }

    private func pathButton(_ url: URL) -> some View {
        Button(url.path(percentEncoded: false)) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            NSWorkspace.shared.open(url)
        }
        .buttonStyle(.link)
        .lineLimit(1)
        .truncationMode(.middle)
    }
}
