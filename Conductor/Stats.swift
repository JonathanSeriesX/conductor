import SwiftUI

/// A handful of numbers for the empty detail column, each one request to Jira's approximate-count
/// endpoint (or one tiny search), cached on disk and refreshed at most hourly.
struct Stats: Codable, Sendable {
    var openForMe = 0
    var reported = 0
    var resolvedByMe = 0
    var watching = 0
    var createdLast30Days = 0
    var firstReported: Date?
    var fetched = Date.distantPast
}

extension AccountState {
    /// Fetches every number in parallel and saves the result; cheap enough to run after the lists have warmed.
    func refreshStats() async {
        let c = client
        async let open = c.approximateCount(jql: "assignee = currentUser() AND resolution is EMPTY")
        async let reported = c.approximateCount(jql: "reporter = currentUser()")
        async let resolved = c.approximateCount(jql: "assignee = currentUser() AND resolution is not EMPTY")
        async let watching = c.approximateCount(jql: "watcher = currentUser()")
        async let recent = c.approximateCount(jql: "created >= -30d")
        async let first = c.search(jql: "reporter = currentUser() ORDER BY created ASC", fields: "created,summary,status,issuetype")   // the issue model needs these
        guard let open = try? await open, let reported = try? await reported, let resolved = try? await resolved,
              let watching = try? await watching, let recent = try? await recent else { return }
        var s = Stats(openForMe: open, reported: reported, resolvedByMe: resolved, watching: watching, createdLast30Days: recent, fetched: .now)
        s.firstReported = (try? await first)?.issues.first?.fields.created
        stats = s
        DiskCache.saveAsync(s, account: account, name: "stats")
    }
}

/// What the detail column shows with nothing selected: the signed-in sites and some numbers about them.
struct StatsView: View {
    @Environment(Session.self) private var session

    private var states: [AccountState] { session.states }
    private var all: [Stats] { states.compactMap(\.stats) }
    private var firstYear: Int? { all.compactMap(\.firstReported).min().map { Calendar.current.component(.year, from: $0) } }

    var body: some View {
        VStack(spacing: 28) {
            cover
            VStack(spacing: 4) {
                Text(states.count == 1 ? states[0].title : "All Accounts").font(.largeTitle.weight(.bold))
                if let firstYear {
                    let now = Calendar.current.component(.year, from: .now)
                    Text(firstYear == now ? "Since \(String(now))" : "\(String(firstYear)) – \(String(now))").foregroundStyle(.secondary)
                } else {
                    Text("Select an issue").foregroundStyle(.secondary)
                }
            }
            if !all.isEmpty { tiles }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await refresh() }
    }

    private var cover: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(LinearGradient(colors: states.isEmpty ? [.gray] : states.map(\.color), startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 64, height: 84)
            .overlay { Image(systemName: "ticket").font(.title).foregroundStyle(.white.opacity(0.9)) }
            .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
    }

    private var tiles: some View {
        let sum = { (f: (Stats) -> Int) in all.map(f).reduce(0, +) }
        let items: [(String, Int)] = [("Open for Me", sum(\.openForMe)), ("Reported", sum(\.reported)), ("Resolved by Me", sum(\.resolvedByMe)),
                                      ("Watching", sum(\.watching)), ("New per Day", sum(\.createdLast30Days) / 30),
                                      ("Projects", states.map(\.projects.count).reduce(0, +))]
        return HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                if i > 0 { Divider().frame(height: 36) }
                tile(item.0, item.1)
            }
        }
        .padding(.horizontal, 24)
    }

    private func tile(_ label: String, _ value: Int) -> some View {
        VStack(spacing: 6) {
            Text(label.uppercased()).font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
            Text(value, format: .number).font(.title2.weight(.semibold).monospacedDigit()).contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity)
    }

    /// Cache first; one refresh per hour, after a pause so launch traffic goes to the lists.
    private func refresh() async {
        for st in states where st.stats == nil {
            st.stats = await DiskCache.loadAsync(account: st.account, name: "stats")
        }
        try? await Task.sleep(for: .seconds(2))
        for st in states where (st.stats?.fetched ?? .distantPast).timeIntervalSinceNow < -3600 {
            await st.refreshStats()
        }
    }
}
