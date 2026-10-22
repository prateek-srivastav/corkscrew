import AppKit
import GameCore
import SwiftUI

/// The reports this Mac sent (and issues the user added): each one's status, the developer's
/// notes, and the fix. The sidebar's dot says something changed; the cards that changed keep a
/// dot while the page is open.
struct ReportsView: View {
    @Environment(AppModel.self) private var model
    /// The reports that had news when the page opened, or got news while it was open.
    @State private var fresh: Set<Int> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if model.trackedReports.isEmpty {
                    Text("Reports you send show here.").foregroundStyle(.secondary)
                }
                ForEach(model.trackedReports) { report in
                    ReportCard(report: report, isNew: fresh.contains(report.number))
                }
                TrackReportField().padding(.top, 16)
            }
            .pageHeader("Reports", subtitle: "What happens to the problems you reported.")
            // A readable column, centred on wide windows.
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 40)
            .padding(.top, 52)
            .padding(.bottom, 40)
        }
        .ignoresSafeArea(.container, edges: .top)
        .animation(.snappy, value: model.trackedReports.map(\.number))
        .onAppear(perform: markSeen)
        .onChange(of: model.hasReportNews) { if model.hasReportNews { markSeen() } }
    }

    private func markSeen() {
        fresh.formUnion(model.trackedReports.filter(model.hasNews).map(\.number))
        model.markReportsSeen()
    }
}

/// One report: its status, notes and what the user can do.
private struct ReportCard: View {
    let report: AppModel.TrackedReport
    let isNew: Bool
    @Environment(AppModel.self) private var model
    @State private var isReplying = false
    /// The notes and replies show only when the user opens the card, so a long list stays short.
    @State private var isExpanded = false

    var body: some View {
        let status = model.status(of: report)
        let thread = thread
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: status.systemImage)
                .font(.system(size: Theme.controlIconSize, weight: .semibold))
                .foregroundStyle(status.tint)
                .frame(width: 32, height: 32)
                .background(status.tint.opacity(0.16), in: .rect(cornerRadius: Theme.cornerRadius - 5))
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(report.title).font(.headline).lineLimit(2)
                        if isNew { Circle().fill(.red).frame(width: 8, height: 8).accessibilityLabel("New") }
                    }
                    HStack(spacing: 6) {
                        Text(status.line).foregroundStyle(status.tint)
                        Text("·")
                        Text("#\(report.number)")
                        if let sent = report.sent {
                            Text("·")
                            Text("Sent \(sent.formatted(date: .abbreviated, time: .omitted))")
                        }
                        if !thread.isEmpty {
                            Text("·")
                            Button { toggle() } label: {
                                HStack(spacing: 4) {
                                    Text(thread.count == 1 ? "1 message" : "\(thread.count) messages")
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                if isExpanded {
                    ForEach(thread) { message in
                        switch message {
                        case .note(let note): NoteView(note: note)
                        case .reply(let reply): ReplyView(reply: reply)
                        }
                    }
                }
                actions(status)
            }
            Spacer(minLength: 8)
            menu
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: .rect(cornerRadius: Theme.cornerRadius))
        .overlay { RoundedRectangle(cornerRadius: Theme.cornerRadius).strokeBorder(Theme.stroke) }
        .contentShape(.rect(cornerRadius: Theme.cornerRadius))
        .onTapGesture { if !thread.isEmpty { toggle() } }
        .contextMenu { menuItems }
        .sheet(isPresented: $isReplying) { ReplySheet(report: report).environment(model) }
    }

    private func toggle() {
        withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() }
    }

    /// The developer's notes and the user's replies, newest first.
    private var thread: [Message] {
        let notes = (report.issue?.notes ?? []).map(Message.note)
        let replies = (report.replies ?? []).map(Message.reply)
        return (notes + replies).sorted { $0.date > $1.date }
    }

    private enum Message: Identifiable {
        case note(ReportIssue.Note)
        case reply(AppModel.TrackedReport.Reply)

        var date: Date {
            switch self {
            case .note(let note): note.date
            case .reply(let reply): reply.date
            }
        }

        var id: String {
            switch self {
            case .note(let note): "note-\(note.id)"
            case .reply(let reply): "reply-\(reply.date.timeIntervalSinceReferenceDate)"
            }
        }
    }

    @ViewBuilder
    private func actions(_ status: ReportIssue.Status) -> some View {
        if case .fixed(let version, let availability) = status, availability != .coming {
            HStack(spacing: 8) {
                if availability == .update, model.availableUpdate != nil {
                    BusyButton("Update to \(model.availableUpdate?.version ?? version)", systemImage: "arrow.down.circle",
                               busyTitle: "Updating…", isBusy: model.isPending(.update)) { model.installUpdate() }
                        .buttonStyle(.prominentPill)
                }
                Button("What Changed") { model.showFix(of: report) }
                    .buttonStyle(.pill)
            }
            .padding(.top, 2)
        } else if status == .needsDetails, AppModel.reportRelay != nil {
            Button(report.replies == nil ? "Reply" : "Reply Again", systemImage: "arrowshape.turn.up.left") { isReplying = true }
                .buttonStyle(.prominentPill)
                .padding(.top, 2)
        } else if status == .needsDetails {
            Text("Add details on its GitHub page.").font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private var menu: some View {
        Menu { menuItems } label: { Image(systemName: "ellipsis") }
            .menuStyle(.button)
            .buttonStyle(CircleMenuButtonStyle())
            .focusLine(in: .circle)
            .menuIndicator(.hidden)
            .fixedSize()
    }

    @ViewBuilder
    private var menuItems: some View {
        Link("Open on GitHub", destination: ReportIssues.page(of: report.number))
        Divider()
        Button("Stop Following", role: .destructive) { model.untrackReport(report.number) }
    }
}

/// A note from the developer, with links that work.
private struct NoteView: View {
    let note: ReportIssue.Note

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("From the developer · \(note.date.formatted(date: .abbreviated, time: .omitted))")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(Self.markdown(note.text))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.05), in: .rect(cornerRadius: 8))
    }

    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

/// What the user answered with Reply. Only this Mac keeps the text to show it; the relay's copy is private.
private struct ReplyView: View {
    let reply: AppModel.TrackedReport.Reply

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("You · \(reply.date.formatted(date: .abbreviated, time: .omitted))"
                 + (reply.logs == 0 ? "" : " · \(reply.logs == 1 ? "1 launch log" : "\(reply.logs) launch logs")"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(reply.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 8))
    }
}

/// The user's answer to the developer's note, with the program's newest launch logs if they
/// choose. Only the developer sees it: the relay keeps it privately and says on the issue that
/// there is one.
private struct ReplySheet: View {
    let report: AppModel.TrackedReport
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var attachLogs = true
    @State private var isSending = false
    @State private var error: String?

    var body: some View {
        let logs = model.replyLogs(for: report)
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Reply to the developer").font(.headline)
                Text("“\(report.title)”").foregroundStyle(.secondary).lineLimit(2)
            }
            if let note = report.issue?.notes.last {
                Text(NoteView.markdown(note.text))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.05), in: .rect(cornerRadius: 8))
            }
            TextEditor(text: $text)
                .font(.body)
                .frame(height: 120)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Theme.surface, in: .rect(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.stroke) }
            if !logs.isEmpty {
                HStack(spacing: 6) {
                    Toggle("Attach the last \(logs.count == 1 ? "launch log" : "\(logs.count) launch logs")", isOn: $attachLogs)
                    InfoButton(text: "The start and the end of \(model.game(of: report)?.name ?? "the program")'s newest launch logs. "
                               + "Your home folder shows as ~ and your user name as <user>.")
                }
            }
            InfoLine("Only the developer sees your answer.",
                     info: "Corkscrew's server keeps your answer and the logs privately, and adds a comment to the public issue "
                        + "that you answered. It doesn't show what you wrote.")
                .foregroundStyle(.secondary)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                BusyButton("Send", busyTitle: "Sending…", isBusy: isSending, action: send)
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func send() {
        guard !isSending else { return }
        isSending = true
        error = nil
        Task {
            defer { isSending = false }
            do {
                try await model.reply(to: report, text: text.trimmingCharacters(in: .whitespacesAndNewlines), attachLogs: attachLogs)
                dismiss()
            } catch {
                self.error = "Couldn't send it. Try again later."
            }
        }
    }
}

/// Follows an issue by its number or link: a report sent with Report on GitHub, or from an
/// older version.
private struct TrackReportField: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var isAdding = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                SectionLabel("Follow a report")
                InfoButton(text: "Reports sent with Report on GitHub, or from Corkscrew 1.0.1 or older, aren't followed "
                           + "by themselves. Type the issue's number or paste its link.")
            }
            HStack(spacing: 8) {
                TextField("Issue number or link", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                BusyButton("Follow", busyTitle: "Adding…", isBusy: isAdding, action: add)
                    .buttonStyle(.pill)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(.orange)
            }
        }
    }

    private func add() {
        guard !isAdding else { return }
        isAdding = true
        error = nil
        Task {
            defer { isAdding = false }
            do {
                try await model.trackReport(text)
                text = ""
            } catch let failure as AppModel.ReportTrackingError {
                error = failure.localizedDescription
            } catch {
                self.error = "Couldn't reach GitHub. Try again later."
            }
        }
    }
}

/// The app's own popup for a fix: what was wrong, what changed, and the update if it's needed.
struct FixedReportSheet: View {
    let fixed: AppModel.FixedReport
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 28)).foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 4) {
                    Text(fixed.isSent ? "Your report is fixed" : "A reported problem is fixed").font(.headline)
                    Text("“\(fixed.title)”").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let cause = fixed.cause { line("What was wrong", cause, systemImage: "ladybug.fill", tint: .orange) }
            if let change = fixed.change { line("What changed", change, systemImage: "wrench.and.screwdriver.fill", tint: .green) }
            Text(fixed.needsUpdate ? "Fixed in \(fixed.version). Update to get it." : "Fixed in this version.")
                .foregroundStyle(.secondary)
            HStack {
                Link("Details", destination: ReportIssues.page(of: fixed.issue))
                Spacer()
                if fixed.needsUpdate, model.availableUpdate != nil {
                    Button("Later", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Update") {
                        model.installUpdate()
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("OK") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func line(_ title: String, _ text: String, systemImage: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage).foregroundStyle(tint).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Text(text).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension ReportIssue.Status {
    /// One short line, in the card and the notification.
    var line: String {
        switch self {
        case .received: "Received"
        case .investigating: "Looking into it"
        case .needsDetails: "Needs details from you"
        case .notCorkscrew: "Not a Corkscrew problem"
        case .closed: "Closed"
        case .fixed(_, .installed): "Fixed in this version"
        case .fixed(let version, .update): "Fixed in \(version)"
        case .fixed(let version, .coming): "Fix coming in \(version)"
        }
    }

    var systemImage: String {
        switch self {
        case .received: "tray.fill"
        case .investigating: "magnifyingglass"
        case .needsDetails: "questionmark.bubble.fill"
        case .notCorkscrew: "lightbulb.fill"
        case .closed: "checkmark.circle"
        case .fixed(_, .coming): "hammer.fill"
        case .fixed: "checkmark.seal.fill"
        }
    }

    var tint: Color {
        switch self {
        case .received, .closed: .secondary
        case .investigating: .blue
        case .needsDetails: .orange
        case .notCorkscrew: .yellow
        case .fixed(_, .coming): .teal
        case .fixed: .green
        }
    }
}
