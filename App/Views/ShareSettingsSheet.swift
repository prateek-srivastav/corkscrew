import AppKit
import GameCore
import SwiftUI

/// Offered after a Steam game ran a while without a crash, with settings that Corkscrew's tested
/// list doesn't have: share them in a Game report, and after a maintainer checks it, other players'
/// copies of the game start with them.
struct ShareSettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let prompt: AppModel.SharePrompt
    @State private var playsWell = true
    @State private var performance = ""
    @State private var issues = ""

    private var game: Game { prompt.game }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 28)).foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Did \(game.name) run well?").font(.headline)
                    Text("You played for \(prompt.minutes) minutes with settings that aren't on Corkscrew's tested list. "
                         + "Share them, and after a check they're added to the list, so other players start with them.")
                        .font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(settingLines, id: \.self) { Text($0) }
            }
            .font(.body)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: .rect(cornerRadius: 8))

            Picker("Result", selection: $playsWell) {
                Text("Plays well").tag(true)
                Text("Plays, with issues").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            TextField("In-game settings, resolution and frame rate (optional)", text: $performance, axis: .vertical)
                .lineLimit(1...3)
                .textFieldStyle(.roundedBorder)
            if !playsWell {
                TextField("What doesn't work, and what helped (optional)", text: $issues, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.roundedBorder)
            }

            Text("Share on GitHub opens a new Game report on Corkscrew's GitHub page with this filled in. "
                 + "GitHub issues are public; the report has the game, these settings, and your Mac and macOS.")
                .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Not Now", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Share on GitHub…") { share() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    /// The shared settings, as Settings names them.
    private var settingLines: [String] {
        let profile = Steam.sharedProfile(of: game)
        var lines = ["Graphics: \(profile.backendOverride?.displayName ?? "Automatic")",
                     "MetalFX: \(profile.metalFX ? "on" : "off")   Retina mode: \(profile.retinaMode ? "on" : "off")   "
                         + "AVX: \(profile.advertiseAVX ? "on" : "off")   Steam overlay: \(profile.steamOverlay ? "on" : "off")"]
        if !profile.arguments.isEmpty { lines.append("Arguments: \(profile.arguments.joined(separator: " "))") }
        if !profile.environment.isEmpty {
            lines.append("Environment: " + profile.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        }
        return lines
    }

    private func share() {
        let form = model.formVersionAndMac()
        if let url = Steam.shareURL(of: game, repository: AboutPanel.source, playsWell: playsWell, performance: performance,
                                    issues: playsWell ? "" : issues, version: form.version, mac: form.mac) {
            NSWorkspace.shared.open(url)
        }
        dismiss()
    }
}
