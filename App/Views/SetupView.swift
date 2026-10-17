import GameCore
import SwiftUI

/// Settings: first-run setup, Advanced mode, runtimes and graphics components, and uninstalling.
struct SetupView: View {
    @Environment(AppModel.self) private var model
    @State private var archiveSHA256 = ""
    @State private var isCreatingBottle = false
    @State private var confirmsUninstall = false
    @AppStorage(Theme.advancedModeKey) private var advancedMode = false
    @AppStorage(AppModel.lowersLaunchersKey) private var lowersLaunchers = false
    @AppStorage(AppModel.excludesGamesFromBackupsKey) private var excludesGamesFromBackups = false
    @AppStorage(AppModel.sendsUsageCountsKey) private var sendsUsageCounts = true
    @AppStorage(AppModel.offersReportsKey) private var offersReports = true

    static let gameportingToolkitPage = URL(string: "https://developer.apple.com/games/game-porting-toolkit/")!
    static let usageCountsPage = URL(string: "https://github.com/Prateek-Srivastav/corkscrew#usage-counts")!

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Card(padding: 24) {
                    VStack(alignment: .leading, spacing: 20) {
                        status
                        HStack(spacing: 12) {
                            step(1, .rosetta, "Rosetta", systemImage: "cpu", done: model.hasRosetta)
                            step(2, .engine, "Wine and graphics", systemImage: "wineglass", done: !model.runtimes.isEmpty)
                            // steam.exe is there before Steam has updated itself; the install isn't done yet.
                            step(3, .steam, "Steam", systemImage: "gamecontroller", done: model.hasSteam,
                                 busy: model.launcherBottle.map { model.steamInstalls.contains($0.id) } == true)
                            step(4, .protectedGames, "Protected Programs", systemImage: "lock.shield",
                                 done: model.bottle(role: .sandbox) != nil && model.bottle(role: .sandboxOnline) != nil)
                        }
                    }
                }

                Card {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Advanced mode").font(.headline)
                            Text("Corkscrew picks tested settings for each game. Turn this on to change them: graphics, "
                                 + "overlays, arguments and launch logs. Settings then also shows what's installed, the bottles "
                                 + "and data folders, and lets you add your own runtimes and components.")
                                .font(.body).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("Advanced mode", isOn: $advancedMode)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: 16) {
                        SectionLabel("While you play")
                        setting("Lower Steam and launchers during games", isOn: $lowersLaunchers,
                                "Steam, its web pages and the Rockstar Games Launcher run at background priority while a game "
                                + "plays, on the Mac's efficiency cores. Steam's notifications and downloads may be slower. "
                                + "Back to normal when the game ends.")
                        setting("Don't back up installed games", isOn: $excludesGamesFromBackups,
                                "Time Machine skips the games installed in the bottles, so a backup doesn't copy them during "
                                + "play. Saves in Documents, AppData and Steam stay in backups. A game that keeps its saves "
                                + "in its own folder loses them from backups.")
                            .onChange(of: excludesGamesFromBackups) { model.updateBackupExclusions() }
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: 16) {
                        SectionLabel("Privacy")
                        setting("Send anonymous usage counts", isOn: $sendsUsageCounts,
                                "Counts the first launch and each finished setup, with the Mac model, chip and memory, the "
                                + "macOS and Corkscrew versions, and the language. The country comes from the connection; the "
                                + "IP address isn't kept. No names, files or programs.")
                        Link("What's sent", destination: Self.usageCountsPage)
                            .font(.subheadline)
                        setting("Offer to report crashes and working settings", isOn: $offersReports,
                                "After a program crashes, or something in Corkscrew fails, shows the report: what happened, "
                                + "the Mac, the program's settings and the end of its log. After a Steam game runs well with "
                                + "settings that aren't on the tested list, asks to share them. Nothing is sent until you click.")
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
                                .font(.subheadline).foregroundStyle(.secondary)
                            Link("Game Porting Toolkit at Apple", destination: Self.gameportingToolkitPage)
                                .font(.subheadline)
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                Card {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Clean Up and Uninstall").font(.headline)
                            Text("Deletes every bottle with the games installed in it, Wine, your library, logs, caches "
                                 + "and settings, then Corkscrew itself.")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        BusyButton("Uninstall…", systemImage: "trash", busyTitle: "Uninstalling…",
                                   isBusy: model.isPending(.uninstall)) { confirmsUninstall = true }
                            .buttonStyle(.destructivePill)
                    }
                }
            }
            .animation(.snappy, value: advancedMode)
            .pageHeader("Settings", subtitle: "Corkscrew runs Windows games with Wine.")
            .padding(.horizontal, 40)
            .padding(.top, 52)
            .padding(.bottom, 40)
        }
        .ignoresSafeArea(.container, edges: .top)
        .sheet(isPresented: $isCreatingBottle) { NewBottleSheet() }
        .alert("Delete all games and uninstall Corkscrew?", isPresented: $confirmsUninstall) {
            Button("Delete Everything and Uninstall", role: .destructive) { model.uninstall() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every game installed in Corkscrew's bottles is deleted from this Mac, with saves that are only in "
                 + "a bottle. Wine, your library, logs, caches and settings are deleted, and Corkscrew is uninstalled "
                 + "and quits. You can't undo this. Files outside Corkscrew's folders stay.\n\n"
                 + "Data folder: \(model.paths.supportRoot.path)")
        }
    }

    @ViewBuilder
    private var status: some View {
        Text("One click sets up everything: Rosetta if your Mac needs it, Wine with its graphics translators "
             + "(D3DMetal, DXMT and DXVK), a Steam bottle (a Windows drive) with Steam, and two protected places "
             + "for other programs, which can't see your files: Offline Programs, without internet, and Online Programs.")
            .foregroundStyle(.secondary)
        if model.isSettingUp {
            HStack(spacing: 12) {
                // The whole setup; a background engine upgrade only has its own step.
                if let progress = model.setupProgress ?? model.enginePackProgress?.overall {
                    ProgressView(value: progress) { Text(setupTitle).lineLimit(2) }
                        .animation(.snappy, value: progress)
                } else {
                    ProgressView().controlSize(.small)
                    Text(setupTitle).lineLimit(2)
                }
                Spacer()
                Button("Cancel") { model.cancelSetUp() }.buttonStyle(.pill)
            }
        } else if !model.isReady {
            HStack(spacing: 14) {
                Button(model.setupFailure == nil ? "Set Up Corkscrew" : "Try Again",
                       systemImage: model.setupFailure == nil ? "sparkles" : "arrow.clockwise") { model.setUp() }
                    .buttonStyle(.prominentPill)
                    .controlSize(.large)
                    .disabled(model.activity != nil)
                Text((AppModel.bundledEnginePack != nil
                      ? "Wine comes with the app. Steam is downloaded, and updates itself the first time it opens. "
                      : "Downloads \(ByteCountFormatter.string(fromByteCount: AppModel.enginePack.size, countStyle: .file)) for Wine; Steam updates itself the first time it opens. ")
                     + "If Rosetta isn't installed yet, macOS asks for your password once.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        } else {
            Label("Ready. Open Steam from the Library and sign in: your Steam games show there.", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)
        }
    }

    private var setupTitle: String {
        guard let progress = model.enginePackProgress else { return model.activity ?? "Setting up…" }
        guard progress.step == .downloading else { return progress.title }
        return "\(progress.title) of \(ByteCountFormatter.string(fromByteCount: AppModel.enginePack.size, countStyle: .file))"
    }

    /// A step setup works on (or `busy` outside setup) shows a spinner: what `done` checks may be
    /// there before the step ends. The step setup stopped at with an error shows as failed.
    private func setting(_ title: String, isOn: Binding<Bool>, _ detail: String) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.body).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(title, isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }

    private func step(_ number: Int, _ step: SetupStep, _ title: String, systemImage: String, done: Bool, busy: Bool = false) -> some View {
        let active = model.setupStep == step || busy
        let failed = !active && model.setupFailure == step
        let done = done && !active && !failed
        let tint: Color? = failed ? .red : done ? .green : nil
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: systemImage).font(.title3)
                Spacer()
                if active {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: failed ? "exclamationmark.circle.fill" : done ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(tint ?? Color.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Step \(number)").font(.subheadline).foregroundStyle(.secondary)
                Text(title).font(.headline).lineLimit(1)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint?.opacity(0.1) ?? Theme.surface, in: .rect(cornerRadius: Theme.cornerRadius))
        .overlay { RoundedRectangle(cornerRadius: Theme.cornerRadius).strokeBorder(tint?.opacity(0.3) ?? Theme.stroke) }
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
