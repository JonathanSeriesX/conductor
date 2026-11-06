import XCTest

@testable import Conductor

final class ListPatchTests: XCTestCase {
    /// A unified list holds ABC-12 from two sites: an edit made through one account changes that account's row only.
    @MainActor func testPatchChangesOnlyTheTargetedAccountsRow() throws {
        let site = { (h: String) in
            AccountState(account: Account(site: URL(string: "https://\(h).atlassian.net")!, email: "e", token: "t"))
        }
        let (a, b) = (site("a"), site("b"))
        let issue = try a.client.decoder.decode(
            Issue.self,
            from: Data(
                #"{"id":"1","key":"ABC-12","fields":{"summary":"s","status":{"id":"1","name":"To Do","statusCategory":{"key":"new","name":"To Do"}},"issuetype":{"id":"1","name":"Task"}}}"#
                    .utf8))
        let store = IssueListStore()
        store.rows = [ListRow(issue: issue, state: a), ListRow(issue: issue, state: b)]
        store.patch([IssueTarget(accountID: b.id, key: "ABC-12")]) { $0.fields.summary = "changed" }
        XCTAssertEqual(store.rows.map(\.issue.fields.summary), ["s", "changed"])
    }
}
