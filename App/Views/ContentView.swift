import GameCore
import SwiftUI

enum SidebarItem: Hashable {
    case library, bottles, setup
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigator.self) private var navigator
    @AppStorage(Theme.advancedModeKey) private var advancedMode = false

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 0) {
            Sidebar()
            Group {
                switch navigator.route.section {
                case .library: LibraryView(openSetup: { navigator.go(.setup) })
                case .bottles: BottlesView()
                case .setup: SetupView()
                }
            }
            .id(navigator.route.section)
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.2), value: navigator.route.section)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Pages that slide sideways stay off the sidebar.
            .clipped()
            .ignoresSafeArea(.container, edges: .top)
        }
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
                            ProgressView(value: progress).frame(width: 90)
                            Text("Downloading Wine… \(Int(progress * 100))%").lineLimit(1)
                        }
                    } else if let activity = model.activity {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text(activity).lineLimit(1)
                        }
                    }
                }
                .font(.callout)
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
