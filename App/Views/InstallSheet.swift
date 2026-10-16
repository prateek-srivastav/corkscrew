import GameCore
import SwiftUI
import UniformTypeIdentifiers

/// Installs a download step by step: where it goes and what happens to the file, unpacking, the
/// disc image question, the setup, and which program starts the game.
struct InstallSheet: View {
    @Environment(AppModel.self) private var model
    @State private var candidate: SetupFinder.Candidate?
    @State private var program: URL?
    @State private var name = ""
    @State private var confirmsCancel = false
    @State private var mountsDisc = true

    private var installer: ProgramInstaller { model.installer }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let job = installer.job {
                header(job)
                if let note = job.note {
                    Label(note, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                step(job)
            }
        }
        .padding(20)
        .frame(width: 540)
        .interactiveDismissDisabled()
        .confirmationDialog("Stop installing?", isPresented: $confirmsCancel) {
            Button("Stop and Delete Setup Files", role: .destructive) { installer.cancel() }
            Button("Keep Installing", role: .cancel) {}
        } message: {
            Text("You chose Move, so your download is already deleted. The setup files go too: to try again, you'd need to download it again.")
        }
    }

    private func header(_ job: ProgramInstaller.Job) -> some View {
        HStack(spacing: 12) {
            // By type, not file: with Move the file is gone after unpacking.
            Image(nsImage: NSWorkspace.shared.icon(for: UTType(filenameExtension: job.source.pathExtension) ?? .data))
                .resizable().frame(width: 48, height: 48)
            VStack(alignment: .leading) {
                Text("Install \(job.name)").font(.headline)
                Text(job.parts.count > 1 ? "\(job.parts.count) parts, \(bytes(job.size))" : "\(job.source.lastPathComponent), \(bytes(job.size))")
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
    }

    @ViewBuilder
    private func step(_ job: ProgramInstaller.Job) -> some View {
        switch job.step {
        case .choose: choose(job)
        case .unpacking(let fraction):
            working("Unpacking… \(Int(fraction * 100))%", fraction: fraction,
                    detail: "Big games take a while. You can hide this window: Corkscrew keeps going.")
            buttons { cancelButton(job); Spacer(); hideButton }
        case .disc(let images): disc(images, job: job)
        case .preparingDisc(let mounting):
            working(mounting ? "Putting the disc in the drive…" : "Copying the files out of the disc image…", fraction: nil,
                    detail: mounting ? nil : "Big disc images take a while. You can hide this window: Corkscrew keeps going.")
            buttons { cancelButton(job); Spacer(); if !mounting { hideButton } }
        case .pickSetup(let candidates): pickSetup(candidates, job: job)
        case .runningSetup:
            working("The setup is running", fraction: nil,
                    detail: "Follow the steps in the setup's window. Keep the install folder it suggests. "
                        + "When the setup closes, Corkscrew deletes the setup files and asks which program starts the game.")
            buttons {
                cancelButton(job)
                Spacer()
                hideButton
                Button("Setup Is Finished") { installer.setupIsDone() }
                    .help("The setup's window is closed, but Corkscrew still waits")
            }
        case .pickProgram(let programs): pickProgram(programs)
        case .finishing:
            working("Deleting the setup files…", fraction: nil, detail: nil)
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon").foregroundStyle(.red)
            buttons { Spacer(); Button("Close") { installer.cancel() }.keyboardShortcut(.defaultAction) }
        }
    }

    // MARK: Steps

    @ViewBuilder
    private func choose(_ job: ProgramInstaller.Job) -> some View {
        Form {
            Picker("Install into", selection: Binding(get: { job.bottleID }, set: { installer.setBottle($0) })) {
                ForEach(model.programBottles) { bottle in
                    Text(bottle.kind == .isolated ? "\(bottle.name) (protected)" : bottle.name).tag(Optional(bottle.id))
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 70)

        SectionLabel("Your file")
        Option(title: "Copy", systemImage: "doc.on.doc", isSelected: job.original == .copy,
               text: job.isDiscImage
                   ? "Your disc image stays where it is. Corkscrew only reads it."
                   : "Your file stays where it is. Corkscrew unpacks what's inside into the bottle, so you need room for both.") {
            installer.setOriginal(.copy)
        }
        Option(title: "Move", systemImage: "arrow.right.doc.on.clipboard", isSelected: job.original == .move,
               text: job.isDiscImage
                   ? "Corkscrew uses your disc image, then deletes it when the setup is done. Saves space; to install again, you'd need to download it again."
                   : "Corkscrew deletes your file as soon as it's unpacked, to free the space. Best for big games; to install again, you'd need to download it again.") {
            installer.setOriginal(.move)
        }
        spaceNote(job)

        buttons {
            cancelButton(job)
            Spacer()
            Button("Install") { installer.start() }
                .keyboardShortcut(.defaultAction)
                .disabled(installer.bottle == nil)
        }
    }

    @ViewBuilder
    private func spaceNote(_ job: ProgramInstaller.Job) -> some View {
        if let free = installer.freeSpace {
            // Unpacked, a download takes about its own size (games inside are compressed); the installed game as much again.
            let needed = job.isDiscImage ? job.size : job.size * 2
            let tight = free < needed
            Label("\(bytes(free)) free. " + (job.isDiscImage
                    ? "The installed game needs about \(bytes(job.size))."
                    : "Unpacking needs about \(bytes(job.size)), and the installed game about as much again."),
                  systemImage: tight ? "exclamationmark.triangle" : "internaldrive")
                .font(.subheadline)
                .foregroundStyle(tight ? .orange : .secondary)
        }
    }

    @ViewBuilder
    private func disc(_ images: [URL], job: ProgramInstaller.Job) -> some View {
        Text(images.count == 1
             ? "\(job.isDiscImage ? "This is" : "This download has") a disc image: \(images[0].lastPathComponent)."
             : "This download has \(images.count) disc images: \(images.map(\.lastPathComponent).joined(separator: ", ")).")
            .font(.body)
        Option(title: "Use the disc image (recommended)", systemImage: "opticaldisc", isSelected: mountsDisc,
               text: "Corkscrew puts the disc image in the bottle's drive, like a DVD, and runs the setup from it. "
                   + "Fast, and needs no extra space. After the setup, the disc comes out again. "
                   + "A few old games ask for their disc every time they start; those won't start then.") {
            mountsDisc = true
        }
        Option(title: "Unpack the disc image", systemImage: "square.and.arrow.down.on.square", isSelected: !mountsDisc,
               text: "Corkscrew copies every file out of the disc image first, then runs the setup from those files. "
                   + "Slower, and needs as much free space again as the disc image, until the setup is done. "
                   + "Choose this when the setup doesn't work with the disc image.") {
            mountsDisc = false
        }
        buttons {
            cancelButton(job)
            Spacer()
            Button("Continue") { installer.useDiscs(images, mount: mountsDisc) }.keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder
    private func pickSetup(_ candidates: [SetupFinder.Candidate], job: ProgramInstaller.Job) -> some View {
        let picked = candidate.flatMap { candidates.contains($0) ? $0 : nil } ?? candidates[0]
        Text(picked.isSetup
             ? "Corkscrew runs the setup once. Follow its steps and keep the install folder it suggests. "
                + "When it's done, Corkscrew deletes the setup files and adds the game to your library."
             : "There's no setup in this download: it's the game itself. Corkscrew keeps its files in the bottle "
                + "(in C:\\Games) and adds the game to your library.")
            .font(.body)
        Form {
            Picker(picked.isSetup ? "Setup" : "Program", selection: Binding(get: { picked }, set: { candidate = $0 })) {
                ForEach(candidates) { item in
                    Text(installer.displayPath(of: item.url) + (item.isSetup ? "" : "  (the game)")).tag(item)
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 70)
        buttons {
            cancelButton(job)
            Spacer()
            Button(picked.isSetup ? "Run Setup" : "Add to Library") { installer.choose(picked) }
                .keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder
    private func pickProgram(_ programs: [URL]) -> some View {
        let picked = program.flatMap { programs.contains($0) ? $0 : nil } ?? programs.first
        if let picked {
            Text("The setup is done. Pick the program that starts the game; the setup files are deleted then.").font(.body)
            Form {
                Picker("Program", selection: Binding(get: { picked }, set: { program = $0; name = Game.defaultName(for: $0) })) {
                    ForEach(programs, id: \.self) { item in Text(installer.displayPath(of: item)).tag(item) }
                }
                TextField("Name in Library", text: $name)
            }
            .formStyle(.grouped)
            .frame(height: 110)
            .onAppear { if name.isEmpty { name = Game.defaultName(for: picked) } }
        }
        buttons {
            Menu("More") {
                Button("Run the Setup Again") { installer.runSetupAgain() }
                Button("Choose Another Program…") { installer.chooseProgram() }
                Divider()
                Button("Finish Without Adding") { installer.finishWithoutAdding() }
            }
            .fixedSize()
            Spacer()
            if let picked {
                Button("Add to Library") { installer.add(picked, name: name.trimmingCharacters(in: .whitespaces)) }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Choose Program…") { installer.chooseProgram() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Parts

    private func working(_ title: String, fraction: Double?, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if fraction == nil { ProgressView().controlSize(.small) }
                Text(title).font(.headline)
            }
            if let fraction { ProgressView(value: fraction) }
            if let detail { Text(detail).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }

    private func buttons<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack { content() }.padding(.top, 4)
    }

    private func cancelButton(_ job: ProgramInstaller.Job) -> some View {
        Button("Cancel", role: .cancel) { job.originalDeleted ? (confirmsCancel = true) : installer.cancel() }
            .keyboardShortcut(.cancelAction)
    }

    private var hideButton: some View {
        Button("Hide") { installer.hide() }.help("Corkscrew keeps going; click the bar at the bottom to come back")
    }

    private func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }
}

/// A choice with a short explanation of what it means.
private struct Option: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let text: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .font(.system(size: Theme.controlIconSize))
                VStack(alignment: .leading, spacing: 4) {
                    Label(title, systemImage: systemImage).font(.headline)
                    Text(text).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .contentShape(.rect)
            .background(isSelected ? Theme.surfaceHover : Theme.surface, in: .rect(cornerRadius: Theme.cornerRadius))
        }
        .buttonStyle(.plain)
    }
}
