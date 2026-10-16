import GameCore
import SwiftUI

enum SidebarItem: Hashable {
    case library, bottles, setup
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigator.self) private var navigator
    @AppStorage(Theme.advancedModeKey) private var advancedMode = false
    @AppStorage(Theme.sidebarCollapsedKey) private var isSidebarCollapsed = false

    private var pageShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: Theme.windowCornerRadius, bottomLeadingRadius: Theme.windowCornerRadius,
                               style: .continuous)
    }

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 0) {
            Sidebar(isCollapsed: isSidebarCollapsed)
            // The container animates, so the section that leaves stays while the new one comes in.
            ZStack {
                Group {
                    switch navigator.route.section {
                    case .library: LibraryView(openSetup: { navigator.go(.setup) })
                    case .bottles: BottlesView()
                    case .setup: SetupView()
                    }
                }
                .id(navigator.route.section)
                .transition(CoverTransition(opaque: true))
            }
            .animation(.smooth(duration: 0.3), value: navigator.route.section)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Pages that slide sideways stay off the sidebar.
            .clipShape(pageShape)
            // The page lies over the sidebar: a sharp edge with a shadow on the sidebar, and left
            // corners as round as the window's.
            .background { pageShape.fill(Theme.background).shadow(color: .black.opacity(0.55), radius: 18, x: -4) }
            .overlay { pageShape.strokeBorder(.white.opacity(0.07)) }
            .ignoresSafeArea(.container, edges: .top)
            .zIndex(1)
        }
        // On the page, always at its top left, never on the sidebar; it moves with the page's edge,
        // frame by frame (see `GlassFollowingOffset`).
        .overlay(alignment: .topLeading) {
            SidebarToggle(isCollapsed: $isSidebarCollapsed)
                .modifier(GlassFollowingOffset(x: isSidebarCollapsed ? Sidebar.collapsedWidth : Sidebar.width))
                .ignoresSafeArea(.container, edges: .top)
        }
        .animation(.snappy(duration: 0.3), value: isSidebarCollapsed)
        .background { WindowButtonsPlacement() }
        .background(Theme.background)
        .overlay(alignment: .bottom) { ActivityBar().padding(.bottom, 16) }
        .preferredColorScheme(.dark)
        .sheet(isPresented: Binding(get: { !model.openRequests.isEmpty }, set: { if !$0 { model.openRequests = [] } })) {
            if let program = model.openRequests.first {
                OpenProgramSheet(program: program).id(program)
            }
        }
        .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .swipeNavigation(navigator)
        // Bottles is an Advanced page; turning Advanced off leaves it, and Back doesn't return to it.
        .onChange(of: advancedMode, initial: true) { if !advancedMode { navigator.remove(.bottles) } }
        .onAppear { if !model.isSetUp { navigator.reset(to: .init(section: .setup)) } }
        // Loads the art pages open with, so a page doesn't show dark while its art loads.
        .task(id: model.allGames.map(\.id)) {
            for game in model.allGames.prefix(40) {
                _ = await SteamArtwork.load(.hero, for: game, model: model)
                _ = await SteamArtwork.load(.logo, for: game, model: model)
            }
        }
    }
}

/// What the app is busy with, floating at the bottom of the window.
private struct ActivityBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            if model.enginePackProgress != nil || model.activity != nil {
                Group {
                    if let progress = model.enginePackProgress {
                        HStack(spacing: 10) {
                            ProgressView(value: progress.fraction).frame(width: 90)
                            Text(progress.title).lineLimit(1)
                        }
                    } else if let activity = model.activity {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text(activity).lineLimit(1)
                        }
                    }
                }
                .font(.body)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: .capsule)
                .padding(.horizontal, 100)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: model.activity)
    }
}

/// A program's icon, or a generic one.
struct GameIcon: View {
    @Environment(AppModel.self) private var model
    let game: Game
    var size: CGFloat = 64

    var body: some View {
        Group {
            if let image = model.icon(for: game) {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Image(systemName: "app.dashed").resizable().fontWeight(.ultraLight).foregroundStyle(.secondary)
            }
        }
        .aspectRatio(contentMode: .fit)
        .frame(width: size, height: size)
    }
}

extension AppModel.Session.Status {
    var text: String {
        switch self {
        case .preparing: "Starting…"
        case .running: "Running"
        case .exited(0): "Exited normally"
        case .exited(let code): "Exited with code \(code)"
        case .stopped: "Stopped"
        case .failed(let message): "Couldn't start: \(message)"
        }
    }
}
