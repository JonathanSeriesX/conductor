import AppKit
import Quartz
import SwiftUI

// The comment thread in AppKit. A thread of a thousand comments scrolls at the display's rate because nothing is
// built while it scrolls: rows are plain views reused from a pool, their text is one attributed string per comment
// laid out by TextKit once and measured off a cache, and only the rows in and around the window exist at all.
// Everything around the thread (the card, the composer, the editor on one comment) stays SwiftUI.

// MARK: - SwiftUI bridge

struct CommentThread: NSViewRepresentable {
    /// Oldest first, as Jira gives them; shown as threads (see `Comment.threads`).
    let comments: [Comment]
    /// The order of the threads; replies stay oldest first under theirs.
    let newestFirst: Bool
    /// The issue's, so inline media resolves to images and files.
    let attachments: [Attachment]
    /// The signed-in user: their comments carry Edit and Delete.
    let meID: String?
    /// The comment whose editor is open, shown in its row in place of the text.
    let editingID: String?
    /// The thread whose reply composer is open, by its root: the composer sits under the thread's last reply.
    let replyingTo: String?
    let editor: (Comment, FocusState<Bool>.Binding) -> AnyView
    /// The reply composer for a thread, by its root.
    let replier: (String, FocusState<Bool>.Binding) -> AnyView
    let onEdit: (Comment) -> Void
    let onDelete: (Comment) -> Void
    /// Opens the reply composer on a thread, by its root.
    let onReply: (String) -> Void
    let onPreview: (Attachment) -> Void
    /// An image from memory, disk or the site, shrunk to `maxPixels`; it lands in `ImageCache`.
    let loadImage: (URL, Int) async -> NSImage?
    /// Downloads an inline image or file dragged or copied out; Server's has no replies.
    let client: JiraClient?

    func makeNSView(context: Context) -> CommentThreadView { CommentThreadView() }

    func updateNSView(_ v: CommentThreadView, context: Context) {
        v.onEdit = onEdit
        v.onDelete = onDelete
        v.onReply = onReply
        v.onPreview = onPreview
        v.loadImage = loadImage
        v.client = client
        v.update(
            comments: comments, newestFirst: newestFirst, attachments: attachments, meID: meID, editingID: editingID,
            replyingTo: replyingTo, editor: editor, replier: replier)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView v: CommentThreadView, context: Context) -> CGSize? {
        guard let w = proposal.width, w.isFinite, w > 0 else { return nil }
        return CGSize(width: w, height: v.height)
    }
}

/// The editor on a comment, hosted in its row: its own focus, so the composer takes the keyboard as it opens,
/// and its height reported back as it grows.
private struct HostedEditor: View {
    let build: (FocusState<Bool>.Binding) -> AnyView
    let onHeight: (CGFloat) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        build($focused)
            .focusSoon($focused)
            .onGeometryChange(for: CGFloat.self) {
                $0.size.height
            } action: {
                onHeight($0)
            }
    }
}

// MARK: - The thread

@MainActor final class CommentThreadView: NSView {
    /// Between rows, the lazy stack's.
    static let spacing: CGFloat = 16
    /// The avatar and the gap after it: where a row's text starts.
    static let textInset: CGFloat = 36

    var onEdit: (Comment) -> Void = { _ in }
    var onDelete: (Comment) -> Void = { _ in }
    var onReply: (String) -> Void = { _ in }
    var onPreview: (Attachment) -> Void = { _ in }
    var client: JiraClient?
    var loadImage: (URL, Int) async -> NSImage? = { _, _ in nil }

    /// In display order, threaded; `roots` holds each one's thread root, and a row whose root is its predecessor's
    /// is a reply, set one avatar in.
    private(set) var comments: [Comment] = []
    private var roots: [String] = []
    /// What `comments` was threaded from, oldest first, and in which order.
    private var source: [Comment] = []
    private var newestFirst = true
    private var attachments: [Attachment] = []
    private var meID: String?
    private var editingID: String?
    private var replyingTo: String?
    /// The row the reply composer sits under: the last of its thread.
    private var replyIndex: Int?
    /// Each comment's text, built once; rebuilt when the comment or an image in it changes.
    private var strings: [String: (comment: Comment, text: NSAttributedString)] = [:]
    /// Body heights by comment id and the width they were measured at. A height measured at another width
    /// stands in as the estimate until the row is measured again.
    private var heights: [String: (width: CGFloat, height: CGFloat)] = [:]
    /// Comments whose text shows the image at a URL, to rebuild when it loads.
    private var imageUsers: [URL: Set<String>] = [:]
    private var loading: Set<URL> = []
    private var width: CGFloat = 0
    /// Row tops, from the row heights or estimates.
    private var tops: [CGFloat] = []
    private var total: CGFloat = 0
    private var shown: [Int: CommentRowView] = [:]
    private var pool: [CommentRowView] = []
    private var editorHost: NSHostingController<AnyView>?
    private var editorHeight: CGFloat = 0
    private var observers: [NSObjectProtocol] = []
    private var idle: Task<Void, Never>?
    private let measurer = TextMeasurer()

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: total) }

    func update(
        comments: [Comment], newestFirst: Bool, attachments: [Attachment], meID: String?, editingID: String?,
        replyingTo: String?, editor: @escaping (Comment, FocusState<Bool>.Binding) -> AnyView,
        replier: @escaping (String, FocusState<Bool>.Binding) -> AnyView
    ) {
        self.meID = meID
        if attachments != self.attachments {
            self.attachments = attachments
            strings = [:]
            heights = heights.mapValues { (-1, $0.height) }
        }
        if comments != source || newestFirst != self.newestFirst {
            source = comments
            self.newestFirst = newestFirst
            let threads = Comment.threads(comments, newestFirst: newestFirst)
            self.comments = threads.map(\.comment)
            roots = threads.map(\.root)
        }
        if editingID != self.editingID || replyingTo != self.replyingTo {
            self.editingID = editingID
            self.replyingTo = replyingTo
            editorHost?.view.removeFromSuperview()
            editorHost = nil
            editorHeight = 0
        }
        replyIndex = replyingTo.flatMap { roots.lastIndex(of: $0) }
        if let editingID, let i = self.comments.firstIndex(where: { $0.id == editingID }) {
            let c = self.comments[i]
            updateEditor(width: textWidth(i)) { editor(c, $0) }
        } else if let replyingTo, replyIndex != nil {
            updateEditor(width: width - Self.textInset) { replier(replyingTo, $0) }
            if let v = editorHost?.view, v.superview !== self { addSubview(v) }
        }
        recomputeTops()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    /// The thread's height for SwiftUI's layout. SwiftUI probes several widths; the rows are measured at the width
    /// the view is given (see `layout`), and a change there asks for a new layout.
    var height: CGFloat { total }

    // MARK: Editor

    /// The comment editor or the reply composer, whichever is open, sized at the width it gets.
    private func updateEditor(width w: CGFloat, _ build: @escaping (FocusState<Bool>.Binding) -> AnyView) {
        let root = AnyView(HostedEditor(build: build, onHeight: { [weak self] in self?.editorHeightChanged($0) }))
        let host: NSHostingController<AnyView>
        if let editorHost {
            host = editorHost
            host.rootView = root
        } else {
            host = NSHostingController(rootView: root)
            host.sizingOptions = []
            editorHost = host
        }
        if w > 0 {
            let h = host.sizeThatFits(in: NSSize(width: w, height: CGFloat.greatestFiniteMagnitude)).height
            if h.isFinite, h > 0 { editorHeight = h }
        }
    }

    private func editorHeightChanged(_ h: CGFloat) {
        guard h > 0, abs(h - editorHeight) > 0.5 else { return }
        editorHeight = h
        recomputeTops()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    // MARK: Heights

    /// For rows not yet measured: the measured rows' mean, kept up to date by `recomputeTops`.
    private var estimate: CGFloat = 44

    private func buttons(on c: Comment) -> Bool { meID != nil && c.author?.accountId == meID && editingID == nil }
    /// Reply on every comment while no editor is open; Server has no replies.
    private var replies: Bool { client?.account.isServer == false && editingID == nil }

    private func rowHeight(_ c: Comment, estimate: CGFloat) -> CGFloat {
        let body = c.id == editingID ? max(editorHeight, 100) : heights[c.id]?.height ?? estimate
        let header = buttons(on: c) || replies ? CommentRowView.buttonHeaderHeight : CommentRowView.headerHeight
        return max(26, header + 6 + body)
    }

    private var replyHeight: CGFloat { editorHeight > 0 ? editorHeight : 80 }

    private func nested(_ i: Int) -> Bool { i > 0 && roots[i - 1] == roots[i] }

    /// Row `i`'s text width: a reply's row starts one avatar further in.
    private func textWidth(_ i: Int) -> CGFloat { width - Self.textInset * (nested(i) ? 2 : 1) }

    private func recomputeTops() {
        var sum: CGFloat = 0
        var n = 0
        for h in heights.values where h.width >= 0 {
            sum += h.height
            n += 1
        }
        if n > 0 { estimate = sum / CGFloat(n) }
        let est = estimate
        var y: CGFloat = 0
        tops = []
        tops.reserveCapacity(comments.count)
        for (i, c) in comments.enumerated() {
            tops.append(y)
            y += rowHeight(c, estimate: est) + Self.spacing
            if i == replyIndex { y += replyHeight + Self.spacing }
        }
        total = max(0, y - Self.spacing)
    }

    /// Measures row `i` at the current width if it has not been. True when its height changed.
    private func measure(_ i: Int) -> Bool {
        let c = comments[i]
        guard c.id != editingID else { return false }
        let w = textWidth(i)
        if let h = heights[c.id], h.width == w { return false }
        let h = measurer.height(of: string(for: c), width: w)
        let old = heights[c.id]?.height
        heights[c.id] = (w, h)
        return old != h
    }

    private func string(for c: Comment) -> NSAttributedString {
        if let s = strings[c.id], s.comment == c { return s.text }
        let text = ADFAttributed.render(c.body, attachments: attachments) { [weak self] a in
            self?.image(for: a, in: c.id)
        }
        strings[c.id] = (c, text)
        return text
    }

    /// A cached inline image, or nil while it loads: the comment is rebuilt once it has.
    private func image(for a: Attachment, in id: String) -> NSImage? {
        let url = a.content
        imageUsers[url, default: []].insert(id)
        if let hit = ImageCache.shared.object(forKey: url as NSURL) { return hit }
        guard !loading.contains(url) else { return nil }
        loading.insert(url)
        let load = loadImage
        Task { [weak self] in
            let image = await load(url, 1600)
            guard let self else { return }
            loading.remove(url)
            guard image != nil else { return }
            for id in imageUsers[url] ?? [] {
                strings[id] = nil
                heights[id] = nil
            }
            recomputeTops()
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
        return nil
    }

    /// Measures the rows not yet measured at this width, a few milliseconds per turn of the run loop, so the
    /// thread's height is exact soon after it shows without a stall. Restarted by a width change.
    private func scheduleIdle() {
        idle?.cancel()
        idle = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            var i = 0
            var changed = false
            while let self, !Task.isCancelled, self.window != nil, i < self.comments.count {
                let start = CACurrentMediaTime()
                while i < self.comments.count, CACurrentMediaTime() - start < 0.003 {
                    if self.measure(i) { changed = true }
                    i += 1
                }
                if i < self.comments.count { try? await Task.sleep(for: .milliseconds(1)) }
            }
            guard let self, changed, !Task.isCancelled else { return }
            self.recomputeTops()
            self.invalidateIntrinsicContentSize()
            self.needsLayout = true
        }
    }

    // MARK: Rows

    override func layout() {
        super.layout()
        if bounds.width > 0, bounds.width != width {
            width = bounds.width
            recomputeTops()
            invalidateIntrinsicContentSize()
            scheduleIdle()
        }
        placeRows()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let window else {
            idle?.cancel()
            return
        }
        if let clip = enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            observers.append(
                NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification, object: clip, queue: nil
                ) { [weak self] _ in MainActor.assumeIsolated { self?.placeRows() } })
        }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            observers.append(
                NotificationCenter.default.addObserver(forName: name, object: window, queue: nil) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        let active = self.window?.isKeyWindow ?? true
                        for row in self.shown.values { row.active = active }
                    }
                })
        }
        needsLayout = true
        scheduleIdle()
    }

    /// The first row that can reach `y`.
    private func index(at y: CGFloat) -> Int {
        var lo = 0
        var hi = tops.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if tops[mid] <= y { lo = mid + 1 } else { hi = mid }
        }
        return max(0, lo - 1)
    }

    /// Puts rows on the part of the thread in and around the window, measuring them first, and takes the rest back.
    private func placeRows() {
        defer { placeReply() }
        guard width > 0, !comments.isEmpty, superview != nil else {
            for (_, row) in shown { recycle(row) }
            shown = [:]
            return
        }
        // The scroll view's visible area, not `visibleRect`: while a fold opens, SwiftUI's clip around the thread is
        // still a few points tall, and rows placed for that alone would arrive only once the fold had finished.
        let vis = enclosingScrollView.map { convert($0.contentView.bounds, from: $0.contentView) } ?? visibleRect
        guard !vis.isEmpty else {
            for (_, row) in shown { recycle(row) }
            shown = [:]
            return
        }
        // Half a window above and below: responsive scrolling draws ahead of the main thread.
        let top = vis.minY - vis.height / 2
        let bottom = vis.maxY + vis.height / 2
        var changed = false
        var i = index(at: top)
        while i < comments.count, tops[i] < bottom {
            if measure(i) { changed = true }
            i += 1
        }
        if changed {
            recomputeTops()
            invalidateIntrinsicContentSize()
        }
        let est = estimate
        let rtl = userInterfaceLayoutDirection == .rightToLeft
        var keep = Set<Int>()
        var ahead = 0
        i = index(at: top)
        while i < comments.count, tops[i] < bottom {
            // A reply's whole row one avatar in, so its avatar sits under its parent's text.
            let x = nested(i) ? Self.textInset : 0
            let frame = NSRect(
                x: rtl ? 0 : x, y: tops[i], width: width - x, height: rowHeight(comments[i], estimate: est))
            // A row still outside the window waits its turn: one per tick, since setting a row up lays out and
            // draws its text, and two heavy ones in one tick cost a frame.
            if shown[i] == nil, !frame.intersects(vis) {
                ahead += 1
                if ahead > 1 {
                    i += 1
                    continue
                }
            }
            keep.insert(i)
            let row = shown[i] ?? dequeue()
            shown[i] = row
            configure(row, comments[i])
            row.frame = frame
            i += 1
        }
        for (i, row) in shown where !keep.contains(i) {
            recycle(row)
            shown[i] = nil
        }
    }

    /// The reply composer, under its thread's last row, one avatar in as a reply is.
    private func placeReply() {
        guard editingID == nil, let i = replyIndex, i < tops.count, let v = editorHost?.view else { return }
        let x = Self.textInset
        v.frame = NSRect(
            x: userInterfaceLayoutDirection == .rightToLeft ? 0 : x,
            y: tops[i] + rowHeight(comments[i], estimate: estimate) + Self.spacing, width: max(0, width - x),
            height: replyHeight)
    }

    /// Opens the reply composer on `c`'s thread.
    func reply(to c: Comment) {
        if let i = comments.firstIndex(where: { $0.id == c.id }) { onReply(roots[i]) }
    }

    private func configure(_ row: CommentRowView, _ c: Comment) {
        let editing = c.id == editingID
        let text = editing ? nil : string(for: c)
        let own = buttons(on: c)
        let key = CommentRowView.Key(
            id: c.id, text: text.map(ObjectIdentifier.init), buttons: own, reply: replies, editing: editing,
            updated: c.updated)
        guard row.key != key else { return }
        row.key = key
        row.show(c, text: text, buttons: own, reply: replies, editor: editing ? editorHost?.view : nil)
        row.active = window?.isKeyWindow ?? true
    }

    /// Rows stay in the view, hidden while out of use: adding and removing them had AppKit rebuild its layer tree
    /// and tracking areas on every tick of a scroll.
    private func dequeue() -> CommentRowView {
        if let row = pool.popLast() {
            row.isHidden = false
            return row
        }
        let row = CommentRowView(thread: self)
        addSubview(row)
        return row
    }

    private func recycle(_ row: CommentRowView) {
        row.isHidden = true
        row.prepareForReuse()
        if pool.count < 60 { pool.append(row) } else { row.removeFromSuperview() }
    }
}

/// Lays text out as the rows' text views do (TextKit 1, the pill gutter) and reports its height at a text width.
@MainActor private final class TextMeasurer {
    private let storage = NSTextStorage()
    private let manager = TextLayout()
    private let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))

    init() {
        container.lineFragmentPadding = TextLayout.pad
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
    }

    func height(of s: NSAttributedString, width: CGFloat) -> CGFloat {
        container.size = NSSize(width: max(1, width) + 2 * TextLayout.pad, height: CGFloat.greatestFiniteMagnitude)
        storage.setAttributedString(s)
        manager.ensureLayout(for: container)
        return ceil(manager.usedRect(for: container).height)
    }
}

// MARK: - A row

/// One comment: the avatar, then the name, when, "· edited", Reply, Edit and Delete on a line, and the text under
/// them.
@MainActor final class CommentRowView: NSView, InlineImageHost {
    struct Key: Equatable {
        let id: String
        let text: ObjectIdentifier?
        let buttons: Bool
        let reply: Bool
        let editing: Bool
        let updated: Date
    }
    var key: Key?
    override var isFlipped: Bool { true }
    /// Avatars grey while the window is inactive, as every remote image does.
    var active = true {
        didSet { if active != oldValue { dim() } }
    }

    private unowned let thread: CommentThreadView
    private let avatar = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let date = NSTextField(labelWithString: "")
    private let edited = NSTextField(labelWithString: String(localized: "· edited"))
    private let replyButton: SymbolButton
    private let editButton: SymbolButton
    private let deleteButton: SymbolButton
    private let body = CommentTextView()
    private var editorView: NSView?
    private var comment: Comment?
    private var avatarURL: URL?

    private static let nameFont = NSFont.systemFont(
        ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: .semibold)
    private static let captionFont = NSFont.preferredFont(forTextStyle: .caption1)
    /// The header line's height: the name's.
    static let headerHeight: CGFloat = {
        let probe = NSTextField(labelWithString: "Ag")
        probe.font = nameFont
        return probe.fittingSize.height
    }()
    /// With Edit and Delete on the line: a symbol in a SwiftUI label at the body size is 16.5 points tall.
    static let buttonHeaderHeight: CGFloat = max(headerHeight, 16.5)
    private static let placeholder = NSImage(
        systemSymbolName: "person.crop.circle.fill", accessibilityDescription: nil)!
        .withSymbolConfiguration(.init(pointSize: 19, weight: .regular))!
    private static let nobody = NSImage(
        systemSymbolName: "person.crop.circle.badge.questionmark", accessibilityDescription: nil)!
        .withSymbolConfiguration(.init(pointSize: 19, weight: .regular))!
    private static let desaturate: CIFilter = {
        let f = CIFilter(name: "CIColorControls")!
        f.setValue(0, forKey: kCIInputSaturationKey)
        return f
    }()

    init(thread: CommentThreadView) {
        self.thread = thread
        replyButton = SymbolButton(
            "arrowshape.turn.up.left", label: String(localized: "Reply"), help: String(localized: "Reply"))
        editButton = SymbolButton("pencil", label: String(localized: "Edit"), help: String(localized: "Edit comment"))
        deleteButton = SymbolButton(
            "trash", label: String(localized: "Delete"), help: String(localized: "Delete comment"))
        super.init(frame: .zero)
        // Its own layer: drawn once when set up and moved while scrolling. Without one the row drew into an
        // ancestor's layer in strips as it scrolled in, each a partial draw of its text (see `CommentTextView`).
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        avatar.imageScaling = .scaleProportionallyUpOrDown
        avatar.wantsLayer = true
        avatar.layer?.cornerRadius = 13
        avatar.layer?.masksToBounds = true
        name.font = Self.nameFont
        name.lineBreakMode = .byTruncatingTail
        date.font = Self.captionFont
        date.textColor = .secondaryLabelColor
        edited.font = Self.captionFont
        edited.textColor = .tertiaryLabelColor
        replyButton.action = { [unowned self] in if let comment { thread.reply(to: comment) } }
        editButton.action = { [unowned self] in if let comment { thread.onEdit(comment) } }
        deleteButton.action = { [unowned self] in if let comment { thread.onDelete(comment) } }
        body.host = self
        for v in [avatar, name, date, edited, replyButton, editButton, deleteButton, body] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ c: Comment, text: NSAttributedString?, buttons: Bool, reply: Bool, editor: NSView?) {
        comment = c
        name.stringValue = c.author?.displayName ?? String(localized: "Unknown")
        date.stringValue = c.created.formatted(.relative(presentation: .named))
        date.toolTip = c.created.formatted()
        edited.isHidden = !(c.updated.timeIntervalSince(c.created) > 60)
        editButton.isHidden = !buttons
        deleteButton.isHidden = !buttons
        replyButton.isHidden = !reply
        setAvatar(c.author)
        if let editor {
            body.isHidden = true
            if editorView !== editor {
                editorView?.removeFromSuperview()
                editor.removeFromSuperview()
                addSubview(editor)
                editorView = editor
            }
        } else {
            editorView?.removeFromSuperview()
            editorView = nil
            body.isHidden = false
            body.textStorage?.setAttributedString(text ?? NSAttributedString())
            body.dim()
        }
        needsLayout = true
        needsDisplay = true
    }

    override func prepareForReuse() {
        key = nil
        comment = nil
        avatarURL = nil
        editorView?.removeFromSuperview()
        editorView = nil
        body.setSelectedRange(NSRange(location: 0, length: 0))
    }

    private func setAvatar(_ user: JiraUser?) {
        let label = user?.displayName ?? String(localized: "Unassigned")
        avatar.toolTip = label
        avatar.setAccessibilityLabel(label)
        guard let user, let url = user.avatar else {
            avatarURL = nil
            placeholder(user == nil ? Self.nobody : Self.placeholder)
            return
        }
        avatarURL = url
        if let hit = ImageCache.shared.object(forKey: url as NSURL) {
            picture(hit)
            return
        }
        // Disk on this thread, as `RemoteImage` reads it: the avatar is there in the row's first frame.
        if let data = DiskCache.imageDataNow(for: url),
            let img = ImageCache.svg(data) ?? NSImage(data: data)
        {
            ImageCache.shared.setObject(img, forKey: url as NSURL)
            picture(img)
            return
        }
        placeholder(Self.placeholder)
        let load = thread.loadImage
        Task { [weak self] in
            guard let img = await load(url, 256), let self, self.avatarURL == url else { return }
            self.picture(img)
        }
    }

    private func picture(_ img: NSImage) {
        avatar.image = img
        avatar.contentTintColor = nil
        avatar.imageScaling = .scaleProportionallyUpOrDown
    }

    private func placeholder(_ symbol: NSImage) {
        avatar.image = symbol
        avatar.contentTintColor = .tertiaryLabelColor
        avatar.imageScaling = .scaleNone
    }

    private func dim() {
        avatar.contentFilters = active ? [] : [Self.desaturate]
        avatar.alphaValue = active ? 1 : 0.6
        body.active = active
    }

    override func layout() {
        super.layout()
        let rtl = userInterfaceLayoutDirection == .rightToLeft
        let w = bounds.width
        func place(_ v: NSView, _ x: CGFloat, _ y: CGFloat, _ vw: CGFloat, _ vh: CGFloat) {
            v.frame = NSRect(x: rtl ? w - x - vw : x, y: y, width: vw, height: vh)
        }
        place(avatar, 0, 0, 26, 26)
        let cx = CommentThreadView.textInset
        let cw = max(0, w - cx)
        let hh = editButton.isHidden && replyButton.isHidden ? Self.headerHeight : Self.buttonHeaderHeight
        // The buttons at the trailing end; the name gives way to them and the date.
        var right = cx + cw
        for b in [deleteButton, editButton, replyButton] where !b.isHidden {
            let s = b.frame.size
            place(b, right - s.width, (hh - s.height) / 2, s.width, s.height)
            right -= s.width + 6
        }
        // The cell's size, not the intrinsic one: a label draws its text two points in from each side.
        let ds = date.cell!.cellSize
        let es = edited.isHidden ? .zero : edited.cell!.cellSize
        let ns = name.cell!.cellSize
        let nw = min(ns.width, max(4, right - cx - (ds.width - 4) - 6 - (edited.isHidden ? 0 : es.width - 4 + 6)))
        var x = cx
        place(name, x - 2, (hh - ns.height) / 2, nw, ns.height)
        x += nw - 4 + 6
        place(date, x - 2, (hh - ds.height) / 2, ds.width, ds.height)
        x += ds.width - 4 + 6
        if !edited.isHidden { place(edited, x - 2, (hh - es.height) / 2, es.width, es.height) }
        let by = hh + 6
        let bh = max(0, bounds.height - by)
        if let editorView {
            place(editorView, cx, by, cw, bh)
        } else {
            place(body, cx - TextLayout.pad, by, cw + 2 * TextLayout.pad, bh)
        }
        // The whole text now, not line by line as it draws: laid out in pieces while a row scrolls in, a table's
        // first row came out short.
        if !body.isHidden, let tc = body.textContainer { body.layoutManager?.ensureLayout(for: tc) }
    }

    var client: JiraClient? { thread.client }
    func preview(_ a: Attachment) { thread.onPreview(a) }
}

/// A symbol in the tertiary colour that runs an action on a click, as `.buttonStyle(.plain).foregroundStyle(.tertiary)`
/// draws one. Not an NSButton: its tooltip and baseline asked the button's visual provider for metrics on every
/// tick of a scroll. The protocol makes it an accessibility element: a plain view is none, whatever its role and label.
final class SymbolButton: NSView, @MainActor NSAccessibilityButton {
    var action: () -> Void = {}
    private let name: String
    private var symbol: NSImage

    /// Filled as `Image(systemName:)` fills it: palette colours gave a quarter of the ink of the page's other icons.
    static func image(_ name: String) -> NSImage {
        .symbol(
            name, size: NSFont.preferredFont(forTextStyle: .body).pointSize, weight: .regular, tint: .tertiaryLabelColor
        )
    }

    init(_ name: String, label: String, help: String) {
        self.name = name
        symbol = Self.image(name)
        super.init(frame: NSRect(origin: .zero, size: symbol.size))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay  // drawn once, and again only for an appearance change
        toolTip = help
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        symbol.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        symbol = Self.image(name)  // the tint is resolved as the image is made
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }
    override func accessibilityPerformPress() -> Bool {
        action()
        return true
    }
}

/// What a text view with inline images asks of its host: the account the images belong to, Quick Look, and what
/// a click on a task circle or an expand title does (nothing in a comment).
@MainActor protocol InlineImageHost: AnyObject {
    var client: JiraClient? { get }
    func preview(_ a: Attachment)
    func toggleTask(_ id: String)
    func toggleExpand(_ path: String)
}

extension InlineImageHost {
    func toggleTask(_ id: String) {}
    func toggleExpand(_ path: String) {}
}

/// A comment's or the description's text: selectable, never editable, laid out by TextKit 1 (text blocks draw the
/// code, quote, panel and table backgrounds). A right-click offers Copy when there is a selection, and nothing
/// otherwise, as the reader menu on SwiftUI text does; on an inline image or file, the attachment tile's menu.
class CommentTextView: NSTextView {
    weak var host: InlineImageHost?

    init() {
        let storage = NSTextStorage()
        let manager = TextLayout()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        // Room for a code pill's rounded end at the start of a line (see `TextLayout`): TextKit draws nothing outside
        // a line, so the line starts this far before the text, and whoever places the view makes it as much wider
        // on each side.
        container.lineFragmentPadding = TextLayout.pad
        container.widthTracksTextView = true
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        isEditable = false
        isSelectable = true
        isRichText = true
        drawsBackground = false
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
        focusRingType = .none
        usesFontPanel = false
        allowsUndo = false
        linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
    }

    required init?(coder: NSCoder) { fatalError() }

    /// With nothing selected, ⌘C passes on to the page, which copies the issue's key.
    override func responds(to aSelector: Selector!) -> Bool {
        aSelector == #selector(copy(_:)) && MainActor.assumeIsolated { selectedRange().length == 0 }
            ? false : super.responds(to: aSelector)
    }

    /// Inline images and accent-coloured text (mentions) grey while the window is inactive, as the attachment
    /// tiles do (`inactiveDim`): the images as they draw (see `ImageCell`), the text through a temporary colour.
    var active = true {
        didSet { if active != oldValue { dim() } }
    }

    /// Lays the grey over the accent-coloured runs, or takes it off; again after every new text.
    func dim() {
        guard let lm = layoutManager, let storage = textStorage else { return }
        let all = NSRange(location: 0, length: storage.length)
        lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: all)
        if !active, let grey = NSColor.controlAccentColor.usingColorSpace(.genericGray)?.withAlphaComponent(0.6) {
            storage.enumerateAttribute(.foregroundColor, in: all) { c, r, _ in
                if c as? NSColor == .controlAccentColor {
                    lm.addTemporaryAttribute(.foregroundColor, value: grey, forCharacterRange: r)
                }
            }
        }
        needsDisplay = true
    }

    /// The whole text on every draw: a block's background (the quote bar, a code box, a table cell) is drawn from
    /// the frame AppKit hands the block, and for a partial redraw that frame is the part alone. Rows have their own
    /// layers, so a draw happens once per row and then only for a hover.
    override func draw(_ dirtyRect: NSRect) { super.draw(bounds) }

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        if let file = (cell(at: event)?.cell as? FileCell)?.file {
            func item(_ title: String, _ action: Selector) {
                let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
                i.target = self
                i.representedObject = file
                m.addItem(i)
            }
            item(String(localized: "Quick Look"), #selector(quickLookFile(_:)))
            item(String(localized: "Open"), #selector(openFile(_:)))
            item(String(localized: "Copy"), #selector(copyFile(_:)))
            item(String(localized: "Save As…"), #selector(saveFile(_:)))
            return m
        }
        guard selectedRange().length > 0 else { return nil }
        m.addItem(withTitle: String(localized: "Copy"), action: #selector(copy(_:)), keyEquivalent: "")
        return m
    }

    private func file(_ sender: NSMenuItem) -> (Attachment, JiraClient)? {
        guard let a = sender.representedObject as? Attachment, let c = host?.client else { return nil }
        return (a, c)
    }
    @objc private func quickLookFile(_ sender: NSMenuItem) { if let (a, _) = file(sender) { host?.preview(a) } }
    @objc private func openFile(_ sender: NSMenuItem) {
        if let (a, c) = file(sender) { Task { await AttachmentOpener.open(a, client: c) } }
    }
    @objc private func copyFile(_ sender: NSMenuItem) {
        if let (a, c) = file(sender) { Task { await AttachmentOpener.copy(a, client: c) } }
    }
    @objc private func saveFile(_ sender: NSMenuItem) {
        if let (a, c) = file(sender) { AttachmentOpener.saveAs(a, client: c) }
    }

    /// A press on an inline image or file, a task circle or an expand title: a release is a click (Quick Look, a
    /// flip, a fold), a drag on an image or file takes it out as its file, a drag anywhere else selects. None goes
    /// through the text view's own click on an attachment, which would select it.
    override func mouseDown(with event: NSEvent) {
        let hit = cell(at: event)
        let expand = attribute(.expand, at: event) as? String
        guard hit != nil || expand != nil, let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged])
        else { return super.mouseDown(with: event) }
        if next.type == .leftMouseDragged {
            guard let cell = hit?.cell as? FileCell, let frame = hit?.frame, let client = host?.client,
                let rep = bitmapImageRepForCachingDisplay(in: frame)
            else { return super.mouseDown(with: event) }
            // The cell as drawn goes with the pointer.
            cacheDisplay(in: frame, to: rep)
            let picture = NSImage(size: frame.size)
            picture.addRepresentation(rep)
            let item = NSDraggingItem(pasteboardWriter: AttachmentPromise(cell.file, client: client))
            item.setDraggingFrame(frame, contents: picture)
            beginDraggingSession(with: [item], event: event, source: self)
        } else if let cell = hit?.cell as? FileCell {
            host?.preview(cell.file)
        } else if let task = (hit?.cell as? SymbolCell)?.taskID {
            host?.toggleTask(task)
        } else if let expand {
            host?.toggleExpand(expand)
        }
    }

    override func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext)
        -> NSDragOperation
    {
        .copy
    }

    /// The attachment cell under the pointer, with its frame.
    private func cell(at event: NSEvent) -> (cell: NSTextAttachmentCell, frame: NSRect)? {
        let o = textContainerOrigin
        let p = convert(event.locationInWindow, from: nil).applying(.init(translationX: -o.x, y: -o.y))
        guard let lm = layoutManager, let tc = textContainer, let storage = textStorage, storage.length > 0 else {
            return nil
        }
        let glyph = lm.glyphIndex(for: p, in: tc)
        let frame = lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: tc)
        guard frame.contains(p) else { return nil }
        let i = lm.characterIndexForGlyph(at: glyph)
        guard
            let cell = (storage.attribute(.attachment, at: i, effectiveRange: nil) as? NSTextAttachment)?.attachmentCell
                as? NSTextAttachmentCell
        else { return nil }
        return (cell, frame.offsetBy(dx: o.x, dy: o.y))
    }

    /// An attribute of the text under the pointer; nil off the text (to the right of a short line, say).
    private func attribute(_ key: NSAttributedString.Key, at event: NSEvent) -> Any? {
        let o = textContainerOrigin
        let p = convert(event.locationInWindow, from: nil).applying(.init(translationX: -o.x, y: -o.y))
        guard let lm = layoutManager, let tc = textContainer, let storage = textStorage, storage.length > 0 else {
            return nil
        }
        let glyph = lm.glyphIndex(for: p, in: tc)
        guard lm.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil).contains(p) else { return nil }
        return storage.attribute(key, at: lm.characterIndexForGlyph(at: glyph), effectiveRange: nil)
    }

    /// Never scrolls the page while being resized: NSTextView then brings its selection into view, unselected or not,
    /// and laid out as the next issue appeared, a comment pulled the whole page up under the toolbar to its first
    /// line. Any other time it does, so a selection extended with ⇧ and the arrows keeps its end in view.
    private var resizing = false
    override func setFrameSize(_ newSize: NSSize) {
        let outer = resizing  // AppKit resizes again from inside a resize
        resizing = true
        defer { resizing = outer }
        super.setFrameSize(newSize)
    }
    override func scrollToVisible(_ rect: NSRect) -> Bool { resizing ? false : super.scrollToVisible(rect) }

    /// Quick Look asks the first responder first, and a text view answers for its selected attachments: none, so
    /// the panel opened by `.quickLookPreview` read "No items selected" once a comment had been clicked.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { false }
}

// MARK: - The description

/// The description as one TextKit view, so a selection runs across paragraphs, lists, tables and panels (SwiftUI
/// selects within one Text at a time), laid out to the card's look by `ADFAttributed`.
struct DescriptionText: NSViewRepresentable {
    let node: ADFNode
    let attachments: [Attachment]
    let loadImage: (URL, Int) async -> NSImage?
    let onPreview: (Attachment) -> Void
    let client: JiraClient?
    /// Nil where the description is read-only: the task circles then only show.
    let toggleTask: ((String) -> Void)?
    @Environment(\.appearsActive) private var active

    func makeNSView(context: Context) -> DescriptionTextView { DescriptionTextView() }

    func updateNSView(_ v: DescriptionTextView, context: Context) {
        v.loadImage = loadImage
        v.onPreview = onPreview
        v.client = client
        v.onToggleTask = toggleTask
        v.active = active
        v.show(node, attachments: attachments)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView v: DescriptionTextView, context: Context) -> CGSize? {
        guard let w = proposal.width, w.isFinite, w > 2 * TextLayout.pad else { return nil }
        return CGSize(width: w, height: v.height(at: w - 2 * TextLayout.pad))
    }
}

@MainActor final class DescriptionTextView: CommentTextView, InlineImageHost {
    var loadImage: (URL, Int) async -> NSImage? = { _, _ in nil }
    var onPreview: (Attachment) -> Void = { _ in }
    var client: JiraClient?
    var onToggleTask: ((String) -> Void)?
    private var shown: (node: ADFNode, attachments: [Attachment])?
    /// Expands opened by a click, by their place in the document; new text starts with every one closed.
    private var expanded: Set<String> = []
    private var loading: Set<URL> = []
    /// Measured apart from the live layout: SwiftUI probes several widths and only sets the frame it settles on.
    private let measurer = TextMeasurer()
    private var heights: [CGFloat: CGFloat] = [:]

    override init() {
        super.init()
        host = self
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ node: ADFNode, attachments: [Attachment]) {
        guard shown?.node != node || shown?.attachments != attachments else { return }
        if shown?.node != node { expanded = [] }
        shown = (node, attachments)
        render()
    }

    private func render() {
        guard let shown else { return }
        let text = ADFAttributed.render(shown.node, attachments: shown.attachments, expanded: expanded) { [weak self] in
            self?.image(for: $0)
        }
        textStorage?.setAttributedString(text)
        dim()
        // TextKit drops the first paragraph's spacing before; the card had it (a heading's 4 points).
        top =
            text.length == 0
            ? 0
            : (text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.paragraphSpacingBefore
                ?? 0
        heights = [:]
        invalidateIntrinsicContentSize()
    }

    private var top: CGFloat = 0
    override var textContainerOrigin: NSPoint { NSPoint(x: 0, y: top) }

    /// Symbols are drawn in the appearance of the moment (see `NSImage.symbol`).
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        render()
    }

    func height(at width: CGFloat) -> CGFloat {
        if let h = heights[width] { return h }
        let h = measurer.height(of: textStorage ?? NSTextStorage(), width: width) + top
        heights[width] = h
        return h
    }

    /// A cached inline image, or nil while it loads: the text is rebuilt once it has.
    private func image(for a: Attachment) -> NSImage? {
        let url = a.content
        if let hit = ImageCache.shared.object(forKey: url as NSURL) { return hit }
        guard !loading.contains(url) else { return nil }
        loading.insert(url)
        let load = loadImage
        Task { [weak self] in
            let image = await load(url, 1600)
            guard let self else { return }
            loading.remove(url)
            if image != nil { render() }
        }
        return nil
    }

    func preview(_ a: Attachment) { onPreview(a) }
    func toggleTask(_ id: String) { onToggleTask?(id) }
    func toggleExpand(_ path: String) {
        expanded.formSymmetricDifference([path])
        render()
    }
}

// MARK: - ADF → attributed string

/// The card's look as one attributed string for TextKit 1: the same fonts, colours and gaps; code, quotes, panels
/// and tables as text blocks that draw their own backgrounds; images and rules as attachment cells.
@MainActor final class ADFAttributed {
    private let attachments: [Attachment]
    private let image: (Attachment) -> NSImage?
    /// The expands shown open, by path; nil opens every one.
    private let expanded: Set<String>?
    private let out = NSMutableAttributedString()

    /// A block's font: the size and the weight it starts from, before the runs' own marks.
    private struct Base {
        var size: CGFloat
        var weight: NSFont.Weight = .regular
        /// What SwiftUI adds under a line of this font beyond TextKit's line height (see `lineExtra`).
        var extra: CGFloat = 0
        func font(mono: Bool = false, bold: Bool = false, italic: Bool = false) -> NSFont {
            let w: NSFont.Weight = bold ? .semibold : weight
            var f =
                mono ? NSFont.monospacedSystemFont(ofSize: size, weight: w) : NSFont.systemFont(ofSize: size, weight: w)
            if italic { f = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) }
            return f
        }
    }

    /// Where a block sits: inside which text blocks, how far in, and how far from the block before it.
    private struct Ctx {
        var blocks: [NSTextBlock] = []
        /// Every line's indent, and the first line's: a list marker's tab starts at the latter.
        var indent: CGFloat = 0
        var firstIndent: CGFloat = 0
        var tabs: [NSTextTab] = []
        var base = Base(size: NSFont.preferredFont(forTextStyle: .body).pointSize)
        /// Between the blocks of this container: 10 at the top, 8 in a quote or panel, 6 in a cell, 4 in a list.
        var spacing: CGFloat = 10
        /// The block's place in the document ("2/0/1"): an expand is remembered open by it.
        var path = ""
    }

    private init(attachments: [Attachment], expanded: Set<String>?, image: @escaping (Attachment) -> NSImage?) {
        self.attachments = attachments
        self.expanded = expanded
        self.image = image
    }

    static func render(
        _ doc: ADFNode, attachments: [Attachment], expanded: Set<String>? = nil,
        image: @escaping (Attachment) -> NSImage?
    ) -> NSAttributedString {
        let r = ADFAttributed(attachments: attachments, expanded: expanded, image: image)
        r.blocks(doc.content ?? [], Ctx())
        // Every paragraph ends in a newline; the last one would be an empty line.
        if r.out.length > 0 { r.out.deleteCharacters(in: NSRange(location: r.out.length - 1, length: 1)) }
        return r.out
    }

    // MARK: Blocks

    private func blocks(_ nodes: [ADFNode], _ ctx: Ctx, first: CGFloat = 0) {
        if nodes.isEmpty, !ctx.blocks.isEmpty {
            paragraph(NSAttributedString(), ctx, before: first)  // a text block needs a paragraph to exist
            return
        }
        for (i, n) in nodes.enumerated() {
            var c = ctx
            c.path += "/\(i)"
            block(n, c, before: i == 0 ? first : ctx.spacing)
        }
    }

    private func block(_ node: ADFNode, _ ctx: Ctx, before: CGFloat) {
        switch node.type {
        case "paragraph":
            paragraph(inline(node, ctx.base), ctx, before: before)
        case "heading":
            var c = ctx
            let level = Int(node.attrs?["level"]?.number ?? 3)
            c.base = Base(size: Self.headingSize(level), weight: .semibold, extra: Self.lineExtra(level))
            paragraph(inline(node, c.base), c, before: before + 4)
        case "bulletList", "orderedList":
            list(node, ctx, before: before, ordered: node.type == "orderedList")
        case "codeBlock":
            // ponytail: an unwrapped block wraps here too; the SwiftUI card scrolled it sideways.
            var c = ctx
            c.blocks.append(CodeBlock(topMargin: before))
            let code = node.plainText.trimmingCharacters(in: .newlines)
            paragraph(
                NSAttributedString(
                    string: code, attributes: [.font: ctx.base.font(mono: true), .foregroundColor: NSColor.labelColor]),
                c, before: 0)
        case "blockquote":
            var c = ctx
            c.blocks.append(QuoteBlock(topMargin: before))
            c.spacing = 8
            blocks(node.content ?? [], c)
        case "rule":
            let att = NSTextAttachment()
            att.attachmentCell = RuleCell()
            var c = ctx
            c.base.size = 1  // the line's own height, not a text line's
            paragraph(NSAttributedString(attachment: att), c, before: before)
        case "panel":
            var c = ctx
            c.blocks.append(PanelBlock(type: node.attr("panelType"), topMargin: before))
            c.spacing = 8
            blocks(node.content ?? [], c)
        case "table":
            table(node, ctx, before: before)
        case "mediaSingle", "mediaGroup":
            media(node, ctx, before: before)
        case "taskList":
            // The circle, 8 points, then the text; a click on the circle flips the task where the host allows.
            for (i, item) in (node.content ?? []).enumerated() {
                let done = item.attr("state") == "DONE"
                let s = NSMutableAttributedString(
                    attachment: SymbolCell.attachment(
                        done ? "checkmark.circle.fill" : "circle", tint: done ? .systemGreen : .secondaryLabelColor,
                        font: ctx.base.font(), gap: 8, taskID: item.attr("localId")))
                s.append(inline(item, ctx.base))
                paragraph(s, ctx, before: i == 0 ? before : 6)
            }
        case "expand", "nestedExpand":
            // The disclosure chevron, the title 13 points in, and the content under it only while open; a click on
            // the line toggles it (the whole line carries the path).
            let open = expanded?.contains(ctx.path) ?? true
            let title = NSMutableAttributedString(
                attachment: SymbolCell.attachment(
                    open ? "chevron.down" : "chevron.right", tint: .secondaryLabelColor,
                    font: NSFont.systemFont(ofSize: Self.chevronSize), centred: ctx.base.font()))
            title.append(
                NSAttributedString(
                    string: "\t" + (node.attr("title") ?? String(localized: "Details")),
                    attributes: [.font: ctx.base.font(), .foregroundColor: NSColor.labelColor]))
            title.addAttribute(.expand, value: ctx.path, range: NSRange(location: 0, length: title.length))
            var c = ctx
            c.tabs = [NSTextTab(textAlignment: .left, location: ctx.indent + 11.5, options: [:])]
            paragraph(title, c, before: before + 4, after: 4)  // the group's row is 24 points to the text's 16
            guard open else { return }
            c.tabs = ctx.tabs
            c.spacing = 8
            blocks(node.content ?? [], c, first: 6)
        case "layoutSection":
            // Columns side by side, 16 apart, as a table with no borders.
            let cols = node.content ?? []
            let table = NSTextTable()
            table.numberOfColumns = max(1, cols.count)
            table.setWidth(before, type: .absoluteValueType, for: .margin, edge: .minY)
            for (i, col) in cols.enumerated() {
                let b = NSTextTableBlock(table: table, startingRow: 0, rowSpan: 1, startingColumn: i, columnSpan: 1)
                b.setValue(100 / CGFloat(cols.count), type: .percentageValueType, for: .width)
                if i > 0 { b.setWidth(8, type: .absoluteValueType, for: .padding, edge: .minX) }
                if i + 1 < cols.count { b.setWidth(8, type: .absoluteValueType, for: .padding, edge: .maxX) }
                var c = ctx
                c.blocks.append(b)
                c.spacing = 8
                c.path += "/\(i)"
                blocks(col.content ?? [], c)
            }
        default:
            if node.content != nil, node.type != "text" {
                var c = ctx
                c.spacing = 8
                blocks(node.content ?? [], c, first: before)
            } else {
                paragraph(inline(node, ctx.base), ctx, before: before)
            }
        }
    }

    /// Appends `text` as one paragraph (hard breaks inside it are line separators) in `ctx`'s blocks and indents.
    private func paragraph(_ text: NSAttributedString, _ ctx: Ctx, before: CGFloat, after: CGFloat = 0) {
        let start = out.length
        out.append(text)
        out.append(
            NSAttributedString(
                string: "\n", attributes: [.font: ctx.base.font(), .foregroundColor: NSColor.labelColor]))
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = before
        // SwiftUI lays a title2 or title3 line out a point taller than TextKit, with the point under the text.
        style.paragraphSpacing = after + ctx.base.extra
        style.firstLineHeadIndent = ctx.firstIndent
        style.headIndent = ctx.indent
        style.tabStops = ctx.tabs
        style.defaultTabInterval = 28
        style.textBlocks = ctx.blocks
        out.addAttribute(.paragraphStyle, value: style, range: NSRange(location: start, length: out.length - start))
    }

    /// Items 4 apart: a marker right-aligned in a 16-point column (wider for "10."), then the text 8 points on, the
    /// whole list 4 points in. Wrapped lines and the item's later blocks start under the text.
    private func list(_ node: ADFNode, _ ctx: Ctx, before: CGFloat, ordered: Bool) {
        let items = node.content ?? []
        let start = Int(node.attrs?["order"]?.number ?? 1)
        let markers = items.indices.map { ordered ? "\(start + $0)." : "•" }
        let font = ctx.base.font()
        let markerW = max(16, markers.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0)
        let markerEnd = ctx.indent + 4 + markerW
        let textX = markerEnd + 8
        var item = ctx
        item.indent = textX
        item.firstIndent = textX
        item.tabs = []
        item.spacing = 4
        var first = item
        first.firstIndent = ctx.indent + 4
        first.tabs = [
            NSTextTab(textAlignment: .right, location: markerEnd, options: [:]),
            NSTextTab(textAlignment: .left, location: textX, options: [:]),
        ]
        for (i, it) in items.enumerated() {
            let gap = i == 0 ? before : 4
            var content = it.content ?? []
            let line = NSMutableAttributedString(
                string: "\t\(markers[i])\t", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
            if let p = content.first, p.type == "paragraph" {
                line.append(inline(p, ctx.base))
                content.removeFirst()
            }
            paragraph(line, first, before: gap)
            if !content.isEmpty { blocks(content, item, first: 4) }
        }
    }

    private func table(_ node: ADFNode, _ ctx: Ctx, before: CGFloat) {
        let rows = node.content ?? []
        let cols = rows.map { $0.content?.count ?? 0 }.max() ?? 0
        guard cols > 0 else { return }
        let table = NSTextTable()
        table.numberOfColumns = cols
        for (r, row) in rows.enumerated() {
            for (ci, cell) in (row.content ?? []).enumerated() {
                let header = cell.type == "tableHeader"
                let b = CellBlock(table: table, startingRow: r, rowSpan: 1, startingColumn: ci, columnSpan: 1)
                b.header = header
                // The gap above the table on its first row's cells: a margin on the table itself took the same
                // off its width.
                if r == 0 {
                    b.top = before
                    b.setWidth(before, type: .absoluteValueType, for: .margin, edge: .minY)
                }
                b.setWidth(8, type: .absoluteValueType, for: .padding)
                b.setValue(100 / CGFloat(cols), type: .percentageValueType, for: .width)
                var c = ctx
                c.blocks.append(b)
                c.spacing = 6
                if header { c.base.weight = .semibold }
                blocks(cell.content ?? [], c)
            }
        }
    }

    private func media(_ node: ADFNode, _ ctx: Ctx, before: CGFloat) {
        let s = NSMutableAttributedString()
        let font = ctx.base.font()
        for (i, m) in (node.content ?? []).enumerated() {
            if i > 0 { s.append(NSAttributedString(string: " ", attributes: [.font: font, .kern: 4])) }
            if let a = attachments.first(where: { $0.filename == m.attr("alt") }) {
                s.append(
                    Self.clickable(
                        (a.mimeType ?? "").hasPrefix("image/")
                            ? ImageCell(attachment: a, picture: image(a)) as FileCell : FileChipCell(a)))
            } else {
                let att = NSTextAttachment()
                att.attachmentCell = ChipCell(m.attr("alt") ?? String(localized: "Attached media"))
                s.append(NSAttributedString(attachment: att))
            }
        }
        paragraph(s, ctx, before: before)
    }

    /// One of the issue's files as a cell, with the pointing hand and the tooltip of a click that previews it.
    private static func clickable(_ cell: FileCell) -> NSAttributedString {
        let att = NSTextAttachment()
        att.attachmentCell = cell
        return NSAttributedString(
            attachment: att,
            attributes: [
                .cursor: NSCursor.pointingHand, .toolTip: String(localized: "\(cell.file.filename) — click to preview"),
            ])
    }

    /// The disclosure chevron's size: a caption-sized symbol, as the SwiftUI group draws it.
    static let chevronSize: CGFloat = NSFont.preferredFont(forTextStyle: .caption1).pointSize

    private static func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: NSFont.preferredFont(forTextStyle: .title1).pointSize
        case 2: NSFont.preferredFont(forTextStyle: .title2).pointSize
        case 3: NSFont.preferredFont(forTextStyle: .title3).pointSize
        default: NSFont.preferredFont(forTextStyle: .headline).pointSize
        }
    }

    /// What a one-line heading is taller in SwiftUI's `Text` than in TextKit, measured once from a hosted Text:
    /// there is no formula (title2 and title3 come out a point taller, title1 and body the same). The card put the
    /// extra under the text, so it goes after the paragraph; a heading that wraps runs that much short per line.
    private static var extras: [Int: CGFloat] = [:]
    private static func lineExtra(_ level: Int) -> CGFloat {
        if let e = extras[level] { return e }
        let font: Font =
            switch level {
            case 1: .title.weight(.semibold)
            case 2: .title2.weight(.semibold)
            case 3: .title3.weight(.semibold)
            default: .headline
            }
        let one = NSHostingView(rootView: Text(verbatim: "Ag").font(font)).fittingSize.height
        let natural = NSLayoutManager().defaultLineHeight(for: Base(size: headingSize(level), weight: .semibold).font())
        let e = max(0, one - natural)
        extras[level] = e
        return e
    }

    // MARK: Inline

    private func inline(_ node: ADFNode, _ base: Base) -> NSAttributedString {
        let s = NSMutableAttributedString()
        for n in node.content ?? [] {
            let r = run(n, base)
            // A code pill's room before it: the character ahead of it moves its successor along.
            if r.length > 0, s.length > 0, r.attribute(.code, at: 0, effectiveRange: nil) != nil {
                s.addAttribute(.kern, value: TextLayout.room, range: NSRange(location: s.length - 1, length: 1))
            }
            s.append(r)
        }
        return s
    }

    private func run(_ node: ADFNode, _ base: Base) -> NSAttributedString {
        switch node.type {
        case "text":
            var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.labelColor]
            var bold = false
            var italic = false
            var code = false
            for m in node.marks ?? [] {
                switch m.type {
                case "strong": bold = true
                case "em": italic = true
                case "code": code = true
                case "strike": attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                case "underline": attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                case "link": if let u = m.attrs?["href"]?.string.flatMap(URL.init) { attrs[.link] = u }
                case "textColor": if let hex = m.attrs?["color"]?.string { attrs[.foregroundColor] = NSColor(hex: hex) }
                default: break
                }
            }
            if code {
                // A size under the text's, as monospaced letters run large beside it, on a pill (see `TextLayout`).
                var mono = base
                mono.size = (base.size * 0.9).rounded()
                attrs[.font] = mono.font(mono: true, bold: bold, italic: italic)
                let text = node.text ?? ""
                attrs[.code] =
                    ceil(NSAttributedString(string: text, attributes: attrs).size().width) + 2 * TextLayout.room
                let s = NSMutableAttributedString(string: text, attributes: attrs)
                if s.length > 0 {
                    s.addAttribute(.kern, value: TextLayout.room, range: NSRange(location: s.length - 1, length: 1))
                }
                return s
            }
            attrs[.font] = base.font(bold: bold, italic: italic)
            return NSAttributedString(string: node.text ?? "", attributes: attrs)
        case "hardBreak":
            return NSAttributedString(string: "\u{2028}", attributes: [.font: base.font()])
        case "mention":
            return NSAttributedString(
                string: node.attr("text") ?? "@someone",
                attributes: [
                    .font: NSFont.systemFont(
                        ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize, weight: .medium),
                    .foregroundColor: NSColor.controlAccentColor,
                ])
        case "inlineCard":
            let url = node.attr("url") ?? ""
            var attrs: [NSAttributedString.Key: Any] = [.font: base.font(), .foregroundColor: NSColor.labelColor]
            if let u = URL(string: url) { attrs[.link] = u }
            return NSAttributedString(string: url.replacingOccurrences(of: "https://", with: ""), attributes: attrs)
        case "emoji":
            return NSAttributedString(
                string: node.attr("text") ?? node.attr("shortName") ?? "", attributes: [.font: base.font()])
        case "status":
            let tint: NSColor =
                switch node.attr("color") {
                case "green": .systemGreen
                case "red": .systemRed
                case "blue": .systemBlue
                case "yellow": .systemOrange
                case "purple": .systemPurple
                default: .secondaryLabelColor
                }
            return NSAttributedString(
                string: " \(node.attr("text")?.uppercased() ?? "") ",
                attributes: [
                    .font: NSFont.systemFont(
                        ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .bold),
                    .foregroundColor: tint, .backgroundColor: tint.withAlphaComponent(0.15),
                ])
        case "date":
            guard let ms = node.attrs?["timestamp"]?.string.flatMap(Double.init) else { return NSAttributedString() }
            return NSAttributedString(
                string: Date(timeIntervalSince1970: ms / 1000).formatted(date: .abbreviated, time: .omitted),
                attributes: [.font: base.font(), .foregroundColor: NSColor.labelColor])
        case "mediaInline":
            if let a = attachments.first(where: { $0.filename == node.attr("alt") }) {
                return Self.clickable(FileChipCell(a))
            }
            return NSAttributedString(string: "📎", attributes: [.font: base.font()])
        default:
            return inline(node, base)
        }
    }
}

extension NSColor {
    convenience init(hex: String) {
        var h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        let v = UInt64(h, radix: 16) ?? 0
        self.init(
            srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

// MARK: Text blocks

/// A table cell: its fill and a hairline on all four sides, as `.border` drew on every SwiftUI cell. TextKit's own
/// cell borders never showed on a table's top and right edges.
final class CellBlock: NSTextTableBlock {
    var header = false
    /// The gap above the table, which the frame handed here includes.
    var top: CGFloat = 0

    override func drawBackground(
        withFrame frameRect: NSRect, in controlView: NSView?, characterRange: NSRange, layoutManager: NSLayoutManager
    ) {
        let frameRect = NSRect(
            x: frameRect.minX, y: frameRect.minY + top, width: frameRect.width, height: frameRect.height - top)
        if header {
            NSColor.labelColor.withAlphaComponent(0.06).setFill()
            frameRect.fill()
        }
        NSColor.labelColor.withAlphaComponent(0.12).setStroke()
        let edge = NSBezierPath(rect: frameRect.insetBy(dx: 0.25, dy: 0.25))
        edge.lineWidth = 0.5
        edge.stroke()
    }
}

/// A block with a gap above it. The frame TextKit hands `drawBackground` includes that margin, so a background
/// is drawn in `box`, which leaves it out.
class MarginBlock: NSTextBlock {
    private let top: CGFloat

    init(topMargin: CGFloat) {
        top = topMargin
        super.init()
        setWidth(topMargin, type: .absoluteValueType, for: .margin, edge: .minY)
        setValue(100, type: .percentageValueType, for: .width)
    }
    required init?(coder: NSCoder) { fatalError() }

    func box(_ frame: NSRect) -> NSRect {
        NSRect(x: frame.minX, y: frame.minY + top, width: frame.width, height: frame.height - top)
    }
}

/// A code block: 10 points of padding on a faint rounded background.
final class CodeBlock: MarginBlock {
    override init(topMargin: CGFloat) {
        super.init(topMargin: topMargin)
        setWidth(10, type: .absoluteValueType, for: .padding)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func drawBackground(
        withFrame frameRect: NSRect, in controlView: NSView?, characterRange: NSRange, layoutManager: NSLayoutManager
    ) {
        NSColor.labelColor.withAlphaComponent(0.05).setFill()
        NSBezierPath(roundedRect: box(frameRect), xRadius: 8, yRadius: 8).fill()
    }
}

/// A quote: a 3-point bar at the leading edge, the text 13 points in.
final class QuoteBlock: MarginBlock {
    override init(topMargin: CGFloat) {
        super.init(topMargin: topMargin)
        setWidth(13, type: .absoluteValueType, for: .padding, edge: .minX)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func drawBackground(
        withFrame frameRect: NSRect, in controlView: NSView?, characterRange: NSRange, layoutManager: NSLayoutManager
    ) {
        let r = box(frameRect)
        NSColor.tertiaryLabelColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: r.minX, y: r.minY, width: 3, height: r.height), xRadius: 2, yRadius: 2)
            .fill()
    }
}

/// A panel: an icon in its colour, the text beside it, on a tinted rounded background with 12 points of padding.
final class PanelBlock: MarginBlock {
    private let tint: NSColor
    private let icon: NSImage

    init(type: String?, topMargin: CGFloat) {
        let (tint, symbol): (NSColor, String) =
            switch type {
            case "warning": (.systemOrange, "exclamationmark.triangle.fill")
            case "error": (.systemRed, "xmark.octagon.fill")
            case "success": (.systemGreen, "checkmark.circle.fill")
            case "note": (.systemPurple, "note.text")
            default: (.systemBlue, "info.circle.fill")
            }
        self.tint = tint
        icon = .symbol(symbol, size: NSFont.preferredFont(forTextStyle: .body).pointSize, weight: .regular, tint: tint)
        super.init(topMargin: topMargin)
        setWidth(12, type: .absoluteValueType, for: .padding)
        setWidth(12 + icon.size.width + 10, type: .absoluteValueType, for: .padding, edge: .minX)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func drawBackground(
        withFrame frameRect: NSRect, in controlView: NSView?, characterRange: NSRange, layoutManager: NSLayoutManager
    ) {
        let r = box(frameRect)
        tint.withAlphaComponent(0.1).setFill()
        NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10).fill()
        let size = icon.size
        icon.draw(
            in: NSRect(x: r.minX + 12, y: r.minY + 12, width: size.width, height: size.height), from: .zero,
            operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

extension NSImage {
    /// An SF Symbol filled with one colour, as `Image(systemName:)` draws under a `foregroundStyle`: the symbol's
    /// shape is the template's alpha, so a checkmark stays cut out of its filled circle (a palette colour painted
    /// every layer, which made a solid blob). Resolved in the app's appearance, so rebuild on a change of it.
    static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight, tint: NSColor) -> NSImage {
        let template = NSImage(systemSymbolName: name, accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: size, weight: weight))!
        let box = NSRect(origin: .zero, size: template.size)
        let out = NSImage(size: template.size)
        out.lockFocus()
        template.draw(in: box)
        tint.set()
        box.fill(using: .sourceIn)  // the tint's own alpha too: a secondary-label grey, not black under it
        out.unlockFocus()
        return out
    }
}

// MARK: Attachment cells

/// A cell standing for one of the issue's files: a click previews it, a drag takes the file out, and a right-click
/// offers the attachment tile's menu (see `CommentTextView`).
@MainActor protocol FileCell: NSTextAttachmentCell {
    var file: Attachment { get }
}

/// An inline image: fitted into 520 by 360 points (or the line's width), rounded; a grey box until it has loaded.
final class ImageCell: NSTextAttachmentCell, FileCell {
    let file: Attachment
    let picture: NSImage?

    init(attachment: Attachment, picture: NSImage?) {
        self.file = attachment
        self.picture = picture
        super.init(imageCell: nil)
    }
    required init(coder: NSCoder) { fatalError() }

    nonisolated private func size(forWidth w: CGFloat) -> NSSize {
        guard let picture, picture.size.width > 0, picture.size.height > 0 else {
            return NSSize(width: min(240, w), height: 140)
        }
        let k = min(w / picture.size.width, 360 / picture.size.height)
        return NSSize(width: floor(picture.size.width * k), height: floor(picture.size.height * k))
    }

    /// The picture without its colour, for an inactive window: made on the first draw that needs it.
    private lazy var grey: NSImage? = picture.flatMap { p in
        guard let cg = p.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let ci = CIImage(cgImage: cg).applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        return Self.context.createCGImage(ci, from: ci.extent).map { NSImage(cgImage: $0, size: p.size) }
    }
    private static let context = CIContext()

    override func cellSize() -> NSSize { size(forWidth: 520) }

    override func cellFrame(
        for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect, glyphPosition position: NSPoint,
        characterIndex: Int
    ) -> NSRect {
        NSRect(origin: .zero, size: size(forWidth: max(1, min(520, lineFrag.maxX - position.x))))
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: cellFrame, xRadius: 10, yRadius: 10).addClip()
        if let picture {
            let dim = (controlView as? CommentTextView)?.active == false
            (dim ? grey ?? picture : picture).draw(
                in: cellFrame, from: .zero, operation: .sourceOver, fraction: dim ? 0.6 : 1, respectFlipped: true,
                hints: nil)
        } else {
            NSColor.quaternaryLabelColor.withAlphaComponent(0.04).setFill()
            cellFrame.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// A rule: a one-point line across the text.
final class RuleCell: NSTextAttachmentCell {
    override func cellFrame(
        for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect, glyphPosition position: NSPoint,
        characterIndex: Int
    ) -> NSRect {
        NSRect(x: 0, y: 0, width: max(1, lineFrag.maxX - position.x), height: 1)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        NSColor.separatorColor.setFill()
        cellFrame.fill()
    }
}

/// An SF Symbol on the text's baseline, in a colour, as `Image(systemName:)` sits in a line of text, with a gap
/// after it; or centred on a line of `centred`'s x-height, as a disclosure chevron sits beside its label.
final class SymbolCell: NSTextAttachmentCell {
    private let symbol: NSImage
    private let gap: CGFloat
    private let offset: CGFloat
    /// The task this circle stands for: a click flips it.
    let taskID: String?

    static func attachment(
        _ name: String, tint: NSColor, font: NSFont, gap: CGFloat = 0, taskID: String? = nil, centred: NSFont? = nil
    ) -> NSTextAttachment {
        let a = NSTextAttachment()
        a.attachmentCell = SymbolCell(name, tint: tint, font: font, gap: gap, taskID: taskID, centred: centred)
        return a
    }

    init(_ name: String, tint: NSColor, font: NSFont, gap: CGFloat, taskID: String?, centred: NSFont?) {
        let image = NSImage.symbol(name, size: font.pointSize, weight: font.weight, tint: tint)
        symbol = image
        self.gap = gap
        self.taskID = taskID
        // Centred: the symbol's middle on the middle of the line (its height from the baseline is the descent, the
        // half leading and half the line), as a disclosure chevron sits beside its label.
        offset =
            centred.map {
                $0.descender - $0.leading / 2 + NSLayoutManager().defaultLineHeight(for: $0) / 2 - image.size.height / 2
            }
            ?? font.descender
        super.init(imageCell: nil)
    }
    required init(coder: NSCoder) { fatalError() }

    override func cellSize() -> NSSize { NSSize(width: symbol.size.width + gap, height: symbol.size.height) }
    override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: offset) }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        var box = cellFrame
        box.size.width = symbol.size.width
        symbol.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

/// A media item that is not one of the issue's files: its name after a photo symbol in a grey capsule, as the
/// SwiftUI card's `Label` chip. Never wider than the line: a long name gives way in the middle.
class ChipCell: NSTextAttachmentCell {
    private let text: NSAttributedString
    private let symbol: NSImage
    private let size: NSSize
    private let baseline: CGFloat

    init(_ name: String, symbol: String = "photo", detail: String? = nil) {
        let font = NSFont.preferredFont(forTextStyle: .callout)
        let middle = NSMutableParagraphStyle()
        middle.lineBreakMode = .byTruncatingMiddle
        let t = NSMutableAttributedString(
            string: name,
            attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: middle])
        if let detail {
            t.append(
                NSAttributedString(
                    string: "  " + detail,
                    attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: middle]))
        }
        text = t
        self.symbol = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!
            .withSymbolConfiguration(
                .init(pointSize: font.pointSize, weight: .regular).applying(
                    .init(paletteColors: [.secondaryLabelColor])))!
        size = NSSize(width: 10 + self.symbol.size.width + 4 + ceil(text.size().width) + 10, height: 6 + 16 + 6)
        baseline = font.descender - 6
        super.init(imageCell: nil)
    }
    required init(coder: NSCoder) { fatalError() }

    override func cellSize() -> NSSize { size }
    override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: baseline) }

    override func cellFrame(
        for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect, glyphPosition position: NSPoint,
        characterIndex: Int
    ) -> NSRect {
        // The whole line's width, not what is left of it: a chip that does not fit moves to the next line whole.
        NSRect(
            x: 0, y: baseline, width: max(1, min(size.width, lineFrag.width - 2 * TextLayout.pad)), height: size.height)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        NSColor.labelColor.withAlphaComponent(0.05).setFill()
        NSBezierPath(roundedRect: cellFrame, xRadius: cellFrame.height / 2, yRadius: cellFrame.height / 2).fill()
        let s = symbol.size
        symbol.draw(
            in: NSRect(x: cellFrame.minX + 10, y: cellFrame.midY - s.height / 2, width: s.width, height: s.height),
            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        let x = cellFrame.minX + 10 + s.width + 4
        text.draw(
            in: NSRect(
                x: x, y: cellFrame.minY + 6, width: max(0, cellFrame.maxX - 10 - x), height: cellFrame.height - 6))
    }
}

/// One of the issue's files that is not a picture: its type's symbol, its name and its size.
final class FileChipCell: ChipCell, FileCell {
    let file: Attachment

    init(_ file: Attachment) {
        self.file = file
        super.init(
            file.filename, symbol: AttachmentOpener.symbol(for: file),
            detail: ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
    }
    required init(coder: NSCoder) { fatalError() }
}

extension NSAttributedString.Key {
    /// On an expand's title line: the expand's path, for the click that opens or closes it.
    static let expand = NSAttributedString.Key("conductor.expand")
    /// On inline code: the run's width with its pill, which `TextLayout` draws and keeps on one line while short.
    static let code = NSAttributedString.Key("conductor.code")
}

/// TextKit 1 with inline code as GitHub and Slack draw it: a rounded pill around each line's part of the run, where
/// `.backgroundColor` filled whole line heights and, on a wrapped run, ran to the edge of the text on both lines.
/// A run up to half a line wide never wraps: it moves to the next line whole.
final class TextLayout: NSLayoutManager, NSLayoutManagerDelegate {
    /// How far the pill reaches past the letters on each side, and the room the text makes for it with kerning: a
    /// point more, so a bracket beside it never touches.
    static let pad: CGFloat = 3
    static let room: CGFloat = 4

    override init() {
        super.init()
        delegate = self
    }
    required init?(coder: NSCoder) { fatalError() }

    func layoutManager(_ lm: NSLayoutManager, shouldBreakLineByWordBeforeCharacterAt i: Int) -> Bool {
        guard let s = lm.textStorage, i < s.length else { return true }
        var run = NSRange()
        guard let width = s.attribute(.code, at: i, effectiveRange: &run) as? CGFloat, i > run.location else {
            return true
        }
        return width > (lm.textContainers.first?.size.width ?? 0) / 2
    }

    override func drawBackground(forGlyphRange glyphs: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphs, at: origin)
        guard let s = textStorage, let container = textContainers.first else { return }
        let chars = characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        s.enumerateAttribute(.code, in: chars) { value, range, _ in
            guard value != nil, let font = s.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
            else { return }
            let run = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            enumerateLineFragments(forGlyphRange: run) { line, _, _, lineGlyphs, _ in
                let part = NSIntersectionRange(lineGlyphs, run)
                guard part.length > 0 else { return }
                var box = self.boundingRect(forGlyphRange: part, in: container)
                // The last letter's advance carries the kerning after it; the pill ends at the letter.
                if NSMaxRange(part) == NSMaxRange(run) { box.size.width -= Self.room }
                let baseline = line.minY + self.location(forGlyphAt: part.location).y
                let rect = NSRect(
                    x: box.minX - Self.pad + origin.x, y: baseline - font.ascender - 1 + origin.y,
                    width: box.width + 2 * Self.pad, height: font.ascender - font.descender + 2)
                NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            }
        }
    }
}

extension NSFont {
    /// The weight the font was made with, for a symbol drawn beside it.
    var weight: NSFont.Weight {
        let traits = fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        return NSFont.Weight(rawValue: traits?[.weight] as? CGFloat ?? 0)
    }
}
