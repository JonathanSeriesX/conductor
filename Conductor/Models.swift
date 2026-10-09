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
    let favourite: Bool?  // Jira's own star, read-only through the public API
    var avatar: URL? { avatarUrls?["48x48"] }
}

struct ProjectPage: Codable, Sendable {
    let values: [Project]
    let isLast: Bool
}

struct StatusCategory: Codable, Hashable, Sendable {
    let key: String  // new | indeterminate | done
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

struct IssueType: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let name: String
    let iconUrl: URL?
    let subtask: Bool?
    /// -1 subtask, 0 standard, 1 epic: a parent sits one level up.
    var hierarchyLevel: Int?
    var isSubtask: Bool { subtask == true }
}

struct Sprint: Codable, Hashable, Sendable, Identifiable {
    let id: Int
    let name: String
    let state: String
    let originBoardId: Int?
}

struct SprintPage: Codable, Sendable {
    let values: [Sprint]
    let isLast: Bool?
}

struct Attachment: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let filename: String
    let mimeType: String?
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

/// A component or version: what an issue shows and what editmeta offers.
struct NamedRef: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let name: String
}

struct IssueRef: Codable, Hashable, Sendable, Identifiable {
    struct Fields: Codable, Hashable, Sendable {
        var summary: String
        let status: Status?
        let issuetype: IssueType?
    }
    let id: String
    let key: String
    var fields: Fields
}

extension Issue {
    var isDone: Bool { fields.status.statusCategory.key == "done" }

    /// How many subtasks are Done, out of all of them; nil when the issue has none.
    var subtaskProgress: (done: Int, total: Int)? {
        guard let subs = fields.subtasks, !subs.isEmpty else { return nil }
        return (subs.filter { $0.fields.status?.statusCategory.key == "done" }.count, subs.count)
    }
}

struct Issue: Codable, Hashable, Sendable, Identifiable {
    struct Fields: Codable, Hashable, Sendable {
        var summary: String
        var description: ADFNode?
        var status: Status
        let assignee: JiraUser?
        let reporter: JiraUser?
        let priority: Priority?
        let issuetype: IssueType
        let labels: [String]?
        let created: Date?
        let updated: Date?
        let lastViewed: Date?
        let project: Project?
        let parent: IssueRef?
        let subtasks: [IssueRef]?
        let comment: CommentPage?
        let attachment: [Attachment]?
        let issuelinks: [IssueLink]?
        let worklog: WorklogPage?
        let timetracking: TimeTracking?
        let watches: Watches?
        let duedate: String?  // "2026-10-31", no time or zone
        let components: [NamedRef]?
        let fixVersions: [NamedRef]?
    }

    let id: String
    let key: String
    var fields: Fields
    let sprints: [Sprint]?
    /// Story points from whichever of the site's points fields this issue has.
    let points: Double?

    /// `sprints` and `points` are the cache's own keys: Jira keeps them in per-site custom fields that only the
    /// client's decoder knows, and a cached copy must carry them too or a page opened from disk shows "None".
    private enum CodingKeys: String, CodingKey { case id, key, fields, sprints, points }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        key = try c.decode(String.self, forKey: .key)
        fields = try c.decode(Fields.self, forKey: .fields)
        if let cached = try? c.decodeIfPresent([Sprint].self, forKey: .sprints) {
            sprints = cached
        } else if let sprintKey = decoder.userInfo[.sprintField] as? String {
            // Sprint is a per-site custom field; the client passes its id via userInfo.
            let dyn = try c.nestedContainer(keyedBy: AnyKey.self, forKey: .fields)
            sprints = try? dyn.decodeIfPresent([Sprint].self, forKey: AnyKey(sprintKey))
        } else {
            sprints = nil
        }
        let pointsKeys = decoder.userInfo[.pointsFields] as? [String] ?? []
        if let cached = try? c.decodeIfPresent(Double.self, forKey: .points) {
            points = cached
        } else if !pointsKeys.isEmpty {
            let dyn = try c.nestedContainer(keyedBy: AnyKey.self, forKey: .fields)
            points = pointsKeys.lazy.compactMap { try? dyn.decodeIfPresent(Double.self, forKey: AnyKey($0)) }.first
        } else {
            points = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(key, forKey: .key)
        try c.encode(fields, forKey: .fields)
        try c.encodeIfPresent(sprints, forKey: .sprints)
        try c.encodeIfPresent(points, forKey: .points)
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
    static let pointsFields = CodingUserInfoKey(rawValue: "pointsFields")!
}

// MARK: - Links, worklogs, watchers

struct LinkType: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let name: String
    let inward: String
    let outward: String
}

struct LinkTypeList: Codable, Sendable { let issueLinkTypes: [LinkType] }

struct IssueLink: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let type: LinkType
    let inwardIssue: IssueRef?
    let outwardIssue: IssueRef?

    /// The issue on the other end plus the wording that describes it from this issue's point of view.
    var other: IssueRef? { outwardIssue ?? inwardIssue }
    var relation: String { outwardIssue != nil ? type.outward : type.inward }
}

struct Worklog: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let author: JiraUser?
    let comment: ADFNode?
    let started: Date
    let timeSpent: String
    let timeSpentSeconds: Int
}

struct WorklogPage: Codable, Hashable, Sendable {
    let worklogs: [Worklog]
    let total: Int
}

struct TimeTracking: Codable, Hashable, Sendable {
    let originalEstimate: String?
    let remainingEstimate: String?
    let timeSpent: String?
    let originalEstimateSeconds: Int?
    let remainingEstimateSeconds: Int?
    let timeSpentSeconds: Int?
}

struct Watches: Codable, Hashable, Sendable {
    let watchCount: Int
    let isWatching: Bool
}

// MARK: - Create / edit metadata

struct FieldSchema: Codable, Hashable, Sendable {
    let type: String
    let items: String?
    let custom: String?
}

struct CreateField: Codable, Hashable, Sendable, Identifiable {
    var id: String { fieldId }
    let fieldId: String
    let name: String
    let required: Bool
    let schema: FieldSchema
    let allowedValues: [JSONValue]?
}

struct CreateMetaTypes: Codable, Sendable { let issueTypes: [IssueType] }
struct CreateMetaFields: Codable, Sendable { let fields: [CreateField] }

struct EditField: Codable, Hashable, Sendable {
    let name: String
    let operations: [String]
    let schema: FieldSchema
    let allowedValues: [JSONValue]?
}

struct EditMeta: Codable, Sendable { let fields: [String: EditField] }

struct CreatedIssue: Codable, Sendable {
    let id: String
    let key: String
}

struct IssuePickerResult: Codable, Sendable {
    struct Section: Codable, Sendable { let issues: [Item] }
    struct Item: Codable, Hashable, Sendable, Identifiable {
        var id: String { key }
        let key: String
        let summaryText: String?
    }
    let sections: [Section]
    var items: [Item] {
        var seen = Set<String>()
        return sections.flatMap(\.issues).filter { seen.insert($0.key).inserted }
    }
}

// MARK: - Boards

struct Board: Codable, Hashable, Sendable, Identifiable {
    let id: Int
    let name: String
    let type: String  // scrum | kanban | simple
}

struct BoardPage: Codable, Sendable {
    let values: [Board]
    let isLast: Bool?
}

struct BoardConfiguration: Codable, Sendable {
    struct Column: Codable, Hashable, Sendable, Identifiable {
        struct StatusRef: Codable, Hashable, Sendable { let id: String }
        var id: String { name + statuses.map(\.id).joined() }
        let name: String
        let statuses: [StatusRef]
        /// WIP limits, when the board sets them.
        let min: Int?
        let max: Int?
    }
    struct ColumnConfig: Codable, Sendable { let columns: [Column] }
    let type: String
    let columnConfig: ColumnConfig
}

struct QuickFilter: Codable, Hashable, Sendable, Identifiable {
    let id: Int
    let name: String
    let jql: String
}

struct QuickFilterPage: Codable, Sendable { let values: [QuickFilter] }

struct AgileIssuePage: Codable, Sendable {
    let issues: [Issue]
    let total: Int
    let startAt: Int
    let maxResults: Int
}

// MARK: - JQL assist

struct JQLAutocomplete: Codable, Sendable {
    struct Field: Codable, Sendable {
        let value: String
        let displayName: String
        let operators: [String]?
        let auto: String?
    }
    struct Function: Codable, Sendable {
        let value: String
        let displayName: String
    }
    let visibleFieldNames: [Field]
    let visibleFunctionNames: [Function]
}

struct JQLSuggestions: Codable, Sendable {
    struct Result: Codable, Sendable {
        let value: String
        let displayName: String
    }
    let results: [Result]
}

extension JSONValue {
    /// Any Encodable (e.g. an ADF document) as a JSON value, for mixed field payloads.
    init(_ value: some Encodable) throws {
        self = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }
    var object: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }
}
