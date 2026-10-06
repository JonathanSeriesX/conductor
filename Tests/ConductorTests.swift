import XCTest
@testable import Conductor

final class JQLTests: XCTestCase {
    let account = UUID()
    let project = Project(id: "1", key: "IN", name: "Infrastructure", projectTypeKey: nil, avatarUrls: nil, favourite: nil)

    func testProjectKeysAreQuoted() {
        // IN is a JQL reserved word; unquoted it fails server-side.
        XCTAssertEqual(Source.project(project, account).jql(search: ""), "project = \"IN\" ORDER BY updated DESC")
    }

    func testFreeTextBecomesTextSearch() {
        XCTAssertEqual(Source.smart(.assigned, account).jql(search: "billing \"engine\""),
                       "assignee = currentUser() AND statusCategory != Done AND text ~ \"billing \\\"engine\\\"\" ORDER BY updated DESC")
    }

    func testIssueKeyIsLookedUpDirectly() {
        XCTAssertEqual(Source.all(.recent).jql(search: "es-2284"), "key = \"ES-2284\"")
    }

    func testRawJQLPassesThrough() {
        XCTAssertEqual(Source.all(.recent).jql(search: "status = Done order by created"), "status = Done order by created")
    }

    func testSourceIdsRoundTripShape() {
        XCTAssertEqual(Source.all(.watching).id, "all:watching")
        XCTAssertEqual(Source.project(project, account).id, "\(account):project:IN")
        XCTAssertTrue(Source.all(.assigned).isUnified)
        XCTAssertEqual(Source.filter(Filter(id: "7", name: "x", jql: ""), account).accountID, account)
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

    func testLossyDetection() {
        XCTAssertTrue(ADFNode(type: "doc", content: [ADFNode(type: "table")]).hasLossyNodes)
        XCTAssertFalse(ADFNode.document(markdown: "plain").hasLossyNodes)
    }
}

final class FilterAndDurationTests: XCTestCase {
    func testChipsExtendTheQuery() {
        var f = ListFilters()
        f.status = .inProgress
        f.assignee = .me
        f.type = "Bug"
        f.updated = .week
        XCTAssertEqual(Source.all(.recent).jql(search: "", filters: f),
                       "issuekey IN issueHistory() AND statusCategory = \"In Progress\" AND assignee = currentUser() AND issuetype = \"Bug\" AND updated >= startOfWeek() ORDER BY lastViewed DESC")
        XCTAssertEqual(Source.all(.recent).jql(search: "status = Done", filters: f), "status = Done", "raw JQL ignores chips")
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

final class PaletteTests: XCTestCase {
    func testFuzzyMatchesInOrderAndPrefersWordStarts() throws {
        XCTAssertNil(Fuzzy.match("lc", "Issue: Copy Link"), "characters must appear in order")
        let link = try XCTUnwrap(Fuzzy.match("cl", "Issue: Copy Link"))
        XCTAssertEqual(link.indices, [7, 12]) // C of Copy, L of Link
        let scattered = try XCTUnwrap(Fuzzy.match("cl", "View: Toggle Sidebar collapse"))
        XCTAssertGreaterThan(link.score, scattered.score)
        XCTAssertNotNil(Fuzzy.match("ISSUE", "Issue: Watch"), "case-insensitive")
    }
}
