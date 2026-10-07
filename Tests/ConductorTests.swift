import XCTest
@testable import Conductor

final class JQLTests: XCTestCase {
    let account = UUID()
    /// Chips all off, whatever the Hide Done setting says.
    var blank: ListFilters { var f = ListFilters(); f.status = .any; return f }

    func testProjectKeysAreQuoted() {
        // IN is a JQL reserved word; unquoted it fails server-side.
        var f = blank
        f.account = account
        f.project = "IN"
        XCTAssertEqual(f.jql(), "project = \"IN\" ORDER BY updated DESC")
    }

    func testFreeTextBecomesTextSearch() {
        var f = Smart.assigned.filters(account: account)
        f.status = .open
        f.text = "billing \"engine\""
        XCTAssertEqual(f.jql(), "statusCategory != Done AND assignee = currentUser() AND text ~ \"billing \\\"engine\\\"\" ORDER BY updated DESC")
    }

    func testIssueKeyIsLookedUpDirectly() {
        var f = blank
        f.text = "es-2284"
        XCTAssertEqual(f.jql(), "key = \"ES-2284\"")
    }

    func testRawJQLPassesThrough() {
        var f = blank
        f.text = "status = Done order by created"
        XCTAssertEqual(f.jql(), "status = Done order by created")
    }

    func testPresetsCarryTheirOwnOrderAndRoundTripThroughJSON() throws {
        let recent = Smart.recent.filters(account: account)
        XCTAssertEqual(recent.jql(), "issuekey IN issueHistory() ORDER BY lastViewed DESC")
        XCTAssertEqual(Smart.reported.filters(account: nil).sort.field, .created)
        var f = Smart.starred.filters(account: account)
        f.jiraFilter = Filter(id: "7", name: "x", jql: "")
        f.type = "Bug"
        f.sort = .init(field: .priority, descending: false)
        XCTAssertEqual(try JSONDecoder().decode(ListFilters.self, from: JSONEncoder().encode(f)), f)
        XCTAssertEqual(f.jql(starredKeys: ["ES-1", "ES-2"]), "filter = 7 AND issuekey IN (\"ES-1\", \"ES-2\") AND issuetype = \"Bug\" ORDER BY priority ASC")
    }

    func testMergeOrderMatchesTheClause() throws {
        let decoder = JiraClient(account: Account(site: URL(string: "https://x.atlassian.net")!, email: "e", token: "t")).decoder
        func issue(_ key: String, priority: String, updated: String) throws -> Issue {
            try decoder.decode(Issue.self, from: Data(#"{"id":"1","key":"\#(key)","fields":{"summary":"s","updated":"\#(updated)","priority":{"id":"\#(priority)","name":"p"},"status":{"id":"1","name":"To Do","statusCategory":{"key":"new","name":"To Do"}},"issuetype":{"id":"1","name":"Task"}}}"#.utf8))
        }
        let a = try issue("ES-9", priority: "3", updated: "2026-10-05T09:00:00.000Z")
        let b = try issue("ES-10", priority: "1", updated: "2026-10-06T09:00:00.000Z")
        XCTAssertTrue(ListFilters.Sort(field: .updated, descending: true).areInOrder(b, a))
        XCTAssertTrue(ListFilters.Sort(field: .updated, descending: false).areInOrder(a, b))
        XCTAssertTrue(ListFilters.Sort(field: .priority, descending: true).areInOrder(b, a), "DESC is the highest priority (lowest id) first, as in JQL")
        XCTAssertTrue(ListFilters.Sort(field: .key, descending: false).areInOrder(a, b), "keys compare numerically")
    }
}

final class ADFTests: XCTestCase {
    func testPlainTextDocumentHasOneParagraphPerLine() throws {
        let doc = ADFNode.document(text: "first\n\nthird")
        XCTAssertEqual(doc.type, "doc")
        XCTAssertEqual(doc.version, 1)
        XCTAssertEqual(doc.content?.count, 3)
        XCTAssertEqual(doc.content?[0].content?.first?.text, "first")
        XCTAssertEqual(doc.content?[1].content?.count, 0)
        XCTAssertEqual(doc.plainText, "first\n\nthird")
    }

    func testRealWorldNodesDecodeAndRender() throws {
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
        let paragraph = try XCTUnwrap(doc.content?[1])
        let rendered = String(paragraph.inlineAttributed().characters)
        XCTAssertEqual(rendered, "Карточка View all\n@Vitalyexample.com/x")
        // Round-trips through Codable without losing attrs.
        let again = try JSONDecoder().decode(ADFNode.self, from: JSONEncoder().encode(doc))
        XCTAssertEqual(again, doc)
    }
}

final class DecodingTests: XCTestCase {
    @MainActor func testConnectivityIsPerHostAndOnlyForTransportErrors() {
        let c = Connectivity()
        c.report(URLError(.timedOut), host: "a")
        c.report(JiraError(status: 500, data: Data()), host: "b")   // Jira answered: not offline
        XCTAssertEqual(c.offlineHosts, ["a"])
        c.reportSuccess(host: "a")
        XCTAssertFalse(c.isOffline)
    }

    func testAccountIDIsStableAcrossLaunches() {
        let site = URL(string: "https://x.atlassian.net")!
        XCTAssertEqual(Account(site: site, email: "E@x.com", token: "a").id, Account(site: site, email: "e@x.com", token: "b").id)
        XCTAssertNotEqual(Account(site: site, email: "e@x.com", token: "a").id, Account(site: site, email: "f@x.com", token: "a").id)
    }

    struct Dates: Decodable { let a: Date; let b: Date }

    func testBothJiraDateFormatsDecode() throws {
        let decoder = JiraClient(account: Account(site: URL(string: "https://x.atlassian.net")!, email: "e", token: "t")).decoder
        let json = #"{"a":"2026-10-05T09:56:55.551+0300","b":"2026-09-16T15:04:00.000Z"}"#
        let d = try decoder.decode(Dates.self, from: Data(json.utf8))
        XCTAssertEqual(d.a.timeIntervalSince1970, 1791183415.551, accuracy: 0.001)
        XCTAssertEqual(d.b.timeIntervalSince1970, 1789571040, accuracy: 0.001)
    }

    func testStoryPointsComeFromWhicheverPointsFieldIsSet() throws {
        var client = JiraClient(account: Account(site: URL(string: "https://x.atlassian.net")!, email: "e", token: "t"))
        client.pointsFields = ["customfield_10026", "customfield_10016"]
        let json = #"{"id":"1","key":"ES-1","fields":{"summary":"s","status":{"id":"1","name":"To Do","statusCategory":{"key":"new","name":"To Do"}},"issuetype":{"id":"1","name":"Task"},"customfield_10026":null,"customfield_10016":5,"duedate":"2026-10-31","components":[{"id":"7","name":"API"}]}}"#
        let issue = try client.decoder.decode(Issue.self, from: Data(json.utf8))
        XCTAssertEqual(issue.points, 5)
        XCTAssertEqual(issue.fields.components?.map(\.name), ["API"])
        XCTAssertEqual(issue.fields.duedate.flatMap(DueDate.parse).map(DueDate.string), "2026-10-31")
    }

    func testSiteNormalization() {
        XCTAssertEqual(Account.normalizeSite("team")?.absoluteString, "https://team.atlassian.net")
        XCTAssertEqual(Account.normalizeSite(" team.atlassian.net ")?.absoluteString, "https://team.atlassian.net")
        XCTAssertEqual(Account.normalizeSite("https://jira.corp.example/browse/X?y=1")?.absoluteString, "https://jira.corp.example")
        XCTAssertNil(Account.normalizeSite(""))
    }
}

/// Exercises every write path against a real issue. Skipped unless the environment names one:
/// TEST_RUNNER_CONDUCTOR_SITE / _EMAIL / _TOKEN / _TEST_ISSUE (xcodebuild strips the prefix).
final class LiveWriteTests: XCTestCase {
    func testCommentAssignTransitionRoundTrip() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let site = env["CONDUCTOR_SITE"].flatMap(Account.normalizeSite),
              let email = env["CONDUCTOR_EMAIL"], let token = env["CONDUCTOR_TOKEN"],
              let key = env["CONDUCTOR_TEST_ISSUE"] else { throw XCTSkip("No live credentials in the environment") }
        var c = JiraClient(account: Account(site: site, email: email, token: token))
        c.sprintField = try await c.customFieldIds().sprint
        let me = try await c.myself()
        let before = try await c.issue(key)

        // Comment, then remove it so the issue is left as found.
        try await c.addComment(key, text: "Conductor self-test, safe to ignore.\nSecond line.")
        let withComment = try await c.issue(key)
        XCTAssertEqual(withComment.fields.comment?.total, (before.fields.comment?.total ?? 0) + 1)
        let mine = try XCTUnwrap(withComment.fields.comment?.comments.last)
        XCTAssertEqual(mine.author?.accountId, me.accountId)
        XCTAssertEqual(mine.body.content?.count, 2)
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
        XCTAssertEqual(p.content?.map { $0.marks?.first?.type ?? "plain" }, ["plain", "strong", "plain", "em", "plain", "code", "plain", "link", "plain"])
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
        let cases = ["", "\n\n", "**", "*", "`", "~~", "[", "[x](", "[](", "- ", "-", "1.", "1. ", "#", "# ", "####### seven", "```", "```\n", "> ", ">",
                     "**bold *nested* bold**", "a_b_c", "_", "__", "*a**b*", "- a\n    - b\n  - c\n- d", "1) x\n- y\n2. z", "  - indented first",
                     "```swift\nlet a = 1", "text\r\nmore\r\n", "@", "@ ", "ping @", "https://", "http://x", "<https://x>", "\u{200B}", "😀 **😀**", "a\u{0301}"]
        for md in cases {
            let doc = ADFNode.document(markdown: md, mentions: ["Ivan K": "a1", "": "empty"])
            _ = try JSONValue(doc)
            var m: [String: String] = [:]
            let back = doc.markdown(mentions: &m)
            _ = ADFNode.document(markdown: back, mentions: m)
        }
    }

    func testLossyDetection() {
        XCTAssertTrue(ADFNode(type: "doc", content: [ADFNode(type: "table")]).hasLossyNodes)
        XCTAssertFalse(ADFNode.document(markdown: "plain").hasLossyNodes)
    }
}

final class FilterAndDurationTests: XCTestCase {
    func testChipsExtendTheQuery() {
        var f = Smart.recent.filters(account: nil)
        f.status = .inProgress
        f.assignee = .me
        f.type = "Bug"
        f.updated = .week
        XCTAssertEqual(f.jql(), "issuekey IN issueHistory() AND statusCategory = \"In Progress\" AND assignee = currentUser() AND issuetype = \"Bug\" AND updated >= startOfWeek() ORDER BY lastViewed DESC")
        f.text = "status = Done"
        XCTAssertEqual(f.jql(), "status = Done", "raw JQL ignores chips")
        f = Smart.assigned.filters(account: nil)
        f.status = .open
        XCTAssertEqual(f.jql(), "statusCategory != Done AND assignee = currentUser() ORDER BY updated DESC")
        f.status = .any
        XCTAssertEqual(f.jql(), "assignee = currentUser() ORDER BY updated DESC", "Done is a filter, not baked into the list")
        var everything = ListFilters()
        everything.status = .any
        everything.sort.descending = false
        XCTAssertEqual(everything.jql(), "ORDER BY updated ASC", "no chips at all is the whole site")
    }

    func testBoardURL() {
        let c = JiraClient(account: Account(site: URL(string: "https://x.atlassian.net")!, email: "e", token: "t"))
        XCTAssertEqual(c.boardURL(project: "ES").absoluteString, "https://x.atlassian.net/secure/RapidBoard.jspa?projectKey=ES")
        XCTAssertEqual(c.boardURL(project: "ES", board: 7).absoluteString, "https://x.atlassian.net/secure/RapidBoard.jspa?projectKey=ES&rapidView=7")
    }

    func testDurationParsing() {
        XCTAssertEqual(LogWorkView.parseDuration("1h 30m"), 5400)
        XCTAssertEqual(LogWorkView.parseDuration("2d"), 16 * 3600)
        XCTAssertEqual(LogWorkView.parseDuration("1w"), 40 * 3600)
        XCTAssertEqual(LogWorkView.parseDuration("45"), 45 * 60)
        XCTAssertNil(LogWorkView.parseDuration("soon"))
        XCTAssertNil(LogWorkView.parseDuration("1h x"))
    }

    func testVersionCompare() {
        XCTAssertTrue(UpdateChecker.isNewer("1.2.10", than: "1.2.9"))
        XCTAssertTrue(UpdateChecker.isNewer("1.1", than: "1.0.5"))
        XCTAssertFalse(UpdateChecker.isNewer("1.0", than: "1.0.0"))
    }

    func testIssueKeyFromLinks() {
        XCTAssertEqual(Session.issueKey(in: URL(string: "https://x.atlassian.net/browse/es-12")!), "ES-12")
        XCTAssertEqual(Session.issueKey(in: URL(string: "https://x.atlassian.net/jira/software/projects/ES/boards/62?selectedIssue=ES-9")!), "ES-9")
        XCTAssertNil(Session.issueKey(in: URL(string: "https://x.atlassian.net/")!))
    }
}

final class BoardTests: XCTestCase {
    private func issue(_ key: String, assignee: String?) throws -> Issue {
        let who = assignee.map { #"{"accountId":"\#($0)","displayName":"\#($0.capitalized)"}"# } ?? "null"
        let json = #"{"id":"\#(key)","key":"\#(key)","fields":{"summary":"s","status":{"id":"1","name":"To Do","statusCategory":{"key":"new","name":"To Do"}},"issuetype":{"id":"1","name":"Task"},"assignee":\#(who)}}"#
        return try JSONDecoder().decode(Issue.self, from: Data(json.utf8))
    }

    func testAssigneeLanesKeepFirstSeenOrderWithUnassignedLast() throws {
        let issues = try [issue("A-1", assignee: nil), issue("A-2", assignee: "bo"), issue("A-3", assignee: "al"), issue("A-4", assignee: "bo")]
        let lanes = Swimlanes.assignee.lanes(issues)
        XCTAssertEqual(lanes.map(\.title), ["Bo", "Al", "Unassigned"])
        XCTAssertEqual(lanes[0].issues.map(\.key), ["A-2", "A-4"])
        XCTAssertEqual(Swimlanes.none.lanes(issues).first?.issues.count, 4)
    }
}
