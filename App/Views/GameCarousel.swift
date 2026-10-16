import GameCore
import SwiftUI

/// The top of a page of games: one game after another, only its art and name. A click on the name
/// opens the game's page. Moves on by itself every few seconds, except while the pointer is over
/// it or another app (a game) is in front. The page draws the game's art behind it, from `current`.
struct GameCarousel: View {
    let games: [Game]
    @Binding var current: Game.ID?
    let open: (Game) -> Void
    @State private var isHovering = false
    @Environment(\.controlActiveState) private var activeState

    static var interval: Duration { .seconds(8) }

    var body: some View {
        let index = games.firstIndex { $0.id == current } ?? 0
        let game = games[min(index, games.count - 1)]
        HStack(alignment: .bottom, spacing: 24) {
            SteamArt(game: game, kind: .logo, contentMode: .fit, maxSize: CGSize(width: 440, height: 150)) {
                Text(game.name)
                    .font(.system(size: 56, weight: .heavy))
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .shadow(color: .black.opacity(0.5), radius: 12)
            }
            .frame(maxWidth: 560, alignment: .bottomLeading)
            .contentShape(.rect)
            .onTapGesture { open(game) }
            .pointerStyle(.link)
            .help("Open \(game.name)")
            .id(game.id)
            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 24)), removal: .opacity))
            Spacer(minLength: 0)
            if games.count > 1 { dots(index: index) }
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
        .onHover { isHovering = $0 }
        .task(id: "\(game.id) \(isHovering) \(activeState == .inactive)") {
            guard games.count > 1, !isHovering, activeState != .inactive else { return }
            try? await Task.sleep(for: Self.interval)
            guard !Task.isCancelled else { return }
            show(index + 1)
        }
    }

    private func dots(index: Int) -> some View {
        HStack(spacing: 6) {
            ForEach(games.indices, id: \.self) { dot in
                Capsule()
                    .fill(dot == index ? Color.white : Color.white.opacity(0.3))
                    .frame(width: dot == index ? 18 : 7, height: 7)
                    .contentShape(.rect.inset(by: -4))
                    .onTapGesture { show(dot) }
            }
        }
        .padding(.bottom, 10)
        .fixedSize()
    }

    private func show(_ index: Int) {
        guard !games.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.45)) {
            current = games[(index % games.count + games.count) % games.count].id
        }
    }
}
