import GameCore
import SwiftUI

struct BottlesView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Bottle.ID?
    @State private var isCreating = false
    @State private var bottleToReset: Bottle?
    @State private var bottleForSteam: Bottle?
    @State private var bottleToDelete: Bottle?

    private let columns = [GridItem(.adaptive(minimum: 280, maximum: 420), spacing: 18, alignment: .top)]

    var body: some View {
        ScrollView {
            Group {
                if model.bottles.isEmpty {
                    ContentUnavailableView("No bottles", systemImage: "shippingbox",
                                           description: Text("A bottle is a Windows drive with its own settings and programs."))
                        .padding(.top, 60)
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                        ForEach(model.bottles) { bottle in
                            BottleCard(bottle: bottle, isSelected: selection == bottle.id)
                                .onTapGesture { selection = selection == bottle.id ? nil : bottle.id }
                                .contextMenu { actions(for: bottle) }
                        }
                    }
                }
            }
            .pageHeader("Bottles", subtitle: "Windows drives, each with its own settings and programs.") {
                BusyButton("Add Existing…", systemImage: "square.and.arrow.down", busyTitle: "Adding…",
                           isBusy: model.isPending(.importBottle)) {
                    if let folder = Pickers.folder("Choose a bottle folder (it holds bottle.json and prefix).") {
                        model.importBottle(from: folder)
                    }
                }
                .buttonStyle(.pill)
                .help("Add Existing Bottle…")
                BusyButton("New Bottle…", systemImage: "plus", busyTitle: "Creating…", isBusy: model.isPending(.createBottle)) {
                    isCreating = true
                }
                .buttonStyle(.prominentPill)
                    .disabled(model.runtimes.isEmpty)
            }
            .padding(.horizontal, 40)
            .padding(.top, 52)
            .padding(.bottom, 40)
        }
        .ignoresSafeArea(.container, edges: .top)
        .sidePanel(isPresented: selectedBottle != nil, title: selectedBottle?.name ?? "", close: { selection = nil }) {
            if let bottle = selectedBottle {
                BottleDetail(bottle: bottle, reset: { bottleToReset = bottle }, installSteam: { installSteam(into: bottle) },
                             delete: { bottleToDelete = bottle })
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
        // The Steam bottle only has Steam's games.
        if bottle.role != .steam {
            Button("Run Program…") { runProgram(in: bottle) }
        }
        Button("Show C: Drive in Finder") { NSWorkspace.shared.open(model.driveC(of: bottle)) }
        if !model.hasSteam(in: bottle) {
            busyItem(bottle.kind == .isolated ? "Install Steam…" : "Install Steam", "Installing Steam…",
                     model.steamInstalls.contains(bottle.id)) { installSteam(into: bottle) }
        }
        if model.runningBottles.contains(bottle.id) {
            busyItem("Stop Everything in It", "Stopping…", model.isPending(.stopBottle(bottle.id))) { model.stop(bottle) }
        }
        if bottle.kind == .isolated || bottle.role == nil { Divider() }
        if bottle.kind == .isolated {
            busyItem("Reset to Clean…", "Resetting…", model.isPending(.resetBottle(bottle.id))) { bottleToReset = bottle }
        }
        // Setup's bottles (Steam, Offline and Online Programs) stay; Reset to Clean empties a protected one.
        if bottle.role == nil {
            busyItem("Delete Bottle…", "Moving to Trash…", model.isPending(.deleteBottle(bottle.id))) { bottleToDelete = bottle }
        }
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

private struct BottleCard: View {
    @Environment(AppModel.self) private var model
    let bottle: Bottle
    let isSelected: Bool
    @State private var isHovering = false

    var body: some View {
        let isolated = bottle.kind == .isolated
        let tint = isolated ? Theme.isolated : Color.accentColor
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                Image(systemName: isolated ? "lock.shield.fill" : "shippingbox.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 48, height: 48)
                    .background(tint.opacity(0.16), in: .rect(cornerRadius: Theme.cornerRadius))
                Spacer()
                if model.runningBottles.contains(bottle.id) {
                    Chip(title: "Running", systemImage: "circle.fill", tint: Theme.running)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(bottle.name).font(.title3.weight(.bold)).lineLimit(1)
                Text(summary).font(.body).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHovering || isSelected ? Theme.surfaceHover : Theme.surface, in: .rect(cornerRadius: Theme.cornerRadius))
        .background(alignment: .topTrailing) {
            Circle().fill(tint.opacity(0.18)).frame(width: 160, height: 160).blur(radius: 50).offset(x: 30, y: -50)
        }
        .clipShape(.rect(cornerRadius: Theme.cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cornerRadius).strokeBorder(isSelected ? Color.white : Theme.stroke, lineWidth: isSelected ? 2 : 1)
        }
        .contentShape(.rect(cornerRadius: Theme.cornerRadius))
        .onHover { isHovering = $0 }
        .animation(.snappy(duration: 0.15), value: isHovering)
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
                if bottle.role != nil {
                    LabeledContent("Made by", value: "Setup")
                }
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
                        .font(.body).foregroundStyle(.secondary)
                    if model.hasSteam(in: bottle) {
                        Label(IsolatedSteam.warning, systemImage: "exclamationmark.triangle")
                            .font(.body).foregroundStyle(.orange)
                    }
                }
            }
            Section {
                if bottle.role != .steam {
                    Button("Run Program…") { model.open(Pickers.programs(), in: bottle) }
                }
                Button("Show C: Drive in Finder") { NSWorkspace.shared.open(model.driveC(of: bottle)) }
                if model.steamInstalls.contains(bottle.id) {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Installing Steam…")
                    }
                } else if !model.hasSteam(in: bottle) {
                    Button(bottle.kind == .isolated ? "Install Steam…" : "Install Steam", action: installSteam)
                }
                BusyButton("Stop Everything in It", busyTitle: "Stopping…", isBusy: model.isPending(.stopBottle(bottle.id))) {
                    model.stop(bottle)
                }
                .disabled(!model.runningBottles.contains(bottle.id))
                if bottle.kind == .isolated {
                    BusyButton("Reset to Clean…", busyTitle: "Resetting…", isBusy: model.isPending(.resetBottle(bottle.id)), action: reset)
                        .foregroundStyle(.red)
                }
                if bottle.role == nil {
                    BusyButton("Delete Bottle…", busyTitle: "Moving to Trash…", isBusy: model.isPending(.deleteBottle(bottle.id)), action: delete)
                        .foregroundStyle(.red)
                }
            }
        }
        .panelForm()
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
            Text("New Bottle").font(.title2.weight(.bold))
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
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    Text("For games and launchers like Steam. Programs here can read your files, as on Windows.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Toggle("Install Steam", isOn: $installSteam)
                if kind == .isolated && installSteam {
                    Label(IsolatedSteam.warning + " Steam needs the internet, so it's on.", systemImage: "exclamationmark.triangle")
                        .font(.subheadline).foregroundStyle(.orange)
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
