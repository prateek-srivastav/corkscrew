import GameCore
import SwiftUI

/// Quitting found games running, whose bottles Corkscrew can't stop cleanly. Show opens a game's
/// page (where it runs); Force Quit stops them and quits; ✕ or Esc stays.
struct QuitBlockedSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigator.self) private var navigator
    @Environment(\.dismiss) private var dismiss
    let games: [Game]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetHeader(
                systemImage: "exclamationmark.triangle.fill", tint: .orange,
                title: games.count == 1 ? "\(games[0].name) is still running" : "\(games.count) games are still running",
                message: "Corkscrew can't quit cleanly while \(games.count == 1 ? "it runs" : "they run"). Quit from inside the game "
                    + "first, or Force Quit to stop \(games.count == 1 ? "it" : "them") now: unsaved progress is lost.",
                closeHelp: "Don't quit")

            VStack(spacing: 6) {
                ForEach(games) { game in
                    HStack(spacing: 10) {
                        GameIcon(game: game, size: 28)
                        Text(game.name).lineLimit(1)
                        Spacer()
                        Button("Show") { show(game) }
                    }
                    .padding(8)
                    .background(Theme.surface, in: .rect(cornerRadius: 8))
                }
            }

            HStack {
                Spacer()
                Button("Force Quit", role: .destructive) { model.forceQuit() }
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func show(_ game: Game) {
        dismiss()
        navigator.go(library: .game(game.id, from: .all))
    }
}
