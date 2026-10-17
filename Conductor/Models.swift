import Foundation

struct JiraUser: Codable, Hashable, Sendable, Identifiable {
    var id: String { accountId }
    /// On Server, the username: it names the user in every query and payload there, as the account id does on Cloud.
    let accountId: String
    let displayName: String
    let emailAddress: String?
    let avatarUrls: [String: URL]?
    let active: Bool?
    /// Cloud only: "atlassian" for a person, "app" for a bot, "customer" for a service desk customer.
    let accountType: String?

    var avatar: URL? { avatarUrls?["48x48"] ?? avatarUrls?.values.first }

    private enum CodingKeys: String, CodingKey {
        case accountId, name, displayName, emailAddress, avatarUrls, active, accountType
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accountId = try c.decodeIfPresent(String.self, forKey: .accountId) ?? c.decode(String.self, forKey: .name)
        displayName = try c.decode(String.self, forKey: .displayName)
        emailAddress = try c.decodeIfPresent(String.self, forKey: .emailAddress)
        avatarUrls = try c.decodeIfPresent([String: URL].self, forKey: .avatarUrls)
        active = try c.decodeIfPresent(Bool.self, forKey: .active)
        accountType = try c.decodeIfPresent(String.self, forKey: .accountType)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(accountId, forKey: .accountId)
        try c.encode(displayName, forKey: .displayName)
        try c.encodeIfPresent(emailAddress, forKey: .emailAddress)
        try c.encodeIfPresent(avatarUrls, forKey: .avatarUrls)
        try c.encodeIfPresent(active, forKey: .active)
        try c.encodeIfPresent(accountType, forKey: .accountType)
    }
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

    private enum CodingKeys: String, CodingKey { case id, name, iconUrl, subtask, hierarchyLevel }
}

extension IssueType {
    /// Server has no levels; its epic type is known to the client, which passes it in through `userInfo`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        iconUrl = try c.decodeIfPresent(URL.self, forKey: .iconUrl)
        subtask = try c.decodeIfPresent(Bool.self, forKey: .subtask)
        hierarchyLevel = try c.decodeIfPresent(Int.self, forKey: .hierarchyLevel)
        if hierarchyLevel == nil, let epic = decoder.userInfo[.epicType] as? String {
            hierarchyLevel = subtask == true ? -1 : id == epic ? 1 : 0
        }
    }
}

struct Sprint: Codable, Hashable, Sendable, Identifiable {
    let id: Int
    let name: String
    let state: String
    let originBoardId: Int?

    private enum CodingKeys: String, CodingKey { case id, name, state, originBoardId }

    init(from decoder: Decoder) throws {
        // Server's sprint field holds Java's toString of each sprint:
        // "com.atlassian.greenhopper.service.sprint.Sprint@1f[id=1,rapidViewId=3,state=ACTIVE,name=Sprint 1,…]".
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            func value(_ key: String) -> String? {
                guard let r = Self.serverPatterns[key], let m = s.firstMatch(of: r) else { return nil }
                return m.output[1].substring.map(String.init)
            }
            guard let id = value("id").flatMap(Int.init) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "Sprint \(s)"))
            }
            self.id = id
            name = value("name") ?? ""
            state = value("state")?.lowercased() ?? ""
            originBoardId = value("rapidViewId").flatMap(Int.init)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        state = try c.decode(String.self, forKey: .state).lowercased()
        originBoardId = try c.decodeIfPresent(Int.self, forKey: .originBoardId)
    }

    private static let serverKeys = [
        "activatedDate", "autoStartStop", "completeDate", "endDate", "goal", "id", "incompleteIssuesDestinationId",
        "name", "rapidViewId", "sequence", "startDate", "state", "synced",
    ]
    /// Each key's pattern, compiled once rather than for every key of every sprint of every issue decoded.
    /// `Regex` is not Sendable; these are never changed after they are built.
    nonisolated(unsafe) private static let serverPatterns: [String: Regex<AnyRegexOutput>] = {
        // A name may hold commas: a value runs to the next ",key=" Jira writes, or to the closing bracket.
        let keys = serverKeys.joined(separator: "|")
        return Dictionary(
            uniqueKeysWithValues: serverKeys.compactMap { key in
                (try? Regex("[\\[,]\(key)=(.*?)(?=,(?:\(keys))=|\\]$)")).map { (key, $0) }
            })
    }()
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
    var body: ADFNode
    let created: Date
    let updated: Date
    /// Cloud: the comment this one replies to. Only the comment endpoint sends it (a number there); Server has none.
    let parentId: String?
}

extension Comment {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        author = try c.decodeIfPresent(JiraUser.self, forKey: .author)
        body = try c.decode(ADFNode.self, forKey: .body)
        created = try c.decode(Date.self, forKey: .created)
        updated = try c.decode(Date.self, forKey: .updated)
        // A number from Jira, text from a copy on disk.
        parentId =
            try (try? c.decodeIfPresent(Int.self, forKey: .parentId)).map { String($0) }
            ?? c.decodeIfPresent(String.self, forKey: .parentId)
    }

    /// The thread as the issue page shows it: each top-level comment, then its replies oldest first; `newestFirst`
    /// orders the threads alone. Jira nests one level, so a reply to a reply joins its top-level thread, and replies
    /// whose parent is gone stay together under the first of them. Each comes with its thread's root: the parent a
    /// reply to it is posted under. `comments` oldest first, as Jira gives them.
    static func threads(_ comments: [Comment], newestFirst: Bool) -> [(comment: Comment, root: String)] {
        let parents = Dictionary(comments.map { ($0.id, $0.parentId) }, uniquingKeysWith: { a, _ in a })
        var roots: [String] = []
        var members: [String: [Comment]] = [:]
        for c in comments {
            var root = c.parentId ?? c.id
            for _ in 0..<8 {  // bounded, so a cycle in bad data cannot hang the page
                guard let up = parents[root] ?? nil else { break }
                root = up
            }
            if members[root] == nil { roots.append(root) }
            if c.id == root {
                members[root, default: []].insert(c, at: 0)
            } else {
                members[root, default: []].append(c)
            }
        }
        return (newestFirst ? roots.reversed() : roots).flatMap { r in members[r, default: []].map { ($0, r) } }
    }
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

extension Issue {
    /// A copy without the description, comments and work logs, to keep in memory where only row fields are read.
    var rowSized: Issue {
        var i = self
        i.fields.description = nil
        i.fields.comment = nil
        i.fields.worklog = nil
        return i
    }
}

struct Issue: Codable, Hashable, Sendable, Identifiable {
    struct Fields: Codable, Hashable, Sendable {
        var summary: String
        var description: ADFNode?
        var status: Status
        var assignee: JiraUser?
        let reporter: JiraUser?
        let priority: Priority?
        let issuetype: IssueType
        let labels: [String]?
        let created: Date?
        let updated: Date?
        let lastViewed: Date?
        let project: Project?
        var parent: IssueRef?
        let subtasks: [IssueRef]?
        var comment: CommentPage?
        let attachment: [Attachment]?
        let issuelinks: [IssueLink]?
        var worklog: WorklogPage?
        let timetracking: TimeTracking?
        var watches: Watches?
        let duedate: String?  // "2026-10-31", no time or zone
        let components: [NamedRef]?
        let fixVersions: [NamedRef]?
    }

    let id: String
    let key: String
    var fields: Fields
    let sprints: [Sprint]?
    /// Every comment is here: a search result carries Jira's first 20, an issue of its own the newest 100.
    var hasAllComments: Bool { fields.comment.map { $0.comments.count >= $0.total } ?? false }
    /// Every work log is here: a search result and an issue of its own both carry only Jira's oldest 20.
    var hasAllWorklogs: Bool { fields.worklog.map { $0.worklogs.count >= $0.total } ?? true }
    /// A full record a page can show as it is, with nothing to add afterwards.
    var isComplete: Bool { hasAllComments && hasAllWorklogs }
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
        // Server names a standard issue's epic in a custom field, as a bare key; the client fills in the rest.
        if fields.parent == nil, let link = decoder.userInfo[.epicLinkField] as? String {
            let dyn = try c.nestedContainer(keyedBy: AnyKey.self, forKey: .fields)
            if let epic = try? dyn.decodeIfPresent(String.self, forKey: AnyKey(link)) {
                fields.parent = IssueRef(id: epic, key: epic, fields: .init(summary: "", status: nil, issuetype: nil))
            }
        }
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
    /// Server only, which counts its results.
    var total: Int?
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
    static let epicLinkField = CodingUserInfoKey(rawValue: "epicLinkField")!
    static let epicType = CodingUserInfoKey(rawValue: "epicType")!
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

/// Cloud names the list `issueTypes` or `fields`; Server calls either one `values`.
struct CreateMetaTypes: Decodable, Sendable {
    let issueTypes: [IssueType]
    private enum CodingKeys: String, CodingKey { case issueTypes, values }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        issueTypes =
            try c.decodeIfPresent([IssueType].self, forKey: .issueTypes) ?? c.decode([IssueType].self, forKey: .values)
    }
}
struct CreateMetaFields: Decodable, Sendable {
    let fields: [CreateField]
    private enum CodingKeys: String, CodingKey { case fields, values }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fields =
            try c.decodeIfPresent([CreateField].self, forKey: .fields) ?? c.decode([CreateField].self, forKey: .values)
    }
}

struct EditField: Codable, Hashable, Sendable {
    let name: String
    let operations: [String]
    let schema: FieldSchema
    let allowedValues: [JSONValue]?
}

struct EditMeta: Codable, Hashable, Sendable { let fields: [String: EditField] }

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
    var issues: [Issue]
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
