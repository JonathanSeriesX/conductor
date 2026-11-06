import XCTest

@testable import Conductor

/// Answers the Agile board endpoints of race.atlassian.net from memory, board N's configuration after N tenths of a
/// second, so a test decides which of two picks answers first.
final class BoardStub: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host() == "race.atlassian.net" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        let parts = url.pathComponents
        let id = parts.firstIndex(of: "board").flatMap { Int(parts[$0 + 1]) } ?? 0
        let body =
            switch parts.last {
            case "configuration":
                #"{"type":"kanban","columnConfig":{"columns":[{"name":"Board \#(id)","statuses":[{"id":"1"}]}]}}"#
            case "quickfilter": #"{"values":[]}"#
            default: #"{"issues":[],"total":0,"startAt":0,"maxResults":100}"#
            }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        nonisolated(unsafe) let me = self
        DispatchQueue.global().asyncAfter(deadline: .now() + (parts.last == "configuration" ? Double(id) / 10 : 0)) {
            me.client?.urlProtocol(me, didReceive: response, cacheStoragePolicy: .notAllowed)
            me.client?.urlProtocol(me, didLoad: Data(body.utf8))
            me.client?.urlProtocolDidFinishLoading(me)
        }
    }
}

final class MetaRaceTests: XCTestCase {
    private let client = JiraClient(
        account: Account(site: URL(string: "https://race.atlassian.net")!, email: "e", token: "t"))

    override func setUp() { URLProtocol.registerClass(BoardStub.self) }
    override func tearDown() { URLProtocol.unregisterClass(BoardStub.self) }

    /// Picks board `first`, then `second` while the first's configuration is still out, as the toolbar menu does.
    @MainActor private func pick(_ first: Int, then second: Int) async -> (
        BoardStore, Task<Void, Never>, Task<Void, Never>
    ) {
        let store = BoardStore()
        store.isLoading = false
        store.board = Board(id: first, name: "\(first)", type: "kanban")
        let a = Task { await store.loadBoard(client) }
        while !store.isLoading { await Task.yield() }
        store.board = Board(id: second, name: "\(second)", type: "kanban")
        let b = Task { await store.loadBoard(client) }
        return (store, a, b)
    }

    @MainActor func testALateAnswerForABoardPickedBeforeDoesNotLand() async {
        let (store, a, b) = await pick(5, then: 1)
        await b.value
        XCTAssertEqual(store.config?.columnConfig.columns.first?.name, "Board 1")
        XCTAssertFalse(store.isLoading)
        await a.value
        XCTAssertEqual(store.config?.columnConfig.columns.first?.name, "Board 1", "board 5's late configuration landed")
        XCTAssertNil(store.error)
    }

    @MainActor func testAnEarlierPickAnsweringFirstLeavesTheSpinnerToTheNewerOne() async {
        let (store, a, b) = await pick(1, then: 5)
        await a.value
        XCTAssertNil(store.config, "board 1's configuration landed under board 5")
        XCTAssertTrue(store.isLoading, "board 1's load cleared the spinner while board 5's was still out")
        await b.value
        XCTAssertEqual(store.config?.columnConfig.columns.first?.name, "Board 5")
        XCTAssertFalse(store.isLoading)
    }
}
