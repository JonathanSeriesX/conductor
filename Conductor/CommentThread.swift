import AppKit
import SwiftUI

// The comment thread in AppKit. A thread of a thousand comments scrolls at the display's rate because nothing is
// built while it scrolls: rows are plain views reused from a pool, their text is one attributed string per comment
// laid out by TextKit once and measured off a cache, and only the rows in and around the window exist at all.
// Everything around the thread (the card, the composer, the editor on one comment) stays SwiftUI.

// MARK: - SwiftUI bridge

struct CommentThread: NSViewRepresentable {
    /// In display order.
    let comments: [Comment]
    /// The issue's, so inline media resolves to images.
    let attachments: [Attachment]
    /// The signed-in user: their comments carry Edit and Delete.
    let meID: String?
    /// The comment whose editor is open, shown in its row in place of the text.
    let editingID: String?
    let editor: (Comment, FocusState<Bool>.Binding) -> AnyView
    let onEdit: (Comment) -> Void
    let onDelete: (Comment) -> Void
    let onPreview: (Attachment) -> Void
    /// An image from memory, disk or the site, shrunk to `maxPixels`; it lands in `ImageCache`.
    let loadImage: (URL, Int) async -> NSImage?

    func makeNSView(context: Context) -> CommentThreadView { CommentThreadView() }

    func updateNSView(_ v: CommentThreadView, context: Context) {
        v.onEdit = onEdit
        v.onDelete = onDelete
        v.onPreview = onPreview
        v.loadImage = loadImage
        v.update(comments: comments, attachments: attachments, meID: meID, editingID: editingID, editor: editor)
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
    var onPreview: (Attachment) -> Void = { _ in }
    var loadImage: (URL, Int) async -> NSImage? = { _, _ in nil }

    private(set) var comments: [Comment] = []
    private var attachments: [Attachment] = []
    private var meID: String?
    private var editingID: String?
    private var editor: ((Comment, FocusState<Bool>.Binding) -> AnyView)?
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
        comments: [Comment], attachments: [Attachment], meID: String?, editingID: String?,
        editor: @escaping (Comment, FocusState<Bool>.Binding) -> AnyView
    ) {
        self.editor = editor
        self.meID = meID
        if attachments != self.attachments {
            self.attachments = attachments
            strings = [:]
            heights = heights.mapValues { (-1, $0.height) }
        }
        if comments != self.comments { self.comments = comments }
        if editingID != self.editingID {
            self.editingID = editingID
            editorHost?.view.removeFromSuperview()
            editorHost = nil
            editorHeight = 0
        }
        if let editingID, let c = comments.first(where: { $0.id == editingID }) { updateEditor(c) }
        recomputeTops()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    /// The thread's height for SwiftUI's layout. SwiftUI probes several widths; the rows are measured at the width
    /// the view is given (see `layout`), and a change there asks for a new layout.
    var height: CGFloat { total }

    // MARK: Editor

    private func updateEditor(_ c: Comment) {
        guard let editor else { return }
        let root = AnyView(
            HostedEditor(build: { editor(c, $0) }, onHeight: { [weak self] in self?.editorHeightChanged($0) }))
        let host: NSHostingController<AnyView>
        if let editorHost {
            host = editorHost
            host.rootView = root
        } else {
            host = NSHostingController(rootView: root)
            host.sizingOptions = []
            editorHost = host
        }
        let w = width - Self.textInset
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

    private func rowHeight(_ c: Comment, estimate: CGFloat) -> CGFloat {
        let body = c.id == editingID ? max(editorHeight, 100) : heights[c.id]?.height ?? estimate
        let header = buttons(on: c) ? CommentRowView.buttonHeaderHeight : CommentRowView.headerHeight
        return max(26, header + 6 + body)
    }

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
        for c in comments {
            tops.append(y)
            y += rowHeight(c, estimate: est) + Self.spacing
        }
        total = max(0, y - Self.spacing)
    }

    /// Measures row `i` at the current width if it has not been. True when its height changed.
    private func measure(_ i: Int) -> Bool {
        let c = comments[i]
        guard c.id != editingID else { return false }
        let w = width - Self.textInset
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
        var keep = Set<Int>()
        var ahead = 0
        i = index(at: top)
        while i < comments.count, tops[i] < bottom {
            let frame = NSRect(x: 0, y: tops[i], width: width, height: rowHeight(comments[i], estimate: est))
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

    private func configure(_ row: CommentRowView, _ c: Comment) {
        let editing = c.id == editingID
        let text = editing ? nil : string(for: c)
        let own = buttons(on: c)
        let key = CommentRowView.Key(
            id: c.id, text: text.map(ObjectIdentifier.init), buttons: own, editing: editing, updated: c.updated)
        guard row.key != key else { return }
        row.key = key
        row.show(c, text: text, buttons: own, editor: editing ? editorHost?.view : nil)
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

/// Lays text out as the rows' text views do (TextKit 1, no padding) and reports its height.
@MainActor private final class TextMeasurer {
    private let storage = NSTextStorage()
    private let manager = NSLayoutManager()
    private let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))

    init() {
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
    }

    func height(of s: NSAttributedString, width: CGFloat) -> CGFloat {
        container.size = NSSize(width: max(1, width), height: CGFloat.greatestFiniteMagnitude)
        storage.setAttributedString(s)
        manager.ensureLayout(for: container)
        return ceil(manager.usedRect(for: container).height)
    }
}

// MARK: - A row

/// One comment: the avatar, then the name, when, "· edited", Edit and Delete on a line, and the text under them.
@MainActor final class CommentRowView: NSView, NSTextViewDelegate {
    struct Key: Equatable {
        let id: String
        let text: ObjectIdentifier?
        let buttons: Bool
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
        editButton.action = { [unowned self] in if let comment { thread.onEdit(comment) } }
        deleteButton.action = { [unowned self] in if let comment { thread.onDelete(comment) } }
        body.delegate = self
        for v in [avatar, name, date, edited, editButton, deleteButton, body] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ c: Comment, text: NSAttributedString?, buttons: Bool, editor: NSView?) {
        comment = c
        name.stringValue = c.author?.displayName ?? String(localized: "Unknown")
        date.stringValue = c.created.formatted(.relative(presentation: .named))
        date.toolTip = c.created.formatted()
        edited.isHidden = !(c.updated.timeIntervalSince(c.created) > 60)
        editButton.isHidden = !buttons
        deleteButton.isHidden = !buttons
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
        if let data = DiskCache.imageDataNow(for: url), let img = NSImage(data: data) {
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
        let hh = editButton.isHidden ? Self.headerHeight : Self.buttonHeaderHeight
        // The buttons at the trailing end; the name gives way to them and the date.
        var right = cx + cw
        if !editButton.isHidden {
            let bs = deleteButton.frame.size
            place(deleteButton, right - bs.width, (hh - bs.height) / 2, bs.width, bs.height)
            right -= bs.width + 6
            let es = editButton.frame.size
            place(editButton, right - es.width, (hh - es.height) / 2, es.width, es.height)
            right -= es.width + 6
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
        if let editorView { place(editorView, cx, by, cw, bh) } else { place(body, cx, by, cw, bh) }
        // The whole text now, not line by line as it draws: laid out in pieces while a row scrolls in, a table's
        // first row came out short.
        if !body.isHidden, let tc = body.textContainer { body.layoutManager?.ensureLayout(for: tc) }
    }

    /// A click on an inline image opens it in Quick Look, as a click on the SwiftUI image did.
    func textView(
        _ textView: NSTextView, clickedOnCell cell: NSTextAttachmentCellProtocol, in cellFrame: NSRect,
        at charIndex: Int
    ) {
        if let image = cell as? ImageCell { thread.onPreview(image.file) }
    }
}

/// A symbol in the tertiary colour that runs an action on a click, as `.buttonStyle(.plain).foregroundStyle(.tertiary)`
/// draws one. Not an NSButton: its tooltip and baseline asked the button's visual provider for metrics on every
/// tick of a scroll.
final class SymbolButton: NSView {
    var action: () -> Void = {}
    private let symbol: NSImage

    static func image(_ name: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)!
            .withSymbolConfiguration(
                .init(pointSize: NSFont.preferredFont(forTextStyle: .body).pointSize, weight: .regular)
                    .applying(.init(paletteColors: [.tertiaryLabelColor])))!
    }

    init(_ name: String, label: String, help: String) {
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

/// A comment's text: selectable, never editable, laid out by TextKit 1 (text blocks draw the code, quote, panel
/// and table backgrounds). A right-click offers Copy when there is a selection, and nothing otherwise, as the
/// reader menu on SwiftUI text does.
final class CommentTextView: NSTextView {
    init() {
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
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

    /// The whole text on every draw: a block's background (the quote bar, a code box, a table cell) is drawn from
    /// the frame AppKit hands the block, and for a partial redraw that frame is the part alone. Rows have their own
    /// layers, so a draw happens once per row and then only for a hover.
    override func draw(_ dirtyRect: NSRect) { super.draw(bounds) }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard selectedRange().length > 0 else { return nil }
        let m = NSMenu()
        m.addItem(withTitle: String(localized: "Copy"), action: #selector(copy(_:)), keyEquivalent: "")
        return m
    }
}

// MARK: - ADF → attributed string

/// `ADFView`'s look as one attributed string for TextKit 1: the same fonts, colours and gaps; code, quotes, panels
/// and tables as text blocks that draw their own backgrounds; images and rules as attachment cells.
@MainActor final class ADFAttributed {
    private let attachments: [Attachment]
    private let image: (Attachment) -> NSImage?
    private let out = NSMutableAttributedString()

    /// A block's font: the size and the weight it starts from, before the runs' own marks.
    private struct Base {
        var size: CGFloat
        var weight: NSFont.Weight = .regular
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
    }

    private init(attachments: [Attachment], image: @escaping (Attachment) -> NSImage?) {
        self.attachments = attachments
        self.image = image
    }

    static func render(_ doc: ADFNode, attachments: [Attachment], image: @escaping (Attachment) -> NSImage?)
        -> NSAttributedString
    {
        let r = ADFAttributed(attachments: attachments, image: image)
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
        for (i, n) in nodes.enumerated() { block(n, ctx, before: i == 0 ? first : ctx.spacing) }
    }

    private func block(_ node: ADFNode, _ ctx: Ctx, before: CGFloat) {
        switch node.type {
        case "paragraph":
            paragraph(inline(node, ctx.base), ctx, before: before)
        case "heading":
            var c = ctx
            c.base = Base(size: Self.headingSize(Int(node.attrs?["level"]?.number ?? 3)), weight: .semibold)
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
            for (i, item) in (node.content ?? []).enumerated() {
                let done = item.attr("state") == "DONE"
                let s = NSMutableAttributedString(
                    attachment: SymbolCell.attachment(
                        done ? "checkmark.circle.fill" : "circle", tint: done ? .systemGreen : .secondaryLabelColor,
                        font: ctx.base.font()))
                s.append(NSAttributedString(string: "  ", attributes: [.font: ctx.base.font()]))
                s.append(inline(item, ctx.base))
                paragraph(s, ctx, before: i == 0 ? before : 6)
            }
        case "expand", "nestedExpand":
            // ponytail: always open; the SwiftUI card folded it.
            let title = NSMutableAttributedString(
                attachment: SymbolCell.attachment("chevron.down", tint: .secondaryLabelColor, font: ctx.base.font()))
            title.append(
                NSAttributedString(
                    string: "  " + (node.attr("title") ?? String(localized: "Details")),
                    attributes: [.font: ctx.base.font(), .foregroundColor: NSColor.labelColor]))
            paragraph(title, ctx, before: before)
            var c = ctx
            c.spacing = 8
            blocks(node.content ?? [], c, first: 6)
        case "layoutSection":
            // ponytail: columns one under another; the SwiftUI card put them side by side.
            for (i, col) in (node.content ?? []).enumerated() {
                blocks(col.content ?? [], ctx, first: i == 0 ? before : 8)
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
    private func paragraph(_ text: NSAttributedString, _ ctx: Ctx, before: CGFloat) {
        let start = out.length
        out.append(text)
        out.append(
            NSAttributedString(
                string: "\n", attributes: [.font: ctx.base.font(), .foregroundColor: NSColor.labelColor]))
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = before
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
        table.setWidth(before, type: .absoluteValueType, for: .margin, edge: .minY)
        for (r, row) in rows.enumerated() {
            for (ci, cell) in (row.content ?? []).enumerated() {
                let header = cell.type == "tableHeader"
                let b = CellBlock(table: table, startingRow: r, rowSpan: 1, startingColumn: ci, columnSpan: 1)
                b.header = header
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
            if let a = attachments.first(where: { $0.filename == m.attr("alt") }),
                (a.mimeType ?? "").hasPrefix("image/")
            {
                let att = NSTextAttachment()
                att.attachmentCell = ImageCell(attachment: a, picture: image(a))
                s.append(NSAttributedString(attachment: att))
            } else {
                // ponytail: a square chip, not a capsule.
                let callout = NSFont.preferredFont(forTextStyle: .callout)
                let bg = NSColor.labelColor.withAlphaComponent(0.05)
                s.append(NSAttributedString(string: " ", attributes: [.font: callout, .backgroundColor: bg]))
                s.append(
                    NSAttributedString(
                        attachment: SymbolCell.attachment(
                            "photo", tint: .secondaryLabelColor, font: callout, background: bg)))
                s.append(
                    NSAttributedString(
                        string: " " + (m.attr("alt") ?? String(localized: "Attached media")) + " ",
                        attributes: [
                            .font: callout, .foregroundColor: NSColor.secondaryLabelColor, .backgroundColor: bg,
                        ]))
            }
        }
        paragraph(s, ctx, before: before)
    }

    private static func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: NSFont.preferredFont(forTextStyle: .title1).pointSize
        case 2: NSFont.preferredFont(forTextStyle: .title2).pointSize
        case 3: NSFont.preferredFont(forTextStyle: .title3).pointSize
        default: NSFont.preferredFont(forTextStyle: .headline).pointSize
        }
    }

    // MARK: Inline

    private func inline(_ node: ADFNode, _ base: Base) -> NSAttributedString {
        let s = NSMutableAttributedString()
        for n in node.content ?? [] { s.append(run(n, base)) }
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
            attrs[.font] = base.font(mono: code, bold: bold, italic: italic)
            if code { attrs[.backgroundColor] = NSColor.labelColor.withAlphaComponent(0.08) }
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

    override func drawBackground(
        withFrame frameRect: NSRect, in controlView: NSView?, characterRange: NSRange, layoutManager: NSLayoutManager
    ) {
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

/// A code block: 10 points of padding on a faint rounded background.
final class CodeBlock: NSTextBlock {
    init(topMargin: CGFloat) {
        super.init()
        setWidth(10, type: .absoluteValueType, for: .padding)
        setWidth(topMargin, type: .absoluteValueType, for: .margin, edge: .minY)
        setValue(100, type: .percentageValueType, for: .width)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func drawBackground(
        withFrame frameRect: NSRect, in controlView: NSView?, characterRange: NSRange, layoutManager: NSLayoutManager
    ) {
        NSColor.labelColor.withAlphaComponent(0.05).setFill()
        NSBezierPath(roundedRect: frameRect, xRadius: 8, yRadius: 8).fill()
    }
}

/// A quote: a 3-point bar at the leading edge, the text 13 points in.
final class QuoteBlock: NSTextBlock {
    init(topMargin: CGFloat) {
        super.init()
        setWidth(13, type: .absoluteValueType, for: .padding, edge: .minX)
        setWidth(topMargin, type: .absoluteValueType, for: .margin, edge: .minY)
        setValue(100, type: .percentageValueType, for: .width)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func drawBackground(
        withFrame frameRect: NSRect, in controlView: NSView?, characterRange: NSRange, layoutManager: NSLayoutManager
    ) {
        NSColor.tertiaryLabelColor.setFill()
        NSBezierPath(
            roundedRect: NSRect(x: frameRect.minX, y: frameRect.minY, width: 3, height: frameRect.height), xRadius: 2,
            yRadius: 2
        ).fill()
    }
}

/// A panel: an icon in its colour, the text beside it, on a tinted rounded background with 12 points of padding.
final class PanelBlock: NSTextBlock {
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
        icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!
            .withSymbolConfiguration(
                .init(pointSize: NSFont.preferredFont(forTextStyle: .body).pointSize, weight: .regular)
                    .applying(.init(paletteColors: [tint])))!
        super.init()
        setWidth(12, type: .absoluteValueType, for: .padding)
        setWidth(12 + 16 + 10, type: .absoluteValueType, for: .padding, edge: .minX)
        setWidth(topMargin, type: .absoluteValueType, for: .margin, edge: .minY)
        setValue(100, type: .percentageValueType, for: .width)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func drawBackground(
        withFrame frameRect: NSRect, in controlView: NSView?, characterRange: NSRange, layoutManager: NSLayoutManager
    ) {
        tint.withAlphaComponent(0.1).setFill()
        NSBezierPath(roundedRect: frameRect, xRadius: 10, yRadius: 10).fill()
        let size = icon.size
        icon.draw(
            in: NSRect(x: frameRect.minX + 12, y: frameRect.minY + 12, width: size.width, height: size.height),
            from: .zero,
            operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

// MARK: Attachment cells

/// An inline image: fitted into 520 by 360 points (or the line's width), rounded; a grey box until it has loaded.
final class ImageCell: NSTextAttachmentCell {
    let file: Attachment
    private let picture: NSImage?

    init(attachment: Attachment, picture: NSImage?) {
        self.file = attachment
        self.picture = picture
        super.init(imageCell: nil)
    }
    required init(coder: NSCoder) { fatalError() }

    private func size(forWidth w: CGFloat) -> NSSize {
        guard let picture, picture.size.width > 0, picture.size.height > 0 else {
            return NSSize(width: min(240, w), height: 140)
        }
        let k = min(w / picture.size.width, 360 / picture.size.height)
        return NSSize(width: floor(picture.size.width * k), height: floor(picture.size.height * k))
    }

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
            picture.draw(
                in: cellFrame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
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

/// An SF Symbol on the text's baseline, in a colour, as `Image(systemName:)` sits in a line of text.
final class SymbolCell: NSTextAttachmentCell {
    private let symbol: NSImage
    private let descent: CGFloat
    private let background: NSColor?

    static func attachment(_ name: String, tint: NSColor, font: NSFont, background: NSColor? = nil) -> NSTextAttachment
    {
        let a = NSTextAttachment()
        a.attachmentCell = SymbolCell(name, tint: tint, font: font, background: background)
        return a
    }

    init(_ name: String, tint: NSColor, font: NSFont, background: NSColor?) {
        symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)!
            .withSymbolConfiguration(
                .init(pointSize: font.pointSize, weight: .regular).applying(.init(paletteColors: [tint])))!
        descent = font.descender
        self.background = background
        super.init(imageCell: nil)
    }
    required init(coder: NSCoder) { fatalError() }

    override func cellSize() -> NSSize { symbol.size }
    override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: descent) }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        if let background {
            background.setFill()
            cellFrame.fill()
        }
        symbol.draw(in: cellFrame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}
