import XCTest

@testable import Conductor

final class JQLTests: XCTestCase {
    let account = UUID()
    /// Chips all off, whatever the Hide Done setting says.
    var blank: ListFilters {
        var f = ListFilters()
        f.status = .any
        return f
    }

    func testProjectKeysAreQuoted() {
        // IN is a JQL reserved word; unquoted it fails server-side.
        var f = blank
        f.account = account
        f.project = "IN"
        XCTAssertEqual(f.jql, "project = \"IN\" ORDER BY updated DESC")
    }

    func testFreeTextBecomesTextSearch() {
        var f = Smart.assigned.filters(account: account)
        f.status = .open
        f.text = "billing \"engine\""
        XCTAssertEqual(
            f.jql,
            "statusCategory != Done AND assignee = currentUser() AND text ~ \"billing \\\"engine\\\"\" ORDER BY updated DESC"
        )
    }

    func testIssueKeyIsLookedUpDirectly() {
        var f = blank
        f.text = "es-2284"
        XCTAssertEqual(f.jql, "key = \"ES-2284\"")
    }

    func testRawJQLPassesThrough() {
        var f = blank
        f.text = "status = Done order by created"
        XCTAssertEqual(f.jql, "status = Done order by created")
    }

    func testPresetsCarryTheirOwnOrderAndRoundTripThroughJSON() throws {
        let recent = Smart.recent.filters(account: account)
        XCTAssertEqual(recent.jql, "issuekey IN issueHistory() ORDER BY lastViewed DESC")
        XCTAssertEqual(Smart.reported.filters(account: nil).sort.field, .created)
        var f = Smart.watching.filters(account: account)
        f.status = .any
        f.jiraFilter = Filter(id: "7", name: "x", jql: "")
        f.type = "Bug"
        f.sort = .init(field: .priority, descending: false)
        XCTAssertEqual(try JSONDecoder().decode(ListFilters.self, from: JSONEncoder().encode(f)), f)
        XCTAssertEqual(f.jql, "filter = 7 AND watcher = currentUser() AND issuetype = \"Bug\" ORDER BY priority ASC")
    }

    /// One of the project's people: their id goes into the JQL and the preset keeps them; another project or
    /// account drops them, since ids belong to one site. A preset saved before people could be picked still loads.
    func testAPersonFilterNarrowsToThemAndStaysWithItsProject() throws {
        var f = blank
        f.account = account
        f.project = "QA"
        f.assignedTo = .init(id: "5b10ac8d82e05b22cc7d4ef5", name: "Ada Lovelace")
        XCTAssertEqual(f.jql, "project = \"QA\" AND assignee = \"5b10ac8d82e05b22cc7d4ef5\" ORDER BY updated DESC")
        XCTAssertEqual(try JSONDecoder().decode(ListFilters.self, from: JSONEncoder().encode(f)), f)
        f.project = "QA"
        XCTAssertNotNil(f.assignedTo, "the same project again keeps them")
        f.project = "ES"
        XCTAssertNil(f.assignedTo)
        f.assignedTo = .init(id: "jdoe", name: "Jane Doe")
        f.account = UUID()
        XCTAssertNil(f.assignedTo)
        let old = """
            {"project":"QA","scope":"Everything","status":"Open","assignee":"Assigned to me","reporter":"Any reporter",\
            "updated":"Any time","sort":{"field":"Updated","descending":true},"text":""}
            """
        let saved = try JSONDecoder().decode(ListFilters.self, from: Data(old.utf8))
        XCTAssertNil(saved.assignedTo)
        XCTAssertEqual(
            saved.jql, "project = \"QA\" AND statusCategory != Done AND assignee = currentUser() ORDER BY updated DESC")
    }

    /// A few accounts of several: the list takes only those, and one account set on its own wins.
    func testAFewAccountsNarrowTheUnifiedList() throws {
        let other = UUID()
        var f = Smart.reported.filters(account: nil)
        XCTAssertTrue(f.includes(account) && f.includes(other))
        f.accounts = [account]
        XCTAssertTrue(f.includes(account))
        XCTAssertFalse(f.includes(other))
        XCTAssertEqual(try JSONDecoder().decode(ListFilters.self, from: JSONEncoder().encode(f)), f)
        f.accounts = nil
        f.account = other
        XCTAssertFalse(f.includes(account))
    }

    func testMergeOrderMatchesTheClause() throws {
        let decoder = JiraClient(
            account: Account(site: URL(string: "https://x.atlassian.net")!, email: "e", token: "t")
        ).decoder
        func issue(_ key: String, priority: String, updated: String, type: String = "Task", level: Int = 0) throws
            -> Issue
        {
            try decoder.decode(
                Issue.self,
                from: Data(
                    #"{"id":"1","key":"\#(key)","fields":{"summary":"s","updated":"\#(updated)","priority":{"id":"\#(priority)","name":"p"},"status":{"id":"1","name":"To Do","statusCategory":{"key":"new","name":"To Do"}},"issuetype":{"id":"1","name":"\#(type)","hierarchyLevel":\#(level)}}}"#
                        .utf8))
        }
        let a = try issue("ES-9", priority: "3", updated: "2026-10-05T09:00:00.000Z")
        let b = try issue("ES-10", priority: "1", updated: "2026-10-06T09:00:00.000Z")
        XCTAssertTrue(ListFilters.Sort(field: .updated, descending: true).areInOrder(b, a))
        XCTAssertTrue(ListFilters.Sort(field: .updated, descending: false).areInOrder(a, b))
        // A tie on the field stays a tie for the merge, which must not split it; the list order breaks it by key.
        let c = try issue("ES-11", priority: "3", updated: "2026-10-05T09:00:00.000Z")
        XCTAssertEqual(ListFilters.Sort(field: .updated, descending: true).compare(a, c), .orderedSame)
        XCTAssertTrue(ListFilters.Sort(field: .updated, descending: true).areInOrder(c, a))
        XCTAssertTrue(
            ListFilters.Sort(field: .priority, descending: true).areInOrder(b, a),
            "DESC is the highest priority (lowest id) first, as in JQL")
        XCTAssertTrue(ListFilters.Sort(field: .key, descending: false).areInOrder(a, b), "keys compare numerically")
        let t = "2026-10-05T09:00:00.000Z"
        let types = [
            try issue("ES-1", priority: "3", updated: t, type: "Sub-task", level: -1),
            try issue("ES-2", priority: "3", updated: t, type: "Bug"),
            try issue("ES-3", priority: "3", updated: t, type: "Epic", level: 1),
            try issue("ES-4", priority: "3", updated: t),
        ]
        // Jira, Cloud and Data Center alike: ORDER BY issuetype ASC gave Bug, Epic, Story, Sub-task, Task.
        XCTAssertEqual(
            types.sorted(by: ListFilters.Sort(field: .type, descending: false).areInOrder).map(\.key),
            ["ES-2", "ES-3", "ES-1", "ES-4"], "A to Z by name")
        XCTAssertEqual(
            types.sorted(by: ListFilters.Sort(field: .type, descending: true).areInOrder).map(\.key),
            ["ES-4", "ES-1", "ES-3", "ES-2"])
    }

    /// Statuses sort as a board reads on Cloud; Data Center refuses "ORDER BY statusCategory", so it gets status alone.
    func testStatusSortAsksForTheCategoryWhereJiraCanSortByIt() {
        var f = ListFilters()
        f.sort = .init(field: .status, descending: false)
        XCTAssertTrue(f.jql.hasSuffix("ORDER BY statusCategory ASC, status ASC"), f.jql)
        XCTAssertEqual(JiraClient.serverJQL(f.jql), f.jql.replacingOccurrences(of: "statusCategory ASC, ", with: ""))
        XCTAssertEqual(JiraClient.serverJQL("a ORDER BY statusCategory DESC, status DESC"), "a ORDER BY status DESC")
        XCTAssertEqual(JiraClient.serverJQL("a ORDER BY updated DESC"), "a ORDER BY updated DESC")
    }

    /// A merged list waits only for the others' rows that tie with the slowest account's last one: that account's
    /// own tied rows show at once, in Jira's order. A reload keeps the rows below its fresh page until one reaches them.
    @MainActor func testMergeShowsTheWaitingAccountsTiesAndAReloadNeverShortensTheList() throws {
        let site = { (h: String) in
            AccountState(account: Account(site: URL(string: "https://\(h).atlassian.net")!, email: "e", token: "t"))
        }
        let (a, b) = (site("a"), site("b"))
        let decoder = a.client.decoder
        func row(_ key: String, _ second: Int, _ st: AccountState) throws -> ListRow {
            let issue = try decoder.decode(
                Issue.self,
                from: Data(
                    #"{"id":"1","key":"\#(key)","fields":{"summary":"s","updated":"2026-10-05T09:00:\#(String(format: "%02d", second)).000Z","status":{"id":"1","name":"To Do","statusCategory":{"key":"new","name":"To Do"}},"issuetype":{"id":"1","name":"Task"}}}"#
                        .utf8))
            return ListRow(issue: issue, state: st)
        }
        // A's page ends in a tie that runs on into its next page; its keys sort against Jira's order on purpose.
        let rowsA = [try row("A-1", 10, a), try row("A-9", 5, a), try row("A-10", 5, a), try row("A-2", 5, a)]
        let rowsB = [try row("B-1", 7, b), try row("B-2", 5, b), try row("B-3", 3, b)]
        let sort = ListFilters.Sort(field: .updated, descending: true)
        XCTAssertEqual(
            IssueListStore.merge([rowsA, rowsB], bound: rowsA.last, sort: sort).map(\.issue.key),
            ["A-1", "B-1", "A-9", "A-10", "A-2"])
        XCTAssertEqual(
            IssueListStore.merge([rowsA, rowsB], bound: nil, sort: sort).map(\.issue.key),
            ["A-1", "B-1", "A-9", "A-10", "A-2", "B-2", "B-3"], "everything is in: ties go in account order")

        // B-0 is new, B-2 moved further down: the rows below the fresh page stay, less what it already holds.
        let old = [try row("B-1", 7, b), try row("B-2", 5, b), try row("B-3", 3, b), try row("B-4", 2, b)]
        let fresh = [try row("B-0", 9, b), try row("B-1", 7, b), try row("B-3", 3, b)]
        XCTAssertEqual(
            IssueListStore.refreshed(old, fetched: fresh, more: true).map(\.issue.key), ["B-0", "B-1", "B-3", "B-4"])
        XCTAssertEqual(
            IssueListStore.refreshed(old, fetched: fresh, more: false).map(\.issue.key), ["B-0", "B-1", "B-3"],
            "the list ends with the fresh rows")
        // B-4, edited, went to the top: B-3, pushed past the fresh page, stays below it.
        let edited = [try row("B-4", 9, b), try row("B-1", 7, b), try row("B-2", 5, b)]
        XCTAssertEqual(
            IssueListStore.refreshed(old, fetched: edited, more: true).map(\.issue.key), ["B-4", "B-1", "B-2", "B-3"])
        // The whole list from disk goes under the first page on screen, which is as new or newer: B-0 came since,
        // and the rest runs on from where that page ends, once each.
        let whole = old + [try row("B-5", 1, b), try row("B-6", 0, b)]
        XCTAssertEqual(
            IssueListStore.refreshed(whole, fetched: fresh, more: true).map(\.issue.key),
            ["B-0", "B-1", "B-3", "B-4", "B-5", "B-6"])
        // Every account whole: the merge waits on none and is one plain sort.
        XCTAssertEqual(
            IssueListStore.merge([rowsA, whole], bound: nil, sort: sort).map(\.issue.key),
            ["A-1", "B-1", "A-9", "A-10", "A-2", "B-2", "B-3", "B-4", "B-5", "B-6"])
    }

    /// A selected row a reload drops stays where it was, after the row above it; one that only moved is not kept.
    @MainActor func testASelectedRowTheReloadDropsKeepsItsPlace() throws {
        let st = AccountState(account: Account(site: URL(string: "https://a.atlassian.net")!, email: "e", token: "t"))
        func rows(_ keys: String...) throws -> [ListRow] {
            try keys.map { key in
                let issue = try st.client.decoder.decode(
                    Issue.self,
                    from: Data(
                        #"{"id":"1","key":"\#(key)","fields":{"summary":"s","status":{"id":"1","name":"To Do","statusCategory":{"key":"new","name":"To Do"}},"issuetype":{"id":"1","name":"Task"}}}"#
                            .utf8))
                return ListRow(issue: issue, state: st)
            }
        }
        func kept(_ keys: String...) -> Set<IssueTarget> { Set(keys.map { IssueTarget(accountID: st.id, key: $0) }) }
        let old = try rows("A-1", "A-2", "A-3", "A-4")
        func keys(_ r: ([ListRow], Set<String>)) -> [String] { r.0.map(\.issue.key) }
        XCTAssertEqual(
            keys(IssueListStore.keeping(kept("A-3"), of: old, in: try rows("A-1", "A-2", "A-4"))),
            ["A-1", "A-2", "A-3", "A-4"])
        XCTAssertEqual(
            keys(IssueListStore.keeping(kept("A-2", "A-3"), of: old, in: try rows("A-1", "A-4"))),
            ["A-1", "A-2", "A-3", "A-4"], "two in a row keep their order")
        XCTAssertEqual(
            keys(IssueListStore.keeping(kept("A-1"), of: old, in: try rows("A-2", "A-3"))),
            ["A-1", "A-2", "A-3"])
        let moved = IssueListStore.keeping(kept("A-3"), of: old, in: try rows("A-3", "A-1", "A-2", "A-4"))
        XCTAssertEqual(keys(moved), ["A-3", "A-1", "A-2", "A-4"])
        XCTAssertTrue(moved.1.isEmpty, "a row that only moved is not greyed")
        XCTAssertEqual(keys(IssueListStore.keeping([], of: old, in: try rows("A-1"))), ["A-1"])
    }

    /// A refresh of a whole list: the keys in the server's order, each once, each the newest copy there is (a changed
    /// row, else the row as it stands), a key nobody has left out; rows that tie keep the order they stand in.
    @MainActor func testASyncTakesTheServersOrderAndTheNewestRows() throws {
        let st = AccountState(account: Account(site: URL(string: "https://a.atlassian.net")!, email: "e", token: "t"))
        func row(_ key: String, _ second: Int, _ summary: String = "s") throws -> ListRow {
            let issue = try st.client.decoder.decode(
                Issue.self,
                from: Data(
                    #"{"id":"1","key":"\#(key)","fields":{"summary":"\#(summary)","updated":"2026-10-05T09:00:\#(String(format: "%02d", second)).000Z","status":{"id":"1","name":"To Do","statusCategory":{"key":"new","name":"To Do"}},"issuetype":{"id":"1","name":"Task"}}}"#
                        .utf8))
            return ListRow(issue: issue, state: st)
        }
        let rows = [try row("A-1", 9), try row("A-2", 8), try row("A-3", 8), try row("A-4", 5), try row("A-5", 3)]
        // A-4 was edited and leads; A-5 left the list; A-6 joined (fetched by key); A-7 is listed but came in neither.
        // The server ties A-3 and A-2 the other way round.
        let out = IssueListStore.synced(
            ["A-4", "A-1", "A-3", "A-2", "A-7", "A-6", "A-4"], rows: rows,
            changed: [try row("A-4", 10, "edited"), try row("A-6", 1)],
            sort: ListFilters.Sort(field: .updated, descending: true))
        XCTAssertEqual(out.map(\.issue.key), ["A-4", "A-1", "A-2", "A-3", "A-6"])
        XCTAssertEqual(out[0].issue.fields.summary, "edited")
        XCTAssertTrue(out[1] === rows[0], "an unchanged row is the same object, which the redraw skips")

        // The changes since the last pass: the list's query narrowed by the server's own clock, newest first.
        XCTAssertEqual(
            IssueListStore.changed(#"project = "KAN" AND statusCategory != Done ORDER BY updated DESC"#, minutes: 8),
            #"(project = "KAN" AND statusCategory != Done) AND (updated >= -8m OR lastViewed >= -8m) ORDER BY updated DESC"#
        )
        XCTAssertEqual(
            IssueListStore.changed("assignee = currentUser() order by created", minutes: 5),
            "(assignee = currentUser()) AND (updated >= -5m OR lastViewed >= -5m) ORDER BY updated DESC")
        XCTAssertEqual(
            IssueListStore.changed("ORDER BY key", minutes: 5),
            "(updated >= -5m OR lastViewed >= -5m) ORDER BY updated DESC")
        // A list's count is kept under its query without the order, so every order finds it (CON-282).
        XCTAssertEqual(
            IssueListStore.countName("assignee = currentUser() ORDER BY updated DESC"),
            IssueListStore.countName("assignee = currentUser() order by statusCategory ASC, status ASC"))
    }

    /// Search suggestions: the five newest issues in memory by key prefix or summary, a key once across accounts.
    @MainActor func testSuggestionsAreTheFiveNewestMatches() throws {
        let site = { (h: String) in
            AccountState(account: Account(site: URL(string: "https://\(h).atlassian.net")!, email: "e", token: "t"))
        }
        let (a, b) = (site("a"), site("b"))
        func put(_ key: String, _ summary: String, _ second: Int, _ st: AccountState) throws {
            st.peek[key] = try st.client.decoder.decode(
                Issue.self,
                from: Data(
                    #"{"id":"1","key":"\#(key)","fields":{"summary":"\#(summary)","updated":"2026-10-05T09:00:\#(String(format: "%02d", second)).000Z","status":{"id":"1","name":"To Do","statusCategory":{"key":"new","name":"To Do"}},"issuetype":{"id":"1","name":"Task"}}}"#
                        .utf8))
        }
        for n in 1...7 { try put("QA-\(n)", "Fix the login", n, a) }
        try put("QA-8", "Unrelated", 50, a)
        try put("QA-7", "Fix the login, the other site's", 59, b)
        try put("ST-1", "Login page", 40, b)
        XCTAssertEqual(
            IssueListView.newestKnown(matching: "login", in: [a, b]).map(\.key),
            ["ST-1", "QA-7", "QA-6", "QA-5", "QA-4"])
        XCTAssertEqual(IssueListView.newestKnown(matching: "qa-8", in: [a, b]).map(\.key), ["QA-8"], "a key prefix")
        XCTAssertEqual(IssueListView.newestKnown(matching: "nothing", in: [a, b]).map(\.key), [])
    }

    /// Jira puts undated issues first under "duedate DESC"; the list puts them last whichever way it sorts.
    @MainActor func testDueDateOrderPutsUndatedLast() throws {
        func issue(_ key: String, due: String?) throws -> Issue {
            let d = due.map { "\"\($0)\"" } ?? "null"
            return try JSONDecoder().decode(
                Issue.self,
                from: Data(
                    #"{"id":"\#(key)","key":"\#(key)","fields":{"summary":"s","duedate":\#(d),"status":{"id":"1","name":"To Do","statusCategory":{"key":"new","name":"To Do"}},"issuetype":{"id":"1","name":"Task"}}}"#
                        .utf8))
        }
        let early = try issue("A-1", due: "2026-10-01")
        let late = try issue("A-2", due: "2026-10-20")
        let none = try issue("A-3", due: nil)
        let desc = ListFilters.Sort(field: .due, descending: true)
        let asc = ListFilters.Sort(field: .due, descending: false)
        XCTAssertEqual([none, early, late].sorted(by: desc.areInOrder).map(\.key), ["A-2", "A-1", "A-3"])
        XCTAssertEqual([none, late, early].sorted(by: asc.areInOrder).map(\.key), ["A-1", "A-2", "A-3"])
        // Ties go by key the same way, as the queries ask Jira to, so a merge and a page agree.
        let alsoLate = try issue("A-10", due: "2026-10-20")
        let alsoNone = try issue("A-11", due: nil)
        XCTAssertEqual(
            [none, alsoNone, late, alsoLate].sorted(by: desc.areInOrder).map(\.key), ["A-10", "A-2", "A-11", "A-3"])
        XCTAssertEqual(
            [alsoNone, none, alsoLate, late].sorted(by: asc.areInOrder).map(\.key), ["A-2", "A-10", "A-3", "A-11"])
        // Jira itself is asked twice: the dated issues, then the undated, each part in a fixed order.
        var f = ListFilters()
        f.project = "QA"
        f.sort = desc
        XCTAssertEqual(
            f.jqlParts,
            [
                "project = \"QA\" AND statusCategory != Done AND duedate IS NOT EMPTY ORDER BY duedate DESC, key DESC",
                "project = \"QA\" AND statusCategory != Done AND duedate IS EMPTY ORDER BY key DESC",
            ].map { f.status == .open ? $0 : $0.replacingOccurrences(of: " AND statusCategory != Done", with: "") })
        f.sort.field = .updated
        XCTAssertEqual(f.jqlParts, [f.jql], "any other order is one query")
    }
}

final class ADFTests: XCTestCase {
    func testPlainTextDocumentHasOneParagraphPerLine() throws {
        let doc = ADFNode.document(markdown: "first\n\nthird")
        XCTAssertEqual(doc.type, "doc")
        XCTAssertEqual(doc.version, 1)
        XCTAssertEqual(doc.content?.count, 2, "a blank line ends a paragraph and makes none of its own")
        XCTAssertEqual(doc.content?[0].content?.first?.text, "first")
        XCTAssertEqual(doc.content?[1].content?.first?.text, "third")
        XCTAssertEqual(doc.plainText, "first\nthird")
    }

    @MainActor func testRealWorldNodesDecodeAndRender() throws {
        let json = """
            {"type":"doc","version":1,"content":[
              {"type":"heading","attrs":{"level":2},"content":[{"type":"text","text":"Контекст"}]},
              {"type":"paragraph","content":[
                {"type":"text","text":"Карточка ","marks":[]},
                {"type":"text","text":"View all","marks":[{"type":"strong"}]},
                {"type":"hardBreak"},
                {"type":"mention","attrs":{"id":"abc","text":"@Vitaly"}},
                {"type":"inlineCard","attrs":{"url":"https://example.com/x"}}]},
              {"type":"bulletList","content":[{"type":"listItem","content":[{"type":"paragraph","content":[{"type":"text","text":"item"}]}]}]},
              {"type":"mediaSingle","attrs":{"layout":"center"},"content":[{"type":"media","attrs":{"id":"m","type":"file","alt":"shot.png"}}]}
            ]}
            """
        let doc = try JSONDecoder().decode(ADFNode.self, from: Data(json.utf8))
        XCTAssertEqual(doc.content?.count, 4)
        let rendered = ADFAttributed.render(doc, attachments: []) { _ in nil }
        for part in ["Контекст", "Карточка View all", "@Vitaly", "example.com/x"] {
            XCTAssertTrue(rendered.string.contains(part), part)
        }
        var linked = false
        rendered.enumerateAttribute(.link, in: NSRange(location: 0, length: rendered.length)) { value, _, _ in
            linked = linked || value as? URL == URL(string: "https://example.com/x")
        }
        XCTAssertTrue(linked, "the inline card links to its page")
        // Round-trips through Codable without losing attrs.
        let again = try JSONDecoder().decode(ADFNode.self, from: JSONEncoder().encode(doc))
        XCTAssertEqual(again, doc)
    }
}

final class DecodingTests: XCTestCase {
    @MainActor func testConnectivityIsPerHostAndOnlyForTransportErrors() {
        let c = Connectivity()
        c.report(URLError(.timedOut), host: "a")
        c.report(JiraError(status: 500, data: Data()), host: "b")  // Jira answered: not offline
        XCTAssertEqual(c.offlineHosts, ["a"])
        let hung = ContinuousClock.now
        c.reportSuccess(host: "a")
        XCTAssertFalse(c.isOffline)
        // Sent before the site answered again: it hung through the outage, and the site is back (CON-287).
        c.report(URLError(.timedOut), host: "a", sent: hung)
        XCTAssertFalse(c.isOffline)
        c.report(URLError(.timedOut), host: "a")
        XCTAssertTrue(c.isOffline)
    }

    func testAccountIDIsStableAcrossLaunches() {
        let site = URL(string: "https://x.atlassian.net")!
        XCTAssertEqual(
            Account(site: site, email: "E@x.com", token: "a").id, Account(site: site, email: "e@x.com", token: "b").id)
        XCTAssertNotEqual(
            Account(site: site, email: "e@x.com", token: "a").id, Account(site: site, email: "f@x.com", token: "a").id)
    }

    struct Dates: Decodable {
        let a: Date
        let b: Date
    }

    func testBothJiraDateFormatsDecode() throws {
        let decoder = JiraClient(
            account: Account(site: URL(string: "https://x.atlassian.net")!, email: "e", token: "t")
        ).decoder
        let json = #"{"a":"2026-10-05T09:56:55.551+0300","b":"2026-09-16T15:04:00.000Z"}"#
        let d = try decoder.decode(Dates.self, from: Data(json.utf8))
        XCTAssertEqual(d.a.timeIntervalSince1970, 1791183415.551, accuracy: 0.001)
        XCTAssertEqual(d.b.timeIntervalSince1970, 1_789_571_040, accuracy: 0.001)
    }

    func testStoryPointsComeFromWhicheverPointsFieldIsSet() throws {
        var client = JiraClient(account: Account(site: URL(string: "https://x.atlassian.net")!, email: "e", token: "t"))
        client.pointsFields = ["customfield_10026", "customfield_10016"]
        let json =
            #"{"id":"1","key":"ES-1","fields":{"summary":"s","status":{"id":"1","name":"To Do","statusCategory":{"key":"new","name":"To Do"}},"issuetype":{"id":"1","name":"Task"},"customfield_10026":null,"customfield_10016":5,"duedate":"2026-10-31","components":[{"id":"7","name":"API"}]}}"#
        let issue = try client.decoder.decode(Issue.self, from: Data(json.utf8))
        XCTAssertEqual(issue.points, 5)
        XCTAssertEqual(issue.fields.components?.map(\.name), ["API"])
        XCTAssertEqual(issue.fields.duedate.flatMap(DueDate.parse).map(DueDate.string), "2026-10-31")
    }

    func testACopyWithFewerCommentsThanTheTotalIsIncomplete() throws {
        let client = JiraClient(account: Account(site: URL(string: "https://x.atlassian.net")!, email: "e", token: "t"))
        func issue(_ comment: String) throws -> Issue {
            let json =
                #"{"id":"1","key":"QA-1","fields":{"summary":"s","status":{"id":"1","name":"To Do","statusCategory":{"key":"new","name":"To Do"}},"issuetype":{"id":"1","name":"Task"}"#
                + comment + "}}"
            return try client.decoder.decode(Issue.self, from: Data(json.utf8))
        }
        let c =
            #"{"id":"10","body":"hi","created":"2026-10-05T09:56:55.551+0300","updated":"2026-10-05T09:56:55.551+0300"}"#
        // A search result carries the first 20 of a longer thread; an issue of its own the newest 100.
        XCTAssertFalse(try issue(#","comment":{"comments":["# + c + #"],"total":3}"#).hasAllComments)
        XCTAssertTrue(try issue(#","comment":{"comments":["# + c + #"],"total":1}"#).hasAllComments)
        XCTAssertTrue(try issue(#","comment":{"comments":[],"total":0}"#).hasAllComments)
        // A list row has no comments at all: not a full record.
        XCTAssertFalse(try issue("").hasAllComments)
    }

    func testWorkLogsCountTowardACompleteCopy() throws {
        let client = JiraClient(account: Account(site: URL(string: "https://x.atlassian.net")!, email: "e", token: "t"))
        func issue(worklog: String) throws -> Issue {
            let json =
                #"{"id":"1","key":"QA-1","fields":{"summary":"s","status":{"id":"1","name":"To Do","statusCategory":{"key":"new","name":"To Do"}},"issuetype":{"id":"1","name":"Task"},"comment":{"comments":[],"total":0}"#
                + worklog + "}}"
            return try client.decoder.decode(Issue.self, from: Data(json.utf8))
        }
        let w = #"{"id":"7","timeSpent":"1h","timeSpentSeconds":3600,"started":"2026-10-05T09:56:55.551+0300"}"#
        // Jira embeds a work log's oldest 20 entries in an issue and in a search result alike.
        XCTAssertFalse(try issue(worklog: #","worklog":{"worklogs":["# + w + #"],"total":30}"#).isComplete)
        XCTAssertTrue(try issue(worklog: #","worklog":{"worklogs":["# + w + #"],"total":1}"#).isComplete)
        XCTAssertTrue(try issue(worklog: "").isComplete, "no work log field: nothing to complete")
    }

    func testRepliesSitUnderTheirThreadInEitherOrder() throws {
        let client = JiraClient(account: Account(site: URL(string: "https://x.atlassian.net")!, email: "e", token: "t"))
        func comment(_ id: String, _ parent: String = "") throws -> Comment {
            let json =
                #"{"id":"\#(id)","body":"x","created":"2026-10-05T09:56:55.551+0300","updated":"2026-10-05T09:56:55.551+0300""#
                + parent + "}"
            return try client.decoder.decode(Comment.self, from: Data(json.utf8))
        }
        // Jira sends a reply's parent as a number, a copy on disk keeps it as text, a top-level comment has none.
        let all = try [
            comment("1"), comment("2", #","parentId":1"#), comment("3"),
            comment("4", #","parentId":"2""#),  // a reply to a reply: Jira refuses one, but shows what it has
            comment("5", #","parentId":99"#),  // its parent deleted
            comment("6", #","parentId":1"#), comment("7", #","parentId":99"#),
        ]
        XCTAssertEqual(all.map(\.parentId), [nil, "1", nil, "2", "99", "1", "99"])
        XCTAssertEqual(try JSONDecoder().decode(Comment.self, from: JSONEncoder().encode(all[1])), all[1])
        // Replies stay oldest first under their thread whichever way the threads run; orphans lead a thread of
        // their own.
        let oldest = Comment.threads(all, newestFirst: false)
        XCTAssertEqual(oldest.map(\.comment.id), ["1", "2", "4", "6", "3", "5", "7"])
        XCTAssertEqual(oldest.map(\.root), ["1", "1", "1", "1", "3", "99", "99"])
        XCTAssertEqual(Comment.threads(all, newestFirst: true).map(\.comment.id), ["5", "7", "3", "1", "2", "4", "6"])
    }

    @MainActor func testFilesNamedByIDAloneShowAsTheirAttachments() throws {
        let json =
            #"{"type":"doc","version":1,"content":[{"type":"mediaGroup","content":[{"type":"media","attrs":{"type":"file","id":"m1","collection":""}},{"type":"media","attrs":{"type":"file","id":"m2","collection":"","alt":"shot.png"}}]}]}"#
        let doc = try JSONDecoder().decode(ADFNode.self, from: Data(json.utf8))
        XCTAssertTrue(doc.hasUnnamedFiles)
        let named = doc.namingFiles(["m1": "data.json", "m2": "other.png"])
        XCTAssertEqual(named.content?[0].content?.map { $0.attr("alt") }, ["data.json", "shot.png"])
        XCTAssertFalse(named.hasUnnamedFiles)
        let file = Attachment(
            id: "10", filename: "data.json", mimeType: "application/json", size: 62,
            content: URL(string: "https://x.atlassian.net/rest/api/3/attachment/content/10")!, thumbnail: nil,
            created: .now, author: nil)
        let text = ADFAttributed.render(named, attachments: [file]) { _ in nil }
        var cells: [String] = []
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { v, _, _ in
            if let c = (v as? NSTextAttachment)?.attachmentCell { cells.append("\(type(of: c))") }
        }
        XCTAssertEqual(cells, ["FileChipCell", "ChipCell"], "shot.png is none of the issue's attachments")
    }

    func testHistoryReadsLikeTheIssuePage() {
        typealias Item = ChangeGroup.Item
        let spent = Item(field: "timespent", fromString: "3600", toString: "5400", from: "3600", to: "5400")
        XCTAssertEqual(spent.shownFrom.map { String($0.characters) }, "1h")
        XCTAssertEqual(spent.shownTo.map { String($0.characters) }, "1h 30m")
        XCTAssertEqual(spent.label, String(localized: "History.TimeSpent", defaultValue: "Time spent"))
        XCTAssertTrue(Item(field: "WorklogId", fromString: nil, toString: "10169").isNoise)
        XCTAssertTrue(Item(field: "timeestimate", fromString: "0", toString: "0", from: "0", to: "0").isNoise)
        XCTAssertEqual(
            Item(field: "IssueParentAssociation", fromString: nil, toString: "QA-18").label, String(localized: "Parent")
        )
        let due = Item(
            field: "duedate", fromString: "2026-10-18 00:00:00.0", toString: nil, from: "2026-10-18", to: nil)
        XCTAssertEqual(
            due.shownFrom.map { String($0.characters) },
            DueDate.parse("2026-10-18")!.formatted(date: .abbreviated, time: .omitted))
        // Jira keeps texts in wiki markup here: the markup goes, the formatting stays.
        let text = ChangeGroup.Item.fromWiki("*bold* and _it_ and a [link|https://example.com] in QA-18_x")
        XCTAssertEqual(String(text.characters), "bold and it and a link in QA-18_x")
        XCTAssertTrue(text.runs.contains { $0.link == URL(string: "https://example.com") })
        // Block marks go too, and blocks sit a line apart, not two.
        let blocks = ChangeGroup.Item.fromWiki(
            "h1. Heading one\nh2. Heading two\n* item\n# first\n{code}\nlet a = 1\n{code}")
        XCTAssertEqual(String(blocks.characters), "Heading one\nHeading two\n• item\n• first\nlet a = 1")
    }

    func testSiteNormalization() {
        XCTAssertEqual(Account.normalizeSite("team")?.absoluteString, "https://team.atlassian.net")
        XCTAssertEqual(Account.normalizeSite(" team.atlassian.net ")?.absoluteString, "https://team.atlassian.net")
        XCTAssertEqual(
            Account.normalizeSite("https://jira.corp.example/browse/X?y=1")?.absoluteString, "https://jira.corp.example"
        )
        XCTAssertNil(Account.normalizeSite(""))
    }
}

/// Reads a real issue with more than 100 comments. Skipped unless the environment names one:
/// TEST_RUNNER_CONDUCTOR_SITE / _EMAIL / _TOKEN / _LONG_THREAD (xcodebuild strips the prefix).
final class LiveReadTests: XCTestCase {
    func testALongThreadLoadsWholeAndInOrder() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let site = env["CONDUCTOR_SITE"].flatMap(Account.normalizeSite),
            let email = env["CONDUCTOR_EMAIL"], let token = env["CONDUCTOR_TOKEN"],
            let key = env["CONDUCTOR_LONG_THREAD"]
        else { throw XCTSkip("No live credentials in the environment") }
        let c = JiraClient(account: Account(site: site, email: email, token: token))
        // Jira embeds only the newest 100 in an issue: the rest must have come from the comment endpoint.
        let issue = try await c.issue(key)
        let page = try XCTUnwrap(issue.fields.comment)
        XCTAssertGreaterThan(page.total, 100)
        XCTAssertEqual(page.comments.count, page.total)
        XCTAssertEqual(Set(page.comments.map(\.id)).count, page.total)
        XCTAssertEqual(page.comments.map(\.created), page.comments.map(\.created).sorted())
        // A Cloud search result carries the first 20 (Server's carries them all): completing it gives the same thread.
        let search = try await c.search(jql: "key = \(key)", fields: c.detailFields)
        let found = try XCTUnwrap(search.issues.first)
        if !c.account.isServer { XCTAssertFalse(found.hasAllComments) }
        let completed = try await c.completing(found)
        XCTAssertEqual(completed.fields.comment?.comments.map(\.id), page.comments.map(\.id))
    }

    func testALongWorkLogLoadsWhole() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let site = env["CONDUCTOR_SITE"].flatMap(Account.normalizeSite),
            let email = env["CONDUCTOR_EMAIL"], let token = env["CONDUCTOR_TOKEN"],
            let key = env["CONDUCTOR_LONG_WORKLOG"]
        else { throw XCTSkip("No live credentials in the environment") }
        let c = JiraClient(account: Account(site: site, email: email, token: token))
        // Jira embeds the oldest 20 only: the rest come from the work-log endpoint.
        let issue = try await c.issue(key)
        let page = try XCTUnwrap(issue.fields.worklog)
        XCTAssertGreaterThan(page.total, 20)
        XCTAssertEqual(page.worklogs.count, page.total)
        XCTAssertEqual(Set(page.worklogs.map(\.id)).count, page.total)
        XCTAssertEqual(
            page.worklogs.reduce(0) { $0 + $1.timeSpentSeconds }, issue.fields.timetracking?.timeSpentSeconds)
    }

    /// Every person on the site, page after page: each once, active, by name, me among them.
    func testEveryoneListsTheSitesPeopleWhole() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let site = env["CONDUCTOR_SITE"].flatMap(Account.normalizeSite),
            let email = env["CONDUCTOR_EMAIL"], let token = env["CONDUCTOR_TOKEN"]
        else { throw XCTSkip("No live credentials in the environment") }
        let c = JiraClient(account: Account(site: site, email: email, token: token))
        let me = try await c.myself()
        let people = try await c.everyone()
        XCTAssertEqual(Set(people.map(\.id)).count, people.count)
        XCTAssertTrue(people.allSatisfy { $0.active == true })
        XCTAssertTrue(
            zip(people, people.dropFirst()).allSatisfy {
                $0.displayName.localizedStandardCompare($1.displayName) != .orderedDescending
            })
        XCTAssertTrue(people.contains { $0.id == me.id })
    }
}

/// Exercises every write path against a real issue. Skipped unless the environment names one:
/// TEST_RUNNER_CONDUCTOR_SITE / _EMAIL / _TOKEN / _TEST_ISSUE (xcodebuild strips the prefix).
final class LiveWriteTests: XCTestCase {
    func testCommentAssignTransitionRoundTrip() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let site = env["CONDUCTOR_SITE"].flatMap(Account.normalizeSite),
            let email = env["CONDUCTOR_EMAIL"], let token = env["CONDUCTOR_TOKEN"],
            let key = env["CONDUCTOR_TEST_ISSUE"]
        else { throw XCTSkip("No live credentials in the environment") }
        var c = JiraClient(account: Account(site: site, email: email, token: token))
        c.sprintField = try await c.customFieldIds().sprint
        let me = try await c.myself()
        let before = try await c.issue(key)

        // Comment, then remove it so the issue is left as found.
        try await c.addComment(key, body: .document(markdown: "Conductor self-test, safe to ignore.\nSecond line."))
        let withComment = try await c.issue(key)
        XCTAssertEqual(withComment.fields.comment?.total, (before.fields.comment?.total ?? 0) + 1)
        let mine = try XCTUnwrap(withComment.fields.comment?.comments.last)
        XCTAssertEqual(mine.author?.accountId, me.accountId)
        XCTAssertEqual(mine.body.content?.count, 1, "one paragraph: text, hard break, text")
        if !c.account.isServer {
            // A reply names its parent.
            try await c.addComment(key, body: .document(markdown: "Conductor self-test reply."), parentId: mine.id)
            let replied = try await c.issue(key)
            let reply = try XCTUnwrap(replied.fields.comment?.comments.last)
            XCTAssertEqual(reply.parentId, mine.id)
            try await c.deleteComment(key, id: reply.id)
        }
        try await c.deleteComment(key, id: mine.id)
        let afterDelete = try await c.issue(key)
        XCTAssertEqual(afterDelete.fields.comment?.total, before.fields.comment?.total)

        // Assign to me, then put the previous assignee back.
        try await c.assign(key, to: me.accountId)
        let assigned = try await c.issue(key)
        XCTAssertEqual(assigned.fields.assignee?.accountId, me.accountId)
        try await c.assign(key, to: before.fields.assignee?.accountId)
        let restored = try await c.issue(key)
        XCTAssertEqual(restored.fields.assignee?.accountId, before.fields.assignee?.accountId)

        // Transition somewhere else and back, if the workflow allows a return trip.
        let transitions = try await c.transitions(key)
        guard let away = transitions.first(where: { $0.to.id != before.fields.status.id }) else { return }
        try await c.transition(key, to: away.id)
        let moved = try await c.issue(key)
        XCTAssertEqual(moved.fields.status.id, away.to.id)
        let returnTrips = try await c.transitions(key)
        if let back = returnTrips.first(where: { $0.to.id == before.fields.status.id }) {
            try await c.transition(key, to: back.id)
            let home = try await c.issue(key)
            XCTAssertEqual(home.fields.status.id, before.fields.status.id)
        }
    }
}

final class MarkdownTests: XCTestCase {
    func testPipeTablesRoundTrip() {
        let md = "| Name | Size |\n| --- | --- |\n| **a** | 1 |\n| b | 2 |"
        let doc = ADFNode.document(markdown: md)
        XCTAssertEqual(doc.content?.first?.type, "table")
        XCTAssertEqual(doc.content?.first?.content?.count, 3)
        XCTAssertEqual(doc.content?.first?.content?.first?.content?.first?.type, "tableHeader")
        XCTAssertEqual(doc.content?.first?.content?.last?.content?.first?.type, "tableCell")
        XCTAssertFalse(doc.hasLossyNodes)
        var mentions: [String: String] = [:]
        XCTAssertEqual(doc.markdown(mentions: &mentions), md)
    }

    func testBlocksAndMarksRoundTrip() {
        let md = """
            # Title

            Some **bold** and *italic* with `code` and a [link](https://x.y/z).

            - one
            - two
              1. nested

            > quoted

            ```swift
            let a = 1
            ```
            """
        let doc = ADFNode.document(markdown: md)
        XCTAssertEqual(doc.content?.map(\.type), ["heading", "paragraph", "bulletList", "blockquote", "codeBlock"])
        let p = doc.content![1]
        XCTAssertEqual(
            p.content?.map { $0.marks?.first?.type ?? "plain" },
            ["plain", "strong", "plain", "em", "plain", "code", "plain", "link", "plain"])
        XCTAssertEqual(doc.content![2].content?[1].content?[1].type, "orderedList")
        XCTAssertEqual(doc.content![4].attr("language"), "swift")
        var mentions: [String: String] = [:]
        let back = doc.markdown(mentions: &mentions)
        XCTAssertEqual(ADFNode.document(markdown: back), doc, "second pass must be stable")
    }

    func testMentionsBecomeNodesAndBack() {
        let doc = ADFNode.document(markdown: "ping @Ivan K and @Nikita", mentions: ["Ivan K": "a1", "Nikita": "b2"])
        let nodes = doc.content![0].content!
        XCTAssertEqual(nodes.map(\.type), ["text", "mention", "text", "mention"])
        XCTAssertEqual(nodes[1].attr("id"), "a1")
        var found: [String: String] = [:]
        XCTAssertEqual(doc.markdown(mentions: &found), "ping @Ivan K and @Nikita")
        XCTAssertEqual(found, ["Ivan K": "a1", "Nikita": "b2"])
    }

    func testBareURLsAndUnderscoresInIdentifiers() {
        let doc = ADFNode.document(markdown: "see https://a.b/c?d=1 and snake_case_name")
        let nodes = doc.content![0].content!
        XCTAssertEqual(nodes[1].marks?.first?.attrs?["href"]?.string, "https://a.b/c?d=1")
        XCTAssertEqual(nodes.last?.text, " and snake_case_name")
    }

    /// Anything a person can type into the description editor must convert without trapping.
    func testAwkwardMarkdownNeverTraps() throws {
        let cases = [
            "", "\n\n", "**", "*", "`", "~~", "[", "[x](", "[](", "- ", "-", "1.", "1. ", "#", "# ", "####### seven",
            "```", "```\n", "> ", ">",
            "**bold *nested* bold**", "a_b_c", "_", "__", "*a**b*", "- a\n    - b\n  - c\n- d", "1) x\n- y\n2. z",
            "  - indented first",
            "```swift\nlet a = 1", "text\r\nmore\r\n", "@", "@ ", "ping @", "https://", "http://x", "<https://x>",
            "\u{200B}", "😀 **😀**", "a\u{0301}",
        ]
        for md in cases {
            let doc = ADFNode.document(markdown: md, mentions: ["Ivan K": "a1", "": "empty"])
            _ = try JSONValue(doc)
            var m: [String: String] = [:]
            let back = doc.markdown(mentions: &m)
            _ = ADFNode.document(markdown: back, mentions: m)
        }
    }

    func testLossyDetection() {
        XCTAssertTrue(ADFNode(type: "doc", content: [ADFNode(type: "panel")]).hasLossyNodes)  // tables round-trip now
        XCTAssertFalse(ADFNode.document(markdown: "plain").hasLossyNodes)
    }

    func testTaskListsRoundTrip() {
        let md = "- [ ] todo item\n- [x] done item\n\n- plain bullet"
        let doc = ADFNode.document(markdown: md)
        XCTAssertEqual(doc.content?.map(\.type), ["taskList", "bulletList"])
        let items = doc.content?.first?.content ?? []
        XCTAssertEqual(items.map { $0.attr("state") }, ["TODO", "DONE"])
        XCTAssertEqual(items.first?.content?.first?.text, "todo item", "a task item holds inline text, not a paragraph")
        XCTAssertNotNil(items.first?.attr("localId"))
        XCTAssertFalse(doc.hasLossyNodes)
        var m: [String: String] = [:]
        XCTAssertEqual(doc.markdown(mentions: &m), md)
    }

    func testJiraErrorsReadAsPlainSentences() {
        let body = Data(
            #"{"errorMessages":[],"errors":{"parentId":"Parent issue cannot be found.","parent":"Parent issue cannot be found.","summary":"Summary can't exceed 255 characters."}}"#
                .utf8)
        XCTAssertEqual(
            JiraError(status: 400, data: body).messages,
            ["Parent issue cannot be found.", "Summary can't exceed 255 characters."],
            "no field keys, and one text for a parent Jira reports under two keys")
    }
}

final class FilterAndDurationTests: XCTestCase {
    func testChipsExtendTheQuery() {
        var f = Smart.recent.filters(account: nil)
        f.status = .inProgress
        f.assignee = .me
        f.type = "Bug"
        f.updated = .week
        XCTAssertEqual(
            f.jql,
            "issuekey IN issueHistory() AND statusCategory = \"In Progress\" AND assignee = currentUser() AND issuetype = \"Bug\" AND updated >= startOfWeek() ORDER BY lastViewed DESC"
        )
        f.text = "status = Done"
        XCTAssertEqual(f.jql, "status = Done", "raw JQL ignores chips")
        f = Smart.assigned.filters(account: nil)
        f.status = .open
        XCTAssertEqual(f.jql, "statusCategory != Done AND assignee = currentUser() ORDER BY updated DESC")
        f.status = .any
        XCTAssertEqual(
            f.jql, "assignee = currentUser() ORDER BY updated DESC", "Done is a filter, not baked into the list")
        var everything = ListFilters()
        everything.status = .any
        everything.sort.descending = false
        XCTAssertEqual(everything.jql, "ORDER BY updated ASC", "no chips at all is the whole site")
        XCTAssertFalse(everything.isBounded, "Jira refuses that, so the list must not ask")
        everything.text = "es-1"
        XCTAssertTrue(everything.isBounded)
        everything.text = ""
        everything.project = "ES"
        XCTAssertTrue(everything.isBounded)
    }

    func testBoardURL() {
        let c = JiraClient(account: Account(site: URL(string: "https://x.atlassian.net")!, email: "e", token: "t"))
        XCTAssertEqual(c.boardURL(project: "ES").absoluteString, "https://x.atlassian.net/projects/ES")
        XCTAssertEqual(
            c.boardURL(project: "ES", board: 7).absoluteString,
            "https://x.atlassian.net/secure/RapidBoard.jspa?rapidView=7")
    }

    func testDurationParsing() {
        XCTAssertEqual(LogWorkView.parseDuration("1h 30m"), 5400)
        XCTAssertEqual(LogWorkView.parseDuration("2d"), 16 * 3600)
        XCTAssertEqual(LogWorkView.parseDuration("1w"), 40 * 3600)
        XCTAssertEqual(LogWorkView.parseDuration("45"), 45 * 60)
        XCTAssertNil(LogWorkView.parseDuration("soon"))
        XCTAssertNil(LogWorkView.parseDuration("1h x"))
    }

    func testDurationFormat() {
        XCTAssertEqual(LogWorkView.format(15 * 3600), "1d 7h")
        XCTAssertEqual(LogWorkView.format(5400), "1h 30m")
        XCTAssertEqual(LogWorkView.format(40 * 3600), "1w")
        XCTAssertEqual(LogWorkView.format(0), "0m")
    }

    func testStatusSortReadsLikeABoard() throws {
        let sort = ListFilters.Sort(field: .status, descending: false)
        func issue(_ key: String, _ category: String, _ name: String) throws -> Issue {
            let json = """
                {"id":"1","key":"\(key)","fields":{"summary":"s","status":{"id":"1","name":"\(name)","statusCategory":{"key":"\(category)","name":"c"}},"issuetype":{"id":"1","name":"Task"}}}
                """
            return try JSONDecoder().decode(Issue.self, from: Data(json.utf8))
        }
        let done = try issue("A-1", "done", "Done")
        let todo = try issue("A-2", "new", "To Do")
        let doing = try issue("A-3", "indeterminate", "In Progress")
        XCTAssertEqual([done, doing, todo].sorted(by: sort.areInOrder).map(\.key), ["A-2", "A-3", "A-1"])
        // Children: yet to do first by default, and ties keep Jira's order rather than going by key ("A-10" < "A-9").
        let (open10, open9) = (try issue("A-10", "new", "Open"), try issue("A-9", "new", "Open"))
        XCTAssertEqual(
            ChildSorts.standard.ordered([done, open10, doing, open9], by: ChildSorts.standard.compare).map(\.key),
            ["A-10", "A-9", "A-3", "A-1"])
    }

    @MainActor func testLinkPickerOffersBothDirectionsUnlessIdentical() {
        let blocks = LinkType(id: "1", name: "Blocks", inward: "is blocked by", outward: "blocks")
        let relates = LinkType(id: "2", name: "Relates", inward: "relates to", outward: "relates to")
        let picker = LinkIssueView(key: "A-1", types: [blocks, relates]) { _, _, _ in }
        XCTAssertEqual(picker.relations.map(\.label), ["blocks", "is blocked by", "relates to"])
    }

    /// I takes someone else's issue, or nobody's, and gives up my own; an unknown me is never the assignee.
    func testITogglesBetweenAssigningMeAndUnassigning() {
        XCTAssertEqual(Shortcuts.hint(for: .assignToMe), "I")
        XCTAssertTrue(IssueActions.isMine(assignee: "me", me: "me"))
        XCTAssertFalse(IssueActions.isMine(assignee: "you", me: "me"))
        XCTAssertFalse(IssueActions.isMine(assignee: nil, me: "me"))
        XCTAssertFalse(IssueActions.isMine(assignee: nil, me: nil))
    }

    /// A user as a site sends them; Server sends no account type.
    private func user(
        _ id: String, _ name: String, email: String? = nil, type: String? = "atlassian", active: Bool = true
    ) throws -> JiraUser {
        var json: [String: Any] = ["accountId": id, "displayName": name, "active": active]
        json["emailAddress"] = email
        json["accountType"] = type
        return try JSONDecoder().decode(JiraUser.self, from: JSONSerialization.data(withJSONObject: json))
    }

    /// The site's people are its active humans, by name: apps, service desk customers and the deactivated are no
    /// one to filter by. Every active Server user is a person.
    func testTheSitesPeopleAreItsActiveHumansByName() throws {
        let users = [
            try user("1", "zoe"), try user("2", "Automation", type: "app"), try user("3", "Customer", type: "customer"),
            try user("4", "Gone", active: false), try user("5", "Émile"), try user("jdoe", "ada", type: nil),
        ]
        XCTAssertEqual(JiraClient.people(users).map(\.displayName), ["ada", "Émile", "zoe"])
    }

    /// People cached before the account type was kept still load, and the type and fetch date survive the disk.
    func testCachedPeopleLoadAcrossTheAccountTypeChange() throws {
        let old = try JSONDecoder().decode(
            JiraUser.self, from: Data(#"{"accountId":"1","displayName":"Ada","active":true}"#.utf8))
        XCTAssertNil(old.accountType)
        let people = AccountState.People(
            fetched: Date(timeIntervalSince1970: 1_790_000_000), users: [old, try user("2", "Bot", type: "app")])
        let back = try JSONDecoder().decode(AccountState.People.self, from: JSONEncoder().encode(people))
        XCTAssertEqual(back.users, people.users)
        XCTAssertEqual(back.users.last?.accountType, "app")
        XCTAssertEqual(back.fetched, people.fetched)
    }

    /// Up to 500 people the Assignee chip names them all; past that only Choose person…, which searches them. The
    /// chosen person is listed either way, once, even when no longer among the people.
    @MainActor func testTheAssigneeMenuNamesUpTo500PeopleThenOffersThePicker() throws {
        let people = try (1...501).map { try user("\($0)", "Person \($0)") }
        let five = ListFilters.Person(id: "5", name: "Person 5")
        let all = IssueListView.assigneeMenu(Array(people.prefix(500)), chosen: five)
        XCTAssertEqual(all.listed.count, 500)
        XCTAssertFalse(all.picker)
        XCTAssertEqual(all.listed.filter { $0.id == "5" }.count, 1)
        let gone = ListFilters.Person(id: "ada", name: "Ada")
        XCTAssertEqual(
            IssueListView.assigneeMenu(Array(people.prefix(2)), chosen: gone).listed.map(\.id), ["ada", "1", "2"])
        let many = IssueListView.assigneeMenu(people, chosen: nil)
        XCTAssertEqual(many.listed, [])
        XCTAssertTrue(many.picker)
        XCTAssertEqual(IssueListView.assigneeMenu(people, chosen: five).listed, [five])
        let none = IssueListView.assigneeMenu([], chosen: nil)
        XCTAssertTrue(none.listed.isEmpty && !none.picker, "a list of several accounts keeps the built-ins alone")
    }

    /// Choose person… searches the cached people as you type: any part of a name or email, whatever the case or
    /// accents, in the list's order, never more than 200 rows.
    @MainActor func testThePickerSearchesTheCachedPeopleLocally() throws {
        let people = [try user("1", "Zoë Adams", email: "zoe@x.com"), try user("2", "Bob", email: "robert@x.com")]
        XCTAssertEqual(PeoplePicker.matching(people, "").map(\.id), ["1", "2"])
        XCTAssertEqual(PeoplePicker.matching(people, "zoe").map(\.id), ["1"])
        XCTAssertEqual(PeoplePicker.matching(people, "ADA").map(\.id), ["1"])
        XCTAssertEqual(PeoplePicker.matching(people, "robert").map(\.id), ["2"])
        XCTAssertEqual(PeoplePicker.matching(people, " bob ").map(\.id), ["2"])
        XCTAssertEqual(PeoplePicker.matching(people, "nobody"), [])
        let crowd = try (1...300).map { try user("\($0)", "Person \($0)") }
        XCTAssertEqual(PeoplePicker.matching(crowd, "").count, 200)
        XCTAssertEqual(PeoplePicker.matching(crowd, "Person 299").map(\.id), ["299"])
    }

    func testVersionCompare() {
        XCTAssertTrue(UpdateChecker.isNewer("1.2.10", than: "1.2.9"))
        XCTAssertTrue(UpdateChecker.isNewer("1.1", than: "1.0.5"))
        XCTAssertFalse(UpdateChecker.isNewer("1.0", than: "1.0.0"))
    }

    func testIssueKeyFromLinks() {
        XCTAssertEqual(Session.issueKey(in: URL(string: "https://x.atlassian.net/browse/es-12")!), "ES-12")
        XCTAssertEqual(
            Session.issueKey(
                in: URL(string: "https://x.atlassian.net/jira/software/projects/ES/boards/62?selectedIssue=ES-9")!),
            "ES-9")
        XCTAssertEqual(
            Session.issueKey(in: URL(string: "https://x.atlassian.net/jira/software/c/projects/ES/issues/ES-7?jql=")!),
            "ES-7")
        XCTAssertNil(Session.issueKey(in: URL(string: "https://x.atlassian.net/browse/ES")!))
        XCTAssertNil(Session.issueKey(in: URL(string: "https://x.atlassian.net/")!))
    }
}

final class BoardTests: XCTestCase {
    private func issue(_ key: String, assignee: String?) throws -> Issue {
        let who = assignee.map { #"{"accountId":"\#($0)","displayName":"\#($0.capitalized)"}"# } ?? "null"
        let json =
            #"{"id":"\#(key)","key":"\#(key)","fields":{"summary":"s","status":{"id":"1","name":"To Do","statusCategory":{"key":"new","name":"To Do"}},"issuetype":{"id":"1","name":"Task"},"assignee":\#(who)}}"#
        return try JSONDecoder().decode(Issue.self, from: Data(json.utf8))
    }

    func testAssigneeLanesKeepFirstSeenOrderWithUnassignedLast() throws {
        let issues = try [
            issue("A-1", assignee: nil), issue("A-2", assignee: "bo"), issue("A-3", assignee: "al"),
            issue("A-4", assignee: "bo"),
        ]
        let lanes = Swimlanes.assignee.lanes(issues)
        XCTAssertEqual(lanes.map(\.title), ["Bo", "Al", "Unassigned"])
        XCTAssertEqual(lanes[0].issues.map(\.key), ["A-2", "A-4"])
        XCTAssertEqual(Swimlanes.none.lanes(issues).first?.issues.count, 4)
    }
}

final class LocalizationTests: XCTestCase {
    static let languages = [
        "ar", "de", "es", "fr", "hi", "it", "ja", "ko", "pl", "pt-BR", "ru", "tr", "uk", "zh-Hans", "zh-Hant",
    ]

    /// Every string in the catalog is translated into every shipped language, keeping the English placeholders.
    func testCatalogIsCompleteInEveryLanguage() throws {
        let url = URL(filePath: #filePath).deletingLastPathComponent().appending(
            path: "../Conductor/Localizable.xcstrings")
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let strings = try XCTUnwrap(catalog["strings"] as? [String: [String: Any]])
        func placeholders(_ s: String) -> [String] {
            s.matches(of: /%(?:\d+\$)?(lld|@)/).map { String($0.1) }.sorted()
        }
        /// The value, or every plural form of it.
        func forms(_ l: [String: Any]?) -> [String] {
            if let unit = l?["stringUnit"] as? [String: Any] { return [unit["value"] as? String ?? ""] }
            let plural = (l?["variations"] as? [String: Any])?["plural"] as? [String: [String: [String: Any]]] ?? [:]
            return plural.values.compactMap { $0["stringUnit"]?["value"] as? String }
        }
        for (key, entry) in strings where entry["shouldTranslate"] as? Bool != false {
            let localizations = entry["localizations"] as? [String: Any]
            let english = forms(localizations?["en"] as? [String: Any]).first ?? key
            for lang in Self.languages {
                let values = forms(localizations?[lang] as? [String: Any])
                XCTAssertFalse(values.isEmpty, "\(lang) has no translation for \"\(key)\"")
                for v in values {
                    XCTAssertEqual(placeholders(v), placeholders(english), "\(lang): \"\(key)\" → \"\(v)\"")
                }
            }
        }
    }

    func testAppShipsEveryLanguage() {
        XCTAssertEqual(
            Set(Bundle.main.localizations).intersection(Self.languages + ["en"]), Set(Self.languages + ["en"]))
    }
}

final class CacheTests: XCTestCase {
    /// The list store looks rows up in memory by `list-<hash of JQL>`; launch fills that memory from disk by file name.
    func testRecentListsComeBackUnderTheNameTheyWereSavedAs() throws {
        let account = Account(site: URL(string: "https://cache-test.test")!, email: "t@cache.test", token: "")
        let issue = try JSONDecoder().decode(
            Issue.self,
            from: Data(
                #"{"id":"1","key":"T-1","fields":{"summary":"s","status":{"id":"1","name":"To Do","statusCategory":{"key":"new","name":"To Do"}},"issuetype":{"id":"1","name":"Task"}}}"#
                    .utf8))
        let name = "list-" + DiskCache.hash("assignee = currentUser() ORDER BY updated DESC")
        DiskCache.save([issue], account: account, name: name)
        defer {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            try? FileManager.default.removeItem(
                at: root.appending(path: "Conductor/cache/cache-test.test|t@cache.test"))
        }
        XCTAssertEqual(DiskCache.recentLists(account: account)[name]?.map(\.key), ["T-1"])
    }
}

final class RowDateTests: XCTestCase {
    /// The date on a row follows the sort: updated, created, due, or created for orders that are not dates.
    func testSortPicksTheDateItOrdersBy() throws {
        let decoder = JiraClient(
            account: Account(site: URL(string: "https://x.atlassian.net")!, email: "e", token: "t")
        ).decoder
        let issue = try decoder.decode(
            Issue.self,
            from: Data(
                #"{"id":"1","key":"ES-1","fields":{"summary":"s","created":"2026-10-01T09:00:00.000Z","updated":"2026-10-05T09:00:00.000Z","duedate":"2026-10-31","status":{"id":"1","name":"To Do","statusCategory":{"key":"new","name":"To Do"}},"issuetype":{"id":"1","name":"Task"}}}"#
                    .utf8))
        func date(_ f: ListFilters.Sort.Field) -> Date? { ListFilters.Sort(field: f, descending: true).date(of: issue) }
        XCTAssertEqual(date(.updated), issue.fields.updated)
        XCTAssertEqual(date(.viewed), issue.fields.updated, "no lastViewed on this row: the update stands in")
        XCTAssertEqual(date(.created), issue.fields.created)
        XCTAssertEqual(date(.priority), issue.fields.created)
        XCTAssertEqual(date(.key), issue.fields.created)
        XCTAssertEqual(date(.due).map(DueDate.string), "2026-10-31")
    }

    @MainActor func testRelativeDayNamesWholeDays() {
        let cal = Calendar.current
        func day(_ n: Int) -> Date { cal.date(byAdding: .day, value: n, to: .now)! }
        XCTAssertEqual(relativeDay(.now), "Today")
        XCTAssertEqual(relativeDay(day(-1)), "Yesterday")
        XCTAssertEqual(relativeDay(day(1)), "Tomorrow")
        XCTAssertEqual(relativeDay(day(5)), "In 5 days")
        XCTAssertEqual(relativeDay(day(8)), "In 8 days", "a count, not \"next week\", up to two weeks out")
        XCTAssertEqual(relativeDay(day(13)), "In 13 days")
        XCTAssertEqual(relativeDay(day(-9)), "9 days ago")
        XCTAssertFalse(relativeDay(day(30)).contains("days"), "further out the named style stands")
    }
}

final class ServerTests: XCTestCase {
    private let server = JiraClient(
        account: Account(site: URL(string: "http://localhost:8080")!, email: "admin", token: "t"))

    func testWikiMarkupReadsAsTheDocumentCloudWouldSend() {
        let wiki = """
            h2. Goal
            Work *without* a _network_, -now- +really+ {{mono}} [Atlassian|https://atlassian.com] [~tester]

            * cache issues
            ** nested item
            * queue writes

            # first
            # second

            {code:swift}
            let x = 1
            {code}

            {quote}A quote{quote}

            ||Head 1||Head 2||
            |cell a|[x|https://x.y]|

            See !shot.png|thumbnail!
            ----
            """
        let doc = ADFNode.document(wiki: wiki)
        XCTAssertEqual(
            doc.content?.map(\.type),
            [
                "heading", "paragraph", "bulletList", "orderedList", "codeBlock", "blockquote", "table", "paragraph",
                "mediaSingle", "rule",
            ])
        let p = doc.content![1].content!
        XCTAssertEqual(
            p.map { $0.type == "text" ? ($0.marks?.first?.type ?? "plain") : $0.type },
            [
                "plain", "strong", "plain", "em", "plain", "strike", "plain", "underline", "plain", "code", "plain",
                "link",
                "plain", "mention",
            ])
        XCTAssertEqual(p.last?.attr("id"), "tester")
        XCTAssertEqual(doc.content![2].content?.first?.content?.last?.type, "bulletList", "** nests in the item above")
        XCTAssertEqual(doc.content![4].attr("language"), "swift")
        XCTAssertEqual(doc.content![4].plainText, "let x = 1")
        XCTAssertEqual(doc.content![6].content?.first?.content?.first?.type, "tableHeader")
        XCTAssertEqual(doc.content![6].content?.last?.content?.count, 2, "a pipe inside a link stays in its cell")
        XCTAssertEqual(doc.content![8].content?.first?.attr("alt"), "shot.png")
    }

    /// What the composer writes goes to Server as markup and comes back as the same document.
    func testMarkdownSurvivesTheTripThroughWikiMarkup() {
        let samples = [
            "# Title\n\nSome **bold** and *italic* with `code` and a [link](https://x.y/z).",
            "- one\n- two\n  1. nested\n\n> quoted",
            "```swift\nlet a = 1\n```\n\n```\nplain\n```",
            "| Name | Size |\n| --- | --- |\n| **a** | 1 |",
            "snake_case_name, a - b, well-known, x+y, C++, 50%! [not a link] {braces} pipe | here",
            "* starts with a star\n\n# not a heading\n\n- [ ] todo\n- [x] done",
            "line one\nline two",
        ]
        for md in samples {
            let doc = ADFNode.document(markdown: md)
            let back = ADFNode.document(wiki: doc.wiki)
            var m: [String: String] = [:]
            XCTAssertEqual(back.markdown(mentions: &m), doc.markdown(mentions: &m), "via \(doc.wiki)")
        }
    }

    func testMentionsGoOutAsUsernames() {
        let doc = ADFNode.document(markdown: "ping @Taylor Tester", mentions: ["Taylor Tester": "tester"])
        XCTAssertEqual(doc.wiki, "ping [~tester]")
    }

    func testAwkwardWikiNeverTraps() {
        for s in [
            "", "*", "**", "{code}", "{code}\nnever closed", "{quote}", "|", "||", "|a", "[", "[~]", "!", "!!", "h1.",
            "h7. x", "# ", "#", "\\", "\\\\", "a\\", "{color:red}x", "{{", "-", "----", "* a\n### b\n* c", "+", "^x",
            "😀 *😀*", "a\u{0301}", "\r\n\r\n",
        ] {
            let doc = ADFNode.document(wiki: s)
            _ = ADFNode.document(wiki: doc.wiki)
        }
    }

    func testServerSprintFieldDecodes() throws {
        let s =
            #""com.atlassian.greenhopper.service.sprint.Sprint@78214809[activatedDate=2026-10-12T01:00:14.672Z,autoStartStop=false,completeDate=<null>,endDate=2026-10-24T09:00:00.000Z,goal=<null>,id=1,incompleteIssuesDestinationId=<null>,name=QA, Sprint 1,rapidViewId=3,sequence=1,startDate=2026-10-10T09:00:00.000Z,state=ACTIVE,synced=false]""#
        let sprint = try JSONDecoder().decode(Sprint.self, from: Data(s.utf8))
        XCTAssertEqual(sprint.id, 1)
        XCTAssertEqual(sprint.name, "QA, Sprint 1")
        XCTAssertEqual(sprint.state, "active")
        XCTAssertEqual(sprint.originBoardId, 3)
    }

    func testEpicLinkReadsAsTheParentAndEpicsHaveALevel() throws {
        var c = server
        c.epics = EpicFields(link: "customfield_10100", name: "customfield_10102", type: "10000")
        let issue = try c.decoder.decode(
            Issue.self,
            from: Data(
                #"{"id":"1","key":"QA-2","fields":{"summary":"s","customfield_10100":"QA-1","status":{"id":"1","name":"To Do","statusCategory":{"key":"new","name":"To Do"}},"issuetype":{"id":"10001","name":"Story","subtask":false}}}"#
                    .utf8))
        XCTAssertEqual(issue.fields.parent?.key, "QA-1")
        XCTAssertEqual(issue.fields.issuetype.hierarchyLevel, 0)
        let epic = try c.decoder.decode(
            IssueType.self, from: Data(#"{"id":"10000","name":"Epic","subtask":false}"#.utf8))
        XCTAssertEqual(epic.hierarchyLevel, 1)
        XCTAssertEqual(c.parentFields("QA-1", subtask: false), ["customfield_10100": .string("QA-1")])
        XCTAssertEqual(c.parentFields("QA-1", subtask: true), ["parent": .object(["key": .string("QA-1")])])
        XCTAssertEqual(c.childrenJQL(["QA-1"]), #"(parent in ("QA-1") OR cf[10100] in ("QA-1"))"#)
    }

    func testLocalServerSitesStayAsTyped() {
        XCTAssertEqual(Account.normalizeSite("http://localhost:8080")?.absoluteString, "http://localhost:8080")
        XCTAssertEqual(Account.normalizeSite("localhost:8080/jira")?.absoluteString, "https://localhost:8080/jira")
        XCTAssertEqual(Account.normalizeSite("jira:8443")?.absoluteString, "https://jira:8443")
        XCTAssertTrue(server.account.isServer)
    }
}

/// Every Server-specific path against a real Jira Data Center. Skipped unless the environment names one:
/// TEST_RUNNER_CONDUCTOR_SERVER_SITE / _TOKEN and a project key in _PROJECT (xcodebuild strips the prefix).
final class LiveServerTests: XCTestCase {
    /// Server's user search stops at 100 matches whatever the paging; the user list's cursor reaches everyone.
    func testEveryoneWalksTheWholeUserList() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let site = env["CONDUCTOR_SERVER_SITE"].flatMap(Account.normalizeSite),
            let token = env["CONDUCTOR_SERVER_TOKEN"]
        else { throw XCTSkip("No live Server in the environment") }
        let c = JiraClient(account: Account(site: site, email: "", token: token))
        let me = try await c.myself()
        let people = try await c.everyone()
        XCTAssertEqual(Set(people.map(\.id)).count, people.count)
        XCTAssertTrue(people.contains { $0.id == me.id })
    }

    func testEveryReadAndWriteSpeaksServer() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let site = env["CONDUCTOR_SERVER_SITE"].flatMap(Account.normalizeSite),
            let token = env["CONDUCTOR_SERVER_TOKEN"], let project = env["CONDUCTOR_SERVER_PROJECT"]
        else { throw XCTSkip("No live Server in the environment") }
        var c = JiraClient(account: Account(site: site, email: "", token: token))
        XCTAssertTrue(c.account.isServer)
        let me = try await c.myself()
        let ids = try await c.customFieldIds()
        c.sprintField = ids.sprint
        c.pointsFields = ids.points
        c.epics = ids.epics
        let epics = try XCTUnwrap(ids.epics, "Jira Software's epic fields")
        XCTAssertNotNil(epics.type)
        XCTAssertNotNil(ids.sprint)

        // Create: the type list and fields decode, the epic link shows as the parent, an epic gets its name.
        let types = try await c.createIssueTypes(project: project)
        let story = try XCTUnwrap(types.first { $0.name == "Story" })
        let epicType = try XCTUnwrap(types.first { $0.id == epics.type })
        XCTAssertEqual(epicType.hierarchyLevel, 1)
        let fields = try await c.createFields(project: project, issueType: story.id)
        XCTAssertTrue(fields.contains { $0.fieldId == "parent" })
        XCTAssertFalse(fields.contains { $0.fieldId == epics.link })
        let epicFields = try await c.createFields(project: project, issueType: epicType.id)
        XCTAssertFalse(epicFields.contains { $0.fieldId == epics.name }, "the epic name follows the summary")
        let epic = try await c.createIssue(fields: [
            "project": .object(["key": .string(project)]), "issuetype": .object(["id": .string(epicType.id)]),
            "summary": .string("[DC test] Epic"),
        ])
        let doc = ADFNode.document(markdown: "## Plan\n\n- **one**\n- two\n\n```swift\nlet a = 1\n```")
        var f: [String: JSONValue] = [
            "project": .object(["key": .string(project)]), "issuetype": .object(["id": .string(story.id)]),
            "summary": .string("[DC test] Story"), "description": try JSONValue(doc),
            "labels": .array([.string("dc-test")]), "assignee": .object(["name": .string(me.accountId)]),
        ]
        f.merge(c.parentFields(epic.key, subtask: false)) { $1 }
        let created = try await c.createIssue(fields: f)

        // Read: the description comes back as the document sent, the epic as the parent with its summary.
        var issue = try await c.issue(created.key)
        var m: [String: String] = [:]
        XCTAssertEqual(issue.fields.description?.markdown(mentions: &m), doc.markdown(mentions: &m))
        XCTAssertEqual(issue.fields.parent?.key, epic.key)
        XCTAssertEqual(issue.fields.parent?.fields.summary, "[DC test] Epic")
        XCTAssertEqual(issue.fields.assignee?.accountId, me.accountId)
        let found = try await c.search(jql: "key = \(created.key)")
        XCTAssertEqual(found.issues.first?.fields.parent?.fields.summary, "[DC test] Epic")
        let kids = try await c.search(jql: c.childrenJQL([epic.key]))
        XCTAssertEqual(kids.issues.map(\.key), [created.key])
        let parents = try await c.search(jql: "project = \(project) AND \(c.levelJQL(1))")
        XCTAssertTrue(parents.issues.contains { $0.key == epic.key })
        let count = try await c.approximateCount(jql: "project = \(project)")
        XCTAssertGreaterThanOrEqual(count, 2)

        // Edit: the parent goes through the epic link, which the edit screen offers as `parent`.
        let meta = try await c.editMeta(created.key)
        XCTAssertNotNil(meta.fields["parent"])
        try await c.editIssue(created.key, fields: c.parentFields(nil, subtask: false))
        issue = try await c.issue(created.key)
        XCTAssertNil(issue.fields.parent)
        try await c.editIssue(created.key, fields: c.parentFields(epic.key, subtask: false))
        try await c.editIssue(created.key, fields: ["summary": .string("[DC test] Story, edited")])

        // Comments in markup, a mention by username, then gone again.
        try await c.addComment(
            created.key, body: .document(markdown: "Hi @Me, *see* `this`", mentions: ["Me": me.accountId]))
        issue = try await c.issue(created.key)
        let comment = try XCTUnwrap(issue.fields.comment?.comments.last)
        XCTAssertEqual(
            comment.body.content?.first?.content?.map(\.type), ["text", "mention", "text", "text", "text", "text"])
        try await c.updateComment(created.key, id: comment.id, body: .document(markdown: "edited"))
        try await c.deleteComment(created.key, id: comment.id)

        // Work log, watching, assignment, transitions, sprints, labels, links, attachments, history.
        try await c.addWorklog(
            created.key, seconds: 1800, comment: .document(markdown: "**half** an hour"), started: .now,
            adjustsEstimate: false)
        issue = try await c.issue(created.key)
        let log = try XCTUnwrap(issue.fields.worklog?.worklogs.last)
        XCTAssertEqual(log.comment?.content?.first?.content?.first?.marks?.first?.type, "strong")
        try await c.deleteWorklog(created.key, id: log.id)
        try await c.watch(created.key, false, me: me.accountId)
        let unwatched = try await c.watchers(created.key)
        XCTAssertFalse(unwatched.contains { $0.accountId == me.accountId })
        try await c.watch(created.key, true, me: me.accountId)
        let watched = try await c.watchers(created.key)
        XCTAssertTrue(watched.contains { $0.accountId == me.accountId })
        try await c.assign(created.key, to: nil)
        let assignable = try await c.assignableUsers(created.key, query: me.accountId)
        XCTAssertFalse(assignable.isEmpty)
        let people = try await c.users(matching: me.accountId)
        XCTAssertFalse(people.isEmpty)
        let transitions = try await c.transitions(created.key)
        if let t = transitions.first(where: { $0.to.statusCategory.key == "indeterminate" }) {
            try await c.transition(created.key, to: t.id)
        }
        // Server's full list stops at its 15 most used labels; the editors ask it for the typed prefix too.
        let labels = try await c.account.isServer ? c.labelSuggestions("dc-") : c.labels()
        XCTAssertTrue(labels.contains("dc-test"))
        let boards = try await c.boards(project: project)
        let board = try XCTUnwrap(boards.first)
        _ = try await c.boardConfiguration(board.id)
        _ = try await c.quickFilters(board: board.id)
        if let sprint = try await c.sprints(board: board.id).first, let field = c.sprintField {
            try await c.editIssue(created.key, fields: [field: .number(Double(sprint.id))])
            issue = try await c.issue(created.key)
            XCTAssertEqual(issue.sprints?.first?.id, sprint.id)
            XCTAssertEqual(issue.sprints?.first?.state, sprint.state)
            let page = try await c.boardIssues(board.id, sprint: sprint.id)
            XCTAssertTrue(page.issues.contains { $0.key == created.key })
            try await c.editIssue(created.key, fields: [field: .null])
        }
        let linkTypes = try await c.linkTypes()
        let type = try XCTUnwrap(linkTypes.first)
        try await c.link(type: type.name, from: created.key, to: epic.key)
        issue = try await c.issue(created.key)
        let link = try XCTUnwrap(issue.fields.issuelinks?.first)
        try await c.deleteLink(id: link.id)
        let uploaded = try await c.uploadAttachment(created.key, data: Data("hello".utf8), filename: "note.txt")
        let attachment = try XCTUnwrap(uploaded.first)
        let bytes = try await c.data(for: attachment.content)
        XCTAssertEqual(bytes, Data("hello".utf8))
        try await c.deleteAttachment(id: attachment.id)
        let history = try await c.changelog(created.key)
        XCTAssertFalse(history.isEmpty)
        let picked = try await c.pickIssues(query: created.key)
        XCTAssertFalse(picked.isEmpty)
        _ = try await c.jqlAutocomplete()
        _ = try await c.favouriteFilters()
        let projects = try await c.projects()
        XCTAssertFalse(projects.isEmpty)
    }
}

/// A 700-point clip under a 52-point toolbar, over a 3000-point page: the page's top is at clip y -52 and 648 points show.
final class PageRevealTests: XCTestCase {
    func y(_ r: CGRect, _ p: PageReveal.Placement, from clipY: CGFloat) -> CGFloat? {
        PageReveal.destination(
            showing: r, p, visible: CGRect(x: 0, y: clipY, width: 600, height: 700), top: 52, bottom: 0, page: 3000)
    }

    func testInViewWithRoomStays() {
        XCTAssertNil(y(CGRect(x: 0, y: 300, width: 600, height: 20), .middle, from: -52))
    }

    func testRowOffScreenOrTightAgainstAnEdgeIsCentred() {
        XCTAssertEqual(y(CGRect(x: 0, y: 1500, width: 600, height: 20), .middle, from: -52), 1510 - 324 - 52)
        // 8 points under the toolbar: in view, but cramped.
        XCTAssertEqual(y(CGRect(x: 0, y: 1060, width: 600, height: 20), .middle, from: 1000), 1070 - 324 - 52)
    }

    func testEditorNearThePageTopGoesToTheTop() {
        XCTAssertEqual(y(CGRect(x: 0, y: 200, width: 600, height: 1000), .start, from: 2000), -52)
    }

    func testEditorFarDownStopsAMarginUnderTheToolbar() {
        XCTAssertEqual(y(CGRect(x: 0, y: 2000, width: 600, height: 100), .start, from: -52), 2000 - 48 - 52)
    }

    func testScrollStopsAtThePageEnd() {
        XCTAssertEqual(y(CGRect(x: 0, y: 2980, width: 600, height: 20), .middle, from: -52), 3000 - 700)
    }
}

final class TimeoutTests: XCTestCase {
    func testASlowTaskGivesWayAtTheLimit() async {
        let slow = Task<Int, Error> {
            try await Task.sleep(for: .seconds(10))
            return 1
        }
        let start = ContinuousClock.now
        let value = await IssueDetailStore.first(of: slow, within: .milliseconds(100))
        XCTAssertNil(value)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(1))
        slow.cancel()
    }

    func testAQuickTaskGivesItsValue() async {
        let value = await IssueDetailStore.first(of: Task<Int, Error> { 7 }, within: .seconds(5))
        XCTAssertEqual(value, 7)
    }
}

/// A list folds a subtask under its parent when it holds both; a board column folds it into the parent's card.
final class NestAndBoardColumnTests: XCTestCase {
    /// A Task in `status`, or a subtask of `parent`, updated `minute` minutes past nine.
    func issue(_ key: String, status: String = "1", parent: String? = nil, minute: Int = 0) throws -> Issue {
        let up = parent.map { #","parent":{"id":"\#($0)","key":"\#($0)","fields":{"summary":"p"}}"# } ?? ""
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(
            Issue.self,
            from: Data(
                #"{"id":"\#(key)","key":"\#(key)","fields":{"summary":"s","updated":"2026-10-05T09:\#(String(format: "%02d", minute)):00Z","status":{"id":"\#(status)","name":"S","statusCategory":{"key":"new","name":"To Do"}},"issuetype":{"id":"1","name":"Task","subtask":\#(parent != nil)}\#(up)}}"#
                    .utf8))
    }

    @MainActor func testSubtasksFoldUnderAParentInTheListAndCarryItUpTheUpdatedOrder() throws {
        let state = AccountState(
            account: Account(site: URL(string: "https://a.atlassian.net")!, email: "e", token: "t"))
        // A-3 is A-2's subtask and was touched last; A-4's parent A-9 is not in the list.
        let rows = try [
            issue("A-1", minute: 30), issue("A-2", minute: 10), issue("A-3", parent: "A-2", minute: 50),
            issue("A-4", parent: "A-9", minute: 20),
        ].map { ListRow(issue: $0, state: state) }
        let byUpdate = ListFilters.Sort(field: .updated, descending: true)
        let folded = DisplayRow.nest(rows, expanded: [], sort: byUpdate)
        XCTAssertEqual(folded.map(\.row.issue.key), ["A-2", "A-1", "A-4"], "A-2 moves up with its subtask")
        XCTAssertEqual(folded.map(\.depth), [0, 0, 0])
        XCTAssertEqual(folded.first?.children.map(\.issue.key), ["A-3"])
        let open = DisplayRow.nest(rows, expanded: ["\(state.id)|A-2"], sort: byUpdate)
        XCTAssertEqual(open.map(\.row.issue.key), ["A-2", "A-3", "A-1", "A-4"])
        XCTAssertEqual(open.map(\.depth), [0, 1, 0, 0])
        let byCreated = ListFilters.Sort(field: .created, descending: true)
        XCTAssertEqual(
            DisplayRow.nest(rows, expanded: [], sort: byCreated).map(\.row.issue.key), ["A-1", "A-2", "A-4"],
            "any other order is the server's")
    }

    @MainActor func testAColumnHoldsItsStatusesAndFoldsOnlySubtasksWhoseParentIsOnTheBoard() throws {
        let store = BoardStore()
        // A-3's parent A-2 sits in another column; A-4's parent A-9 is not on the board.
        store.issues = try [
            issue("A-1"), issue("A-2", status: "2"), issue("A-3", parent: "A-2"), issue("A-4", parent: "A-9"),
        ]
        let column = BoardConfiguration.Column(
            name: "To Do", statuses: [.init(id: "1"), .init(id: "3")], min: nil, max: nil)
        XCTAssertEqual(store.issues(in: column).map(\.key), ["A-1", "A-3", "A-4"])
        XCTAssertEqual(store.issues(in: column, fold: true).map(\.key), ["A-1", "A-4"])
        let lane = [store.issues[2], store.issues[3]]
        XCTAssertEqual(store.issues(in: column, from: lane).map(\.key), ["A-3", "A-4"])
        XCTAssertEqual(
            store.issues(in: column, from: lane, fold: true).map(\.key), ["A-4"], "the parent counts from the board")
    }
}

final class JQLDetectionTests: XCTestCase {
    func testOnlyJQLShapedTextIsRawJQL() {
        for q in [
            "status = Done", "status=Done", "project = \"IN\" ORDER BY updated DESC", "assignee in (a,b)",
            "issuekey IN issueHistory()", "sprint in openSprints()", "labels is EMPTY", "resolution is not empty",
            "text ~ \"login\"", "summary !~ x", "created >= -1d", "order by created", "(a = 1 or b = 2)",
            "cf[10100] in (x)", "status = Done order by created",
        ] {
            XCTAssertTrue(ListFilters.looksLikeJQL(q), q)
        }
        // "in" and "is" are plain words too; an issue key is isKey's.
        for q in [
            "sign in", "login is broken", "check in with team", "what is this", "in progress", "is it done",
            "billing engine", "ES-12",
        ] {
            XCTAssertFalse(ListFilters.looksLikeJQL(q), q)
        }
    }

    func testPlainWordsSearchTextAndJQLPassesThrough() {
        var f = ListFilters()
        f.status = .any
        f.text = "sign in"
        XCTAssertEqual(f.jql, "text ~ \"sign in\" ORDER BY updated DESC")
        f.text = "status = Done"
        XCTAssertEqual(f.jql, "status = Done")
    }
}

final class LabelMatchTests: XCTestCase {
    func testStartsWithThenWordThenContainsEachAlphabetical() {
        let all = ["boards", "composer", "qa-scratch", "security", "sidebar", "sync", "notifications", "Status"]
        let expected = ["security", "sidebar", "Status", "sync", "qa-scratch", "boards"]
        XCTAssertEqual(Labels.matches("s", in: all, excluding: []), expected)
        XCTAssertEqual(Labels.matches("S", in: all, excluding: []), expected)
        XCTAssertEqual(Labels.matches("x", in: all, excluding: []), [])
        XCTAssertEqual(Labels.matches(" ", in: all, excluding: []), [])
        XCTAssertEqual(
            Labels.matches("s", in: all, excluding: ["security", "sync"]),
            ["sidebar", "Status", "qa-scratch", "boards", "composer", "notifications"])
        // The site's list plus Server's answer for the prefix may name a label twice.
        XCTAssertEqual(
            Labels.matches("dc", in: ["dc-test", "old-dc", "dc-test"], excluding: []), ["dc-test", "old-dc"])
    }

    func testParseSplitsOnCommasAndTurnsSpacesIntoDashes() {
        XCTAssertEqual(Labels.parse("a, b c,,"), ["a", "b-c"])
    }
}

final class IssueTableTests: XCTestCase {
    /// The table's rows follow the list by steps the outline view takes one after another; a page landing is one
    /// insert and an edited row gone to the top is one move, the glide.
    func testStepsTakeTheRowsToTheirNewOrder() {
        typealias Table = IssueTable.Coordinator
        func run(_ old: [String], _ new: [String]) -> [String] {
            var rows = old
            for step in Table.steps(from: old, to: new)! {
                switch step {
                case .remove(let r): rows = rows.indices.filter { !r.contains($0) }.map { rows[$0] }
                case .move(let a, let b): rows.insert(rows.remove(at: a), at: b)
                case .insert(let r): rows.insert(contentsOf: new[r], at: r.lowerBound)
                }
            }
            return rows
        }
        XCTAssertEqual(
            Table.steps(from: ["a", "b", "~spinner"], to: ["a", "b", "c", "d"]), [.remove([2]), .insert(2..<4)])
        XCTAssertEqual(Table.steps(from: ["a", "b", "c", "d"], to: ["c", "a", "b", "d"]), [.move(2, 0)])
        XCTAssertEqual(Table.steps(from: ["a", "b"], to: ["a", "b"]), [])
        XCTAssertEqual(Table.steps(from: [], to: ["a", "b"]), [.insert(0..<2)])
        XCTAssertEqual(Table.steps(from: ["a", "x", "b"], to: ["a", "b"]), [.remove([1])])
        var g = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let old = (0..<Int.random(in: 0...12, using: &g)).map { "r\($0)" }
            let added = (0..<Int.random(in: 0...4, using: &g)).map { "n\($0)" }
            let new = (old.filter { _ in Bool.random(using: &g) } + added).shuffled(using: &g)
            XCTAssertEqual(run(old, new), new, "\(old) → \(new)")
        }
        // A whole list sorted anew is too many moves to take one by one: the table reloads instead.
        XCTAssertNil(Table.steps(from: ["a", "b", "c", "d"], to: ["d", "c", "b", "a"], moves: 2))
        XCTAssertEqual(Table.steps(from: ["a", "b", "c", "d"], to: ["c", "a", "b", "d"], moves: 1), [.move(2, 0)])
    }

    /// In a list loaded whole, a row not measured yet stands at the mean of the measured ones, in whole points, and
    /// keeps the height it was first given until it is measured: a stand-in that followed the mean moved every row
    /// below it.
    @MainActor func testAnUnmeasuredRowStandsAtTheMeanItWasFirstGiven() throws {
        typealias Table = IssueTable.Coordinator
        let c = Table()
        let height = { (id: String) in c.outlineView(NSOutlineView(), heightOfRowByItem: Table.Item(id)) }
        c.record("a", Table.RowKey(), 400, 56)
        c.record("b", Table.RowKey(), 400, 72)
        XCTAssertEqual(height("x"), 64)
        c.record("c", Table.RowKey(), 400, 57)
        XCTAssertEqual(height("x"), 64, "given once")
        XCTAssertEqual(height("y"), 62)
        c.record("b", Table.RowKey(), 400, 56)  // measured again: counted once
        XCTAssertEqual(height("z"), 56)
    }

    /// A run of selected rows is one block: no line at its rows or over its first, and none under the last row.
    /// A row is at the height it was last measured at, whatever width or content that was for, else the estimate.
    @MainActor func testARowIsAtItsLastMeasureElseTheEstimate() {
        typealias Table = IssueTable.Coordinator
        let c = Table()
        c.heights["a"] = (Table.RowKey(), -1, 72)
        XCTAssertEqual(c.outlineView(NSOutlineView(), heightOfRowByItem: Table.Item("a")), 72)
        XCTAssertEqual(c.outlineView(NSOutlineView(), heightOfRowByItem: Table.Item("b")), IssueTable.estimate)
    }

    /// A row is measured again for what moves its height (its summary, its date, its place), not for its status.
    @MainActor func testARowIsMeasuredAgainForItsSummaryNotItsStatus() throws {
        let st = AccountState(account: Account(site: URL(string: "https://a.atlassian.net")!, email: "e", token: "t"))
        func row(_ summary: String, _ status: String, _ second: Int) throws -> DisplayRow {
            let issue = try st.client.decoder.decode(
                Issue.self,
                from: Data(
                    #"{"id":"1","key":"A-1","fields":{"summary":"\#(summary)","updated":"2026-10-05T09:00:\#(String(format: "%02d", second)).000Z","status":{"id":"1","name":"\#(status)","statusCategory":{"key":"new","name":"To Do"}},"issuetype":{"id":"1","name":"Task"}}}"#
                        .utf8))
            return DisplayRow(row: ListRow(issue: issue, state: st))
        }
        let key = IssueTable.Coordinator.key
        XCTAssertEqual(key(try row("Fix it", "To Do", 1)), key(try row("Fix it", "Doing", 1)))
        XCTAssertNotEqual(key(try row("Fix it", "To Do", 1)), key(try row("Fix it now", "To Do", 1)))
        XCTAssertNotEqual(key(try row("Fix it", "To Do", 1)), key(try row("Fix it", "To Do", 2)))
    }

    /// A measured row the table holds at another height is told again, against the height the table was given, not
    /// the last measure: rows the table took at the estimate stayed squashed when the measure was compared with itself.
    /// A row the table has not asked for yet takes its measure when it does.
    func testRowsTheTableHasAtAnotherHeightAreToldAgain() {
        let told: [CGFloat?] = [24, 24, 56, nil]
        let changes = { IssueTable.Coordinator.changes($0) { told[$0] } }
        XCTAssertEqual(changes([(0, 56), (1, 56), (2, 56), (3, 72)]), [0, 1])
        XCTAssertEqual(changes([(2, 56)]), [])
    }

    /// The table takes a row's measure only when told: asked again, it gets the height it was given last.
    @MainActor func testTheTableKeepsTheHeightItWasGivenUntilTold() {
        typealias Table = IssueTable.Coordinator
        let c = Table()
        let height = { (id: String) in c.outlineView(NSOutlineView(), heightOfRowByItem: Table.Item(id)) }
        c.heights["a"] = (Table.RowKey(), 400, 56)
        XCTAssertEqual(height("a"), 56)
        c.record("a", Table.RowKey(), 400, 72)
        XCTAssertEqual(height("a"), 56, "measured since, not told yet")
    }

    /// While rows change around it, the window holds the first row under the toolbar and chips where it is, or the
    /// list's end once End was pressed or the reader is within a row of it; nothing at the top, where rows that come
    /// in above push the others down, or while every row fits.
    func testTheWindowHoldsItsFirstRowOrTheEnd() {
        typealias Table = IssueTable.Coordinator
        let visible = [
            (id: "a", frame: NSRect(x: 0, y: 400, width: 420, height: 56)),
            (id: "b", frame: NSRect(x: 0, y: 456, width: 420, height: 72)),
            (id: "c", frame: NSRect(x: 0, y: 528, width: 420, height: 56)),
        ]
        // 89 points of toolbar and chips over the rows: "a" ends under them, "b" is the first row in sight.
        let mid = NSRect(x: 0, y: 380, width: 420, height: 700)
        XCTAssertEqual(
            Table.anchor(clip: mid, inset: 89, height: 10_000, pinned: false, visible: visible), .row("b", 76))
        XCTAssertEqual(Table.anchor(clip: mid, inset: 89, height: 10_000, pinned: true, visible: visible), .end)
        let nearEnd = NSRect(x: 0, y: 9_250, width: 420, height: 700)  // 50 points short of the end, the last row 56
        XCTAssertEqual(Table.anchor(clip: nearEnd, inset: 89, height: 10_000, pinned: false, visible: visible), .end)
        XCTAssertNotEqual(
            Table.anchor(clip: nearEnd, inset: 89, height: 10_000, pinned: false, settled: false, visible: visible),
            .end, "a list still coming in ends where its rows so far stop")
        let top = NSRect(x: 0, y: -89, width: 420, height: 700)
        XCTAssertNil(Table.anchor(clip: top, inset: 89, height: 10_000, pinned: false, visible: visible))
        XCTAssertNil(Table.anchor(clip: mid, inset: 89, height: 600, pinned: true, visible: visible))
        // Rows above "b" grew by 40: the window moves down with it; the end follows the document, kept inside it.
        let grown = { (id: String) in id == "b" ? NSRect(x: 0, y: 496, width: 420, height: 72) : nil }
        XCTAssertEqual(Table.origin(for: .row("b", 76), frame: grown, height: 10_040, clip: 700, inset: 89), 420)
        XCTAssertEqual(Table.origin(for: .end, frame: grown, height: 10_040, clip: 700, inset: 89), 9_340)
        XCTAssertNil(Table.origin(for: .row("gone", 0), frame: grown, height: 10_040, clip: 700, inset: 89))
        XCTAssertEqual(Table.origin(for: .end, frame: grown, height: 300, clip: 700, inset: 89), -89)
    }

    /// A list opens on the first row of its place that is still there with the next one right under it, at that row's
    /// offset: an issue edited away since (to the top, or out of the list) takes the window nowhere. The end stays the
    /// end; with none of its rows left, or no place, the list opens at its top.
    func testAListOpensOnTheRowItWasLeftOn() {
        typealias Table = IssueTable.Coordinator
        let place: [Table.Anchor] = [.row("a", -5), .row("b", 51), .row("c", 107)]
        XCTAssertEqual(Table.restored(place, in: ["x", "a", "b", "c", "y"]), .row("a", -5))
        XCTAssertEqual(Table.restored(place, in: ["a", "x", "y", "b", "c"]), .row("b", 51), "a went to the top")
        XCTAssertEqual(Table.restored(place, in: ["x", "b", "c"]), .row("b", 51), "a left the list")
        XCTAssertEqual(Table.restored(place, in: ["a", "c", "x"]), .row("a", -5), "b left the list, c is under a")
        XCTAssertEqual(Table.restored(place, in: ["x", "c"]), .row("c", 107))
        XCTAssertEqual(Table.restored(place, in: ["a", "n", "b", "c"]), .row("b", 51), "an issue came in under a")
        XCTAssertNil(Table.restored(place, in: ["x", "y"]))
        XCTAssertNil(Table.restored([], in: ["x", "y"]))
        XCTAssertEqual(Table.restored([.end], in: ["x"]), .end)
        XCTAssertEqual(Table.origin(for: .top, frame: { _ in nil }, height: 10_000, clip: 700, inset: 89), -89)
        // The memory keeps places in the defaults as JSON.
        let data = try! JSONEncoder().encode(place + [.end, .top])
        XCTAssertEqual(try! JSONDecoder().decode([Table.Anchor].self, from: data), place + [.end, .top])
        // A typed search over the same JQL is a list of its own.
        let id = UUID()
        XCTAssertNotEqual(ListKey(accounts: [id], jql: "j"), ListKey(accounts: [id], jql: "j", typed: true))
    }

    /// While rows change, the window holds a row that keeps its place among the rows both orders have, not one an edit
    /// moved away, nor the rows it left; a row gone or come in between moves nothing. When every row moved, any row
    /// still there does.
    func testTheWindowHoldsARowThatKeptItsPlace() {
        typealias Table = IssueTable.Coordinator
        let old = ["a", "b", "c", "d", "e", "f", "g", "h"]
        XCTAssertEqual(Table.staying(0..<8, of: old, in: old), Set(old))
        XCTAssertEqual(
            Table.staying(0..<8, of: old, in: ["c", "a", "b", "d", "e", "f", "g", "h"]), ["e", "f", "g", "h"])
        XCTAssertEqual(Table.staying(0..<4, of: ["a", "b", "c", "d"], in: ["a", "c", "d"]), ["a", "c", "d"])
        XCTAssertEqual(Table.staying(0..<3, of: ["a", "b", "c"], in: ["a", "x", "b", "c"]), ["a", "b", "c"])
        XCTAssertEqual(Table.staying(0..<3, of: ["a", "b", "c"], in: ["c", "b", "a"]), ["a", "b", "c"])
        XCTAssertEqual(Table.staying(2..<4, of: old, in: old), ["c", "d"])
    }

    func testSeparatorsStopAtSelectedRowsAndTheLastRow() {
        let selected: Set<Int> = [1, 2, 3]
        let lines = (0..<6).map { IssueTable.Coordinator.separates($0, of: 6, selected: selected.contains) }
        XCTAssertEqual(lines, [false, false, false, false, true, false])
        XCTAssertFalse(IssueTable.Coordinator.separates(0, of: 1) { _ in false })
    }

    /// Sorted by update, a parent whose subtask was touched last comes first with it; equal dates keep id order.
    @MainActor func testAParentSortsByItsLatestSubtask() throws {
        let st = AccountState(account: Account(site: URL(string: "https://a.atlassian.net")!, email: "e", token: "t"))
        func row(_ key: String, _ second: Int, parent: String? = nil) throws -> ListRow {
            let parentJSON = parent.map { #","parent":{"id":"9","key":"\#($0)","fields":{"summary":"p"}}"# } ?? ""
            let issue = try st.client.decoder.decode(
                Issue.self,
                from: Data(
                    #"{"id":"1","key":"\#(key)","fields":{"summary":"s","updated":"2026-10-05T09:00:\#(String(format: "%02d", second)).000Z","status":{"id":"1","name":"To Do","statusCategory":{"key":"new","name":"To Do"}},"issuetype":{"id":"1","name":"Task","subtask":\#(parent != nil)}\#(parentJSON)}}"#
                        .utf8))
            return ListRow(issue: issue, state: st)
        }
        let rows = [try row("A-2", 20), try row("A-3", 20), try row("A-1", 10), try row("A-4", 30, parent: "A-1")]
        let sort = ListFilters.Sort(field: .updated, descending: true)
        let nested = DisplayRow.nest(rows, expanded: [], sort: sort)
        XCTAssertEqual(nested.map(\.row.issue.key), ["A-1", "A-2", "A-3"])
        XCTAssertEqual(nested.first?.children.map(\.issue.key), ["A-4"])
        XCTAssertEqual(
            DisplayRow.nest(rows, expanded: ["\(st.id)|A-1"], sort: sort).map(\.row.issue.key),
            ["A-1", "A-4", "A-2", "A-3"])
    }
}
