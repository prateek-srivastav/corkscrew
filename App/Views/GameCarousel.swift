import GameCore
import SwiftUI

/// The top of a bottle's page: its games' art, one after another, each with Play and a way to its
/// page. Moves on by itself every few seconds, except while the pointer is over it.
struct GameCarousel<TopBar: View>: View {
    @Environment(AppModel.self) private var model
    let games: [Game]
    let open: (Game) -> Void
    @ViewBuilder var topBar: TopBar
    @State private var current: Game.ID?
    @State private var isHovering = false

    static var interval: Duration { .seconds(8) }

    var body: some View {
        let index = games.firstIndex { $0.id == current } ?? 0
        let game = games[min(index, games.count - 1)]
        ZStack(alignment: .top) {
            HeroBackdrop(game: game)
            VStack(alignment: .leading, spacing: 0) {
                topBar
                Spacer(minLength: 24)
                HStack(alignment: .bottom, spacing: 24) {
                    GameHero(game: game, showSettings: nil, remove: nil, openDetails: { open(game) })
                        .id(game.id)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 24)), removal: .opacity))
                    if games.count > 1 { controls(index: index) }
                }
            }
            .padding(.horizontal, 40)
            .padding(.top, 20)
            .padding(.bottom, 28)
        }
        .onHover { isHovering = $0 }
        .task(id: "\(game.id) \(isHovering)") {
            guard games.count > 1, !isHovering else { return }
            try? await Task.sleep(for: Self.interval)
            guard !Task.isCancelled else { return }
            show(index + 1)
        }
    }

    private func controls(index: Int) -> some View {
        HStack(spacing: 10) {
            Button("Previous", systemImage: "chevron.left") { show(index - 1) }
                .buttonStyle(CircleButtonStyle(size: 30))
            HStack(spacing: 6) {
                ForEach(games.indices, id: \.self) { dot in
                    Capsule()
                        .fill(dot == index ? Color.white : Color.white.opacity(0.3))
                        .frame(width: dot == index ? 18 : 7, height: 7)
                        .contentShape(.rect)
                        .onTapGesture { show(dot) }
                }
            }
            Button("Next", systemImage: "chevron.right") { show(index + 1) }
                .buttonStyle(CircleButtonStyle(size: 30))
        }
        .padding(.bottom, 6)
        .fixedSize()
    }

    private func show(_ index: Int) {
        guard !games.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.45)) {
            current = games[(index % games.count + games.count) % games.count].id
        }
    }
}
