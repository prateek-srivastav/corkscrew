import GameCore
import SwiftUI

struct BottlesView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Bottle.ID?
    @State private var isCreating = false
    @State private var bottleToReset: Bottle?
    @State private var bottleForSteam: Bottle?
    @State private var bottleToDelete: Bottle?

    var body: some View {
        List(selection: $selection) {
            ForEach(model.bottles) { bottle in
                BottleRow(bottle: bottle)
                    .contextMenu { actions(for: bottle) }
            }
        }
        .overlay {
            if model.bottles.isEmpty {
                ContentUnavailableView("No bottles", systemImage: "shippingbox",
                                       description: Text("A bottle is a Windows drive with its own settings and programs."))
            }
        }
        .navigationTitle("Bottles")
        .toolbar {
            ToolbarItemGroup {
                Button("Add Existing Bottle…", systemImage: "square.and.arrow.down") {
                    if let folder = Pickers.folder("Choose a bottle folder (it holds bottle.json and prefix).") {
                        model.importBottle(from: folder)
                    }
                }
                Button("New Bottle…", systemImage: "plus") { isCreating = true }
                    .disabled(model.runtimes.isEmpty)
            }
        }
        .inspector(isPresented: Binding(get: { selectedBottle != nil }, set: { if !$0 { selection = nil } })) {
            if let bottle = selectedBottle {
                BottleDetail(bottle: bottle, reset: { bottleToReset = bottle }, installSteam: { installSteam(into: bottle) },
                             delete: { bottleToDelete = bottle })
                    .inspectorColumnWidth(min: 280, ideal: 320)
                    .inspectorCloseButton { selection = nil }
            }
        }
        .sheet(isPresented: $isCreating) { NewBottleSheet() }
        .confirmationDialog("Reset \(bottleToReset?.name ?? "") to its clean state?",
                            isPresented: Binding(get: { bottleToReset != nil }, set: { if !$0 { bottleToReset = nil } }),
                            presenting: bottleToReset) { bottle in
            Button("Reset", role: .destructive) { model.resetToClean(bottle) }
        } message: { bottle in
            Text("Everything installed or saved in it since it was created is discarded, and running programs are stopped."
                 + (model.hasSteam(in: bottle) ? " Steam and its games are removed too." : ""))
        }
        .confirmationDialog("Delete \(bottleToDelete?.name ?? "")?",
                            isPresented: Binding(get: { bottleToDelete != nil }, set: { if !$0 { bottleToDelete = nil } }),
                            presenting: bottleToDelete) { bottle in
            Button("Move to Trash", role: .destructive) { model.delete(bottle) }
        } message: { bottle in
            Text(deleteMessage(for: bottle))
        }
        .confirmationDialog("Install Steam into \(bottleForSteam?.name ?? "")?",
                            isPresented: Binding(get: { bottleForSteam != nil }, set: { if !$0 { bottleForSteam = nil } }),
                            presenting: bottleForSteam) { bottle in
            Button("Install Steam") { Task { await model.installSteam(into: bottle) } }
        } message: { bottle in
            Text(IsolatedSteam.warning + (bottle.isolation.allowNetwork ? "" : " Steam needs the internet, so it's turned on for this bottle."))
        }
    }

    private var selectedBottle: Bottle? { model.bottles.first { $0.id == selection } }

    @ViewBuilder
    private func actions(for bottle: Bottle) -> some View {
        Button("Run Program…") { runProgram(in: bottle) }
        Button("Show C: Drive in Finder") { NSWorkspace.shared.open(model.driveC(of: bottle)) }
        if !model.hasSteam(in: bottle) {
            Button(bottle.kind == .isolated ? "Install Steam…" : "Install Steam") { installSteam(into: bottle) }
                .disabled(model.steamInstalls.contains(bottle.id))
        }
        if model.runningBottles.contains(bottle.id) {
            Button("Stop Everything in It") { model.stop(bottle) }
        }
        Divider()
        if bottle.kind == .isolated {
            Button("Reset to Clean…", role: .destructive) { bottleToReset = bottle }
        }
        Button("Delete Bottle…", role: .destructive) { bottleToDelete = bottle }
    }

    private func deleteMessage(for bottle: Bottle) -> String {
        let games = model.games.filter { $0.bottleID == bottle.id }.count
        return "Running programs are stopped. Its Windows drive goes to the Trash with everything installed or saved in it"
            + (model.hasSteam(in: bottle) ? ", Steam and its games included" : "")
            + (games > 0 ? ", and its \(games) \(games == 1 ? "game leaves" : "games leave") the Library" : "")
            + ". Until you empty the Trash, Add Existing Bottle… brings it back."
    }

    /// Isolated bottles ask first: Steam's sign-in is then readable by everything in them.
    private func installSteam(into bottle: Bottle) {
        if bottle.kind == .isolated {
            bottleForSteam = bottle
        } else {
            Task { await model.installSteam(into: bottle) }
        }
    }

    private func runProgram(in bottle: Bottle) {
        model.open(Pickers.programs(), in: bottle)
    }
}

private struct BottleRow: View {
    @Environment(AppModel.self) private var model
    let bottle: Bottle

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: bottle.kind == .isolated ? "lock.shield.fill" : "shippingbox.fill")
                .font(.title2)
                .foregroundStyle(bottle.kind == .isolated ? Color.orange : Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(bottle.name).font(.headline)
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.runningBottles.contains(bottle.id) {
                Label("Running", systemImage: "circle.fill").labelStyle(.titleAndIcon).font(.caption)
                    .foregroundStyle(.green)
            }
        }
        .padding(.vertical, 4)
    }

    private var summary: String {
        let games = model.games.filter { $0.bottleID == bottle.id }.count
        let kind = bottle.kind == .isolated
            ? "Isolated, " + (bottle.isolation.allowNetwork ? "internet on" : "offline")
            : "Standard, internet on"
        let steam = model.hasSteam(in: bottle) ? " · Steam" : ""
        return "\(kind)\(steam) · \(games) \(games == 1 ? "game" : "games")"
    }
}

private struct BottleDetail: View {
    @Environment(AppModel.self) private var model
    let bottle: Bottle
    let reset: () -> Void
    let installSteam: () -> Void
    let delete: () -> Void

    var body: some View {
        Form {
            Section {
                LabeledContent("Kind", value: bottle.kind == .isolated ? "Isolated (macOS sandbox)" : "Standard")
                if bottle.kind == .isolated {
                    LabeledContent("Internet", value: bottle.isolation.allowNetwork ? "Allowed" : "Blocked")
                    LabeledContent("Clipboard", value: bottle.isolation.allowClipboard ? "Allowed" : "Blocked")
                } else {
                    LabeledContent("Internet", value: "Allowed")
                }
                LabeledContent("Windows", value: bottle.windowsVersion.rawValue)
                LabeledContent("Runtime", value: bottle.engineID)
                LabeledContent("Created", value: bottle.createdAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Status", value: model.runningBottles.contains(bottle.id) ? "Running" : "Idle")
            }
            if bottle.kind == .isolated {
                Section {
                    Text("Programs here can't see your files, other apps or (unless allowed) the internet. "
                         + "Keep it offline, don't sign into accounts in it, and reset it after use. "
                         + "No sandbox is perfect: macOS or GPU driver bugs can still be exploited.")
                        .font(.callout).foregroundStyle(.secondary)
                    if model.hasSteam(in: bottle) {
                        Label(IsolatedSteam.warning, systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange)
                    }
                }
            }
            Section {
                Button("Run Program…") { model.open(Pickers.programs(), in: bottle) }
                Button("Show C: Drive in Finder") { NSWorkspace.shared.open(model.driveC(of: bottle)) }
                if model.steamInstalls.contains(bottle.id) {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Installing Steam…")
                    }
                } else if !model.hasSteam(in: bottle) {
                    Button(bottle.kind == .isolated ? "Install Steam…" : "Install Steam", action: installSteam)
                }
                Button("Stop Everything in It") { model.stop(bottle) }
                    .disabled(!model.runningBottles.contains(bottle.id))
                if bottle.kind == .isolated {
                    Button("Reset to Clean…", role: .destructive, action: reset)
                }
                Button("Delete Bottle…", role: .destructive, action: delete)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(bottle.name)
    }
}

struct NewBottleSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var kind = Bottle.Kind.standard
    @State private var allowNetwork = false
    @State private var installSteam = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Bottle").font(.title2.weight(.semibold))
            Form {
                TextField("Name", text: $name, prompt: Text(kind == .isolated ? "Untrusted" : "Games"))
                Picker("Kind", selection: $kind) {
                    Text("Standard").tag(Bottle.Kind.standard)
                    Text("Isolated").tag(Bottle.Kind.isolated)
                }
                .pickerStyle(.segmented)
                if kind == .isolated {
                    Toggle("Allow internet", isOn: Binding(get: { allowNetwork || installSteam }, set: { allowNetwork = $0 }))
                        .disabled(installSteam)
                    Text("For programs you don't trust, like installers from unknown sites. They run in a macOS sandbox "
                         + "that hides your files and other apps.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("For games and launchers like Steam. Programs here can read your files, as on Windows.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Install Steam", isOn: $installSteam)
                if kind == .isolated && installSteam {
                    Label(IsolatedSteam.warning + " Steam needs the internet, so it's on.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    let trimmed = name.trimmingCharacters(in: .whitespaces)
                    model.createBottle(name: trimmed.isEmpty ? (kind == .isolated ? "Untrusted" : "Games") : trimmed,
                                       kind: kind, allowNetwork: kind == .isolated && (allowNetwork || installSteam),
                                       installSteam: installSteam)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

/// What signing into Steam inside an isolated bottle gives away.
private enum IsolatedSteam {
    static let warning = "Programs in this bottle can read Steam's sign-in and, with internet on, send it out. "
        + "Sign in with a second Steam account, not your main one. Reset to Clean removes Steam and its games."
}
