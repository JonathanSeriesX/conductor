import SwiftUI

/// What a deletion, or a change that is hard to take back, leaves behind: enough to put it back from the Bin.
struct BinItem: Codable, Identifiable {
    enum Kind: Codable {
        case comment(ADFNode)
        /// The bytes are in the Bin's folder under `file`.
        case attachment(filename: String, file: String)
        case link(type: String, from: String, to: String)
        case worklog(seconds: Int, comment: ADFNode?, started: Date)
        /// The parent before it was removed or replaced.
        case parent(String?)
        /// The status before the transition.
        case status(Status)
        case preset(CustomPreset)
    }
    let id: UUID
    let date: Date
    /// nil for a filter over all accounts.
    let accountID: UUID?
    let key: String
    let kind: Kind

    var title: String {
        switch kind {
        case .comment: String(localized: "Comment on \(key)")
        case .attachment: String(localized: "Attachment on \(key)")
        case .link(_, let from, let to): String(localized: "Link between \(from) and \(to)")
        case .worklog: String(localized: "Work log on \(key)")
        case .parent: String(localized: "Parent of \(key)")
        case .status: String(localized: "Status of \(key)")
        case .preset: String(localized: "Filter")
        }
    }

    var detail: String {
        switch kind {
        case .comment(let body): body.plainText
        case .attachment(let name, _): name
        case .link(let type, _, _): type
        case .worklog(let seconds, _, _): Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes]))
        case .parent(let p): p ?? String(localized: "None")
        case .status(let s): String(localized: "Was \(s.name)")
        case .preset(let p): p.name
        }
    }

    var symbol: String {
        switch kind {
        case .comment: "text.bubble"
        case .attachment: "paperclip"
        case .link: "link"
        case .worklog: "clock"
        case .parent: "arrow.turn.left.up"
        case .status: "arrow.triangle.2.circlepath"
        case .preset: "bookmark"
        }
    }
}

struct BinError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Deleted things, newest first, on disk. Replaces confirmation dialogs: deleting is one click, and so is undoing it.
@MainActor @Observable
final class Bin {
    static let shared = Bin()
    private(set) var items: [BinItem] =
        (try? JSONDecoder().decode([BinItem].self, from: Data(contentsOf: file))) ?? []

    nonisolated private static let dir = URL.applicationSupportDirectory.appending(
        path: "Conductor/bin", directoryHint: .isDirectory)
    nonisolated private static let file = dir.appending(path: "items.json")

    /// Writes an attachment's bytes beside the list and names the file for `.attachment`.
    nonisolated static func store(_ data: Data, _ name: String) -> String {
        let file = UUID().uuidString + "-" + name.replacingOccurrences(of: "/", with: "_")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: dir.appending(path: file))
        return file
    }

    func put(_ kind: BinItem.Kind, account: UUID?, key: String) {
        items.insert(BinItem(id: UUID(), date: .now, accountID: account, key: key, kind: kind), at: 0)
        for old in items.dropFirst(100) { discard(old) }
        items = Array(items.prefix(100))
        save()
    }

    func remove(_ item: BinItem) {
        discard(item)
        items.removeAll { $0.id == item.id }
        save()
    }

    func empty() {
        for i in items { discard(i) }
        items = []
        save()
    }

    /// Puts the item back in Jira (or the sidebar) and takes it out of the Bin.
    func restore(_ item: BinItem, session: Session) async throws {
        if case .preset(let p) = item.kind {
            session.restorePreset(p)
            remove(item)
            return
        }
        guard let st = item.accountID.flatMap(session.state) else {
            throw BinError(message: String(localized: "The account this issue belongs to is no longer signed in."))
        }
        let c = st.client
        switch item.kind {
        case .comment(let body): try await c.addComment(item.key, body: body)
        case .attachment(let name, let file):
            try await c.uploadAttachment(
                item.key, data: try Data(contentsOf: Self.dir.appending(path: file)), filename: name)
        case .link(let type, let from, let to): try await c.link(type: type, from: from, to: to)
        case .worklog(let seconds, let comment, let started):
            try await c.addWorklog(
                item.key, seconds: seconds, comment: comment, started: started, adjustsEstimate: false)
        case .parent(let p):
            try await c.editIssue(item.key, fields: ["parent": p.map { .object(["key": .string($0)]) } ?? .null])
        case .status(let old):
            guard let t = try await c.transitions(item.key).first(where: { $0.to.id == old.id }) else {
                throw BinError(
                    message: String(localized: "No transition back to \(old.name) is allowed for \(item.key)."))
            }
            try await c.transition(item.key, to: t.id)
        case .preset: break
        }
        remove(item)
        session.writeTicks[item.key, default: 0] += 1
        session.listTick += 1
    }

    private func discard(_ item: BinItem) {
        if case .attachment(_, let file) = item.kind {
            try? FileManager.default.removeItem(at: Self.dir.appending(path: file))
        }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        try? JSONEncoder().encode(items).write(to: Self.file, options: .atomic)
    }
}

struct BinView: View {
    @Environment(Session.self) private var session
    @State private var error: String?
    @State private var restoring: Set<UUID> = []
    @State private var emptying = false
    private var bin: Bin { Bin.shared }

    var body: some View {
        Group {
            if bin.items.isEmpty {
                ContentUnavailableView(
                    "The Bin is empty", systemImage: "trash",
                    description: Text("What you delete, and status changes, land here and can be put back."))
            } else {
                List(bin.items) { item in
                    HStack(spacing: 10) {
                        Image(systemName: item.symbol).foregroundStyle(.secondary).frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.callout.weight(.semibold))
                            Text(item.detail).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        Text(item.date.formatted(.relative(presentation: .named))).font(.caption)
                            .foregroundStyle(.tertiary).help(item.date.formatted())
                        if restoring.contains(item.id) {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Restore") { restore(item) }.glassButton()
                        }
                    }
                    .padding(.vertical, 4)
                }
                .scrollContentBackground(.hidden)
            }
        }
        .frame(minWidth: 480, minHeight: 320)
        .background(Backdrop())
        .navigationTitle("Bin")
        .toolbar {
            ToolbarItem {
                Button("Empty Bin", systemImage: "trash.slash") { emptying = true }.disabled(bin.items.isEmpty)
                    // The one dialog left, as the Finder's: this is the step that cannot be taken back.
                    .confirmationDialog("Empty the Bin?", isPresented: $emptying, titleVisibility: .visible) {
                        Button("Empty Bin", role: .destructive) { bin.empty() }
                    } message: {
                        Text("This can't be undone.")
                    }
            }
        }
        .errorAlert($error)
    }

    private func restore(_ item: BinItem) {
        restoring.insert(item.id)
        Task {
            defer { restoring.remove(item.id) }
            do { try await bin.restore(item, session: session) } catch { self.error = error.localizedDescription }
        }
    }
}
