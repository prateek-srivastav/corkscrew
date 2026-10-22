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

    var body: some View {
        let status = model.status(of: report)
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
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                ForEach((report.issue?.notes ?? []).reversed()) { NoteView(note: $0) }
                if status == .needsDetails {
                    Text("Add details on its GitHub page.").font(.subheadline).foregroundStyle(.secondary)
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
        .contextMenu { menuItems }
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
        }
    }

    private var menu: some View {
        Menu { menuItems } label: { Image(systemName: "ellipsis") }
            .menuStyle(.button)
            .buttonStyle(CircleButtonStyle())
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
