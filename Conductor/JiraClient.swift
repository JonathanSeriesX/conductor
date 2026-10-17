import CryptoKit
import Foundation
import Security
import Synchronization

struct Account: Codable, Sendable, Equatable, Identifiable {
    var id: UUID
    var site: URL  // https://team.atlassian.net
    var email: String
    var token: String

    /// The id is derived from host + email so a re-added account (or a dev launch) matches windows restored from a previous run.
    init(site: URL, email: String, token: String) {
        self.site = site
        self.email = email
        self.token = token
        let digest = SHA256.hash(data: Data("\(site.host() ?? "")|\(email.lowercased())".utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80  // UUID v5 shape
        id = NSUUID(uuidBytes: bytes) as UUID
    }

    var label: String { "\(site.host() ?? "") (\(email))" }

    /// Jira Server / Data Center: any host Atlassian does not run. It speaks REST v2 (wiki-markup text where Cloud
    /// has ADF, usernames where Cloud has account ids) and signs in with a personal access token as a bearer.
    var isServer: Bool {
        let host = site.host() ?? ""
        return !["atlassian.net", "jira.com", "jira-dev.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Accepts "team", "team.atlassian.net", or a full URL; a Server URL keeps its context path ("/jira").
    static func normalizeSite(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if !s.contains("://") { s = "https://" + s }
        guard var comps = URLComponents(string: s), var host = comps.host, !host.isEmpty else { return nil }
        // "team" is a Cloud site; "localhost:8080" and "[::1]" are a Server of one's own.
        if !host.contains("."), !host.contains(":"), host != "localhost", comps.port == nil { host += ".atlassian.net" }
        comps.host = host
        // A pasted issue or board link: the site is what comes before Jira's own paths.
        var path = comps.path
        for marker in ["/browse/", "/secure/", "/projects/", "/issues/", "/jira/software/", "/plugins/", "/rest/"] {
            if let r = path.range(of: marker) { path = String(path[..<r.lowerBound]) }
        }
        comps.path = path.hasSuffix("/") ? String(path.dropLast()) : path
        comps.query = nil
        comps.fragment = nil
        return comps.url
    }
}

struct JiraError: LocalizedError, Sendable {
    let status: Int
    let messages: [String]
    var errorDescription: String? {
        messages.isEmpty ? String(localized: "Jira returned HTTP \(status)") : messages.joined(separator: "\n")
    }
    private struct Body: Decodable {
        let errorMessages: [String]?
        let errors: [String: String]?
    }
    /// `server`: a 401 there means the personal access token, as there is no email to get wrong.
    init(status: Int, data: Data, server: Bool = false) {
        self.status = status
        let b = try? JSONDecoder().decode(Body.self, from: data)
        var m = b?.errorMessages ?? []
        // Jira names the field in the message itself ("Summary can't exceed…"), and one bad parent comes back
        // under two keys with one text; the key prefix would only make it read like a log line.
        for v in (b?.errors ?? [:]).values.sorted() where !m.contains(v) { m.append(v) }
        if m.isEmpty, status == 401 {
            m = [
                server
                    ? String(localized: "Invalid personal access token.")
                    : String(localized: "Invalid email or API token.")
            ]
        }
        messages = m
    }
}

struct JiraClient: Sendable {
    let account: Account
    var sprintField: String?
    /// Every numeric field named like story points; which one a project uses shows up in its editmeta.
    var pointsFields: [String] = []
    /// Server only: epics are an issue type and a custom field there, where Cloud has `parent` and levels.
    var epics: EpicFields?

    private var server: Bool { account.isServer }
    private var api: URL { account.site.appending(path: server ? "rest/api/2" : "rest/api/3") }
    private var agile: URL { account.site.appending(path: "rest/agile/1.0") }
    private var authHeader: String {
        server
            ? "Bearer " + account.token
            : "Basic " + Data("\(account.email):\(account.token)".utf8).base64EncodedString()
    }
    /// Server names people by username in queries and payloads where Cloud takes an account id.
    private var userKey: String { server ? "username" : "accountId" }
    /// Server has no ADF: a description, comment or work-log note goes as wiki markup.
    private func text(_ fields: [String: JSONValue]) -> [String: JSONValue] {
        guard server, let d = fields["description"], d.object != nil, let data = try? JSONEncoder().encode(d),
            let doc = try? JSONDecoder().decode(ADFNode.self, from: data)
        else { return fields }
        var f = fields
        f["description"] = .string(doc.wiki)
        return f
    }
    private func text(_ body: ADFNode) -> JSONValue {
        server ? .string(body.wiki) : (try? JSONValue(body)) ?? .null
    }

    /// The fields that make `key` the parent (nil: none). A Server issue names its epic in a custom field; only a
    /// subtask has a `parent` there.
    func parentFields(_ key: String?, subtask: Bool) -> [String: JSONValue] {
        if server, !subtask, let link = epics?.link { return [link: key.map(JSONValue.string) ?? .null] }
        return ["parent": key.map { .object(["key": .string($0)]) } ?? .null]
    }

    /// Issues whose parent is one of `keys`; on Server, also those whose epic is.
    func childrenJQL(_ keys: [String]) -> String {
        let list = keys.map { "\"\($0)\"" }.joined(separator: ",")
        guard server, let link = epics?.link.split(separator: "_").last else { return "parent in (\(list))" }
        return "(parent in (\(list)) OR cf[\(link)] in (\(list)))"
    }

    /// Issues at `level` of the hierarchy (0 standard, 1 epic), where a parent is looked for. Server has no levels:
    /// its epics are an issue type, and every other type but the subtasks is standard.
    func levelJQL(_ level: Int) -> String {
        guard server, let epic = epics?.type else { return "hierarchyLevel = \(level)" }
        return level == 0 ? "issuetype in standardIssueTypes() AND issuetype != \(epic)" : "issuetype = \(epic)"
    }

    /// What a list row carries: everything the issue page's right column shows, so a page opened from a row is
    /// complete there at once; only the description, comments, attachments and links wait for the full record.
    var listFields: String {
        var f =
            "summary,status,assignee,reporter,priority,issuetype,created,updated,lastViewed,project,watches,parent,subtasks,labels,duedate,components,fixVersions,timetracking"
        if let sprintField { f += "," + sprintField }
        if let link = epics?.link { f += "," + link }
        for p in pointsFields { f += "," + p }
        return f
    }
    var detailFields: String {
        var f =
            "summary,description,status,assignee,reporter,priority,issuetype,labels,created,updated,comment,attachment,project,parent,subtasks,issuelinks,worklog,timetracking,watches,duedate,components,fixVersions"
        if let sprintField { f += "," + sprintField }
        if let link = epics?.link { f += "," + link }
        for p in pointsFields { f += "," + p }
        return f
    }

    // MARK: Requests

    private func request(
        _ path: String, query: [String: String] = [:], method: String = "GET", body: (any Encodable)? = nil,
        base: URL? = nil
    ) async throws -> Data {
        var comps = URLComponents(url: (base ?? api).appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.timeoutInterval = 30
        req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(body)
        }
        let host = account.site.host() ?? ""
        var retried = false
        while true {
            let (data, resp): (Data, URLResponse)
            do { (data, resp) = try await URLSession.shared.data(for: req) } catch {
                await Connectivity.shared.report(error, host: host)
                throw error
            }
            await Connectivity.shared.reportSuccess(host: host)
            let http = resp as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            if (200..<300).contains(status) { return data }
            // Rate limited or busy: wait as long as Jira asks (2 s when it doesn't say, 30 s at most), then once more.
            guard !retried, status == 429 || status == 503 else {
                throw JiraError(status: status, data: data, server: server)
            }
            retried = true
            let after = http?.value(forHTTPHeaderField: "Retry-After").flatMap { Int($0) } ?? 2
            try await Task.sleep(for: .seconds(min(max(after, 0), 30)))
        }
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
        if let epics {
            d.userInfo[.epicLinkField] = epics.link
            d.userInfo[.epicType] = epics.type
        }
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
        guard (200..<300).contains(status) else { throw JiraError(status: status, data: data, server: server) }
        return data
    }

    // MARK: Endpoints

    func myself() async throws -> JiraUser { try await get("myself") }

    /// Sprint and story points are custom fields whose ids differ per site; so are a Server's epic fields.
    func customFieldIds() async throws -> (sprint: String?, points: [String], epics: EpicFields?) {
        let fields: [FieldInfo] = try await get("field")
        func custom(_ type: String) -> String? {
            fields.first { $0.schema?.custom == "com.pyxis.greenhopper.jira:\(type)" }?.id
        }
        let points = fields.filter { ["story points", "story point estimate"].contains($0.name.lowercased()) }.map(\.id)
        var epics: EpicFields?
        if server, let link = custom("gh-epic-link") {
            // Jira Software's own record of which issue type is the epic; its name may be translated.
            struct Properties: Decodable { let epicTypeId: String? }
            let p: Properties? = try? await get(
                "api/epicproperties", base: account.site.appending(path: "rest/greenhopper/1.0"))
            epics = EpicFields(link: link, name: custom("gh-epic-label"), type: p?.epicTypeId)
        }
        return (custom("gh-sprint"), points, epics)
    }

    func projects() async throws -> [Project] {
        if server { return try await get("project") }  // the whole list at once; no paging and no favourites
        var all: [Project] = []
        while true {
            let page: ProjectPage = try await get(
                "project/search",
                query: ["maxResults": "100", "startAt": "\(all.count)", "orderBy": "name", "expand": "favourite"])
            all += page.values
            if page.isLast || page.values.isEmpty { return all }
        }
    }

    func favouriteFilters() async throws -> [Filter] { try await get("filter/favourite") }

    /// How many issues a query matches, give or take; enough for a progress bar.
    func approximateCount(jql: String) async throws -> Int {
        if server {
            let page: SearchPage = try await get("search", query: ["jql": jql, "maxResults": "0"])
            return page.total ?? 0
        }
        struct Body: Encodable { let jql: String }
        struct Count: Decodable { let count: Int }
        let c: Count = try await send("search/approximate-count", method: "POST", body: Body(jql: jql))
        return c.count
    }

    /// Server pages by offset; its `nextPageToken` is the next offset, so callers page the same way.
    func search(jql: String, nextPageToken: String? = nil, fields: String? = nil) async throws -> SearchPage {
        var q = ["jql": jql, "maxResults": "50", "fields": fields ?? listFields]
        if server {
            let start = Int(nextPageToken ?? "") ?? 0
            q["startAt"] = "\(start)"
            let page: SearchPage = try await get("search", query: q)
            let end = start + page.issues.count
            let more = end < (page.total ?? 0) && !page.issues.isEmpty
            return SearchPage(
                issues: await serverDetails(page.issues), nextPageToken: more ? "\(end)" : nil, isLast: !more,
                total: page.total)
        }
        if let nextPageToken { q["nextPageToken"] = nextPageToken }
        return try await get("search/jql", query: q)
    }

    /// Every change on the issue's History tab, newest first.
    func changelog(_ key: String) async throws -> [ChangeGroup] {
        if server {
            struct R: Decodable {
                struct C: Decodable { let histories: [ChangeGroup] }
                let changelog: C
            }
            let r: R = try await get("issue/\(key)", query: ["fields": "summary", "expand": "changelog"])
            return r.changelog.histories.reversed()
        }
        var all: [ChangeGroup] = []
        while true {
            let page: ChangelogPage = try await get(
                "issue/\(key)/changelog", query: ["maxResults": "100", "startAt": "\(all.count)"])
            all += page.values
            if page.isLast != false || page.values.isEmpty { return all.reversed() }
        }
    }

    /// The full record, with every comment and every work log.
    func issue(_ key: String) async throws -> Issue {
        let i: Issue = try await get("issue/\(key)", query: ["fields": detailFields])
        return try await completing(await withEpics([i])[0])
    }

    /// What Server leaves out that Cloud sends: each epic's summary, each mentioned person's name.
    private func serverDetails(_ issues: [Issue]) async -> [Issue] {
        guard server else { return issues }
        return await namingMentions(await withEpics(issues))
    }

    /// Server writes a mention as [~username]; the page shows the person's name, as Cloud's mention carries it.
    /// Names come from the people the issues already show, then once per unknown username from Jira.
    private func namingMentions(_ issues: [Issue]) async -> [Issue] {
        let host = account.site.host() ?? ""
        var names = Self.mentionNames.withLock { $0[host] ?? [:] }
        var wanted = Set<String>()
        for i in issues {
            let f = i.fields
            for u in [f.assignee, f.reporter].compactMap({ $0 }) + (f.comment?.comments.compactMap(\.author) ?? [])
                + (f.worklog?.worklogs.compactMap(\.author) ?? [])
            {
                names[u.accountId] = u.displayName
            }
            for doc in [f.description].compactMap({ $0 }) + (f.comment?.comments.map(\.body) ?? [])
                + (f.worklog?.worklogs.compactMap(\.comment) ?? [])
            {
                wanted.formUnion(doc.mentionIDs)
            }
        }
        let unknown = wanted.subtracting(names.keys)
        if !unknown.isEmpty {
            await withTaskGroup(of: JiraUser?.self) { group in
                for id in unknown { group.addTask { try? await get("user", query: ["username": id]) } }
                for await u in group { if let u { names[u.accountId] = u.displayName } }
            }
        }
        guard !wanted.isEmpty else { return issues }
        Self.mentionNames.withLock { [names] in $0[host] = names }
        return issues.map { i in
            var i = i
            i.fields.description = i.fields.description?.namingMentions(names)
            if let page = i.fields.comment {
                i.fields.comment = CommentPage(
                    comments: page.comments.map {
                        var c = $0
                        c.body = c.body.namingMentions(names)
                        return c
                    }, total: page.total)
            }
            if let page = i.fields.worklog {
                i.fields.worklog = WorklogPage(
                    worklogs: page.worklogs.map {
                        Worklog(
                            id: $0.id, author: $0.author, comment: $0.comment?.namingMentions(names),
                            started: $0.started,
                            timeSpent: $0.timeSpent, timeSpentSeconds: $0.timeSpentSeconds)
                    }, total: page.total)
            }
            return i
        }
    }
    /// Display names by username, per Server host, for the whole run.
    private static let mentionNames = Mutex<[String: [String: String]]>([:])

    /// Server: each issue's epic, read from its epic-link field as a bare key, gets its summary, status and type,
    /// all in one search.
    private func withEpics(_ issues: [Issue]) async -> [Issue] {
        let keys = Set(issues.compactMap { $0.fields.parent.flatMap { $0.fields.summary.isEmpty ? $0.key : nil } })
        guard server, !keys.isEmpty else { return issues }
        let jql = "key in (" + keys.sorted().map { "\"\($0)\"" }.joined(separator: ",") + ")"
        guard
            let page: SearchPage = try? await get(
                "search", query: ["jql": jql, "fields": "summary,status,issuetype", "maxResults": "\(keys.count)"])
        else { return issues }
        var refs: [String: IssueRef] = [:]
        for e in page.issues {
            refs[e.key] = IssueRef(
                id: e.id, key: e.key,
                fields: .init(summary: e.fields.summary, status: e.fields.status, issuetype: e.fields.issuetype))
        }
        return issues.map { i in
            var i = i
            if let key = i.fields.parent?.key, let ref = refs[key] { i.fields.parent = ref }
            return i
        }
    }

    /// `issue` with all its comments and work logs, each fetched only when the copy lacks some, both at once.
    func completing(_ issue: Issue) async throws -> Issue {
        async let comments = completingComments(issue)
        async let worklogs = allWorklogs(issue)
        var copy = try await comments
        if let w = try await worklogs { copy.fields.worklog = w }
        return server ? await namingMentions([copy])[0] : await namingFiles(copy)
    }

    /// Cloud names a file in a document by its Media Services id alone (a picture's node has its name too, as `alt`),
    /// and that id shows only where the attachment's content URL redirects. Each such file gets its attachment's name,
    /// so the page finds it among the issue's attachments as it finds a picture.
    private func namingFiles(_ issue: Issue) async -> Issue {
        let f = issue.fields
        let docs = [f.description].compactMap { $0 } + (f.comment?.comments.map(\.body) ?? [])
        guard let atts = f.attachment, !atts.isEmpty, docs.contains(where: \.hasUnnamedFiles) else {
            return issue
        }
        var names: [String: String] = [:]
        await withTaskGroup(of: (String, String)?.self) { group in
            for a in atts { group.addTask { await mediaID(of: a).map { ($0, a.filename) } } }
            for await p in group { if let p { names[p.0] = p.1 } }
        }
        var i = issue
        i.fields.description = f.description?.namingFiles(names)
        i.fields.comment = f.comment.map { page in
            CommentPage(
                comments: page.comments.map {
                    var c = $0
                    c.body = c.body.namingFiles(names)
                    return c
                }, total: page.total)
        }
        return i
    }

    /// An attachment's Media Services id, read off its content URL's redirect (…/file/<id>/binary); once per run.
    private func mediaID(of a: Attachment) async -> String? {
        if let hit = Self.mediaIDs.withLock({ $0[a.content] }) { return hit }
        var req = URLRequest(url: a.content)
        req.httpMethod = "HEAD"
        req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        guard let got = try? await URLSession.shared.data(for: req, delegate: StopAtRedirect()),
            let to = (got.1 as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location"),
            let m = to.firstMatch(of: /\/file\/([0-9a-fA-F-]+)\//)
        else { return nil }
        let id = String(m.1)
        Self.mediaIDs.withLock { $0[a.content] = id }
        return id
    }
    private static let mediaIDs = Mutex<[URL: String]>([:])

    /// Every work log, in Jira's order. A search result and an issue of its own both carry the oldest 20; the
    /// work-log endpoint gives up to 5,000 a page. Nil when the copy has them all already.
    private func allWorklogs(_ issue: Issue) async throws -> WorklogPage? {
        guard let page = issue.fields.worklog, page.worklogs.count < page.total else { return nil }
        var all: [Worklog] = []
        while true {
            let p: WorklogPage = try await get(
                "issue/\(issue.key)/worklog", query: ["startAt": "\(all.count)", "maxResults": "5000"])
            all += p.worklogs
            if p.worklogs.isEmpty || all.count >= p.total { return WorklogPage(worklogs: all, total: all.count) }
        }
    }

    /// `issue` with all its comments, oldest first. Jira embeds the first 20 in a search result and the newest 100
    /// in an issue; the comment endpoint pages 100 at a time, so every page is asked for at once. On Cloud always:
    /// only the endpoint's copy of a reply names its parent.
    private func completingComments(_ issue: Issue) async throws -> Issue {
        guard let page = issue.fields.comment, page.comments.count < page.total || (!server && page.total > 0) else {
            return issue
        }
        let key = issue.key
        let all = try await withThrowingTaskGroup(of: [Comment].self) { group in
            for start in stride(from: 0, to: page.total, by: 100) {
                group.addTask {
                    let p: CommentPage = try await get(
                        "issue/\(key)/comment", query: ["startAt": "\(start)", "maxResults": "100"])
                    return p.comments
                }
            }
            var out: [String: Comment] = [:]  // by id: a comment added meanwhile shifts the pages by one
            for try await p in group { for c in p { out[c.id] = c } }
            return out.values.sorted { ($0.created, Int($0.id) ?? 0) < ($1.created, Int($1.id) ?? 0) }
        }
        var copy = issue
        copy.fields.comment = CommentPage(comments: all, total: all.count)
        return copy
    }

    /// The newest comments, newest first. A search result carries the oldest 20, so a new one on a longer thread
    /// shows up only here.
    func recentComments(_ key: String, limit: Int = 20) async throws -> [Comment] {
        let p: CommentPage = try await get(
            "issue/\(key)/comment", query: ["orderBy": "-created", "maxResults": "\(limit)"])
        return p.comments
    }

    func transitions(_ key: String) async throws -> [Transition] {
        let list: TransitionList = try await get("issue/\(key)/transitions")
        return list.transitions
    }

    func transition(_ key: String, to id: String) async throws {
        struct Body: Encodable {
            struct T: Encodable { let id: String }
            let transition: T
        }
        _ = try await request("issue/\(key)/transitions", method: "POST", body: Body(transition: .init(id: id)))
    }

    func assignableUsers(_ key: String, query: String) async throws -> [JiraUser] {
        try await get(
            "user/assignable/search",
            query: ["issueKey": key, server ? "username" : "query": query, "maxResults": peopleLimit(query)])
    }

    /// An empty query is the whole list (the picker's first rows; the Assignee chip where the site hides its people), a
    /// typed one the best matches.
    /// ponytail: one page of 1000, Jira's cap; Cloud keeps the assignable ones among the site's first 1000 users, so a
    /// larger site would need startAt paging.
    private func peopleLimit(_ query: String) -> String { query.isEmpty ? "1000" : "20" }

    func assign(_ key: String, to accountId: String?) async throws {
        struct Body: Encodable {
            let accountId: String?
            let key: String
            func encode(to e: Encoder) throws {
                var c = e.container(keyedBy: AnyKey.self)
                try c.encode(accountId, forKey: AnyKey(key))
            }
        }
        _ = try await request(
            "issue/\(key)/assignee", method: "PUT", body: Body(accountId: accountId, key: server ? "name" : "accountId")
        )
    }

    /// `parentId` (Cloud only) makes it a reply: Jira takes a top-level comment there, or one deleted with replies
    /// left, and refuses a reply.
    func addComment(_ key: String, body: ADFNode, parentId: String? = nil) async throws {
        struct Body: Encodable {
            let body: JSONValue
            let parentId: String?
        }
        _ = try await request(
            "issue/\(key)/comment", method: "POST", body: Body(body: text(body), parentId: parentId))
    }

    func updateComment(_ key: String, id: String, body: ADFNode) async throws {
        struct Body: Encodable { let body: JSONValue }
        _ = try await request("issue/\(key)/comment/\(id)", method: "PUT", body: Body(body: text(body)))
    }

    func deleteComment(_ key: String, id: String) async throws {
        _ = try await request("issue/\(key)/comment/\(id)", method: "DELETE")
    }

    /// People search for @mentions; falls back to assignable users when the site hides the directory.
    func users(matching query: String) async throws -> [JiraUser] {
        try await get("user/search", query: [server ? "username" : "query": query, "maxResults": "8"])
    }

    /// Every active person on the site, by name, one page after another. Cloud lists apps and service desk customers
    /// too and pages up to 1000 (asked for more, it sends 1000). Server's user search stops at 100 matches whatever
    /// the paging, so it walks the user list's cursor instead.
    func everyone() async throws -> [JiraUser] {
        var all: [JiraUser] = []
        if server {
            struct Page: Decodable {
                let values: [JiraUser]
                let isLast: Bool?
                let nextCursor: String?
            }
            var cursor: String?
            repeat {
                var query = ["maxResults": "1000"]
                query["cursor"] = cursor
                let p: Page = try await get("user/list", query: query)
                all += p.values
                cursor = p.isLast == false ? p.nextCursor : nil
            } while cursor != nil
        } else {
            while true {
                let page: [JiraUser] = try await get(
                    "users/search", query: ["startAt": "\(all.count)", "maxResults": "1000"])
                all += page
                if page.count < 1000 { break }
            }
        }
        return Self.people(all)
    }

    /// The people among a site's users: active humans, by name.
    static func people(_ users: [JiraUser]) -> [JiraUser] {
        users.filter { $0.active == true && ($0.accountType ?? "atlassian") == "atlassian" }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    func assignableUsers(project: String, query: String) async throws -> [JiraUser] {
        try await get(
            "user/assignable/search",
            query: ["project": project, server ? "username" : "query": query, "maxResults": peopleLimit(query)]
        )
    }

    // MARK: Create & edit

    func createIssueTypes(project: String) async throws -> [IssueType] {
        let m: CreateMetaTypes = try await get("issue/createmeta/\(project)/issuetypes", query: ["maxResults": "50"])
        return m.issueTypes
    }

    /// On Server the epic link shows as `parent`, as Cloud's does, and the epic name is the summary's to fill.
    func createFields(project: String, issueType: String) async throws -> [CreateField] {
        let m: CreateMetaFields = try await get(
            "issue/createmeta/\(project)/issuetypes/\(issueType)", query: ["maxResults": "200"])
        guard server, let epics else { return m.fields }
        return m.fields.compactMap { f in
            if f.fieldId == epics.name { return nil }
            if f.fieldId == epics.link, !m.fields.contains(where: { $0.fieldId == "parent" }) {
                return CreateField(
                    fieldId: "parent", name: f.name, required: f.required, schema: f.schema,
                    allowedValues: f.allowedValues)
            }
            return f
        }
    }

    func createIssue(fields: [String: JSONValue]) async throws -> CreatedIssue {
        struct Body: Encodable { let fields: [String: JSONValue] }
        var f = text(fields)
        if server, let name = epics?.name, f[name] == nil, let type = epics?.type,
            f["issuetype"]?.object?["id"]?.string == type
        {
            f[name] = f["summary"]
        }
        return try await send("issue", method: "POST", body: Body(fields: f))
    }

    /// On Server the epic link stands in for `parent`, so the page offers it the same way.
    func editMeta(_ key: String) async throws -> EditMeta {
        let m: EditMeta = try await get("issue/\(key)/editmeta")
        guard server, let link = epics?.link, let field = m.fields[link], m.fields["parent"] == nil else { return m }
        var fields = m.fields
        fields["parent"] = field
        return EditMeta(fields: fields)
    }

    func editIssue(_ key: String, fields: [String: JSONValue]) async throws {
        struct Body: Encodable { let fields: [String: JSONValue] }
        _ = try await request("issue/\(key)", method: "PUT", body: Body(fields: text(fields)))
    }

    /// Every label on the site, for suggestions while typing one. Server has no full list and answers only its 15 most
    /// used, so the label editors there also ask `labelSuggestions` for what is typed.
    func labels() async throws -> [String] {
        if server { return try await jqlSuggestions(field: "labels", value: "").map(\.value) }
        struct Page: Decodable {
            let values: [String]
            let isLast: Bool
        }
        var all: [String] = []
        while true {
            let page: Page = try await get("label", query: ["maxResults": "1000", "startAt": "\(all.count)"])
            all += page.values
            if page.isLast || page.values.isEmpty { return all }
        }
    }

    /// The labels starting with `prefix`, at most 15; Jira matches the prefix itself.
    func labelSuggestions(_ prefix: String) async throws -> [String] {
        try await jqlSuggestions(field: "labels", value: prefix).map(\.value)
    }

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
        body.append(
            "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\nContent-Type: application/octet-stream\r\n\r\n"
                .data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body
        let (resp, http) = try await URLSession.shared.data(for: req)
        let status = (http as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw JiraError(status: status, data: resp, server: server) }
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

    /// Creates "`from` <type's outward wording> `to`", e.g. from blocks to. Jira's POST names the sides the
    /// other way round from what it later reports on each issue: the issue posted as `inwardIssue` is the one
    /// whose link reads with the outward wording.
    func link(type: String, from: String, to: String) async throws {
        struct Ref: Encodable { let key: String }
        struct T: Encodable { let name: String }
        struct Body: Encodable {
            let type: T
            let inwardIssue: Ref
            let outwardIssue: Ref
        }
        _ = try await request(
            "issueLink", method: "POST",
            body: Body(type: T(name: type), inwardIssue: Ref(key: from), outwardIssue: Ref(key: to)))
    }

    func deleteLink(id: String) async throws {
        _ = try await request("issueLink/\(id)", method: "DELETE")
    }

    func pickIssues(query: String, excluding key: String? = nil, jql: String = "ORDER BY updated DESC") async throws
        -> [IssuePickerResult.Item]
    {
        // Jira's "History Search" section only knows issues opened on the web; the "Current Search" section
        // needs a JQL scope, and an empty-text query lists recent issues of that scope.
        var q = ["query": query, "showSubTasks": "true", "currentJQL": jql]
        if let key { q["currentIssueKey"] = key }
        let r: IssuePickerResult = try await get("issue/picker", query: q)
        return r.items
    }

    // MARK: Worklogs & watching

    /// `adjustsEstimate`: subtract the time from the remaining estimate, which Jira otherwise does on its own and
    /// which leaves a "0m remaining" on an issue that never had an estimate.
    func addWorklog(_ key: String, seconds: Int, comment: ADFNode?, started: Date, adjustsEstimate: Bool) async throws {
        struct Body: Encodable {
            let timeSpentSeconds: Int
            let comment: JSONValue?
            let started: String
        }
        _ = try await request(
            "issue/\(key)/worklog", query: ["adjustEstimate": adjustsEstimate ? "auto" : "leave"], method: "POST",
            body: Body(
                timeSpentSeconds: seconds, comment: comment.map(text), started: Self.jiraDate.string(from: started)))
    }

    func deleteWorklog(_ key: String, id: String) async throws {
        // Jira's default ("auto") hands the time back to the remaining estimate, inventing one on issues that had none.
        _ = try await request("issue/\(key)/worklog/\(id)", query: ["adjustEstimate": "leave"], method: "DELETE")
    }

    func watchers(_ key: String) async throws -> [JiraUser] {
        struct R: Decodable { let watchers: [JiraUser] }
        let r: R = try await get("issue/\(key)/watchers")
        return r.watchers
    }

    func watch(_ key: String, _ on: Bool, me: String? = nil) async throws {
        let accountId: String
        if let me { accountId = me } else { accountId = try await myself().accountId }
        if on {
            // The body is the bare account id as a JSON string, not an object; Jira answers 400 to `{"accountId": …}`.
            _ = try await request("issue/\(key)/watchers", method: "POST", body: accountId)
        } else {
            _ = try await request("issue/\(key)/watchers", query: [userKey: accountId], method: "DELETE")
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

    /// A board's active and future sprints.
    func sprints(board: Int) async throws -> [Sprint] {
        let p: SprintPage = try await get(
            "board/\(board)/sprint", query: ["state": "active,future", "maxResults": "50"], base: agile)
        return p.values
    }

    /// `jql` narrows the board, e.g. with its quick filters. `parent` comes along for swimlanes.
    func boardIssues(_ id: Int, sprint: Int?, jql: String? = nil, startAt: Int = 0) async throws -> AgileIssuePage {
        let path = sprint.map { "board/\(id)/sprint/\($0)/issue" } ?? "board/\(id)/issue"
        var q = ["maxResults": "100", "startAt": "\(startAt)", "fields": listFields]
        if let jql { q["jql"] = jql }
        var page: AgileIssuePage = try await get(path, query: q, base: agile)
        page.issues = await serverDetails(page.issues)
        return page
    }

    func quickFilters(board: Int) async throws -> [QuickFilter] {
        if server {
            // Server's Agile API has no quick filters; the board's configuration page reads them from here.
            struct Model: Decodable {
                struct Config: Decodable {
                    struct Q: Decodable {
                        let id: Int
                        let name: String
                        let query: String
                    }
                    let quickFilters: [Q]
                }
                let quickFilterConfig: Config
            }
            let m: Model = try await get(
                "rapidviewconfig/editmodel.json", query: ["rapidViewId": "\(board)"],
                base: account.site.appending(path: "rest/greenhopper/1.0"))
            return m.quickFilterConfig.quickFilters.map { QuickFilter(id: $0.id, name: $0.name, jql: $0.query) }
        }
        let p: QuickFilterPage = try await get("board/\(board)/quickfilter", query: ["maxResults": "50"], base: agile)
        return p.values
    }

    // MARK: Filters & JQL assist

    func jqlAutocomplete() async throws -> JQLAutocomplete { try await get("jql/autocompletedata") }

    func jqlSuggestions(field: String, value: String) async throws -> [JQLSuggestions.Result] {
        let s: JQLSuggestions = try await get(
            "jql/autocompletedata/suggestions", query: ["fieldName": field, "fieldValue": value])
        return s.results
    }

    func browseURL(_ key: String) -> URL { account.site.appending(path: "browse/\(key)") }
    /// A board on the web: `rapidView=ID` redirects to the right team- or company-managed URL. Without an id,
    /// `/projects/KEY` lands on the project's own board; `RapidBoard.jspa?projectKey=` picks a wrong board.
    func boardURL(project: String, board: Int? = nil) -> URL {
        guard let board else { return account.site.appending(path: "projects/\(project)") }
        return account.site.appending(path: "secure/RapidBoard.jspa").appending(queryItems: [
            URLQueryItem(name: "rapidView", value: String(board))
        ])
    }
}

/// A Server's epic fields: the custom field naming an issue's epic, the epic's own name field, the epic issue type.
struct EpicFields: Codable, Hashable, Sendable {
    let link: String
    let name: String?
    let type: String?
}

// MARK: - Keychain

@MainActor enum Keychain {
    /// The last read failed for a reason other than "no item" (locked, a denied prompt). The accounts are still in
    /// there; nothing may write until a read succeeds.
    private(set) static var isUnavailable = false
    /// The last read found the data protection keychain locked (-25308 until the session's first unlock): it answers
    /// once the user logs in, so launch waits on its spinner rather than show the sign-in card.
    private(set) static var isLocked = false
    /// The last read's status, for the sign-in card to say why no accounts came back.
    private(set) static var lastStatus: OSStatus = errSecSuccess

    /// The data protection keychain grants access by entitlement (team + bundle id), so a rebuilt binary never
    /// raises the "wants to use your confidential information" dialog that the legacy keychain's per-binary ACL
    /// does. It needs a signing team; ad-hoc builds (CI releases) stay on the legacy keychain.
    private static let dataProtected: Bool = {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, "com.apple.application-identifier" as CFString, nil) != nil
    }()

    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "org.evgenii.conductor",
            kSecAttrAccount as String: "accounts",
            kSecUseDataProtectionKeychain as String: dataProtected,
        ]
    }

    static func load() -> [Account] {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        isUnavailable = status != errSecSuccess && status != errSecItemNotFound
        isLocked = status == errSecInteractionNotAllowed
        lastStatus = status
        guard status == errSecSuccess, let data = out as? Data else {
            if isUnavailable { NSLog("Keychain read failed: %d", status) }
            return []
        }
        return (try? JSONDecoder().decode([Account].self, from: data)) ?? []
    }

    static func save(_ accounts: [Account]) {
        guard !isUnavailable, let data = try? JSONEncoder().encode(accounts) else { return }
        if accounts.isEmpty {
            SecItemDelete(query as CFDictionary)
            return
        }
        // Updated in place: a delete followed by a failed add (the keychain locked) left no accounts at all.
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query
            q[kSecValueData as String] = data
            status = SecItemAdd(q as CFDictionary, nil)
        }
        if status != errSecSuccess { NSLog("Keychain write failed: %d", status) }
    }
}

/// Ends a request at its redirect, to read where it points.
private final class StopAtRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? { nil }
}
