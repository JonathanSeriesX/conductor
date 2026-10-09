import SwiftUI

/// What is typed on an issue page and not yet sent: the comment box, an open description edit and an open comment
/// edit. Kept per issue and on disk, so a switch to another issue, or a relaunch, finds them exactly as they were.
struct IssueDraft: Codable, Equatable {
    var comment = ""
    var commentMentions: [String: String] = [:]
    /// The description editor is open with this text; nil when it is closed.
    var description: String?
    var descriptionMentions: [String: String] = [:]
    /// What the editor opened with, so an untouched draft is never written back.
    var descriptionOriginal = ""
    /// The comment whose editor is open, with its text.
    var editingComment: String?
    var edit = ""
    var editMentions: [String: String] = [:]
    var editOriginal = ""
    var isEmpty: Bool { comment.isEmpty && description == nil && editingComment == nil }
}

/// A New Issue window's form, kept while the window is open and after it closes, under File > Drafts.
struct CreateDraft: Codable, Equatable, Identifiable {
    var request: CreateRequest
    var id: UUID { request.id }
    var accountID: UUID?
    var projectKey: String?
    var type: IssueType?
    var summary = ""
    var text = ""
    var mentions: [String: String] = [:]
    var assignee: JiraUser?
    var priority: Priority?
    var labels: [String] = []
    var parentKey = ""
}

@MainActor @Observable
final class Drafts {
    static let shared = Drafts()
    private(set) var issues: [IssueTarget: IssueDraft] = Drafts.load("issueDrafts") ?? [:]
    /// Newest first.
    private(set) var creates: [CreateDraft] = Drafts.load("createDrafts") ?? []

    subscript(target: IssueTarget) -> IssueDraft { issues[target] ?? IssueDraft() }

    func update(_ target: IssueTarget, _ change: (inout IssueDraft) -> Void) {
        var d = self[target]
        change(&d)
        issues[target] = d.isEmpty ? nil : d
        Self.save(issues, "issueDrafts")
    }

    func set(_ d: CreateDraft) {
        creates.removeAll { $0.id == d.id }
        creates.insert(d, at: 0)
        Self.save(creates, "createDrafts")
    }

    func removeCreate(_ id: UUID) {
        creates.removeAll { $0.id == id }
        Self.save(creates, "createDrafts")
    }

    private static func load<T: Decodable>(_ key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private static func save(_ value: some Encodable, _ key: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: key)
    }
}
