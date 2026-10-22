import AppKit
import GameCore
import SwiftUI

/// Offered after a crash or an error: the whole report to read, and a way to send it. Nothing
/// leaves the Mac until the user clicks Send Report or Report on GitHub.
struct ReportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var pending: AppModel.PendingReport
    @State private var isSending = false
    @State private var sent = false
    @State private var sendError: String?
    @State private var copied = false

    private var report: ProblemReport { pending.report }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 28)).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text(report.title).font(.headline)
                    Text(report.summary).font(.body).foregroundStyle(.secondary).lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let gameID = pending.gameID, !pending.otherPrograms.isEmpty {
                otherPrograms(for: gameID)
            }

            Text(destinationText)
                .font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            TextField("What were you doing? (optional)", text: $pending.report.note, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
                .disabled(sent)

            ScrollView {
                Text(report.text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(height: 240)
            .background(Theme.surface, in: .rect(cornerRadius: 8))

            if let sendError {
                Label(sendError, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }

            HStack {
                Button("Close", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if let log = pending.logFile {
                    Button("Show Log") { NSWorkspace.shared.activateFileViewerSelecting([log]) }
                }
                Spacer()
                Button(copied ? "Copied" : "Copy Report") { copy() }
                if sent {
                    Label("Report sent", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else if let relay = AppModel.reportRelay, sendError == nil {
                    Button(isSending ? "Sending…" : "Send Report") { send(to: relay) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(isSending)
                } else {
                    Button("Report on GitHub…") { openIssue() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 600)
    }

    /// Some games crash when started directly and must start through another program in their
    /// folder, such as a launcher.
    private func otherPrograms(for gameID: Game.ID) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Try another program (.exe)").font(.headline)
            Text("Some games must start through another program in their folder, such as a launcher. Use and Play starts the game with it from now on; Change Program (.exe) in the game's menu switches back.")
                .font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(pending.otherPrograms, id: \.self) { program in
                HStack {
                    Label(program.lastPathComponent, systemImage: "app").help(program.path)
                    Spacer()
                    Button("Use and Play") {
                        dismiss()
                        model.play(gameID, with: program)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: .rect(cornerRadius: 8))
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report.text, forType: .string)
        copied = true
    }

    /// A filled-in issue on the Bug report form. The link holds as much as fits; the whole report
    /// is on the clipboard for the rest.
    private func openIssue() {
        copy()
        NSWorkspace.shared.open(report.issueURL(repository: AboutPanel.source, backend: pending.backend,
                                                fromSource: AppModel.isBuiltFromSource))
        dismiss()
    }

    /// Says the report is sent and stays open; the issue the relay opens isn't shown, only kept to
    /// say when it's fixed.
    private func send(to relay: URL) {
        isSending = true
        sendError = nil
        Task {
            defer { isSending = false }
            do {
                var report = report
                report.device = AppModel.deviceID
                if let issue = try await report.send(to: relay) { model.remember(report, issue: issue) }
                sent = true
            } catch {
                sendError = "Couldn't send the report: \(AppModel.describe(error)). You can report it on GitHub instead."
            }
        }
    }

    /// Where the report goes, and what of it others can see.
    private var destinationText: String {
        (AppModel.reportRelay == nil
            ? "Report on GitHub opens a new issue on Corkscrew's GitHub page with this report filled in. GitHub issues are public. "
            : "Send Report sends this report to Corkscrew's server, which keeps it privately and opens a public GitHub issue "
                + "with the title, the details and the start of the backtrace. Your note, the log and, with usage counts on, "
                + "this Mac's ID stay private. ")
            + "The report has no files or names: your home folder shows as ~ and your user name as <user>."
    }
}
