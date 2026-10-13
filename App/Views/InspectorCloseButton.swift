import SwiftUI

extension View {
    /// A close button above an inspector's content, which Esc presses too.
    func inspectorCloseButton(_ close: @escaping () -> Void) -> some View {
        toolbar {
            ToolbarItem {
                Button("Close", systemImage: "xmark", action: close)
                    .keyboardShortcut(.cancelAction)
                    .help("Close (Esc)")
            }
        }
    }
}
