import GameCore
import SwiftUI

/// Add Program: where the program goes, and its file. Add Program opens it with the page's bottle
/// selected and asks for the file; a program opened from Finder or dropped comes with its file. A
/// program (.exe, .msi) runs once or goes in the library; a download (zip, rar, 7z, disc image)
/// goes to the installer.
struct OpenProgramSheet: View {
    @Environment(AppModel.self) private var model
    let request: AppModel.OpenRequest
    @State private var file: URL?
    @State private var bottleID: Bottle.ID?
    @State private var name = ""
    @State private var inspection: GameInspection?
    @State private var inspectionError: String?
    @State private var icon: NSImage?
    /// A picked download: its parts (one unless it was split) and their size.
    @State private var download: (parts: [URL], size: Int64)?
    @State private var original = ProgramInstaller.Job.Original.copy
    @State private var fileError: String?

    private var isProgram: Bool { file.map { ["exe", "msi"].contains($0.pathExtension.lowercased()) } ?? false }

    var body: some View {
        let bottle = model.programBottles.first { $0.id == bottleID }
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add Program").font(.title2.weight(.bold))
                Text("An .exe, .msi, .zip, .rar, .7z or .iso file.")
                    .foregroundStyle(.secondary)
            }

            field("Install into") {
                Picker("Install into", selection: $bottleID) {
                    ForEach(model.programBottles) { bottle in
                        Text(bottle.kind == .isolated ? "\(bottle.name) (protected)" : bottle.name).tag(Optional(bottle.id))
                    }
                }
                .labelsHidden()
                .fixedSize()
                if let bottle {
                    Text(summary(of: bottle)).font(.subheadline).foregroundStyle(.secondary)
                }
            }

            field("File") {
                FileField(file: file, icon: icon) {
                    if let picked = Pickers.program() { use(picked) }
                }
                if let fileError {
                    Label(fileError, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }

            if isProgram { program(in: bottle) }
            if let download, let file {
                OriginalChoice(original: $original, isDiscImage: download.parts.count == 1 && Archive.isDiscImage(file),
                               size: download.size, freeSpace: model.installer.freeSpace)
            }
            if model.programBottles.isEmpty {
                Label("Set up Corkscrew in Settings first.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }

            buttons(bottle)
        }
        .padding(24)
        .frame(width: 520)
        .onAppear {
            bottleID = model.openBottle(for: request)?.id
            if let program = request.program { use(program) }
        }
        .task(id: file) { await inspect() }
    }

    /// A program's name in the library, what Corkscrew found in it, and the copy an isolated bottle needs.
    @ViewBuilder
    private func program(in bottle: Bottle?) -> some View {
        field("Name in Library") {
            TextField("Name in Library", text: $name)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
            if let inspection {
                Text("Graphics: \(inspection.recommendedBackend.displayName) · CPU: \(inspection.machine.description)")
                    .font(.subheadline).foregroundStyle(.secondary)
                ForEach(inspection.antiCheat, id: \.evidence) { finding in
                    Label("\(finding.kind.rawValue): "
                          + (finding.severity == .blocksLaunch ? "this game won't run under Wine." : "online play may not work."),
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(finding.severity == .blocksLaunch ? .red : .orange)
                }
            } else if let inspectionError {
                Label(inspectionError, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        }
        if let bottle, let file, model.needsImport(file, into: bottle) {
            HStack(spacing: 6) {
                Label("The program is copied into the bottle first.", systemImage: "lock.shield")
                InfoButton(text: "A protected bottle only sees its own C: drive, so the program (and files next to it named like it) "
                    + "is copied into the bottle's Downloads folder. A program made of many files should be installed inside the bottle instead.")
            }
            .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private func buttons(_ bottle: Bottle?) -> some View {
        HStack {
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            if download != nil {
                Button("Install") {
                    guard let bottle, let file else { return }
                    let original = original
                    dismiss()
                    model.installer.enqueue([file], bottle: bottle, original: original)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(bottle == nil)
            } else {
                if isProgram {
                    Button("Run Once") {
                        guard let bottle, let file else { return }
                        dismiss()
                        Task { await model.runOnce(file, bottle: bottle) }
                    }
                    .disabled(bottle == nil)
                }
                Button("Add to Library") {
                    guard let bottle, let file else { return }
                    let name = name.trimmingCharacters(in: .whitespaces)
                    dismiss()
                    Task { await model.addToLibrary(file, bottle: bottle, name: name.isEmpty ? nil : name) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(bottle == nil || !isProgram)
            }
        }
        .padding(.top, 4)
    }

    private func field(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title)
            content()
        }
    }

    /// What programs in the bottle can reach.
    private func summary(of bottle: Bottle) -> String {
        let online = bottle.kind == .standard || bottle.isolation.allowNetwork
        return (bottle.kind == .isolated ? "Programs here can't see your files or other apps." : "Programs here can read your files, as on Windows.")
            + (online ? " Internet on." : " No internet.")
    }

    /// Takes the picked file: a program to inspect, or a download for the installer.
    private func use(_ picked: URL) {
        file = picked
        fileError = nil
        download = nil
        inspection = nil
        inspectionError = nil
        icon = nil
        if isProgram {
            name = Game.defaultName(for: picked)
            icon = (try? PEFile.icon(contentsOf: picked)).flatMap { $0 }.flatMap(NSImage.init(data:))
        } else if Archive.isArchive(picked) {
            do {
                let parts = try Archive.parts(of: picked)
                download = (parts, Archive.size(of: parts))
            } catch {
                fileError = "\(picked.lastPathComponent): \(AppModel.describe(error))"
            }
        } else {
            fileError = "Only .exe, .msi, .zip, .rar, .7z and .iso files."
        }
    }

    private func inspect() async {
        guard let program = file, program.pathExtension.lowercased() == "exe" else { return }
        do {
            let found = try await Task.detached { try GameDetector.inspect(executable: program) }.value
            // Another file may be picked by now.
            if file == program { inspection = found }
        } catch {
            if file == program { inspectionError = "This doesn't look like a Windows program (\(AppModel.describe(error)))." }
        }
    }

    /// Moves on to the next opened program, if any.
    private func dismiss() {
        model.closeOpenRequest(request)
    }
}

/// The file to add; a click opens the file panel.
private struct FileField: View {
    let file: URL?
    let icon: NSImage?
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Group {
                    if let file {
                        Image(nsImage: icon ?? NSWorkspace.shared.icon(forFile: file.path)).resizable().interpolation(.high)
                    } else {
                        Image(systemName: "doc.badge.plus")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file?.lastPathComponent ?? "Choose a File")
                        .font(.headline).lineLimit(1).truncationMode(.middle)
                    Text(file.map { $0.deletingLastPathComponent().path(percentEncoded: false) } ?? "Click to find it on your Mac.")
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Text(file == nil ? "Choose…" : "Change…")
                    .foregroundStyle(isHovering ? .primary : .secondary)
            }
            .padding(12)
            .contentShape(.rect)
            .background(isHovering ? Theme.surfaceHover : Theme.surface, in: .rect(cornerRadius: Theme.cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                    .strokeBorder(file == nil ? Color.accentColor.opacity(0.6) : Theme.stroke)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}
