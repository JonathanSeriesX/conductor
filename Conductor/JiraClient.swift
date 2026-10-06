import Foundation
import Security
import CryptoKit

struct Account: Codable, Sendable, Equatable, Identifiable {
    var id: UUID
    var site: URL      // https://team.atlassian.net
    var email: String
    var token: String

    /// The id is derived from host + email so a re-added account (or a dev launch) matches windows restored from a previous run.
    init(site: URL, email: String, token: String) {
        self.site = site; self.email = email; self.token = token
        let digest = SHA256.hash(data: Data("\(site.host() ?? "")|\(email.lowercased())".utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50; bytes[8] = (bytes[8] & 0x3F) | 0x80   // UUID v5 shape
        id = NSUUID(uuidBytes: bytes) as UUID
    }

    var label: String { "\(site.host() ?? "") (\(email))" }

    /// Accepts "team", "team.atlassian.net", or a full URL.
    static func normalizeSite(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if !s.contains("://") { s = "https://" + s }
        guard var comps = URLComponents(string: s), var host = comps.host, !host.isEmpty else { return nil }
        if !host.contains(".") { host += ".atlassian.net" }
        comps.host = host
        comps.path = ""
        comps.query = nil
        return comps.url
    }
}

struct JiraError: LocalizedError, Sendable {
    let status: Int
    let messages: [String]
    var errorDescription: String? {
        messages.isEmpty ? "Jira returned HTTP \(status)" : messages.joined(separator: "\n")
    }
    private struct Body: Decodable { let errorMessages: [String]?; let errors: [String: String]? }
    init(status: Int, data: Data) {
        self.status = status
        let b = try? JSONDecoder().decode(Body.self, from: data)
        var m = b?.errorMessages ?? []
        m += (b?.errors ?? [:]).map { "\($0.key): \($0.value)" }
        if m.isEmpty, status == 401 { m = ["Invalid email or API token."] }
        messages = m
    }
}

struct JiraClient: Sendable {
    let account: Account
    var sprintField: String?
    /// Every numeric field named like story points; which one a project uses shows up in its editmeta.
    var pointsFields: [String] = []

    private var api: URL { account.site.appending(path: "rest/api/3") }
    private var agile: URL { account.site.appending(path: "rest/agile/1.0") }
    private var authHeader: String {
        "Basic " + Data("\(account.email):\(account.token)".utf8).base64EncodedString()
    }

    static let listFields = "summary,status,assignee,priority,issuetype,updated,project,watches"
    var detailFields: String {
        var f = "summary,description,status,assignee,reporter,priority,issuetype,labels,created,updated,comment,attachment,project,parent,subtasks,issuelinks,worklog,timetracking,watches,duedate,components,fixVersions"
        if let sprintField { f += "," + sprintField }
        for p in pointsFields { f += "," + p }
        return f
    }

    // MARK: Requests

    private func request(_ path: String, query: [String: String] = [:], method: String = "GET", body: (any Encodable)? = nil, base: URL? = nil) async throws -> Data {
        var comps = URLComponents(url: (base ?? api).appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(body)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw JiraError(status: status, data: data) }
        return data
    }

    private func get<T: Decodable>(_ path: String, query: [String: String] = [:], base: URL? = nil) async throws -> T {
        try decoder.decode(T.self, from: try await request(path, query: query, base: base))
    }

    private func send<T: Decodable>(_ path: String, method: String, body: some Encodable) async throws -> T {
        try decoder.decode(T.self, from: try await request(path, method: method, body: body))
    }

    var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            if let date = Self.jiraDate.date(from: s) ?? Self.isoDate.date(from: s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "Bad date \(s)"))
        }
        if let sprintField { d.userInfo[.sprintField] = sprintField }
        d.userInfo[.pointsFields] = pointsFields
        return d
    }

    // Jira emits "2026-10-05T09:56:55.551+0300"; sprints emit ISO with Z. DateFormatter is thread-safe to read.
    private static let jiraDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        return f
    }()
    nonisolated(unsafe) private static let isoDate: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Raw bytes for images hosted on the site (avatars, thumbnails). Adds auth only for our own host.
    func data(for url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        if url.host == account.site.host { req.setValue(authHeader, forHTTPHeaderField: "Authorization") }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw JiraError(status: status, data: data) }
        return data
    }

    // MARK: Endpoints

    func myself() async throws -> JiraUser { try await get("myself") }

    /// Sprint and story points are custom fields whose ids differ per site.
    func customFieldIds() async throws -> (sprint: String?, points: [String]) {
        let fields: [FieldInfo] = try await get("field")
        let sprint = fields.first { $0.schema?.custom == "com.pyxis.greenhopper.jira:gh-sprint" }?.id
        let points = fields.filter { ["story points", "story point estimate"].contains($0.name.lowercased()) }.map(\.id)
        return (sprint, points)
    }

    func projects() async throws -> [Project] {
        var all: [Project] = []
        while true {
            let page: ProjectPage = try await get("project/search", query: ["maxResults": "100", "startAt": "\(all.count)", "orderBy": "name", "expand": "favourite"])
            all += page.values
            if page.isLast || page.values.isEmpty { return all }
        }
    }

    func favouriteFilters() async throws -> [Filter] { try await get("filter/favourite") }

    func search(jql: String, nextPageToken: String? = nil, fields: String = JiraClient.listFields) async throws -> SearchPage {
        var q = ["jql": jql, "maxResults": "50", "fields": fields]
        if let nextPageToken { q["nextPageToken"] = nextPageToken }
        return try await get("search/jql", query: q)
    }

    func issue(_ key: String) async throws -> Issue {
        try await get("issue/\(key)", query: ["fields": detailFields])
    }

    func transitions(_ key: String) async throws -> [Transition] {
        let list: TransitionList = try await get("issue/\(key)/transitions")
        return list.transitions
    }

    func transition(_ key: String, to id: String) async throws {
        struct Body: Encodable { struct T: Encodable { let id: String }; let transition: T }
        _ = try await request("issue/\(key)/transitions", method: "POST", body: Body(transition: .init(id: id)))
    }

    func assignableUsers(_ key: String, query: String) async throws -> [JiraUser] {
        try await get("user/assignable/search", query: ["issueKey": key, "query": query, "maxResults": "20"])
    }

    func assign(_ key: String, to accountId: String?) async throws {
        struct Body: Encodable { let accountId: String? ; func encode(to e: Encoder) throws {
            var c = e.container(keyedBy: AnyKey.self); try c.encode(accountId, forKey: AnyKey("accountId")) } }
        _ = try await request("issue/\(key)/assignee", method: "PUT", body: Body(accountId: accountId))
    }

    func addComment(_ key: String, text: String) async throws {
        struct Body: Encodable { let body: ADFNode }
        _ = try await request("issue/\(key)/comment", method: "POST", body: Body(body: .document(text: text)))
    }

    func addComment(_ key: String, body: ADFNode) async throws {
        struct Body: Encodable { let body: ADFNode }
        _ = try await request("issue/\(key)/comment", method: "POST", body: Body(body: body))
    }

    func updateComment(_ key: String, id: String, body: ADFNode) async throws {
        struct Body: Encodable { let body: ADFNode }
        _ = try await request("issue/\(key)/comment/\(id)", method: "PUT", body: Body(body: body))
    }

    func deleteComment(_ key: String, id: String) async throws {
        _ = try await request("issue/\(key)/comment/\(id)", method: "DELETE")
    }

    /// People search for @mentions; falls back to assignable users when the site hides the directory.
    func users(matching query: String) async throws -> [JiraUser] {
        try await get("user/search", query: ["query": query, "maxResults": "8"])
    }

    func assignableUsers(project: String, query: String) async throws -> [JiraUser] {
        try await get("user/assignable/search", query: ["project": project, "query": query, "maxResults": "20"])
    }

    // MARK: Create & edit

    func createIssueTypes(project: String) async throws -> [IssueType] {
        let m: CreateMetaTypes = try await get("issue/createmeta/\(project)/issuetypes", query: ["maxResults": "50"])
        return m.issueTypes
    }

    func createFields(project: String, issueType: String) async throws -> [CreateField] {
        let m: CreateMetaFields = try await get("issue/createmeta/\(project)/issuetypes/\(issueType)", query: ["maxResults": "200"])
        return m.fields
    }

    func createIssue(fields: [String: JSONValue]) async throws -> CreatedIssue {
        struct Body: Encodable { let fields: [String: JSONValue] }
        return try await send("issue", method: "POST", body: Body(fields: fields))
    }

    func editMeta(_ key: String) async throws -> EditMeta { try await get("issue/\(key)/editmeta") }

    func editIssue(_ key: String, fields: [String: JSONValue]) async throws {
        struct Body: Encodable { let fields: [String: JSONValue] }
        _ = try await request("issue/\(key)", method: "PUT", body: Body(fields: fields))
    }

    func priorities() async throws -> [Priority] { try await get("priority") }

    func issueTypes() async throws -> [IssueType] { try await get("issuetype") }

    // MARK: Attachments

    @discardableResult
    func uploadAttachment(_ key: String, data: Data, filename: String) async throws -> [Attachment] {
        let boundary = "conductor-\(UUID().uuidString)"
        var req = URLRequest(url: api.appending(path: "issue/\(key)/attachments"))
        req.httpMethod = "POST"
        req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        req.setValue("no-check", forHTTPHeaderField: "X-Atlassian-Token")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let safeName = filename.replacingOccurrences(of: "\"", with: "_")
        var body = Data()
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\nContent-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body
        let (resp, http) = try await URLSession.shared.data(for: req)
        let status = (http as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw JiraError(status: status, data: resp) }
        return try decoder.decode([Attachment].self, from: resp)
    }

    func deleteAttachment(id: String) async throws {
        _ = try await request("attachment/\(id)", method: "DELETE")
    }

    // MARK: Links & relations

    func linkTypes() async throws -> [LinkType] {
        let l: LinkTypeList = try await get("issueLinkType")
        return l.issueLinkTypes
    }

    func link(type: String, outward: String, inward: String) async throws {
        struct Ref: Encodable { let key: String }
        struct T: Encodable { let name: String }
        struct Body: Encodable { let type: T; let inwardIssue: Ref; let outwardIssue: Ref }
        _ = try await request("issueLink", method: "POST", body: Body(type: T(name: type), inwardIssue: Ref(key: inward), outwardIssue: Ref(key: outward)))
    }

    func deleteLink(id: String) async throws {
        _ = try await request("issueLink/\(id)", method: "DELETE")
    }

    func pickIssues(query: String, excluding key: String? = nil) async throws -> [IssuePickerResult.Item] {
        var q = ["query": query, "showSubTasks": "true"]
        if let key { q["currentIssueKey"] = key }
        let r: IssuePickerResult = try await get("issue/picker", query: q)
        return r.items
    }

    // MARK: Worklogs & watching

    func addWorklog(_ key: String, seconds: Int, comment: ADFNode?, started: Date) async throws {
        struct Body: Encodable { let timeSpentSeconds: Int; let comment: ADFNode?; let started: String }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        _ = try await request("issue/\(key)/worklog", method: "POST", body: Body(timeSpentSeconds: seconds, comment: comment, started: f.string(from: started)))
    }

    func deleteWorklog(_ key: String, id: String) async throws {
        _ = try await request("issue/\(key)/worklog/\(id)", method: "DELETE")
    }

    func watch(_ key: String, _ on: Bool, me: String? = nil) async throws {
        let accountId: String
        if let me { accountId = me } else { accountId = try await myself().accountId }
        if on {
            struct Body: Encodable { let accountId: String }
            _ = try await request("issue/\(key)/watchers", method: "POST", body: Body(accountId: accountId))
        } else {
            _ = try await request("issue/\(key)/watchers", query: ["accountId": accountId], method: "DELETE")
        }
    }

    // MARK: Boards (Agile API)

    func boards(project: String) async throws -> [Board] {
        let p: BoardPage = try await get("board", query: ["projectKeyOrId": project, "maxResults": "50"], base: agile)
        return p.values
    }

    func boardConfiguration(_ id: Int) async throws -> BoardConfiguration {
        try await get("board/\(id)/configuration", base: agile)
    }

    func sprints(board: Int, states: String = "active,future") async throws -> [Sprint] {
        let p: SprintPage = try await get("board/\(board)/sprint", query: ["state": states, "maxResults": "50"], base: agile)
        return p.values
    }

    /// `jql` narrows the board, e.g. with its quick filters. `parent` comes along for swimlanes.
    func boardIssues(_ id: Int, sprint: Int?, jql: String? = nil, startAt: Int = 0) async throws -> AgileIssuePage {
        let path = sprint.map { "board/\(id)/sprint/\($0)/issue" } ?? "board/\(id)/issue"
        var q = ["maxResults": "100", "startAt": "\(startAt)", "fields": Self.listFields + ",parent"]
        if let jql { q["jql"] = jql }
        return try await get(path, query: q, base: agile)
    }

    func quickFilters(board: Int) async throws -> [QuickFilter] {
        let p: QuickFilterPage = try await get("board/\(board)/quickfilter", query: ["maxResults": "50"], base: agile)
        return p.values
    }

    // MARK: Filters & JQL assist

    func createFilter(name: String, jql: String) async throws -> Filter {
        struct Body: Encodable { let name: String; let jql: String; let favourite: Bool }
        return try await send("filter", method: "POST", body: Body(name: name, jql: jql, favourite: true))
    }

    func jqlAutocomplete() async throws -> JQLAutocomplete { try await get("jql/autocompletedata") }

    func jqlSuggestions(field: String, value: String) async throws -> [JQLSuggestions.Result] {
        let s: JQLSuggestions = try await get("jql/autocompletedata/suggestions", query: ["fieldName": field, "fieldValue": value])
        return s.results
    }

    func browseURL(_ key: String) -> URL { account.site.appending(path: "browse/\(key)") }
    /// `[ES-123: summary](https://site/browse/ES-123)`, for pasting into Slack, Linear or Notion.
    func markdownLink(_ key: String, summary: String) -> String { "[\(key): \(summary)](\(browseURL(key).absoluteString))" }
}

// MARK: - Keychain

enum Keychain {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "org.evgenii.conductor",
          kSecAttrAccount as String: "accounts"]
    }

    static func load() -> [Account] {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return [] }
        return (try? JSONDecoder().decode([Account].self, from: data)) ?? []
    }

    static func save(_ accounts: [Account]) {
        SecItemDelete(query as CFDictionary)
        guard !accounts.isEmpty, let data = try? JSONEncoder().encode(accounts) else { return }
        var q = query
        q[kSecValueData as String] = data
        SecItemAdd(q as CFDictionary, nil)
    }
}
