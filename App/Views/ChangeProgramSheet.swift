import GameCore
import SwiftUI

/// Change Program (.exe): which program starts a game. Lists its program and the others in its
/// folder; Choose Another… takes any program in the game's bottle.
struct ChangeProgramSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let game: Game
    @State private var programs: [URL] = []
    @State private var selection: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Change Program (.exe)").font(.headline)
            Text("Corkscrew starts this program when you play \(game.name). Some games must start through another program in their folder, such as a launcher.")
                .font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            Picker("Program", selection: $selection) {
                ForEach([game.executable] + programs, id: \.self) { program in
                    Text(name(of: program)).tag(Optional(program)).help(program.path)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            HStack {
                Button("Choose Another…") {
                    guard let program = model.chooseProgram(for: game) else { return }
                    if program != game.executable, !programs.contains(program) { programs.append(program) }
                    selection = program
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Use Program") {
                    if let selection { model.changeProgram(of: game, to: selection) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil || selection == game.executable)
            }
        }
        .padding(20)
        .frame(width: 480)
        .task {
            selection = game.executable
            let executable = game.executable
            // A long list doesn't fit the sheet; Choose Another… finds the rest.
            programs = await Task.detached(priority: .userInitiated) { Array(SetupFinder.otherPrograms(near: executable).prefix(10)) }.value
        }
    }

    /// The program's name, with its folder when it isn't next to the game's program.
    private func name(of program: URL) -> String {
        program.deletingLastPathComponent() == game.executable.deletingLastPathComponent()
            ? program.lastPathComponent : "\(program.deletingLastPathComponent().lastPathComponent)\\\(program.lastPathComponent)"
    }
}
