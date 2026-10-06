import Foundation
import Security

struct Account: Codable, Sendable, Equatable, Identifiable {
    var id = UUID()
    var site: URL      // https://team.atlassian.net
    var email: String
    var token: String

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

    private var api: URL { account.site.appending(path: "rest/api/3") }
    private var authHeader: String {
        "Basic " + Data("\(account.email):\(account.token)".utf8).base64EncodedString()
    }

    static let listFields = "summary,status,assignee,priority,issuetype,updated,project"
    var detailFields: String {
        var f = "summary,description,status,assignee,reporter,priority,issuetype,labels,created,updated,comment,attachment,project,parent,subtasks"
        if let sprintField { f += "," + sprintField }
        return f
    }

    // MARK: Requests

    private func request(_ path: String, query: [String: String] = [:], method: String = "GET", body: (any Encodable)? = nil) async throws -> Data {
        var comps = URLComponents(url: api.appending(path: path), resolvingAgainstBaseURL: false)!
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

    private func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        try decoder.decode(T.self, from: try await request(path, query: query))
    }

    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            if let date = Self.jiraDate.date(from: s) ?? Self.isoDate.date(from: s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "Bad date \(s)"))
        }
        if let sprintField { d.userInfo[.sprintField] = sprintField }
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

    func sprintFieldId() async throws -> String? {
        let fields: [FieldInfo] = try await get("field")
        return fields.first { $0.schema?.custom == "com.pyxis.greenhopper.jira:gh-sprint" }?.id
    }

    func projects() async throws -> [Project] {
        var all: [Project] = []
        while true {
            let page: ProjectPage = try await get("project/search", query: ["maxResults": "100", "startAt": "\(all.count)", "orderBy": "name"])
            all += page.values
            if page.isLast || page.values.isEmpty { return all }
        }
    }

    func favouriteFilters() async throws -> [Filter] { try await get("filter/favourite") }

    func search(jql: String, nextPageToken: String? = nil) async throws -> SearchPage {
        var q = ["jql": jql, "maxResults": "50", "fields": Self.listFields]
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

    func browseURL(_ key: String) -> URL { account.site.appending(path: "browse/\(key)") }
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
