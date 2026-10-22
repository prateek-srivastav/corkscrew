import GameCore
import SwiftUI

/// Settings: the app's version and update, first-run setup, Advanced mode, what happens while you
/// play, privacy, then (in Advanced mode) what's installed, the data folders and your own runtimes
/// and components, and uninstalling. Groups of rows on cards, as in System Settings.
struct SetupView: View {
    @Environment(AppModel.self) private var model
    @State private var archiveSHA256 = ""
    @State private var confirmsUninstall = false
    @AppStorage(Theme.advancedModeKey) private var advancedMode = false
    @AppStorage(AppModel.lowersLaunchersKey) private var lowersLaunchers = false
    @AppStorage(AppModel.excludesGamesFromBackupsKey) private var excludesGamesFromBackups = false
    @AppStorage(AppModel.sendsUsageCountsKey) private var sendsUsageCounts = true

    static let gameportingToolkitPage = URL(string: "https://developer.apple.com/games/game-porting-toolkit/")!
    static let usageCountsPage = URL(string: "https://github.com/Prateek-Srivastav/corkscrew#usage-counts")!
    /// This copy's version.
    private static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                overview

                SettingsGroup("General") {
                    SettingsRow("Advanced mode", systemImage: "slider.horizontal.3", tint: .indigo,
                                detail: "Corkscrew picks tested settings for each game. Turn this on to change them: graphics, "
                                    + "overlays, arguments and launch logs. The sidebar then shows your bottles, and Settings "
                                    + "shows what's installed, the data folders, and lets you add your own runtimes and components.") {
                        toggle("Advanced mode", isOn: $advancedMode)
                    }
                }

                SettingsGroup("While you play") {
                    SettingsRow("Lower Steam and launchers during games", systemImage: "gauge.with.dots.needle.33percent", tint: .orange,
                                detail: "Steam, its web pages and the Rockstar Games Launcher run at background priority while a game "
                                    + "plays, on the Mac's efficiency cores. Steam's notifications and downloads may be slower. "
                                    + "Back to normal when the game ends.") {
                        toggle("Lower Steam and launchers during games", isOn: $lowersLaunchers)
                    }
                    SettingsRow("Don't back up installed games", systemImage: "clock.arrow.circlepath", tint: .green,
                                detail: "Time Machine skips the games installed in the bottles, so a backup doesn't copy them during "
                                    + "play. Saves in Documents, AppData and Steam stay in backups. A game that keeps its saves "
                                    + "in its own folder loses them from backups.") {
                        toggle("Don't back up installed games", isOn: $excludesGamesFromBackups)
                            .onChange(of: excludesGamesFromBackups) { model.updateBackupExclusions() }
                    }
                }

                SettingsGroup("Privacy") {
                    SettingsRow("Send usage counts", systemImage: "chart.bar.fill", tint: .blue,
                                detail: "Counts the first launch and each finished setup, with the Mac model, chip and memory, the "
                                    + "macOS and Corkscrew versions, and the language. At each launch, and with each report you "
                                    + "send, Corkscrew's server also gets this Mac's ID: a hash of its hardware ID that stays the "
                                    + "same, so it can count Macs. The country comes from the connection; the IP address isn't "
                                    + "kept. No names, files or programs.") {
                        toggle("Send usage counts", isOn: $sendsUsageCounts)
                    } footer: {
                        Link("What's sent", destination: Self.usageCountsPage).font(.subheadline).padding(.top, 2)
                    }
                }

                if advancedMode {
                    Group {
                        installed
                        data
                        ownRuntimes
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                SettingsGroup {
                    SettingsRow("Clean Up and Uninstall", systemImage: "trash.fill", tint: .red,
                                detail: "Deletes every bottle with the games installed in it, Wine, your library, logs, caches "
                                    + "and settings, then Corkscrew itself.") {
                        BusyButton("Uninstall…", systemImage: "trash", busyTitle: "Uninstalling…",
                                   isBusy: model.isPending(.uninstall)) { confirmsUninstall = true }
                            .buttonStyle(.destructivePill)
                    }
                }
            }
            .animation(.snappy, value: advancedMode)
            .pageHeader("Settings", subtitle: "Corkscrew runs Windows games with Wine.")
            // A readable column, centred on wide windows.
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 40)
            .padding(.top, 52)
            .padding(.bottom, 40)
        }
        .ignoresSafeArea(.container, edges: .top)
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

    // MARK: Overview

    /// The app, its version and any update; then setup, its steps and its button, until setup is
    /// done, and again while it downloads something (a new engine pack, Steam again).
    private var overview: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().interpolation(.high)
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Corkscrew").font(.title2.bold())
                    Text("Version \(Self.version)").foregroundStyle(.secondary)
                    if let update = model.availableUpdate { updateLine(update) }
                }
                Spacer(minLength: 16)
                if let update = model.availableUpdate {
                    BusyButton("Update to \(update.version)", systemImage: "arrow.down.circle", busyTitle: "Updating…",
                               isBusy: model.isPending(.update)) { model.installUpdate() }
                        .buttonStyle(.prominentPill)
                        .help(model.updateSize > update.app.size
                              ? "Includes a new Wine (engine pack \(update.enginePack.version)), which Corkscrew downloads when the new version opens."
                              : "")
                }
            }
            .padding(20)

            if showsSetup {
                Rectangle().fill(Theme.stroke).frame(height: 1)
                setup
            }
        }
        .background {
            // The app icon's wine red over the whole card, strongest at the top right.
            LinearGradient(colors: [Theme.library.opacity(0.6), Theme.library.opacity(0.15)], startPoint: .topTrailing, endPoint: .bottomLeading)
        }
        .background(Theme.surface)
        .clipShape(.rect(cornerRadius: Theme.cornerRadius))
        .overlay { RoundedRectangle(cornerRadius: Theme.cornerRadius).strokeBorder(Theme.stroke) }
        .animation(.easeOut(duration: 0.25), value: showsSetup)
    }

    private var showsSetup: Bool { !model.isReady || model.isSettingUp || isInstallingSteam }

    /// steam.exe is there before Steam has updated itself; the install isn't done yet.
    private var isInstallingSteam: Bool { model.launcherBottle.map { model.steamInstalls.contains($0.id) } == true }

    /// What setup does, its steps and its button.
    private var setup: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Setup").font(.headline)
                Text("One click sets up everything: Rosetta if your Mac needs it, Wine with its graphics translators "
                     + "(D3DMetal, DXMT and DXVK), a Steam bottle (a Windows drive) with Steam, and two protected places "
                     + "for other programs, which can't see your files: Offline Programs, without internet, and Online Programs.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            steps
            setupAction
        }
        .padding(20)
    }

    @ViewBuilder
    private func updateLine(_ update: AppUpdate) -> some View {
        if let progress = model.updateProgress {
            HStack(spacing: 8) {
                ProgressView(value: progress).frame(width: 120)
                Text("Downloading Corkscrew \(update.version)… \(Int(progress * 100))%").foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        } else {
            Label("Corkscrew \(update.version) is available, \(ByteCountFormatter.string(fromByteCount: model.updateSize, countStyle: .file))",
                  systemImage: "arrow.down.circle.fill")
                .foregroundStyle(Theme.online)
        }
    }

    /// The four steps on a line, joined as each one is done.
    private var steps: some View {
        let steps: [(title: String, systemImage: String, state: StepState)] = [
            ("Rosetta", "cpu", state(.rosetta, done: model.hasRosetta)),
            ("Wine and graphics", "wineglass", state(.engine, done: !model.runtimes.isEmpty)),
            ("Steam", "gamecontroller", state(.steam, done: model.hasSteam, busy: isInstallingSteam)),
            ("Protected Programs", "lock.shield",
             state(.protectedGames, done: model.bottle(role: .sandbox) != nil && model.bottle(role: .sandboxOnline) != nil)),
        ]
        return HStack(alignment: .top, spacing: 0) {
            ForEach(steps.indices, id: \.self) { index in
                StepNode(number: index + 1, title: steps[index].title, systemImage: steps[index].systemImage, state: steps[index].state,
                         before: index == 0 ? nil : steps[index - 1].state == .done,
                         after: index == steps.count - 1 ? nil : steps[index].state == .done)
            }
        }
    }

    /// Setup's button, its progress while it runs, or Steam installing again.
    @ViewBuilder
    private var setupAction: some View {
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
                    .disabled(model.activity != nil)
                Text(setupNote)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text("Installing Steam…")
            }
        }
    }

    /// The note beside the setup button. Wine only while it isn't installed: setup skips it then.
    private var setupNote: String {
        let rosetta = "If Rosetta isn't installed yet, macOS asks for your password once."
        if !model.runtimes.isEmpty { return "Steam is downloaded, and updates itself the first time it opens. " + rosetta }
        if AppModel.bundledEnginePack != nil {
            return "Wine comes with the app. Steam is downloaded, and updates itself the first time it opens. " + rosetta
        }
        return "Downloads \(ByteCountFormatter.string(fromByteCount: AppModel.enginePack.size, countStyle: .file)) for Wine; "
            + "Steam updates itself the first time it opens. " + rosetta
    }

    private var setupTitle: String {
        guard let progress = model.enginePackProgress else { return model.activity ?? "Setting up…" }
        guard progress.step == .downloading else { return progress.title }
        return "\(progress.title) of \(ByteCountFormatter.string(fromByteCount: AppModel.enginePack.size, countStyle: .file))"
    }

    /// A step setup works on (or `busy` outside setup) shows a spinner: what `done` checks may be
    /// there before the step ends. The step setup stopped at with an error shows as failed.
    private func state(_ step: SetupStep, done: Bool, busy: Bool = false) -> StepState {
        if model.setupStep == step || busy { return .active }
        if model.setupFailure == step { return .failed }
        return done ? .done : .waiting
    }

    // MARK: Advanced

    private var installed: some View {
        SettingsGroup("Installed") {
            ForEach(model.runtimes, id: \.id) { runtime in
                SettingsRow(runtime.id, systemImage: "wineglass.fill", tint: .purple,
                            detail: [runtime.architecture.rawValue, runtime.moltenVK.map { "MoltenVK \($0)" }]
                                .compactMap { $0 }.joined(separator: " · ")) {}
            }
            ForEach(model.components, id: \.self) { component in
                SettingsRow(component, systemImage: "cube.fill", tint: .teal) {}
            }
            if model.runtimes.isEmpty && model.components.isEmpty {
                SettingsRow("Nothing yet", systemImage: "tray", tint: .gray) {}
            }
        }
    }

    private var data: some View {
        SettingsGroup("Data") {
            folderRow("Bottles and runtimes", systemImage: "folder.fill", tint: .blue, model.paths.supportRoot)
            folderRow("Logs", systemImage: "doc.text.fill", tint: .gray, model.paths.logsRoot)
        }
    }

    private var ownRuntimes: some View {
        SettingsGroup("Your own runtimes and components") {
            SettingsRow("Runtime folder", systemImage: "wineglass.fill", tint: .purple,
                        detail: "A runtime built on this Mac (build/runtime/winecx-…).") {
                BusyButton("Add Folder…", busyTitle: "Adding…", isBusy: model.isPending(.addRuntime)) {
                    if let folder = Pickers.folder("Choose a runtime built on this Mac (build/runtime/winecx-…).") {
                        model.installRuntime(folder: folder)
                    }
                }
                .buttonStyle(.pill)
            }
            SettingsRow("Components folder", systemImage: "cube.fill", tint: .teal,
                        detail: "The folder install-components.sh filled (build/components).") {
                BusyButton("Add Folder…", busyTitle: "Adding…", isBusy: model.isPending(.addComponents)) {
                    if let folder = Pickers.folder("Choose the folder install-components.sh filled (build/components).") {
                        model.importComponents(from: folder)
                    }
                }
                .buttonStyle(.pill)
            }
            SettingsRow("Game Porting Toolkit", systemImage: "square.and.arrow.down.fill", tint: .gray,
                        detail: "D3DMetal 3.0 comes with the runtime. To try another version, download it from Apple's Game "
                            + "Porting Toolkit page and import its disk image.") {
                BusyButton("Import…", busyTitle: "Importing…", isBusy: model.isPending(.importToolkit)) {
                    if let dmg = Pickers.file("Choose Apple's Game Porting Toolkit disk image (Game_Porting_Toolkit_<version>.dmg).",
                                              extensions: ["dmg"]) {
                        model.importGPTK(dmg: dmg)
                    }
                }
                .buttonStyle(.pill)
            } footer: {
                Link("Game Porting Toolkit at Apple", destination: Self.gameportingToolkitPage).font(.subheadline).padding(.top, 2)
            }
            SettingsRow("Runtime archive", systemImage: "archivebox.fill", tint: .brown,
                        detail: "A runtime archive (.tar.xz, .tar.gz, .tar.zst), checked against its SHA-256.") {
                BusyButton("Install…", busyTitle: "Installing…", isBusy: model.isPending(.addRuntime)) {
                    if let archive = Pickers.file("Choose a runtime archive.", extensions: ["xz", "gz", "zst", "tar"]) {
                        model.installRuntime(archive: archive, sha256: archiveSHA256)
                    }
                }
                .buttonStyle(.pill)
                .disabled(archiveSHA256.trimmingCharacters(in: .whitespaces).count != 64)
            } footer: {
                TextField("Archive SHA-256", text: $archiveSHA256, prompt: Text("Archive SHA-256 (64 hex characters)"))
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .padding(.top, 6)
            }
        }
    }

    private func folderRow(_ title: String, systemImage: String, tint: Color, _ url: URL) -> some View {
        SettingsRow(title, systemImage: systemImage, tint: tint) {
            Button("Show in Finder") {
                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                NSWorkspace.shared.open(url)
            }
            .buttonStyle(.pill)
        } footer: {
            Text(url.path(percentEncoded: false))
                .font(.subheadline).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private func toggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
            .toggleStyle(.switch)
            .labelsHidden()
    }
}

/// A titled group of settings on one card, its rows split by hairlines, as in System Settings.
private struct SettingsGroup<Content: View>: View {
    let title: String?
    @ViewBuilder let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title { SectionLabel(title).padding(.leading, 4) }
            VStack(spacing: 0) {
                Group(subviews: content) { rows in
                    ForEach(rows) { row in
                        if row.id != rows.first?.id {
                            Rectangle().fill(Theme.stroke).frame(height: 1).padding(.leading, SettingsRowLayout.textInset)
                        }
                        row
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: .rect(cornerRadius: Theme.cornerRadius))
            .overlay { RoundedRectangle(cornerRadius: Theme.cornerRadius).strokeBorder(Theme.stroke) }
        }
    }
}

private enum SettingsRowLayout {
    static let padding: CGFloat = 14
    /// The tiles are the sidebar's.
    static let tile: CGFloat = 32
    static let tileRadius = Theme.cornerRadius - 5
    /// Where a row's text starts; the hairlines between rows start there too.
    static let textInset = padding + tile + padding
}

/// One setting: its icon on a tinted tile, a name, what it does, and its switch or button. `footer`
/// goes under the text: a link, a path, a field.
private struct SettingsRow<Accessory: View, Footer: View>: View {
    let title: String
    let systemImage: String
    let tint: Color
    let detail: String?
    let accessory: Accessory
    let footer: Footer

    init(_ title: String, systemImage: String, tint: Color, detail: String? = nil,
         @ViewBuilder accessory: () -> Accessory, @ViewBuilder footer: () -> Footer) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.detail = detail
        self.accessory = accessory()
        self.footer = footer()
    }

    var body: some View {
        HStack(alignment: .top, spacing: SettingsRowLayout.padding) {
            // As a bottle card's icon: the colour, faint, behind the glyph in that colour.
            Image(systemName: systemImage)
                .font(.system(size: Theme.controlIconSize, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: SettingsRowLayout.tile, height: SettingsRowLayout.tile)
                .background(tint.opacity(0.16), in: .rect(cornerRadius: SettingsRowLayout.tileRadius))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body)
                if let detail {
                    Text(detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                footer
            }
            // A short row's text is centred on the tile.
            .frame(minHeight: SettingsRowLayout.tile, alignment: .leading)
            Spacer(minLength: 16)
            accessory
                .frame(minHeight: SettingsRowLayout.tile)
        }
        .padding(SettingsRowLayout.padding)
    }
}

extension SettingsRow where Footer == EmptyView {
    init(_ title: String, systemImage: String, tint: Color, detail: String? = nil, @ViewBuilder accessory: () -> Accessory) {
        self.init(title, systemImage: systemImage, tint: tint, detail: detail, accessory: accessory) { EmptyView() }
    }
}

private enum StepState { case waiting, active, done, failed }

/// A setup step: its icon in a circle, with a check once it's done, and the lines to the steps
/// before and after (`nil` at the ends), green once the step before them is done.
private struct StepNode: View {
    let number: Int
    let title: String
    let systemImage: String
    let state: StepState
    let before: Bool?
    let after: Bool?

    private static let size: CGFloat = 44

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                HStack(spacing: 0) {
                    line(before)
                    Color.clear.frame(width: Self.size + 16)
                    line(after)
                }
                circle
            }
            VStack(spacing: 2) {
                Text("Step \(number)").font(.subheadline).foregroundStyle(.secondary)
                Text(title).font(.body.weight(.medium)).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.snappy, value: state)
    }

    private var tint: Color? {
        switch state {
        case .done: .green
        case .failed: .red
        case .waiting, .active: nil
        }
    }

    private var circle: some View {
        ZStack {
            Circle().fill(tint?.opacity(0.16) ?? Theme.surface)
            Circle().strokeBorder(tint?.opacity(0.45) ?? (state == .active ? Color.white.opacity(0.3) : Theme.stroke))
            if state == .active {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(tint ?? .secondary)
            }
        }
        .frame(width: Self.size, height: Self.size)
        .overlay(alignment: .topTrailing) {
            if state == .done || state == .failed {
                Image(systemName: state == .done ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white, tint ?? .green)
                    .background(Circle().fill(Theme.background).padding(1))
                    .offset(x: 4, y: -2)
                    .transition(.scale.combined(with: .opacity))
            }
        }
    }

    private func line(_ done: Bool?) -> some View {
        Capsule()
            .fill(done == true ? Color.green.opacity(0.5) : Theme.stroke)
            .frame(height: 2)
            .opacity(done == nil ? 0 : 1)
    }
}
