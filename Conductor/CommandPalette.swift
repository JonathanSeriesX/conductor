import SwiftUI

/// One row of the palette: a command in `>` mode, or a place to go in quick-open mode.
struct PaletteItem: Identifiable {
    let id: String
    /// "Issue: Copy Link" for commands, the issue key or list name for places.
    let title: String
    var detail: String?
    var keys: String?
    var symbol: String?
    var color: Color?
    let run: () -> Void
}

/// VS Code's palette: ⌘⇧P opens it on `>` with every command, fuzzy-matched, recently used first and
/// shortcuts on the right. Deleting the `>` turns it into quick open (⌘P): issues, lists, projects and
/// boards on every account. Keyboard only: ↑↓ ↩ esc.
struct CommandPalette: View {
    @Environment(Session.self) private var session
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.controlActiveState) private var activeState
    @State private var query = ""
    @State private var selection = 0
    @State private var found: [PaletteItem] = []
    @FocusState private var focused: Bool
    @AppStorage("paletteRecent") private var recentData = Data()

    private var isCommands: Bool { query.hasPrefix(">") }
    private var needle: String { (isCommands ? String(query.dropFirst()) : query).trimmingCharacters(in: .whitespaces) }

    var body: some View {
        let rows = self.rows
        VStack(spacing: 0) {
            TextField(isCommands ? "Type a command" : "Go to an issue, list, project or board  ·  type > for commands", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($focused)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(.background.opacity(0.6), in: .rect(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 1))
                .padding(8)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.item.id) { i, row in
                            self.row(row, selected: i == selection)
                                .id(i)
                                .onTapGesture { run(row.item) }
                        }
                    }
                    .padding(.horizontal, 6).padding(.bottom, 6)
                }
                .onChange(of: selection) { proxy.scrollTo(selection) }
            }
            .frame(height: 360)
            .overlay { if rows.isEmpty { Text(isCommands ? "No matching commands" : "No matching results").foregroundStyle(.secondary) } }
        }
        .frame(width: 620)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .background(WindowEventMonitor(mask: .keyDown) { e in
            switch e.keyCode {
            case 125: selection = min(selection + 1, max(rows.count - 1, 0)); return nil         // ↓
            case 126: selection = max(selection - 1, 0); return nil                               // ↑
            case 36, 76: if rows.indices.contains(selection) { run(rows[selection].item) }; return nil // ↩
            case 53: dismissWindow(id: "palette"); return nil                                     // esc
            default: return e
            }
        })
        .onAppear {
            query = session.paletteMode
            focused = true
        }
        .onChange(of: query) { selection = 0 }
        .onChange(of: activeState) { _, s in if s != .key { dismissWindow(id: "palette") } }
        .task(id: query) { await search() }
    }

    // MARK: Rows

    private struct Row {
        let item: PaletteItem
        var matches: Set<Int> = []
        var label: String?
    }

    private var rows: [Row] {
        isCommands ? commandRows : placeRows
    }

    private var commandRows: [Row] {
        let recent = recentIDs
        let all = commands
        if needle.isEmpty {
            let used = recent.compactMap { id in all.first { $0.id == id } }
            let rest = all.filter { !recent.contains($0.id) }.sorted { $0.title < $1.title }
            return used.enumerated().map { Row(item: $1, label: $0 == 0 ? "recently used" : nil) }
                + rest.enumerated().map { Row(item: $1, label: $0 == 0 && !used.isEmpty ? "other commands" : nil) }
        }
        return all.compactMap { c in Fuzzy.match(needle, c.title).map { (c, $0) } }
            .sorted { a, b in
                a.1.score != b.1.score ? a.1.score > b.1.score
                    : (recent.firstIndex(of: a.0.id) ?? .max) < (recent.firstIndex(of: b.0.id) ?? .max)
            }
            .map { Row(item: $0.0, matches: $0.1.indices) }
    }

    private var placeRows: [Row] {
        let local = jumpToKey + recentIssues + places
        let shown: [Row]
        if needle.isEmpty {
            shown = local.prefix(60).map { Row(item: $0) }
        } else {
            shown = local.compactMap { p in Fuzzy.match(needle, p.title + " " + (p.detail ?? "")).map { (p, $0) } }
                .sorted { $0.1.score > $1.1.score }
                .prefix(60)
                .map { item, m in Row(item: item, matches: m.indices.filter { $0 < item.title.count }) }
        }
        let ids = Set(shown.map(\.item.id))
        return shown + found.filter { !ids.contains($0.id) }.map { Row(item: $0) }
    }

    private func row(_ row: Row, selected: Bool) -> some View {
        HStack(spacing: 8) {
            if let s = row.item.symbol {
                Image(systemName: s).foregroundStyle(row.item.color ?? .secondary).frame(width: 18)
            }
            Text(highlighted(row.item.title, row.matches)).lineLimit(1)
            if let d = row.item.detail { Text(d).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
            Spacer(minLength: 8)
            if let label = row.label { Text(label).font(.caption).foregroundStyle(.secondary) }
            if let keys = row.item.keys {
                Text(keys).font(.caption.monospaced())
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.quaternary.opacity(0.7), in: .rect(cornerRadius: 4))
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .foregroundStyle(selected ? .white : .primary)
        .background(selected ? Color.accentColor : .clear, in: .rect(cornerRadius: 6))
        .environment(\.backgroundProminence, selected ? .increased : .standard)
        .contentShape(.rect)
    }

    private func highlighted(_ text: String, _ matches: Set<Int>) -> AttributedString {
        var s = AttributedString()
        for (i, ch) in text.enumerated() {
            var part = AttributedString(String(ch))
            if matches.contains(i) { part.font = .body.weight(.bold) }
            s += part
        }
        return s
    }

    private func run(_ item: PaletteItem) {
        if item.id == Self.goTo { query = ""; return } // switches mode in place, like deleting the >
        dismissWindow(id: "palette")
        if item.id.hasPrefix("cmd:") {
            var ids = recentIDs.filter { $0 != item.id }
            ids.insert(item.id, at: 0)
            recentData = (try? JSONEncoder().encode(Array(ids.prefix(8)))) ?? Data()
        }
        // Next turn of the run loop, once the window the command is for is key again.
        DispatchQueue.main.async { item.run() }
    }

    private static let goTo = "cmd:goto"

    private var recentIDs: [String] { (try? JSONDecoder().decode([String].self, from: recentData)) ?? [] }

    // MARK: Commands

    private var commands: [PaletteItem] {
        var all: [PaletteItem] = []
        func add(_ title: String, _ keys: String? = nil, _ run: @escaping () -> Void) {
            all.append(PaletteItem(id: "cmd:" + title, title: title, keys: keys, run: run))
        }

        add("File: New Issue", "⌘N") { main { session.createIssueRequested = true } }
        if let save = session.paletteList?.saveFilter { add("File: Save Search as Filter", "⌘S", save) }
        all.append(PaletteItem(id: Self.goTo, title: "Go to Issue, List or Project…", keys: "⌘P") {})

        for (s, keys) in [(Smart.assigned, "⌘1"), (.reported, "⌘2"), (.recent, "⌘3"), (.watching, "⌘4")] {
            add("Go: \(s.title)", keys) { main { session.navigationRequest = session.source(for: s) } }
        }
        if !session.stars.isEmpty { add("Go: Starred") { main { session.navigationRequest = .starred } } }

        add("View: Toggle Sidebar", "⌃⌘S") { NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil) }
        add("View: Find Issues", "⌘F") { main { session.focusSearchRequested = true } }
        add("View: Reload", "⌘R") { session.reloadTick += 1 }
        if let board = session.paletteList?.openBoard { add("View: Open Board", "⌘⇧B", board) }

        if let ctx = session.paletteIssue {
            let k = ctx.key
            let issue: [(String, String?, IssueActions.Action)] = [
                ("Copy Link", "⌘⇧C", .copyLink), ("Copy as Markdown", "⌥⌘C", .copyMarkdown), ("Copy Key", "⌃⌘C", .copyKey),
                ("Open in Browser", "⌘⇧O", .openInBrowser), ("Open in New Window", "⌘O", .openInWindow),
                ("Assign…", "⌘⇧A", .assign), ("Assign to Me", "⌘⇧I", .assignToMe),
                (ctx.watching ? "Stop Watching" : "Watch", nil, .watch), (ctx.starred ? "Unstar" : "Star", "⌘D", .star),
                ("Remind Me…", "⌥⌘R", .remind), ("Add Comment", "⌘⇧M", .comment), ("Attach Files…", "⌥⌘A", .attach),
                ("Link Issue…", "⌘⇧L", .link), ("Log Work…", "⌥⌘L", .logWork), ("Create Subtask…", "⌘⇧N", .subtask),
                ("Refresh", "⌘⇧R", .refresh),
            ]
            for (title, keys, action) in issue { add("Issue: \(title) (\(k))", keys) { ctx.perform(action) } }
            if ctx.canEditSummary { add("Issue: Edit Summary (\(k))", "⌘E") { ctx.perform(.editSummary) } }
            if ctx.canEditDescription { add("Issue: Edit Description (\(k))", "⌥⌘E") { ctx.perform(.editDescription) } }
            for t in ctx.transitions { add("Issue: Move to \(t.name) (\(k))") { ctx.perform(.transition(t.id)) } }
        }

        add("Accounts: Add Account…") { main { session.addAccountRequested = true } }
        add("Accounts: Refresh Projects and Filters") { Task { await session.refreshAll() } }

        add("Preferences: Open Settings", "⌘,") { openSettings() }
        for (name, tag) in [("Aurora", "mesh"), ("Aurora, Muted", "muted"), ("Dusk", "dusk"), ("Forest", "forest"), ("Plain", "plain")] {
            add("Preferences: Background: \(name)") { UserDefaults.standard.set(tag, forKey: "backdrop") }
        }
        add("Preferences: Toggle Hiding Done Issues in Projects") { toggle("hideDoneInProjects", default: false); session.reloadTick += 1 }
        add("Preferences: Toggle Menu Bar Extra") { toggle("showInMenuBar", default: true) }
        add("Preferences: Toggle Notifications") { toggle("notificationsEnabled", default: true) }

        add("Help: Check for Updates…") { UpdateChecker.shared.check(interactive: true) }
        add("Developer: Clear Recent Searches") { session.clearRecentSearches() }
        add("Developer: Clear Cache and Spotlight Index") { DiskCache.clear() }
        return all
    }

    private func toggle(_ key: String, default value: Bool) {
        let d = UserDefaults.standard
        d.set(!(d.object(forKey: key) as? Bool ?? value), forKey: key)
    }

    private func main(_ request: () -> Void) {
        request()
        bringMainWindowForward(openWindow)
    }

    // MARK: Places

    /// "ES-123" opens straight away in the account that has the project.
    private var jumpToKey: [PaletteItem] {
        let key = needle.uppercased()
        guard key.wholeMatch(of: /[A-Z][A-Z0-9_]+-\d+/) != nil else { return [] }
        let prefix = String(key.split(separator: "-").first ?? "")
        let owners = session.states.filter { $0.projects.contains { $0.key == prefix } }
        return (owners.isEmpty ? Array(session.states.prefix(1)) : owners).map { st in
            issueItem(IssueTarget(accountID: st.id, key: key), summary: "Open issue", symbol: "arrow.right.circle")
        }
    }

    private var recentIssues: [PaletteItem] {
        let starred = session.starredTargets
        let history = session.history.prefix(30).filter { t in !starred.contains { $0.target == t } }
        return starred.map { issueItem($0.target, summary: $0.summary, symbol: "star.fill") }
            + history.map { t in issueItem(t, summary: session.state(t.accountID)?.peek[t.key]?.fields.summary, symbol: "clock") }
    }

    private var places: [PaletteItem] {
        var all: [PaletteItem] = []
        let many = session.states.count > 1
        func add(_ id: String, _ title: String, _ detail: String, _ symbol: String, _ color: Color?, _ run: @escaping () -> Void) {
            all.append(PaletteItem(id: id, title: title, detail: detail, symbol: symbol, color: color, run: run))
        }
        if many {
            for s in Smart.allCases where s != .recent {
                add("all:\(s)", s.title, "All Accounts", s.symbol, nil) { main { session.navigationRequest = .all(s) } }
            }
        }
        for st in session.states {
            let tint = many ? st.color : nil
            for s in Smart.allCases {
                add("\(st.id):\(s)", s.title, st.title, s.symbol, tint) { main { session.navigationRequest = .smart(s, st.id) } }
            }
            for f in st.filters {
                add("\(st.id):f\(f.id)", f.name, "Filter · \(st.title)", "line.3.horizontal.decrease.circle", tint) { main { session.navigationRequest = .filter(f, st.id) } }
            }
            for p in st.starredProjects + st.projects.filter({ !st.starred.contains($0.key) }) {
                add("\(st.id):p\(p.key)", p.name, "\(p.key) · \(st.title)", "folder", tint) { main { session.navigationRequest = .project(p, st.id) } }
                add("\(st.id):b\(p.key)", "\(p.name) Board", "\(p.key) · \(st.title)", "rectangle.split.3x1", tint) {
                    openWindow(id: "board", value: BoardTarget(accountID: st.id, projectKey: p.key))
                }
            }
        }
        return all
    }

    private func issueItem(_ t: IssueTarget, summary: String?, symbol: String) -> PaletteItem {
        PaletteItem(id: "issue:\(t.accountID)|\(t.key)", title: t.key, detail: summary, symbol: symbol,
                    color: session.states.count > 1 ? session.state(t.accountID)?.color : nil) {
            main { session.pendingOpen = t }
        }
    }

    /// Quick open also asks every account's issue picker, which matches summaries Conductor hasn't seen.
    private func search() async {
        found = []
        let q = needle
        guard !isCommands, q.count >= 2 else { return }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        for st in session.states {
            let hits = (try? await st.client.pickIssues(query: q)) ?? []
            guard !Task.isCancelled else { return }
            found += hits.prefix(10).map { issueItem(IssueTarget(accountID: st.id, key: $0.key), summary: $0.summaryText, symbol: "magnifyingglass") }
        }
    }
}

/// VS Code-style fuzzy match: every pattern character in order, scored up for runs and word starts.
enum Fuzzy {
    struct Match { let score: Int; let indices: Set<Int> }

    static func match(_ pattern: String, _ text: String) -> Match? {
        let p = Array(pattern.lowercased()), t = Array(text.lowercased())
        var indices = Set<Int>(), score = 0, pi = 0, last = -2
        for (ti, ch) in t.enumerated() where pi < p.count && ch == p[pi] {
            let wordStart = ti == 0 || " :-·(".contains(t[ti - 1])
            score += 1 + (ti == last + 1 ? 5 : 0) + (wordStart ? 8 : 0)
            indices.insert(ti)
            last = ti
            pi += 1
        }
        return pi == p.count ? Match(score: score, indices: indices) : nil
    }
}

/// Brings the main window forward, reopening it if it was closed. Requests set on the session before
/// calling this are picked up by the window either way.
@MainActor func bringMainWindowForward(_ openWindow: OpenWindowAction) {
    NSApp.activate()
    if let w = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible }) {
        w.makeKeyAndOrderFront(nil)
    } else {
        openWindow(id: "main")
    }
}
