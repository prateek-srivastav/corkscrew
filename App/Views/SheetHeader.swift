import SwiftUI

/// The top of a small sheet that asks something: an icon, a title with a line under it, and ✕ (or
/// Esc) to close it without answering.
struct SheetHeader: View {
    @Environment(\.dismiss) private var dismiss
    let systemImage: String
    let tint: Color
    let title: String
    let message: String
    /// What closing means, for ✕'s tooltip ("Don't quit").
    let closeHelp: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 28)).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(message)
                    .font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).frame(width: 22, height: 22)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .keyboardShortcut(.cancelAction)
            .help(closeHelp)
        }
    }
}
