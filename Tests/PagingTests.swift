import Synchronization
import XCTest

@testable import Conductor

/// Answers paging.atlassian.net from memory: issue P-1 with the newest 100 of its 250 comments, the comment endpoint
/// 100 a page, and board 7's 250 cards 100 a page; every request's path and `startAt` is kept.
final class PagingStub: URLProtocol {
    static let asked = Mutex<[String]>([])

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host() == "paging.atlassian.net" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    private static func comment(_ n: Int) -> String {
        let at = String(format: "2026-10-05T%02d:%02d:00.000Z", n / 60, n % 60)
        return #"{"id":"\#(n)","body":{"type":"doc","version":1,"content":[]},"created":"\#(at)","updated":"\#(at)"}"#
    }
    private static func issue(_ key: String, comments: String = "") -> String {
        #"{"id":"1","key":"\#(key)","fields":{"summary":"s","status":{"id":"1","name":"To Do","statusCategory":{"key":"new","name":"To Do"}},"issuetype":{"id":"1","name":"Task"}\#(comments)}}"#
    }

    override func startLoading() {
        let url = request.url!
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let start = query.first { $0.name == "startAt" }?.value.flatMap(Int.init) ?? 0
        let last = url.lastPathComponent
        Self.asked.withLock { $0.append("\(last) \(start)") }
        let body: String
        switch last {
        case "comment":
            let page = (start..<min(start + 100, 250)).map { Self.comment($0 + 1) }.joined(separator: ",")
            body = #"{"comments":[\#(page)],"total":250,"startAt":\#(start),"maxResults":100}"#
        case "P-1":
            let newest = (150..<250).map { Self.comment($0 + 1) }.joined(separator: ",")
            body = Self.issue("P-1", comments: #","comment":{"comments":[\#(newest)],"total":250}"#)
        default:  // board 7's cards
            let page = (start..<min(start + 100, 250)).map { Self.issue("P-\($0 + 1)") }.joined(separator: ",")
            body = #"{"issues":[\#(page)],"total":250,"startAt":\#(start),"maxResults":100}"#
        }
        client?.urlProtocol(
            self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class PagingTests: XCTestCase {
    private let client = JiraClient(
        account: Account(site: URL(string: "https://paging.atlassian.net")!, email: "e", token: "t"))

    override func setUp() {
        URLProtocol.registerClass(PagingStub.self)
        PagingStub.asked.withLock { $0 = [] }
    }
    override func tearDown() { URLProtocol.unregisterClass(PagingStub.self) }

    /// The first comment page goes out beside the issue; the pages after it are asked for once each, and the thread
    /// is whole and oldest first.
    func testAnIssueComesWithEveryCommentEachPageAskedOnce() async throws {
        let issue = try await client.issue("P-1")
        XCTAssertEqual(issue.fields.comment?.comments.map(\.id), (1...250).map(String.init))
        XCTAssertEqual(issue.fields.comment?.total, 250)
        XCTAssertEqual(
            PagingStub.asked.withLock { $0.filter { $0.hasPrefix("comment") }.sorted() },
            ["comment 0", "comment 100", "comment 200"])
    }

    /// A board's pages after the first go out together and land in Jira's order, each asked once.
    @MainActor func testABoardLoadsEveryPageInOrder() async {
        let store = BoardStore()
        store.board = Board(id: 7, name: "7", type: "kanban")
        await store.loadIssues(client)
        XCTAssertEqual(store.issues.map(\.key), (1...250).map { "P-\($0)" })
        XCTAssertFalse(store.truncated)
        XCTAssertNil(store.error)
        XCTAssertEqual(PagingStub.asked.withLock { $0.sorted() }, ["issue 0", "issue 100", "issue 200"])
    }
}
