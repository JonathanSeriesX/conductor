import AppKit
import SwiftUI

// The issue list's table in AppKit, under the SwiftUI around it (chips, toolbar, search, overlays). SwiftUI's List
// built every row of a page as the page landed, a stall of 50–100 ms under a reader scrolling, and every restored row
// in the launch's first layout. This outline view, the kind the List is made of, sets up only the rows in and around
// the window and measures the others in one row view kept for it, so every row is at its height from the start; each
// row hosts the SwiftUI the List drew, selection block and separator included.

struct IssueTable: NSViewRepresentable {
    /// What sits under the rows: the spinner while the next page loads, or Recently Viewed's caption.
    enum Footer: Equatable { case spinner, caption }

    let rows: [DisplayRow]
    let footer: Footer?
    @Binding var selection: Set<IssueTarget>
    /// The chip strip's height: SwiftUI's inset over the table, which AppKit does not know of (the toolbar's and the
    /// sidebar's it does).
    let chips: CGFloat
    /// Row `i`'s content, as the list's state has it.
    let content: (Int) -> ListRowView
    let session: Session
    /// The context menu over these issues: the selection under the pointer, else the row under it.
    let menu: (Set<IssueTarget>) -> NSMenu?
    /// Double-click and ↩: the issues move to windows of their own.
    let open: (Set<IssueTarget>) -> Void
    /// A key the list acts on before the table (the arrows, Space); true when it did.
    let key: (NSEvent) -> Bool
    /// The last issue row has come on screen, by id.
    let lastShown: (String) -> Void
    /// Every row of the list is here: End lands on the last one.
    var complete = true
    /// End is waiting for the rest of the list: the table stays at its end, on the spinner, until every row is in.
    var pinEnd = false
    /// End pressed before every row was here (true), or a key or a scroll since then (false).
    var waitForEnd: (Bool) -> Void = { _ in }
    /// Which list the rows are of: another list's rows open on that list's place (see `ScrollMemory`), and this one's
    /// place is kept.
    var list: ListKey?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = IssueOutline()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ListColumn"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        // As SwiftUI's inset list sets its table up.
        outline.style = .inset
        outline.rowSizeStyle = .custom
        outline.rowHeight = IssueTable.estimate
        outline.intercellSpacing = NSSize(width: 17, height: 0)
        outline.indentationPerLevel = 0
        outline.autoresizesOutlineColumn = false
        outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outline.headerView = nil
        outline.backgroundColor = .controlBackgroundColor
        outline.selectionHighlightStyle = .none  // the rows paint theirs
        outline.allowsMultipleSelection = true
        outline.allowsEmptySelection = true
        outline.allowsTypeSelect = false  // letters are shortcuts here, not a jump to a row
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.target = context.coordinator
        outline.doubleAction = #selector(Coordinator.doubleClicked)
        outline.coordinator = context.coordinator
        context.coordinator.outline = outline

        let sv = NSScrollView()
        sv.documentView = outline
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = false
        sv.autohidesScrollers = true
        sv.drawsBackground = true
        sv.backgroundColor = .controlBackgroundColor
        sv.horizontalScrollElasticity = .none
        sv.verticalScrollElasticity = .allowed
        sv.verticalLineScroll = IssueTable.estimate
        sv.clipsToBounds = true
        context.coordinator.watch(sv)
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        // The list's two paces: a fold's, and the 0.35 s glide of rows that changed places.
        let animation = context.transaction.animation
        // The chips join the safe area, so AppKit's insets and the pocket under the toolbar take them in.
        if sv.additionalSafeAreaInsets.top != chips { sv.additionalSafeAreaInsets.top = chips }
        context.coordinator.update(
            self, duration: animation == nil ? nil : animation == .snappy(duration: 0.25) ? 0.25 : 0.35)
    }

    /// Whatever it is given, as the List took. Asked, SwiftUI measured the scroll view through Auto Layout on every
    /// page that landed.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 10, height: 10))
    }

    /// The height of a row not measured yet, the List's.
    static let estimate: CGFloat = 24
}

/// Where the reader left each list, by `ListKey`, so that it opens there again: the first row in sight and the two
/// under it, each with how far below the top of the rows' area its own top was, or the list's end; none at its top.
/// In the defaults, the last 50 lists, the one shown last first: a relaunch opens on the same rows too.
enum ScrollMemory {
    struct Place: Codable, Sendable {
        var list: ListKey
        var anchors: [IssueTable.Coordinator.Anchor]
        /// Past the rows the list's first pages hold: its first frame needs the whole list.
        var deep: Bool
    }
    private static let key = "listPlaces"
    @MainActor private static var places = stored()

    nonisolated static func stored() -> [Place] {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([Place].self, from: $0) } ?? []
    }
    @MainActor static func place(_ list: ListKey) -> Place? { places.first { $0.list == list } }
    @MainActor static func keep(_ place: Place) {
        places = Array(([place] + places.filter { $0.list != place.list }).prefix(50))
        UserDefaults.standard.set(try? JSONEncoder().encode(places), forKey: key)
    }
}

/// One table row's SwiftUI: the selection block and the separator the list drew, under the row's content, inset as
/// an inset list insets its rows.
struct TableCell: View, Equatable {
    enum Content: Equatable {
        case issue(ListRowView)
        case spinner
        case caption
    }
    let content: Content
    /// The line under the row. The list drew none under a selected row or over one.
    let separator: Bool
    let session: Session

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.content == b.content && a.separator == b.separator && a.session === b.session
    }

    var body: some View {
        Group {
            switch content {
            case .issue(let row): row
            case .spinner:
                HStack {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Spacer()
                }
            case .caption:
                // Jira's history only records issues opened on the web; nothing Conductor does can add to it.
                Text(
                    "Jira keeps this list from the issues you open on the web. Issues opened in Conductor don't count."
                )
                .font(.caption).foregroundStyle(.tertiary).padding(.vertical, 8)
            }
        }
        .labelStyle(ListRowLabelStyle())
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4).padding(.horizontal, 16)
        .background(alignment: .bottom) {
            if separator, case .issue(let row) = content {
                // From the summary to the row's end, as the list's separators ran.
                Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
                    .padding(.leading, 42 + CGFloat(row.d.depth) * 24).padding(.trailing, 16)
            }
        }
        .background {
            if case .issue(let row) = content { row.selectionBlock }
        }
        .environment(session)
    }
}

/// A label as a List row lays it out: the icon centred in a column of its own, the title a fixed step after it.
private struct ListRowLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon.frame(width: 16)
            configuration.title
        }
    }
}

/// The table's row: its SwiftUI, clipped to the row as the List's rows were. The same graph measures the row and
/// draws it, so a row is set up once.
final class IssueTableRow: NSTableRowView {
    private var host: NSHostingController<TableCell>?
    /// The row the view shows, by id: only that row's cell goes on it again, but where the table takes it.
    private(set) var rowID: String?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = true
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Set up with `cell`, row `id`'s: a row view never reaches the table without its content.
    func show(_ cell: TableCell, id: String) {
        rowID = id
        if let host {
            if host.rootView != cell { host.rootView = cell }
        } else {
            let h = NSHostingController(rootView: cell)
            h.sizingOptions = []
            h.sceneBridgingOptions = []
            // A row under the toolbar is still a row: its content stays put.
            h.safeAreaRegions = []
            box.frame = bounds
            h.view.frame = bounds
            box.addSubview(h.view)
            addSubview(box)
            host = h
        }
        settle()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        box.frame = bounds
        host?.view.frame = bounds
        settle()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        settle()
    }

    /// In a window, the row's SwiftUI is laid out at once. Left to the window's layout pass, a change made after this
    /// frame's pass waited for the next: the frame drew the row as it had been, or empty.
    private func settle() {
        if window != nil { host?.view.layoutSubtreeIfNeeded() }
    }
    private let box = HostBox()

    /// Holds the row's SwiftUI and hands VoiceOver its elements, as the List's cells did: the hosting view alone is a
    /// group to step into in every row.
    private final class HostBox: NSView {
        override func isAccessibilityElement() -> Bool { false }
        override func accessibilityChildren() -> [Any]? { subviews.first?.accessibilityChildren() }
    }
    /// The row's height at `width`, as set up last.
    func height(width: CGFloat) -> CGFloat {
        host?.sizeThatFits(in: NSSize(width: width, height: .greatestFiniteMagnitude)).height ?? 0
    }

    // The cell draws the separator and the selection.
    override func drawSeparator(in dirtyRect: NSRect) {}
    override func drawSelection(in dirtyRect: NSRect) {}
}

final class IssueOutline: NSOutlineView {
    weak var coordinator: IssueTable.Coordinator?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { coordinator?.attach() }
    }

    // The rows AppKit sets up around the window are measured first.
    override func prepareContent(in rect: NSRect) {
        coordinator?.measureVisible(rect)
        super.prepareContent(in: rect)
    }

    override func scrollToEndOfDocument(_ sender: Any?) {
        if coordinator?.toEnd() == true { return }
        // On the last row even right after a resize, before the rows off screen are measured again.
        coordinator?.measureAll()
        super.scrollToEndOfDocument(sender)
    }

    override func keyDown(with e: NSEvent) {
        if coordinator?.key(e) == true { return }
        super.keyDown(with: e)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0, let m = coordinator?.menu(at: row) else { return nil }
        menu = m
        // AppKit's own: it rings the row under the pointer while the menu is open.
        return super.menu(for: event)
    }

    @objc func copy(_ sender: Any?) { coordinator?.copyKeys() }

    // To VoiceOver, as the List was: a list, whose menu opens on the selection.
    override func accessibilityRoleDescription() -> String? { NSAccessibility.Role.list.description(with: nil) }
    override func accessibilityPerformShowMenu() -> Bool {
        let row = selectedRow
        guard row >= 0, let m = coordinator?.menu(at: row) else { return false }
        let r = rect(ofRow: row)
        return m.popUp(positioning: nil, at: NSPoint(x: r.midX, y: r.midY), in: self)
    }
}

extension IssueTable {
    @MainActor final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        /// A row's item: the outline view keeps its rows by item, so one object per row id for as long as it shows.
        final class Item {
            let id: String
            init(_ id: String) { self.id = id }
        }

        /// What a row's height depends on beside the width and what all rows share (`layout`): the summary's lines, the
        /// date beside it (any change Jira makes moves `updated`; viewing an issue moves only `lastViewed`), the
        /// parent's line over it, the nesting. None of the selection. Not the whole issue: comparing every row's took
        /// 11 ms a pass on a list of 2,500.
        struct RowKey: Equatable {
            var summary = ""
            var updated: Date?
            var viewed: Date?
            var crumb = false
            var depth = 0
            var folds = false
        }

        var parent: IssueTable?
        weak var outline: IssueOutline?
        private var items: [Item] = [] { didSet { index = nil } }
        /// Each row's index by id: the outline view's own lookup goes through every row. Made when first asked for
        /// after the rows change: a change of a hundred steps made it a hundred times.
        private var rowOf: [String: Int] {
            if let index { return index }
            let made = Dictionary(items.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
            index = made
            return made
        }
        private var index: [String: Int]?
        private var byID: [String: Item] = [:]
        /// Row heights by row id: what they depend on and the width they were measured at. One measured at another
        /// width, or for older content, stands in until the row is measured again; one not measured yet has no key
        /// and stands at `standIn`, as it was when the table first asked.
        var heights: [String: (key: RowKey?, width: CGFloat, height: CGFloat)] = [:]
        /// The height the table has of each row, the one it was given last: a row measured since keeps it until `note`
        /// tells the table. Given the new one whenever it asked again, the table took heights in without moving the
        /// window for them or growing to hold them, and the last rows hung below the list's end.
        private var told: [String: CGFloat] = [:]
        /// The sum and count of the measured heights in `heights`, for `standIn`.
        private var measuredSum: CGFloat = 0
        private var measuredCount = 0
        /// What every row's height depends on: the account tag and the date the order shows.
        private var layout: [AnyHashable] = []
        /// The table is being changed from here: its selection callbacks are not the user's.
        private var applying = false
        /// The table is in its window. Before that it has no rows: AppKit laid out every row that fitted at the
        /// estimate, at a width the window's insets then changed, and set up all 31 of them for nothing.
        private var attached = false

        func attach() {
            guard !attached, let outline else { return }
            attached = true
            applying = true
            outline.reloadData()
            askAll()
            applying = false
            if opening, parent?.rows.isEmpty == false { open(items.map(\.id)) }
            measureVisible()
            measureRest()
            if let p = parent {
                applying = true
                outline.selectRowIndexes(selected(p), byExtendingSelection: false)
                applying = false
            }
        }

        /// The selection's rows, found by id: a pass over every row for each arrow press took milliseconds on a long
        /// list.
        private func selected(_ p: IssueTable) -> IndexSet {
            IndexSet(p.selection.compactMap { rowOf["\($0.accountID)|\($0.key)"] }.filter { $0 < p.rows.count })
        }
        private var spare: [IssueTableRow] = []
        /// Rows set up and measured ahead of the table asking for them, by row id.
        private var prepared: [String: IssueTableRow] = [:]
        /// During an animated `apply`, the frames rows near the window had before it, by row id.
        private var before: [String: NSRect] = [:]
        /// Measures rows the table does not show: one row view takes each in turn.
        private lazy var sizer = IssueTableRow()
        nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }

        /// The clip view's moves and size changes bring rows on screen: they are measured before the table lays out.
        func watch(_ sv: NSScrollView) {
            let clip = sv.contentView
            clip.postsBoundsChangedNotifications = true
            clip.postsFrameChangedNotifications = true
            for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
                observers.append(
                    NotificationCenter.default.addObserver(forName: name, object: clip, queue: nil) { [weak self] _ in
                        MainActor.assumeIsolated { self?.clipChanged() }
                    })
            }
            // A scroll of the reader's own lets End go, and a waiting End.
            observers.append(
                NotificationCenter.default.addObserver(
                    forName: NSScrollView.willStartLiveScrollNotification, object: sv, queue: nil
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.pinnedToEnd = false
                        if let p = self?.parent, p.pinEnd { p.waitForEnd(false) }
                    }
                })
        }

        // MARK: Rows

        private func cell(_ i: Int) -> TableCell? {
            guard let p = parent else { return nil }
            if i < p.rows.count {
                let line = Self.separates(i, of: p.rows.count) { p.selection.contains(p.rows[$0].row.target) }
                return TableCell(content: .issue(p.content(i)), separator: line, session: p.session)
            }
            guard i == p.rows.count, let f = p.footer else { return nil }
            return TableCell(content: f == .spinner ? .spinner : .caption, separator: false, session: p.session)
        }

        /// The line under row `i` of `count` issue rows, as the List drew it: none at a selected row or over one, and
        /// none under the last, whether the table ends there or a footer (whose own lines were hidden) follows.
        nonisolated static func separates(_ i: Int, of count: Int, selected: (Int) -> Bool) -> Bool {
            i + 1 < count && !selected(i) && !selected(i + 1)
        }

        private func ids(_ p: IssueTable) -> [String] {
            p.rows.map(\.id) + (p.footer.map { ["~\($0)"] } ?? [])
        }

        private func rowKey(_ i: Int) -> RowKey {
            guard let p = parent, i < p.rows.count else { return RowKey() }
            return Self.key(p.rows[i])
        }

        nonisolated static func key(_ d: DisplayRow) -> RowKey {
            RowKey(
                summary: d.row.issue.fields.summary, updated: d.row.issue.fields.updated,
                viewed: d.row.issue.fields.lastViewed,
                crumb: d.depth == 0 && d.row.issue.fields.issuetype.isSubtask && d.row.issue.fields.parent != nil,
                depth: d.depth, folds: !d.children.isEmpty)
        }

        /// The list the rows are of (see `IssueTable.list`).
        private var rowsOf: ListKey?
        /// The list's first rows are still to come: they open on its place (see `open`).
        private var opening = true
        /// The rows and footer the last update had.
        private var lastRows: (rows: [DisplayRow], footer: Footer?)?
        /// The list has been whole since it was opened: a window near its end holds on to the end. Before, its end is
        /// only where the rows so far stop.
        private var settled = false

        /// `duration`: the change's animation, nil for none.
        func update(_ p: IssueTable, duration: Double?) {
            if p.list != rowsOf {
                // Another list: the place in this one is kept for its return, before its rows go.
                keep()
                (rowsOf, settled, pinnedToEnd, opening) = (p.list, false, false, true)
            }
            parent = p
            guard let outline else { return }
            if let r = p.rows.first.map({ _ in p.content(0) }), [r.site, r.sort] != layout {
                layout = [r.site, r.sort]
                heights = heights.mapValues { ($0.key, -1, $0.height) }
            }
            // The same rows as last time (an arrow press, a hover): no pass building and comparing every row's id.
            let same =
                p.footer == lastRows?.footer && p.rows.count == lastRows?.rows.count
                && zip(p.rows, lastRows?.rows ?? []).allSatisfy { $0.row === $1.row && $0.depth == $1.depth }
            lastRows = (p.rows, p.footer)
            let new = same ? [] : ids(p)
            applying = true
            defer { applying = false }
            guard attached else {
                if !same { items = new.map(item) }
                return
            }
            if opening, !p.rows.isEmpty {
                open(same ? items.map(\.id) : new)
            } else if !same, new != items.map(\.id) {
                // The window holds on to its rows, or to the end, as rows come, go and move around it; End before the
                // list was whole stays on the spinner at the end and lands on the last row with the rest.
                let a = anchor(keeping: new)
                // Rows that change places out of sight go in at once: animated, the window glided with them to stay
                // on its anchor, never quite in step.
                let seen = !items.isEmpty && shown(items.map(\.id), on: a) != shown(new, on: a)
                measureBefore(new, anchor: a)
                apply(new, duration: seen ? duration : nil, anchor: a)
            }
            if p.complete { settled = true }
            // Each view its own row's cell: the views include a removed row's, fading out under a row number that is
            // another row's now, and it drew that row's content.
            outline.enumerateAvailableRowViews { view, row in
                guard let view = view as? IssueTableRow, items.indices.contains(row), view.rowID == items[row].id,
                    let c = cell(row)
                else { return }
                view.show(c, id: items[row].id)
            }
            measureVisible()
            // The rows off screen once a fold or a glide has run, so that telling the table their heights does not retile
            // it mid-animation.
            measureRest(after: duration)
            let want = selected(p)
            if outline.selectedRowIndexes != want { outline.selectRowIndexes(want, byExtendingSelection: false) }
        }

        /// A list's first rows, `new`: on its place as the reader left it (see `ScrollMemory`), else at its top, in the
        /// pass that brings them, so no frame shows another place first. The rows above stand at the stand-in until
        /// measured, the window held on the row meanwhile. Before the window's first layout the rows only go in: the
        /// place needs the table's width.
        private func open(_ new: [String]) {
            guard let outline, outline.window != nil, outline.bounds.width > 0 else {
                if new != items.map(\.id) { apply(new, duration: nil, anchor: nil) }
                return
            }
            var place = rowsOf.flatMap(ScrollMemory.place).flatMap { Self.restored($0.anchors, in: new) } ?? .top
            if case .row(let id, let offset) = place, let sv = outline.enclosingScrollView {
                place = .row(id, offset + sv.contentInsets.top)
            }
            opening = false
            pinnedToEnd = place == .end
            measureBefore(new, anchor: place)
            if new != items.map(\.id) { apply(new, duration: nil, anchor: place) }
            restore(place)
            // Again once the rows in the window are measured: near the end, their stand-ins cut the place short.
            restore(place)
            keepSoon()  // the list shown last is the first place (see `Session.prepare`)
        }

        /// `keep`, once the window has stood still a moment.
        private func keepSoon() {
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(keep), object: nil)
            perform(#selector(keep), with: nil, afterDelay: 0.3)
        }

        /// Keeps the place the window stands on (see `ScrollMemory`): the first row in sight and the two under it with
        /// their tops' offsets, the end, or none at the top. Once the window has stood still a moment, and as the list is
        /// left.
        @objc private func keep() {
            guard attached, !opening, let list = rowsOf, !list.typed, let p = parent, let outline,
                let sv = outline.enclosingScrollView, !items.isEmpty
            else { return }
            let clip = outline.convert(sv.contentView.bounds, from: sv.contentView)
            var (anchors, k): ([Anchor], Int) = ([], p.rows.count)
            switch anchor() {
            case .end?: anchors = [.end]
            case .row(let id, _)?:
                guard let i = rowOf[id] else { break }
                // Below the top of the rows' area, under the toolbar and chips: after a launch's first layout the
                // chips' height joins it, and the scroll view keeps the rows where they are under it.
                (anchors, k) = (
                    stride(from: i, to: min(i + 3, p.rows.count), by: 1).map {
                        .row(items[$0].id, outline.rect(ofRow: $0).minY - clip.minY - sv.contentInsets.top)
                    }, i
                )
            default: break
            }
            // Past the first pages' 50 rows an account, folded subtasks counted: the next launch reads the whole list.
            let deep =
                !anchors.isEmpty && p.rows[..<k].reduce(0) { $0 + ($1.depth == 0 ? 1 + $1.children.count : 0) } >= 45
            ScrollMemory.keep(.init(list: list, anchors: anchors, deep: deep))
        }

        /// Takes the table to `new` in place: rows that stay keep their views and heights, and a row that moved glides
        /// to its new place when the change is animated, as the List's did. The data source follows each step, and the
        /// window goes back on `anchor` with the rows, over the same animation.
        private func apply(_ new: [String], duration: Double?, anchor: Anchor?) {
            guard let outline else { return }
            // Hundreds of rows changing places (a whole list sorted anew) go in at once: step by step, each move cost
            // a pass over the rows, the table's and ours.
            guard let steps = Self.steps(from: items.map(\.id), to: new, moves: 100) else {
                items = new.map(item)
                outline.reloadData()
                askAll()
                // The rows reordered wholesale: the end stays the end; the window keeps its place, not one row's.
                if anchor == .end { restore(anchor) }
                return forget(keeping: new)
            }
            let gone: NSTableView.AnimationOptions = duration == nil ? [] : [.effectFade, .slideUp]
            let come: NSTableView.AnimationOptions = duration == nil ? [] : [.effectFade, .slideDown]
            // Where the rows within a screen of the window stand now: one the change brings into the window glides
            // from there (see `rowViewForItem`).
            if duration != nil, let clip = outline.enclosingScrollView?.contentView {
                let near = outline.rows(
                    in: outline.convert(clip.bounds, from: clip).insetBy(dx: 0, dy: -clip.bounds.height))
                before = Dictionary(
                    (near.location..<min(NSMaxRange(near), items.count)).map {
                        (items[$0].id, outline.rect(ofRow: $0))
                    },
                    uniquingKeysWith: { a, _ in a })
            }
            defer { before = [:] }
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = duration ?? 0
            outline.beginUpdates()
            for step in steps {
                switch step {
                case .remove(let rows):
                    items = items.indices.filter { !rows.contains($0) }.map { items[$0] }
                    outline.removeItems(at: rows, inParent: nil, withAnimation: gone)
                case .move(let from, let to):
                    items.insert(items.remove(at: from), at: to)
                    outline.moveItem(at: from, inParent: nil, to: to, inParent: nil)
                case .insert(let rows):
                    items.insert(contentsOf: new[rows].map(item), at: rows.lowerBound)
                    outline.insertItems(at: IndexSet(integersIn: rows), inParent: nil, withAnimation: come)
                }
            }
            outline.endUpdates()
            askAll()
            restore(anchor, animated: duration != nil)
            NSAnimationContext.endGrouping()
            forget(keeping: new)
        }

        /// Has the table ask for the heights of the rows it has not asked for yet. Until it asks, it lays a row out at an
        /// estimate of its own, and whenever it asked (a change to the rows, a scroll) every row below moved: the rows
        /// above the window, the window with them.
        private func askAll() {
            guard let outline else { return }
            for (i, item) in items.enumerated() where told[item.id] == nil { _ = outline.rect(ofRow: i) }
        }

        /// Lets the rows not in `new` go: their items, heights and views set aside.
        private func forget(keeping new: [String]) {
            let keep = Set(new)
            for id in byID.keys where !keep.contains(id) {
                byID[id] = nil
                told[id] = nil
                if let old = heights.removeValue(forKey: id), old.key != nil {
                    measuredSum -= old.height
                    measuredCount -= 1
                }
                if let v = prepared.removeValue(forKey: id), spare.count < 40 { spare.append(v) }
            }
        }

        /// One change to the rows; each counts its rows as the steps before it left them.
        enum Step: Equatable {
            case remove(IndexSet)
            case move(Int, Int)
            case insert(Range<Int>)
        }

        /// What takes the rows `old` to `new`: the rows `new` lacks go at once, then in `new`'s order each row that stays
        /// moves to its place and each run of new rows goes in at once, a page landing as one insert. Nil past `limit`
        /// moves.
        nonisolated static func steps(from old: [String], to new: [String], moves limit: Int = .max) -> [Step]? {
            let keep = Set(new)
            var steps: [Step] = []
            let removed = IndexSet(old.indices.filter { !keep.contains(old[$0]) })
            if !removed.isEmpty { steps.append(.remove(removed)) }
            var rows = old.filter(keep.contains)
            let staying = Set(rows)
            var (j, moves) = (0, 0)
            while j < new.count {
                if j < rows.count, rows[j] == new[j] {
                    j += 1
                } else if staying.contains(new[j]), let k = rows[j...].firstIndex(of: new[j]) {
                    moves += 1
                    guard moves <= limit else { return nil }
                    rows.insert(rows.remove(at: k), at: j)
                    steps.append(.move(k, j))
                    j += 1
                } else {
                    var end = j + 1
                    while end < new.count, !staying.contains(new[end]) { end += 1 }
                    rows.insert(contentsOf: new[j..<end], at: j)
                    steps.append(.insert(j..<end))
                    j = end
                }
            }
            return steps
        }

        private func item(_ id: String) -> Item {
            if let it = byID[id] { return it }
            let it = Item(id)
            byID[id] = it
            return it
        }

        // MARK: Heights

        // Every row is at its height from the moment it goes in: the rows that will be in the window are measured, in
        // views kept for when the table asks for them, before the table takes them, and every other row right after
        // (after the animation, for a fold or a glide), in one row view kept for measuring, so End, the scroller and
        // the window's place among the rows are exact.
        // A row is measured again when its content or the column's width changes: in the window at once, the others
        // once a resize stops. A row measured above the window moves the window with it, so nothing on screen moves.

        private var measuring = false
        private var again = false
        /// Ids measured since the table was last told.
        private var fresh: Set<String> = []
        /// The column's width as every row was last measured at.
        private var measuredWidth: CGFloat = 0

        private func clipChanged() {
            if !adjusting { moved = CACurrentMediaTime() }
            // The window's first layout gives the table its width: the rows that came before it open now.
            if opening, attached, parent?.rows.isEmpty == false { open(items.map(\.id)) }
            measureVisible()
            keepSoon()
            // The column or the window resized: the rows off screen once it stops, not at every step of the drag.
            if let outline, outline.bounds.width != measuredWidth { measureRest(after: 0.1) }
        }

        // A list loaded whole runs to thousands of rows, and measuring all of them at once (about 0.25 ms a row) held
        // the main thread for a second: past the window its rows are measured a few at a time between frames, while
        // nothing scrolls, and a row not measured yet stands at the mean of those that are, given once, so the
        // scroller and End are close from the start and exact once every row is measured.

        /// When the clip view last moved but for `note`'s own moves: a scroll under way leaves the frame its time.
        private var moved: CFTimeInterval = 0
        private var adjusting = false
        private var idle: CADisplayLink?
        /// The idle pass waits until then: a fold's or a glide's end, a resize's pause.
        private var idleFrom: CFTimeInterval = 0
        /// The idle pass goes from the row at the window's top down, then on from the top, `idleSeen` rows so far.
        private var idleStart = 0
        private var idleSeen = 0

        /// What a row not measured yet stands at: the mean of the rows measured so far, in whole points (rows are 56 or
        /// 72 high); the List's estimate before any is.
        private var standIn: CGFloat {
            guard measuredCount > 0 else { return IssueTable.estimate }
            return (measuredSum / CGFloat(measuredCount)).rounded()
        }

        /// Keeps row `id`'s measure, and the sum the stand-in comes from.
        func record(_ id: String, _ key: RowKey, _ width: CGFloat, _ height: CGFloat) {
            if let old = heights[id], old.key != nil {
                measuredSum -= old.height
                measuredCount -= 1
            }
            heights[id] = (key, width, height)
            measuredSum += height
            measuredCount += 1
        }

        /// The rows not measured for their content at the column's width, between frames (after `delay`, for a fold, a
        /// glide or a resize).
        private func measureRest(after delay: TimeInterval? = nil) {
            guard let outline, let clip = outline.enclosingScrollView?.contentView else { return }
            idleFrom = CACurrentMediaTime() + (delay ?? 0)
            idleStart = max(0, outline.row(at: NSPoint(x: outline.bounds.midX, y: clip.bounds.minY)))
            idleSeen = 0
            guard idle == nil else { return }
            idle = outline.displayLink(target: self, selector: #selector(idleTick))
            idle?.add(to: .main, forMode: .common)
        }

        /// Up to 2 ms of rows a frame, while the window is still.
        @objc private func idleTick(_ link: CADisplayLink) {
            let now = CACurrentMediaTime()
            guard attached, !measuring, now >= idleFrom, now - moved > 0.15, let outline, outline.window != nil,
                outline.bounds.width > 0
            else { return }
            let width = outline.bounds.width
            if width != measuredWidth {
                measuredWidth = width
                idleSeen = 0
            }
            measuring = true
            while idleSeen < items.count, CACurrentMediaTime() - now < 0.002 {
                let i = (idleStart + idleSeen) % items.count
                idleSeen += 1
                if !holds(i, items[i].id, width) { take(i, items[i].id, width, keep: false) }
            }
            measuring = false
            note()
            guard idleSeen >= items.count else { return }
            link.invalidate()
            idle = nil
        }

        /// The last screenful measured now, from the bottom up, so the end of the list is where the rows end.
        private func measureEnd() {
            guard let outline, let clip = outline.enclosingScrollView?.contentView, outline.window != nil,
                outline.bounds.width > 0
            else { return }
            let width = outline.bounds.width
            var (i, h) = (items.count - 1, CGFloat(0))
            while i >= 0, h < clip.bounds.height + 100 {
                let id = items[i].id
                h += holds(i, id, width) ? heights[id]!.height : take(i, id, width, keep: false)
                i -= 1
            }
            note()
        }

        /// The end of the list, its last screenful measured, over a glide: rows passed on the way are measured as they
        /// show, which moves the end, so where the glide lands it goes to the end again. The window stays on the end
        /// from then on (see `anchor`).
        private func scrollToEnd() {
            guard let sv = outline?.enclosingScrollView else { return }
            pinnedToEnd = true
            measureEnd()
            gliding = true
            sv.glide(to: .greatestFiniteMagnitude) { [weak self] in
                guard let self, let sv = self.outline?.enclosingScrollView else { return }
                self.gliding = false
                guard self.pinnedToEnd else { return }
                self.measureEnd()
                sv.glide(to: .greatestFiniteMagnitude, animated: false)
            }
        }
        /// End was pressed, and nothing the reader did since took the window off the end.
        private var pinnedToEnd = false
        /// End's glide is under way: it lands on the end itself.
        private var gliding = false

        /// End: the list's last row, flush with the bottom. Before every row is in, the spinner under the rows shows
        /// and the table stays on it until the last row is in, then lands there.
        func toEnd() -> Bool {
            guard let p = parent else { return false }
            if !p.complete { p.waitForEnd(true) }
            scrollToEnd()
            return true
        }

        /// A key in the table before anything else takes it: End as `toEnd`; any other but a command (⌘R refreshes)
        /// lets End go, and a waiting End.
        func endKey(_ e: NSEvent) -> Bool {
            guard e.keyCode == 119, e.modifierFlags.intersection([.command, .option, .shift, .control]).isEmpty else {
                if e.modifierFlags.contains(.command) { return false }
                pinnedToEnd = false
                if let p = parent, p.pinEnd { p.waitForEnd(false) }
                return false
            }
            return toEnd()
        }

        // MARK: Anchoring

        // Rows change height (measured in the window, between frames past it) and come, go and move (a refresh, an
        // edit) above the window as well as in it. The clip view keeps its place in the document, so each of those
        // moved what the window shows: the window holds on to a row instead, or to the end, in the same pass.

        /// What the window holds on to while the rows change under it.
        enum Anchor: Equatable, Codable {
            /// The last row flush with the bottom.
            case end
            /// This row's top this far below the clip view's top.
            case row(String, CGFloat)
            /// The list's top: a list opened with no place kept.
            case top
        }

        /// The anchor of a window over `clip` (the clip view's bounds in the table's coordinates; the rows start
        /// `inset` below its top) on a document `height` high, `visible` its rows in order with their frames: the end
        /// once End was pressed (`pinned`) or, on a list whole since it opened (`settled`), within a row of the
        /// bottom; none at the top, where rows that come in above push the others down, as in Mail, nor while every
        /// row fits; else the first row under the inset.
        nonisolated static func anchor(
            clip: NSRect, inset: CGFloat, height: CGFloat, pinned: Bool, settled: Bool = true,
            visible: [(id: String, frame: NSRect)]
        ) -> Anchor? {
            guard height > clip.height else { return nil }
            if pinned || settled && clip.maxY >= height - (visible.last?.frame.height ?? 0) { return .end }
            guard clip.minY > -inset + 0.5, let first = visible.first(where: { $0.frame.maxY > clip.minY + inset })
            else { return nil }
            return .row(first.id, first.frame.minY - clip.minY)
        }

        /// Where the clip view's top goes to hold `anchor` once the rows changed: the row's top less its offset (`frame`
        /// gives the row's frame by id, nil once it is gone), or the end of a document `height` high; within the
        /// document, as the clip view keeps it.
        nonisolated static func origin(
            for anchor: Anchor, frame: (String) -> NSRect?, height: CGFloat, clip: CGFloat, inset: CGFloat
        ) -> CGFloat? {
            let y: CGFloat
            switch anchor {
            case .end: y = height - clip
            case .row(let id, let offset):
                guard let f = frame(id) else { return nil }
                y = f.minY - offset
            case .top: y = -inset
            }
            return min(max(y, -inset), max(-inset, height - clip))
        }

        /// Where a list opens on its place (`ScrollMemory`), its rows `new`: the first row of the place `new` still has
        /// with the next one it has right under it (an issue that moved since takes the window nowhere), else the
        /// last one it has; the end; nil without a place or any of its rows, for the top.
        nonisolated static func restored(_ place: [Anchor], in new: [String]) -> Anchor? {
            if place.first == .end { return .end }
            let found = place.compactMap { a -> (anchor: Anchor, at: Int)? in
                guard case .row(let id, _) = a, let i = new.firstIndex(of: id) else { return nil }
                return (a, i)
            }
            return found.indices.first { $0 + 1 == found.count || found[$0 + 1].at == found[$0].at + 1 }
                .map { found[$0].anchor }
        }

        /// Of the rows `old[range]`, those that keep their place in `new`: between the same rows as before, of the rows
        /// both have. A row that moved (an edit took it to the top) is no row to hold the window on, nor are the two
        /// it left. When none does, those `new` has.
        nonisolated static func staying(_ range: Range<Int>, of old: [String], in new: [String]) -> Set<String> {
            let at = Dictionary(new.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            let had = Set(old)
            func next(_ rows: [String], _ i: Int, _ step: Int, _ has: (String) -> Bool) -> String? {
                var j = i + step
                while rows.indices.contains(j), !has(rows[j]) { j += step }
                return rows.indices.contains(j) ? rows[j] : nil
            }
            let kept = range.filter { at[old[$0]] != nil }
            let stay = kept.filter { i in
                [-1, 1].allSatisfy { next(old, i, $0) { at[$0] != nil } == next(new, at[old[i]]!, $0, had.contains) }
            }
            return Set((stay.isEmpty ? kept : stay).map { old[$0] })
        }

        /// The table's margins over its first row and under its last, as they were before the rows last changed.
        private var margins: (top: CGFloat, bottom: CGFloat) = (0, 0)

        /// The anchor as the window stands, of the rows that keep their places in `new` (see `staying`; all of them when
        /// nil).
        private func anchor(keeping new: [String]? = nil) -> Anchor? {
            guard let outline, let sv = outline.enclosingScrollView, !items.isEmpty else { return nil }
            let n = outline.numberOfRows
            if n > 0 { margins = (outline.rect(ofRow: 0).minY, outline.frame.height - outline.rect(ofRow: n - 1).maxY) }
            let clip = outline.convert(sv.contentView.bounds, from: sv.contentView)
            let range = outline.rows(in: clip)
            let rows = range.location..<min(NSMaxRange(range), items.count)
            let keep = new.map { Self.staying(rows, of: items.map(\.id), in: $0) }
            let visible = rows.compactMap { i -> (id: String, frame: NSRect)? in
                guard keep?.contains(items[i].id) ?? true else { return nil }
                return (items[i].id, outline.rect(ofRow: i))
            }
            return Self.anchor(
                clip: clip, inset: sv.contentInsets.top, height: outline.frame.height, pinned: pinnedToEnd,
                settled: settled, visible: visible)
        }

        /// The rows of `order` in the window once it stands on `anchor` (at the top without one), by the rows' heights.
        private func shown(_ order: [String], on anchor: Anchor?) -> [String] {
            guard let sv = outline?.enclosingScrollView else { return [] }
            let rows = order.map { told[$0] ?? heights[$0]?.height ?? standIn }
            let clip = sv.contentView.bounds.height
            let top: CGFloat
            switch anchor {
            case .end?: top = rows.reduce(margins.top + margins.bottom, +) - clip
            case .row(let id, let offset)?:
                guard let k = order.firstIndex(of: id) else { return [] }
                top = rows[..<k].reduce(margins.top, +) - offset
            case .top?, nil: top = -sv.contentInsets.top
            }
            var (y, out) = (margins.top, [String]())
            for (id, h) in zip(order, rows) {
                if y >= top + clip { break }
                if y + h > top { out.append(id) }
                y += h
            }
            return out
        }

        /// Puts the window back on `anchor` once the rows changed: at once, or over the change's own animation, so a
        /// row gliding off to the top takes nothing on screen with it. End's own glide lands on the end itself.
        private func restore(_ anchor: Anchor?, animated: Bool = false) {
            guard let anchor, anchor != .end || !gliding, let outline, let sv = outline.enclosingScrollView else {
                return
            }
            let clip = sv.contentView
            outline.tile()  // the table's height as the rows now are, or the clip view stops at the old one
            var height = outline.frame.height
            var frame = { (id: String) in self.rowOf[id].map(outline.rect(ofRow:)) }
            if animated {
                // While rows animate, the table's geometry runs from the old one to the new: the new one is the rows'
                // heights, between the margins the table had.
                let rows = items.map { told[$0.id] ?? heights[$0.id]?.height ?? standIn }
                height = margins.top + rows.reduce(0, +) + margins.bottom
                frame = { id in
                    self.rowOf[id].map { i in
                        NSRect(
                            x: 0, y: rows[..<i].reduce(self.margins.top, +), width: outline.bounds.width,
                            height: rows[i])
                    }
                }
            }
            guard
                let y = Self.origin(
                    for: anchor, frame: frame, height: height, clip: clip.bounds.height, inset: sv.contentInsets.top),
                y != clip.bounds.minY
            else { return }
            adjusting = true
            if animated {
                clip.animator().setBoundsOrigin(NSPoint(x: clip.bounds.minX, y: y))
            } else {
                clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
            }
            sv.reflectScrolledClipView(clip)
            adjusting = false
        }

        /// Measures the rows in the window and those the table sets up around it, and `rect` too. New heights move the
        /// clip view, which calls back here: that pass waits for this one, as one more turn.
        func measureVisible(_ rect: NSRect? = nil) {
            guard !measuring else {
                again = true
                return
            }
            measuring = true
            defer { measuring = false }
            for _ in 0..<4 {
                again = false
                guard let outline, let clip = outline.enclosingScrollView?.contentView else { return }
                let vis = outline.convert(clip.bounds, from: clip)
                var r = vis
                // Within two screens of the window: after a jump (End, the scroller dragged) the area set up before
                // is a thousand rows away, and the union of the two measured every row between them.
                let near = vis.insetBy(dx: 0, dy: -2 * vis.height)
                for more in [outline.preparedContentRect, rect ?? .zero] where more.intersects(near) {
                    r = r.union(more.intersection(near))
                }
                measure(r)
                note()
                lastShown(in: vis)
                guard again else { return }
            }
        }

        /// Measures the rows `rect` holds, from the top down, each in place at its new height.
        private func measure(_ rect: NSRect) {
            guard let outline, outline.window != nil, outline.bounds.width > 0, !items.isEmpty else { return }
            let width = outline.bounds.width
            var i = outline.row(at: NSPoint(x: outline.bounds.midX, y: max(rect.minY, 0)))
            if i < 0 { i = rect.minY < outline.rect(ofRow: 0).minY ? 0 : items.count }
            let first = i
            var y = i < items.count ? outline.rect(ofRow: i).minY : .greatestFiniteMagnitude
            while i < items.count, y < rect.maxY {
                let id = items[i].id
                y += holds(i, id, width) ? heights[id]!.height : take(i, id, width, keep: true)
                i += 1
            }
            // Rows set up ahead that the table did not take go back to the spares.
            for (id, v) in prepared where !(first..<i).contains(rowOf[id] ?? -1) {
                prepared[id] = nil
                if spare.count < 40 { spare.append(v) }
            }
        }

        /// Before the table takes `new`: its rows that will be in the window, on `anchor` as `restore` puts it back, by
        /// the heights the table will give them, are measured in views kept for when the table asks for them, so that a
        /// row folded out or gliding in goes in at its height. The others go in at the heights the table knows, the
        /// stand-in for the rest.
        private func measureBefore(_ new: [String], anchor: Anchor?) {
            guard let outline, let clip = outline.enclosingScrollView?.contentView, outline.window != nil,
                outline.bounds.width > 0
            else { return }
            let width = outline.bounds.width
            let height = { (id: String) in self.told[id] ?? self.heights[id]?.height ?? self.standIn }
            var vis = outline.convert(clip.bounds, from: clip)
            // The inset style's margin over the first row, and under the last.
            let margin = items.isEmpty ? 10 : outline.rect(ofRow: 0).minY
            switch anchor {
            case .end?: vis.origin.y = new.reduce(2 * margin) { $0 + height($1) } - vis.height
            case .row(let id, let offset)?:
                if let k = new.firstIndex(of: id) {
                    vis.origin.y = new[..<k].reduce(margin) { $0 + height($1) } - offset
                }
            case .top?: vis.origin.y = -(outline.enclosingScrollView?.contentInsets.top ?? 0)
            case nil: break
            }
            var y = margin
            for (i, id) in new.enumerated() {
                guard y < vis.maxY else { break }
                let h = height(id)
                y += y + h > vis.minY && !holds(i, id, width) ? take(i, id, width, keep: true) : h
            }
        }

        /// Every row not measured for its content at the column's width, in the sizer unless it shows.
        @objc func measureAll() {
            guard attached, !measuring, let outline, outline.window != nil, outline.bounds.width > 0 else { return }
            measuring = true
            defer { measuring = false }
            let width = outline.bounds.width
            measuredWidth = width
            let rows = parent?.rows ?? []
            for (i, item) in items.enumerated() {
                let key = i < rows.count ? Self.key(rows[i]) : RowKey()
                if let had = heights[item.id], had.width == width, had.key == key { continue }
                take(i, item.id, width, keep: false)
            }
            note()
        }

        private func holds(_ i: Int, _ id: String, _ width: CGFloat) -> Bool {
            heights[id]?.key == rowKey(i) && heights[id]?.width == width
        }

        /// Row `i` measured now: in the view the table shows it in; else, with `keep`, in one set aside for when the
        /// table asks for it; else in the sizer.
        @discardableResult private func take(_ i: Int, _ id: String, _ width: CGFloat, keep: Bool) -> CGFloat {
            guard let c = cell(i) else { return heights[id]?.height ?? IssueTable.estimate }
            // The table's view at the row only when it is this row's: mid-change it can be a removed row's.
            let shown = rowOf[id].flatMap { outline?.rowView(atRow: $0, makeIfNecessary: false) as? IssueTableRow }
                .flatMap { $0.rowID == id ? $0 : nil }
            let v = shown ?? (keep ? prepared[id] ?? spare.popLast() ?? IssueTableRow() : sizer)
            v.show(c, id: id)
            if keep, shown == nil { prepared[id] = v }
            let h = v.height(width: width)
            record(id, rowKey(i), width, h)
            fresh.insert(id)
            return h
        }

        /// Tells the table the rows measured since it was last told whose heights it has wrong, at once, the window
        /// held on its anchor: a row above it moves nothing on screen, one in it moves what is below it, as the List's
        /// did.
        private func note() {
            guard !fresh.isEmpty, let outline else { return }
            let measured = fresh.compactMap { id in rowOf[id].flatMap { i in heights[id].map { (i, id, $0.height) } } }
            fresh = []
            let changed = Self.changes(measured.map { ($0.0, $0.2) }) { self.told[self.items[$0].id] }
            guard !changed.isEmpty else { return }
            let a = anchor()
            for (i, id, h) in measured where changed.contains(i) { told[id] = h }
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0
            outline.noteHeightOfRows(withIndexesChanged: changed)
            NSAnimationContext.endGrouping()
            restore(a)
        }

        /// Of the rows measured (row, new height), those the table has at another height (`told`, nil for one it has
        /// not asked for yet): against what the table was given, not the last measure, or a row the table took at the
        /// estimate stayed there.
        nonisolated static func changes(_ measured: [(Int, CGFloat)], told: (Int) -> CGFloat?) -> IndexSet {
            IndexSet(measured.filter { m in told(m.0).map { $0 != m.1 } ?? false }.map(\.0))
        }

        /// The last issue row has come into the window: once each time it does, as the List's row appeared.
        private var lastInWindow: String?
        private func lastShown(in vis: NSRect) {
            guard let outline, let p = parent, let last = p.rows.last, let i = rowOf[last.id] else { return }
            let shown = outline.rect(ofRow: i).intersects(vis) ? last.id : nil
            if shown != lastInWindow, let shown { p.lastShown(shown) }
            lastInWindow = shown
        }

        // MARK: Data source and delegate

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            item == nil && attached ? items.count : 0
        }
        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { items[index] }
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { false }

        func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
            guard let id = (item as? Item)?.id else { return IssueTable.estimate }
            if let h = told[id] { return h }
            // Given once: a stand-in that changed when the table asked again moved every row below it.
            let h = heights[id]?.height ?? standIn
            if heights[id] == nil { heights[id] = (nil, -1, h) }
            told[id] = h
            return h
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            nil
        }

        func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
            guard let id = (item as? Item)?.id, let row = rowOf[id], let c = cell(row) else { return nil }
            let view = prepared.removeValue(forKey: id) ?? spare.popLast() ?? IssueTableRow()
            // A view from the pool has no frame, or another row's, and inside an animated change AppKit glides it from
            // there: a row that rows leaving above brought into the window slid down from the list's top. It starts
            // where its row stood, gliding in with the rows around it, else where it lands. Put there at once: the
            // table's own animator calls turn implicit animation on for the change's group, and a frame set plainly
            // in it glided too, from the view's last place.
            let frame = before[id] ?? outlineView.rect(ofRow: row)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0
                ctx.allowsImplicitAnimation = false
                view.frame = frame
            }
            view.show(c, id: id)
            return view
        }

        func outlineView(_ outlineView: NSOutlineView, didRemove rowView: NSTableRowView, forRow row: Int) {
            // A row deleted (-1) during an animated `apply` (`before` is filled then) can still be fading out on screen:
            // its view is not used again, or another row's content came up in it there.
            guard row >= 0 || before.isEmpty, let v = rowView as? IssueTableRow, spare.count < 40 else { return }
            spare.append(v)
        }

        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            guard let p = parent, let id = (item as? Item)?.id, let row = rowOf[id] else { return false }
            return row < p.rows.count
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !applying, let p = parent, let outline else { return }
            let new = Set(outline.selectedRowIndexes.compactMap { $0 < p.rows.count ? p.rows[$0].row.target : nil })
            if new != p.selection { p.selection = new }
        }

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            // Dragged into Slack, a browser or a note, a row is its Jira link; into the Finder, a .webloc by its key
            // and summary, as the List's item provider named it.
            guard let p = parent, let id = (item as? Item)?.id, let row = rowOf[id], row < p.rows.count else {
                return nil
            }
            let r = p.rows[row].row
            let link = NSPasteboardItem()
            link.setString(r.state.client.browseURL(r.issue.key).absoluteString, forType: .URL)
            link.setString(
                "\(r.issue.key) \(r.issue.fields.summary)", forType: NSPasteboard.PasteboardType("public.url-name"))
            return link
        }

        // MARK: Actions

        /// The issues an action on row `i` applies to: the selection when `i` is in it, else the row alone.
        private func targets(at i: Int) -> Set<IssueTarget> {
            guard let p = parent, i < p.rows.count else { return [] }
            let t = p.rows[i].row.target
            return p.selection.contains(t) ? p.selection : [t]
        }

        func menu(at row: Int) -> NSMenu? { parent?.menu(targets(at: row)) }

        @objc func doubleClicked() {
            guard let outline, outline.clickedRow >= 0 else { return }
            let t = targets(at: outline.clickedRow)
            if !t.isEmpty { parent?.open(t) }
        }

        func key(_ e: NSEvent) -> Bool {
            guard let p = parent else { return false }
            if [36, 76].contains(e.keyCode), e.modifierFlags.intersection([.command, .option, .control]).isEmpty {
                if !p.selection.isEmpty { p.open(p.selection) }
                return true
            }
            return p.key(e)
        }

        /// ⌘C with rows selected: their keys, in the list's order.
        func copyKeys() {
            guard let p = parent else { return }
            let keys = p.rows.map(\.row).filter { p.selection.contains($0.target) }.map(\.issue.key)
            guard !keys.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([keys.joined(separator: " ") as NSString])
        }
    }
}
