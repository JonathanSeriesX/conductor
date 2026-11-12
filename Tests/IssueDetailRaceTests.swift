import Synchronization
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

    /// W pressed twice: the second write waits for the first, however slow that is (CON-310).
    @MainActor func testWritesRunInTheOrderTheyWereMade() async throws {
        let s = try store()
        let order = Mutex<[Int]>([])
        let first = s.inOrder("QA-1") {
            try? await Task.sleep(for: .milliseconds(80))
            order.withLock { $0.append(1) }
        }
        let second = s.inOrder("QA-1") { order.withLock { $0.append(2) } }
        let third = s.inOrder("QA-1") { order.withLock { $0.append(3) } }
        // Another issue's write waits for none of them: the preview's store serves one issue after another.
        let other = s.inOrder("QA-2") { order.withLock { $0.append(0) } }
        _ = await (first.value, second.value, third.value, other.value)
        XCTAssertEqual(order.withLock { $0 }, [0, 1, 2, 3])
    }
}
