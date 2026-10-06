import XCTest
@testable import Conductor

final class JQLTests: XCTestCase {
    let project = Project(id: "1", key: "IN", name: "Infrastructure", projectTypeKey: nil, avatarUrls: nil, favourite: nil)

    func testProjectKeysAreQuoted() {
        // IN is a JQL reserved word; unquoted it fails server-side.
        XCTAssertEqual(Source.project(project).jql(search: ""), "project = \"IN\" ORDER BY updated DESC")
    }

    func testFreeTextBecomesTextSearch() {
        XCTAssertEqual(Source.assignedToMe.jql(search: "billing \"engine\""),
                       "assignee = currentUser() AND statusCategory != Done AND text ~ \"billing \\\"engine\\\"\" ORDER BY updated DESC")
    }

    func testIssueKeyIsLookedUpDirectly() {
        XCTAssertEqual(Source.recent.jql(search: "es-2284"), "key = \"ES-2284\"")
    }

    func testRawJQLPassesThrough() {
        XCTAssertEqual(Source.recent.jql(search: "status = Done order by created"), "status = Done order by created")
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
        c.sprintField = try await c.sprintFieldId()
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
