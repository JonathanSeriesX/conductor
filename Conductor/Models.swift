import Foundation

struct JiraUser: Codable, Hashable, Sendable, Identifiable {
    var id: String { accountId }
    let accountId: String
    let displayName: String
    let emailAddress: String?
    let avatarUrls: [String: URL]?
    let active: Bool?

    var avatar: URL? { avatarUrls?["48x48"] ?? avatarUrls?.values.first }
}

struct Project: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let key: String
    let name: String
    let projectTypeKey: String?
    let avatarUrls: [String: URL]?
    var avatar: URL? { avatarUrls?["48x48"] }
}

struct ProjectPage: Codable, Sendable {
    let values: [Project]
    let isLast: Bool
}

struct StatusCategory: Codable, Hashable, Sendable {
    let key: String   // new | indeterminate | done
    let name: String
}

struct Status: Codable, Hashable, Sendable {
    let id: String
    let name: String
    let statusCategory: StatusCategory
}

struct Priority: Codable, Hashable, Sendable {
    let id: String
    let name: String
    let iconUrl: URL?
}

struct IssueType: Codable, Hashable, Sendable {
    let id: String
    let name: String
    let iconUrl: URL?
    let subtask: Bool
}

struct Sprint: Codable, Hashable, Sendable, Identifiable {
    let id: Int
    let name: String
    let state: String
}

struct Attachment: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let filename: String
    let mimeType: String
    let size: Int
    let content: URL
    let thumbnail: URL?
    let created: Date
    let author: JiraUser?
}

struct Comment: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let author: JiraUser?
    let body: ADFNode
    let created: Date
    let updated: Date
}

struct CommentPage: Codable, Hashable, Sendable {
    let comments: [Comment]
    let total: Int
}

struct IssueRef: Codable, Hashable, Sendable, Identifiable {
    struct Fields: Codable, Hashable, Sendable {
        let summary: String
        let status: Status?
        let issuetype: IssueType?
    }
    let id: String
    let key: String
    let fields: Fields
}

struct Issue: Codable, Hashable, Sendable, Identifiable {
    struct Fields: Codable, Hashable, Sendable {
        let summary: String
        let description: ADFNode?
        let status: Status
        let assignee: JiraUser?
        let reporter: JiraUser?
        let priority: Priority?
        let issuetype: IssueType
        let labels: [String]?
        let created: Date?
        let updated: Date?
        let project: Project?
        let parent: IssueRef?
        let subtasks: [IssueRef]?
        let comment: CommentPage?
        let attachment: [Attachment]?
    }

    let id: String
    let key: String
    let fields: Fields
    let sprints: [Sprint]?

    private enum CodingKeys: String, CodingKey { case id, key, fields }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        key = try c.decode(String.self, forKey: .key)
        fields = try c.decode(Fields.self, forKey: .fields)
        // Sprint is a per-site custom field; the client passes its id via userInfo.
        if let sprintKey = decoder.userInfo[.sprintField] as? String {
            let dyn = try c.nestedContainer(keyedBy: AnyKey.self, forKey: .fields)
            sprints = try? dyn.decodeIfPresent([Sprint].self, forKey: AnyKey(sprintKey))
        } else {
            sprints = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(key, forKey: .key)
        try c.encode(fields, forKey: .fields)
    }

    var activeSprint: Sprint? { sprints?.first { $0.state == "active" } ?? sprints?.last }
}

struct SearchPage: Codable, Sendable {
    let issues: [Issue]
    let nextPageToken: String?
    let isLast: Bool?
}

struct Transition: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let name: String
    let to: Status
}

struct TransitionList: Codable, Sendable { let transitions: [Transition] }

struct Filter: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let name: String
    let jql: String
}

struct FieldInfo: Codable, Sendable {
    struct Schema: Codable, Sendable { let custom: String? }
    let id: String
    let name: String
    let schema: Schema?
}

struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

extension CodingUserInfoKey {
    static let sprintField = CodingUserInfoKey(rawValue: "sprintField")!
}
