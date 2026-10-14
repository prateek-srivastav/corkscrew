import GameCore
import SwiftUI

enum SidebarItem: Hashable {
    case library, bottles, setup
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigator.self) private var navigator

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 0) {
            NavigationRail(selection: Binding(get: { navigator.route.section }, set: { navigator.go($0) }))
            Group {
                switch navigator.route.section {
                case .library: LibraryView(openSetup: { navigator.go(.setup) })
                case .bottles: BottlesView()
                case .setup: SetupView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .onAppear { if !model.isSetUp { navigator.reset(to: .init(section: .setup)) } }
    }
}

/// The slim column of round buttons on the left: pages, Add Program and Setup.
private struct NavigationRail: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: SidebarItem

    var body: some View {
        VStack(spacing: 10) {
            item(.library, "Library", "square.grid.2x2.fill")
            item(.bottles, "Bottles", "shippingbox.fill")
            Capsule().fill(Theme.stroke).frame(width: 22, height: 2).padding(.vertical, 4)
            Button("Add Program…", systemImage: "plus") { model.open(Pickers.programs()) }
                .buttonStyle(RailButtonStyle(isSelected: false))
                .disabled(!model.isSetUp)
                .help("Add Program… (⌘O)")
            Spacer()
            item(.setup, "Setup", "gearshape.fill")
                .overlay(alignment: .topTrailing) {
                    if !model.isReady {
                        Circle().fill(.red).frame(width: 9, height: 9).offset(x: -2, y: 2)
                    }
                }
        }
        // Clears the window's close, minimize and zoom buttons.
        .padding(.top, 52)
        .padding(.bottom, 18)
        .frame(width: 76)
        .frame(maxHeight: .infinity)
        .background(Color.black.opacity(0.25).gesture(WindowDragGesture()))
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.stroke).frame(width: 1) }
        .ignoresSafeArea(.container, edges: .top)
    }

    private func item(_ page: SidebarItem, _ title: String, _ systemImage: String) -> some View {
        Button(title, systemImage: systemImage) { selection = page }
            .buttonStyle(RailButtonStyle(isSelected: selection == page))
            .help(title)
    }
}

private struct RailButtonStyle: ButtonStyle {
    let isSelected: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(isSelected ? Color.black : Color.primary)
            .frame(width: 44, height: 44)
            .background(isSelected ? Color.white : isHovering ? Theme.surfaceHover : Theme.surface, in: .circle)
            .overlay { Circle().strokeBorder(isSelected ? .clear : Theme.stroke) }
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .contentShape(.circle)
            .onHover { isHovering = $0 }
            .animation(.snappy(duration: 0.15), value: isSelected)
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
                .background(.regularMaterial, in: .capsule)
                .overlay { Capsule().strokeBorder(Theme.stroke) }
                .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
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
