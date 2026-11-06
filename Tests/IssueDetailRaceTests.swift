import XCTest

@testable import Conductor

/// The page keeps the previous issue on screen while the next loads, and writes finish late.
final class IssueDetailRaceTests: XCTestCase {
    let target = IssueTarget(accountID: UUID(), key: "QA-1")
    /// The same key on another site.
    let twin = IssueTarget(accountID: UUID(), key: "QA-1")

    @MainActor private func store() throws -> IssueDetailStore {
        let json =
            #"{"id":"1","key":"QA-1","fields":{"summary":"Old","status":{"id":"1","name":"To Do","statusCategory":{"key":"new","name":"To Do"}},"issuetype":{"id":"1","name":"Task"}}}"#
        let issue = try JSONDecoder().decode(Issue.self, from: Data(json.utf8))
        return IssueDetailStore(
            seed: PageSeed(
                target: target, issue: issue, children: [], related: [:], editMeta: nil, transitions: [], sprints: []))
    }

    @MainActor func testAChangeForTheSameKeyOnAnotherSiteLeavesThePageAlone() throws {
        let s = try store()
        XCTAssertEqual(s.displayed, target)
        s.apply(Session.IssueChange(targets: [twin], change: { $0.fields.summary = "Twin" }, count: 1))
        XCTAssertEqual(s.issue?.fields.summary, "Old")
        s.apply(Session.IssueChange(targets: [target], change: { $0.fields.summary = "New" }, count: 2))
        XCTAssertEqual(s.issue?.fields.summary, "New")
    }

    @MainActor func testAFailedWriteTakesBackOnlyWhatItSetAndStillHolds() throws {
        let s = try store()
        s.issue?.fields.summary = "First"  // provisional
        s.issue?.fields.watches = Watches(watchCount: 1, isWatching: true)  // a later write, which succeeded
        s.undo(\.summary, "First", to: "Old", on: target)
        XCTAssertEqual(s.issue?.fields.summary, "Old")
        XCTAssertEqual(s.issue?.fields.watches?.isWatching, true)

        s.issue?.fields.summary = "Second"  // a newer edit of the same field
        s.undo(\.summary, "First", to: "Old", on: target)
        XCTAssertEqual(s.issue?.fields.summary, "Second")
        s.undo(\.summary, "Second", to: "Old", on: twin)
        XCTAssertEqual(s.issue?.fields.summary, "Second")
    }
}
