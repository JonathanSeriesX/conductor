import SwiftUI

// MARK: - Liquid Glass with a Sequoia fallback
//
// Every macOS 26 effect the app uses goes through one of these, so on 26 the app looks exactly as designed and
// on macOS 15 it falls back to the standard control of the day. Nothing else in the app is version-specific.

extension View {
    /// `.glass` / `.glassProminent` on macOS 26; `.bordered` / `.borderedProminent` on Sequoia.
    @ViewBuilder func glassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26, *) {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else if prominent {
            buttonStyle(.borderedProminent)
        } else {
            buttonStyle(.bordered)
        }
    }

    /// A glass pane on macOS 26; the regular material on Sequoia.
    @ViewBuilder func glassPane(cornerRadius r: CGFloat) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: .rect(cornerRadius: r))
        } else {
            background(.regularMaterial, in: .rect(cornerRadius: r))
        }
    }

    /// Blurs what scrolls under a transparent toolbar. Sequoia's toolbar has an opaque background already.
    /// `band`: inside a split-view column (the main window's preview) AppKit never activates the scroll view's
    /// pocket, so nothing blurs under the toolbar; there the column draws the window toolbar's band itself, once
    /// content has scrolled under it.
    @ViewBuilder func softScrollEdge(band: Bool? = nil) -> some View {
        if #available(macOS 26, *) {
            if let band {
                scrollEdgeEffectStyle(.soft, for: .top).overlay(alignment: .top) { ToolbarBand(visible: band) }
            } else {
                scrollEdgeEffectStyle(.soft, for: .top)
            }
        } else {
            self
        }
    }

    /// A bottom bar that the system blurs on macOS 26; on Sequoia an inset with the `.bar` backing, so rows
    /// don't scroll through it.
    @ViewBuilder func bottomBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        if #available(macOS 26, *) {
            safeAreaBar(edge: .bottom, content: bar)
        } else {
            safeAreaInset(edge: .bottom, spacing: 0) { bar().background(.bar) }
        }
    }
}

extension CustomizableToolbarContent {
    /// The issue title sits straight on the toolbar on macOS 26, with no capsule behind it and the buttons pushed
    /// to the trailing end. Sequoia's toolbar draws no capsules and groups by placement on its own.
    @ToolbarContentBuilder func glassTitle() -> some CustomizableToolbarContent {
        if #available(macOS 26, *) {
            sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.flexible)
        } else {
            self
            // Sequoia has no ToolbarSpacer; a Spacer item is its flexible space, and pushes the buttons trailing.
            ToolbarItem(id: "flex") { Spacer() }
        }
    }
}

extension ToolbarContent {
    /// The same for a toolbar that cannot be customized: the issue page's, which comes and goes in the preview column.
    @ToolbarContentBuilder func glassTitle() -> some ToolbarContent {
        if #available(macOS 26, *) {
            sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.flexible)
        } else {
            self
            ToolbarItem { Spacer() }
        }
    }
}

/// Lets neighbouring glass panes blend on macOS 26; plain content on Sequoia.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26, *) { GlassEffectContainer(spacing: spacing) { content } } else { content }
    }
}

/// The window background, so glass panes sit on the system colour in light and dark mode.
struct Backdrop: View {
    var body: some View { Color(nsColor: .windowBackgroundColor).ignoresSafeArea() }
}

enum ImageCache {
    /// NSCache is thread-safe: launch fills it from other threads before the first layout.
    nonisolated(unsafe) static let shared = NSCache<NSURL, NSImage>()

    /// The colour space SwiftUI rasterizes a vector image in: the screen's (the main one's, as `NSScreen` has it).
    /// CoreGraphics answers on any thread; the first call pays for the window server connection.
    static var space: CGColorSpace { CGDisplayCopyColorSpace(CGMainDisplayID()) }

    /// Every size, in points, an icon or avatar is drawn at: list rows, chips, the board, the sidebar, comments.
    private static let sizes: [CGFloat] = [12, 14, 16, 18, 20, 22, 26]
    /// The backing scales of the displays online at launch, from CoreGraphics on whichever thread asks first (NSScreen
    /// cost the main thread 40 ms that early); 2x when none answers. A rep for a scale no screen has was a fifth of
    /// every icon's memory.
    static let scales: Set<CGFloat> = {
        var (ids, n) = ([CGDirectDisplayID](repeating: 0, count: 16), UInt32(0))
        guard CGGetOnlineDisplayList(16, &ids, &n) == .success else { return [2] }
        let s = Set(
            ids.prefix(Int(n)).compactMap { id -> CGFloat? in
                guard let mode = CGDisplayCopyDisplayMode(id), mode.width > 0 else { return nil }
                return (CGFloat(mode.pixelWidth) / CGFloat(mode.width)).rounded()
            })
        return s.isEmpty ? [2] : s
    }()

    /// Jira's SVG icons as bitmaps, rasterized once at each of those sizes and `scales` the way SwiftUI rasterizes a
    /// vector on every pass (the screen's colour space, half floats): the same pixels, without the work. Nil for
    /// anything else, which `NSImage(data:)` reads as before; a non-square SVG stays a vector.
    static func svg(_ data: Data, space: CGColorSpace = ImageCache.space) -> NSImage? {
        guard data.starts(with: Data("<svg".utf8)) || data.starts(with: Data("<?xml".utf8)),
            let vector = NSImage(data: data), vector.size.width > 0, vector.size.width == vector.size.height
        else { return nil }
        let out = NSImage(size: vector.size)
        for px in Set(sizes.flatMap { s in scales.map { Int(s * $0) } }) {
            let info =
                CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue
            guard
                let ctx = CGContext(
                    data: nil, width: px, height: px, bitsPerComponent: 16, bytesPerRow: 0, space: space,
                    bitmapInfo: info)
            else { return vector }
            ctx.scaleBy(x: CGFloat(px) / vector.size.width, y: CGFloat(px) / vector.size.height)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            vector.draw(in: NSRect(origin: .zero, size: vector.size))
            NSGraphicsContext.restoreGraphicsState()
            guard let cg = ctx.makeImage() else { return vector }
            let rep = NSBitmapImageRep(cgImage: cg)
            rep.size = vector.size  // one point size for all: NSImage draws the rep whose pixels fit the destination
            out.addRepresentation(rep)
        }
        return out
    }

    /// Reads and decodes every image of `urls` that is on disk into memory, on the calling thread and its siblings,
    /// so the first layout finds them all here rather than reading and decoding each on the main thread.
    static func warm(_ urls: Set<URL>) {
        let (urls, space) = (Array(urls), ImageCache.space)
        DispatchQueue.concurrentPerform(iterations: urls.count) { i in
            let key = urls[i] as NSURL
            guard shared.object(forKey: key) == nil, let data = DiskCache.imageDataNow(for: urls[i]),
                let img = svg(data, space: space) ?? NSImage(data: data)
            else { return }
            shared.setObject(img, forKey: key)
        }
    }
}

/// Image that goes through the Jira client so site-hosted avatars and thumbnails get auth.
struct RemoteImage: View {
    let url: URL?
    var placeholder: String = "photo"
    /// The whole image inside the frame (a thumbnail) rather than the frame filled with it (an avatar, an icon).
    var fit = false
    @Environment(Session.self) private var session
    @State private var loaded: NSImage?

    // Memory and disk hits resolve in `body`, so a cached icon draws in the first frame instead of after a task hop.
    private var image: NSImage? {
        if let loaded { return loaded }
        guard let url else { return nil }
        if let hit = ImageCache.shared.object(forKey: url as NSURL) { return hit }
        // A thumbnail (`fit`) is drawn far larger than any icon size: it keeps its vector.
        guard let data = DiskCache.imageDataNow(for: url),
            let img = (fit ? nil : ImageCache.svg(data)) ?? NSImage(data: data)
        else { return nil }
        LaunchProbe.once(
            "img \(url.lastPathComponent) \(data.prefix(4).map { String(format: "%02x", $0) }.joined()) \(data.count)B")
        ImageCache.shared.setObject(img, forKey: url as NSURL)
        return img
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: fit ? .fit : .fill).inactiveDim()
            } else {
                Image(systemName: placeholder).resizable().scaledToFit().padding(2).foregroundStyle(.tertiary)
            }
        }
        .task(id: url) {
            guard let url, image == nil else { return }
            guard let client = session.client(for: url), let data = try? await client.data(for: url) else { return }
            var decoded = fit ? nil : ImageCache.svg(data)
            if decoded == nil { decoded = await DiskCache.decodeImage(data, maxPixels: 256) }
            guard let img = decoded else { return }
            DiskCache.saveImage(data, for: url)
            ImageCache.shared.setObject(img, forKey: url as NSURL)
            loaded = img
        }
    }
}

struct Avatar: View {
    let user: JiraUser?
    var size: CGFloat = 22
    /// The name as a tooltip; a list row has it only under the pointer (see `help(_:tips:)`).
    var tips = true
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        Group {
            if let user {
                RemoteImage(url: user.avatar, placeholder: "person.crop.circle.fill")
            } else {
                // White on a selected row, as its text goes: the tertiary grey all but vanished on the accent.
                Image(systemName: "person.crop.circle.badge.questionmark").resizable().scaledToFit().foregroundStyle(
                    prominence == .increased ? AnyShapeStyle(.white) : AnyShapeStyle(.tertiary))
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        // A ring on a selected row, so an orange avatar still reads on the orange selection. The symbol has its own.
        .overlay { if prominence == .increased, user != nil { Circle().stroke(.white.opacity(0.9), lineWidth: 1.5) } }
        .help(Text(user?.displayName ?? String(localized: "Unassigned")), tips: tips)
        .accessibilityLabel(user?.displayName ?? String(localized: "Unassigned"))
    }
}

extension View {
    /// Greys a coloured element while its window is inactive, as the system does with sidebar icons and the
    /// selection. Text stays as it is; pills, badges and every remote image (icons, avatars) lose their colour.
    func inactiveDim() -> some View { modifier(InactiveDim()) }

    /// `help(text)` with `tips` on; off, the text stays for VoiceOver alone, which is the half of `help` that is not
    /// the tooltip. A tooltip costs its view a tracking area that every scroll moves: a list row has them only while
    /// the pointer is over it, or four per row cost a fast scroll a quarter of its frames.
    @ViewBuilder func help(_ text: Text, tips: Bool) -> some View {
        if tips { help(text) } else { accessibilityHint(text) }
    }
}

private struct InactiveDim: ViewModifier {
    @Environment(\.appearsActive) private var active
    func body(content: Content) -> some View { content.grayscale(active ? 0 : 1).opacity(active ? 1 : 0.6) }
}

/// "Today", "Yesterday", "In 3 days", "Next month": whole days from today, in the user's language, as Mail dates
/// its rows. Within two weeks the count is exact; "next week" alone would cover 6 to 13 days.
@MainActor func relativeDay(_ date: Date) -> String {
    let cal = Calendar.current
    let day = cal.startOfDay(for: date)
    let today = cal.startOfDay(for: .now)
    let days = cal.dateComponents([.day], from: today, to: day).day ?? 0
    if days == 0 { return String(localized: "Today") }  // the formatter would say "Now"
    if abs(days) > 1, abs(days) <= 13 { return relativeDayFormatter.localizedString(from: DateComponents(day: days)) }
    return relativeDayFormatter.localizedString(for: day, relativeTo: today)
}

@MainActor private let relativeDayFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.dateTimeStyle = .named
    f.unitsStyle = .full
    f.formattingContext = .beginningOfSentence
    return f
}()

extension StatusCategory {
    var color: Color {
        switch key {
        case "done": .green
        case "indeterminate": .blue
        default: .secondary
        }
    }
}

struct StatusPill: View {
    let status: Status
    /// `.increased` inside a selected list row, where the accent colour is the background.
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        let tint: Color = prominence == .increased ? .white : status.statusCategory.color
        Text(status.name)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(tint)
            .background(tint.opacity(prominence == .increased ? 0.28 : 0.16), in: .capsule)
            .inactiveDim()
    }
}

/// Jira's coloured priority SVG, given a light disc when sitting on a selection colour.
struct PriorityIcon: View {
    let priority: Priority
    var size: CGFloat = 14
    var tips = true
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        RemoteImage(url: priority.iconUrl, placeholder: "minus")
            .accessibilityLabel(priority.name)
            .frame(width: size, height: size)
            .padding(2)  // constant so the glyph does not shift when the disc appears
            .background(prominence == .increased ? .white.opacity(0.9) : .clear, in: .circle)
            .help(Text(priority.name), tips: tips)
    }
}

struct GlassCard<Content: View>: View {
    var title: LocalizedStringKey?
    /// "• 1 task", "• 1d 7h logged", the title's size in a regular weight, after it: a figure that belongs to the title.
    var detail: String?
    /// A control after the detail, in the hint's size: "• newest first ↓".
    var accessory: AnyView?
    /// "• M to add", faint, after the title: the key that acts on the card.
    var hint: String?
    /// Set for a card that folds away: a chevron at the title's trailing end, and a click on the title, fold it.
    var collapsed: Binding<Bool>?
    @ViewBuilder var content: Content

    var body: some View {
        Foldable(collapsed: collapsed, gap: title == nil ? 0 : 12) {
            if let title {
                HStack(spacing: 3) {
                    // The gap before the bullet equals the space after it. On one baseline: centred on the title, the
                    // smaller hint sat a point high.
                    // One line in a narrow column: the title, the figure and the control stay whole, the key hint
                    // gives way first.
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(title).font(.headline).foregroundStyle(.secondary).fixedSize()
                        if let detail {
                            Text(verbatim: detail).font(.headline.weight(.regular)).foregroundStyle(.secondary)
                                .fixedSize()
                        }
                        if let accessory { accessory.fixedSize() }
                        if let hint { Text(hint).keyHint(.subheadline).lineLimit(1) }
                    }
                    if let collapsed {
                        Spacer(minLength: 8)
                        Disclosure(collapsed: collapsed.wrappedValue)
                    }
                }
            }
        } content: {
            // Its own glass container: glass (the composer's Comment button) is drawn by the nearest one, and the
            // page's ignored the fold's clip and opacity, so the button hung below the card while it folded.
            // Several views in `content` sit 12 apart, leading.
            GlassGroup(spacing: 0) { VStack(alignment: .leading, spacing: 12) { content } }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frosted(cornerRadius: 20)
    }
}

/// A header over content that a click on the header folds away and back: a card, a person's work log.
struct Foldable<Header: View, Content: View>: View {
    /// Nil for content that does not fold.
    var collapsed: Binding<Bool>?
    /// The gap under the header. It folds with the content, so nothing changes size once the fold is over.
    var gap: CGFloat
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content
    /// The content's height while it folds or unfolds: from what is on screen to nothing, or back. Nil at rest.
    @State private var clip: CGFloat?
    /// Read only when the content folds, so kept where SwiftUI does not watch: as state, the window's edge changed on
    /// every frame of a scroll and re-rendered every card, a 250-comment thread included, each time.
    @State private var measured = FoldMeasure()
    /// Without bounce: a spring's overshoot is a share of the distance, and a long fold travels far.
    private static var curve: Animation { .smooth(duration: 0.25) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .contentShape(.rect)
                .onTapGesture { fold() }
                .environment(\.fold) { fold() }
                .background(ScrollProbe(measured: measured))
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.height
                } action: {
                    measured.header = $0
                }
            if collapsed?.wrappedValue != true || clip != nil {
                content
                    .padding(.top, gap)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) {
                        $0.size.height
                    } action: {
                        measured.content = $0
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: clip, alignment: .top)
                    // Clipped only while folding: at rest a focus ring may reach past the edge.
                    .clipShape(.rect.inset(by: clip == nil ? -1000 : 0))
                    .opacity(collapsed?.wrappedValue == true ? 0 : 1)  // and fades, as it did before
            }
        }
    }

    /// Folds or unfolds over what is on screen only. Animated over its whole height, a long thread (thousands of
    /// points) spent the animation below the window's edge and showed only its last few frames, as a jump.
    private func fold() {
        guard let collapsed else { return }
        // How much of the content the window shows: the rest changes unseen.
        let m = measured
        let onScreen = { max(0, min(m.content, m.visibleBottom - m.header)) }
        var still = Transaction()
        still.disablesAnimations = true
        if collapsed.wrappedValue {
            withTransaction(still) { clip = 0 }
            collapsed.wrappedValue = false
            // A turn later the content is laid out, so its height is known.
            Task { @MainActor in
                withAnimation(Self.curve) {
                    clip = onScreen()
                } completion: {
                    withTransaction(still) { clip = nil }
                }
            }
        } else {
            withTransaction(still) { clip = onScreen() }
            Task { @MainActor in
                collapsed.wrappedValue = true
                withAnimation(Self.curve) {
                    clip = 0
                } completion: {
                    withTransaction(still) { clip = nil }
                }
            }
        }
    }
}

/// What a fold needs to know about its header: its height, its content's, and where the window's bottom edge is.
@MainActor private final class FoldMeasure {
    var content: CGFloat = 0
    var header: CGFloat = 0
    /// The header's AppKit view, placed under it by `ScrollProbe`.
    weak var probe: NSView?
    /// The scroll view's bottom edge from the header's top, read when a fold starts. Watched through SwiftUI's
    /// geometry instead, it changed on every frame of a scroll and cost the page a layout pass each time.
    var visibleBottom: CGFloat {
        guard let probe, let sv = probe.enclosingScrollView, let doc = sv.documentView else { return .infinity }
        return probe.convert(sv.documentVisibleRect, from: doc).maxY
    }
}

/// An empty view under a header, so the fold can ask AppKit where the header sits in its scroll view.
private struct ScrollProbe: NSViewRepresentable {
    let measured: FoldMeasure
    func makeNSView(context: Context) -> ProbeView {
        let v = ProbeView()
        measured.probe = v
        return v
    }
    func updateNSView(_ v: ProbeView, context: Context) { measured.probe = v }

    final class ProbeView: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

extension View {
    /// White on white (black on black in dark mode): the window background at partial opacity with a hairline,
    /// like a Tahoe sidebar. Materials carry a grey tint, and lensing glass is too busy for text.
    func frosted(cornerRadius r: CGFloat, opacity: Double = 0.7) -> some View {
        background(.background.opacity(opacity), in: .rect(cornerRadius: r))
            .overlay(RoundedRectangle(cornerRadius: r).strokeBorder(.quaternary.opacity(0.6), lineWidth: 1))
    }
}

/// "1 issue", "2 issues", "50+ issues" for subtitles; the plural forms live in the string catalog.
func issues(_ n: Int, more: Bool = false) -> String {
    more ? String(localized: "\(n)+ issues") : String(localized: "\(n) issues")
}

/// A small-caps caption over a value: the issue page's fields and the New Issue window's.
@MainActor func field<V: View>(_ name: LocalizedStringKey, hint: String? = nil, @ViewBuilder _ value: () -> V)
    -> some View
{
    let caption = Text(name).textCase(.uppercase).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
    return VStack(alignment: .leading, spacing: 4) {
        // "ASSIGNEE • A to assign to…" on one line where it fits; in a narrow column the hint takes a line of its own
        // rather than breaking mid-phrase.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 2) {
                caption
                if let hint { Text(hint).keyHint(.caption2) }
            }
            VStack(alignment: .leading, spacing: 2) {
                caption
                if let hint {
                    Text(hint.hasPrefix("• ") ? String(hint.dropFirst(2)) : hint).keyHint(.caption2)
                }
            }
        }
        value()
    }
}

extension Text {
    /// A key hint ("• M to add"): a shade fainter than the caption it follows.
    func keyHint(_ font: Font) -> some View { self.font(font).foregroundStyle(.secondary.opacity(0.9)) }
}

extension View {
    func errorAlert(_ error: Binding<String?>) -> some View {
        alert(
            "Something went wrong",
            isPresented: Binding(get: { error.wrappedValue != nil }, set: { if !$0 { error.wrappedValue = nil } })
        ) {
            Button("OK") { error.wrappedValue = nil }
        } message: {
            Text(error.wrappedValue ?? "")
        }
    }

    /// Puts the keyboard in `focus` as the view appears. Focus set in the same pass that creates the field is
    /// lost; one turn of the run loop later it sticks.
    func focusSoon(_ focus: FocusState<Bool>.Binding) -> some View {
        task { DispatchQueue.main.async { focus.wrappedValue = true } }
    }
}

/// Sees events of `mask` aimed at the window this view sits in, before any view handles them; return nil to swallow one.
/// Invisible to clicks. SwiftUI has no modifier for a key press outside a focused view.
struct WindowEventMonitor: NSViewRepresentable {
    let mask: NSEvent.EventTypeMask
    let handler: (NSEvent) -> NSEvent?

    func makeNSView(context: Context) -> MonitorView { MonitorView(mask: mask) }
    func updateNSView(_ view: MonitorView, context: Context) { view.handler = handler }

    final class MonitorView: NSView {
        let mask: NSEvent.EventTypeMask
        var handler: (NSEvent) -> NSEvent? = { $0 }
        nonisolated(unsafe) private var monitor: Any?

        init(mask: NSEvent.EventTypeMask) {
            self.mask = mask
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] e in
                guard let self, e.window === self.window else { return e }
                return self.handler(e)
            }
        }
    }
}

/// Lays the window's toolbar out before a frame is committed whenever a SwiftUI toolbar item has changed width (the
/// list's count arriving, a longer title). AppKit's own pass cannot: an item that grows during the toolbar's layout
/// re-requests one that is dropped when the pass returns, and a change SwiftUI applies inside the commit comes after
/// every pass. Either way the frame would show the new content centred in the old item viewer, the list title over
/// the sidebar toggle, until the next pass.
struct ToolbarRelayout: NSViewRepresentable {
    func makeNSView(context: Context) -> Watcher { Watcher() }
    func updateNSView(_ view: Watcher, context: Context) {}

    final class Watcher: NSView {
        nonisolated(unsafe) private var observer: CFRunLoopObserver?
        private var widths: [ObjectIdentifier: CGFloat] = [:]
        /// Found once per window: the search walked the whole window tree on every run-loop pass, which kept a
        /// core a third busy while any other window turned the loop.
        private weak var cachedToolbar: NSView?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { CFRunLoopObserverInvalidate(observer) }
            observer = nil
            cachedToolbar = nil
            guard window != nil else { return }
            // CoreAnimation commits at order 2_000_000; this runs just before, after AppKit's and SwiftUI's passes.
            observer = CFRunLoopObserverCreateWithHandler(
                nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 1_999_999
            ) {
                [weak self] _, _ in
                MainActor.assumeIsolated { self?.relayoutIfChanged() }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        }

        deinit { if let observer { CFRunLoopObserverInvalidate(observer) } }

        /// A window's first content is laid out and flushed inside the call that orders it on screen, with no
        /// run-loop turn in between; this is the one hook after that layout and before the flush.
        override func viewWillDraw() {
            super.viewWillDraw()
            relayoutIfChanged()
        }

        private func relayoutIfChanged() {
            guard let window, window.isVisible, window.occlusionState.contains(.visible), let toolbar = toolbarView,
                let items = window.toolbar?.items
            else { return }
            var changed = toolbar.needsLayout
            for v in items.compactMap(\.view) where String(describing: type(of: v)).contains("Hosting") {
                // Measured only once SwiftUI has marked the item dirty, or the first time: a fitting size costs a
                // constraint pass, and other windows turn the run loop all the time (a board, an animation).
                let key = ObjectIdentifier(v)
                guard widths[key] == nil || v.needsLayout || v.needsUpdateConstraints else { continue }
                let width = v.fittingSize.width  // asking applies a pending SwiftUI change now, before the commit
                if widths.updateValue(width, forKey: key) != width { changed = true }
            }
            guard changed else { return }
            toolbar.needsLayout = true
            toolbar.layoutSubtreeIfNeeded()
        }

        /// The toolbar view lays its items out on its own layout pass; nothing public asks for one. It sits two
        /// levels under the titlebar container, so the search walks the titlebar's siblings of the content view.
        private var toolbarView: NSView? {
            if let cachedToolbar, cachedToolbar.window === window { return cachedToolbar }
            func find(_ v: NSView) -> NSView? {
                if String(describing: type(of: v)) == "NSToolbarView" { return v }
                for s in v.subviews where s !== window?.contentView { if let t = find(s) { return t } }
                return nil
            }
            cachedToolbar = window?.contentView?.superview.flatMap(find)
            return cachedToolbar
        }
    }
}

/// The first table (a SwiftUI List) under a view, depth first.
@MainActor func firstTable(in v: NSView) -> NSTableView? {
    if let t = v as? NSTableView { return t }
    for s in v.subviews { if let t = firstTable(in: s) { return t } }
    return nil
}

extension NSWindow {
    /// Puts the keyboard on the issue list (the window's table), or on nothing when there is none.
    func focusList() { makeFirstResponder(contentView.flatMap(firstTable)) }

    /// A popover hangs from this window. Its Escape arrives tagged with this window on Tahoe and must close it.
    /// Known by its class: macOS 27 hangs a window-sharing button at the traffic lights as a child window of
    /// every window, so "any visible child" was always true.
    var showsPopover: Bool {
        childWindows?.contains { $0.isVisible && NSStringFromClass(type(of: $0)).contains("Popover") } == true
    }
}

/// A closed popover leaves the keyboard on the window's first key view when it had a text field of its own: the
/// search field in the list window, the comment box in an issue window. The list, or nothing, is where it came from.
@MainActor enum PopoverFocusReturn {
    static func install() {
        NotificationCenter.default.addObserver(forName: NSPopover.didCloseNotification, object: nil, queue: .main) {
            _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let w = NSApp.keyWindow, w.firstResponder is NSTextView else { return }
                    w.focusList()
                }
            }
        }
    }
}

extension View {
    /// Marks a value the user can change: it lights up under the pointer, as a field does on the web. Read-only
    /// values stay plain, so the two can be told apart. Off, it changes nothing.
    func editable(_ on: Bool = true) -> some View { modifier(Editable(on: on)) }
}

private struct Editable: ViewModifier {
    let on: Bool
    @State private var hover = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(hover && on ? Color.primary.opacity(0.08) : .clear, in: .rect(cornerRadius: 6))
            .padding(.horizontal, -6).padding(.vertical, -3)  // the highlight draws outside; nothing moves
            .onHover { hover = $0 }
    }
}

/// AppKit swallows the click that dismisses a menu. Here it goes on to whatever it landed on, so a right-click
/// on a project followed by a click on the disclosure beside it needs no third click.
@MainActor enum MenuClickThrough {
    static func install() {
        NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) {
            note in
            // Chip menus hop to the chip under the mouse on their own (ChipMenuController).
            let chip = (note.object as? NSMenu)?.identifier?.rawValue == "chip"
            MainActor.assumeIsolated {
                // Tracking ends on the mouse-up of the click that closed the menu. A click on an item ends
                // over the menu's own window; one outside ends over whatever is under the mouse.
                guard !chip, let e = NSApp.currentEvent, e.type == .leftMouseUp || e.type == .rightMouseUp
                else { return }
                let at = NSEvent.mouseLocation
                let top = NSWindow.windowNumber(at: at, belowWindowWithWindowNumber: 0)
                guard let window = NSApp.window(withWindowNumber: top), !window.className.contains("Menu")
                else { return }
                let down: NSEvent.EventType = e.type == .leftMouseUp ? .leftMouseDown : .rightMouseDown
                let local = window.convertPoint(fromScreen: at)
                DispatchQueue.main.async {
                    for type in [down, e.type] {
                        guard
                            let replay = NSEvent.mouseEvent(
                                with: type, location: local, modifierFlags: e.modifierFlags,
                                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: top, context: nil,
                                eventNumber: 0, clickCount: 1, pressure: 1)
                        else { continue }
                        window.sendEvent(replay)
                    }
                }
            }
        }
    }
}

extension Binding where Value: Sendable {
    /// `Binding($optional)` force-unwraps on every read, and SwiftUI reads a child's bindings once more after
    /// the value went nil (Save sets the draft to nil while the editor is still on screen), which crashed.
    /// This one hands back `fallback` instead.
    init(_ source: Binding<Value?>, or fallback: Value) {
        // Writes after the draft went nil are the field's own echo of its last text; taking them would reopen it.
        self.init(
            get: { source.wrappedValue ?? fallback },
            set: { if source.wrappedValue != nil { source.wrappedValue = $0 } })
    }
}

/// The window toolbar's background, drawn: a blur washed nearly white (black in dark mode) over the toolbar's
/// height, ending at the system's hairline. Shown only while content is under it, as the window's own is.
struct ToolbarBand: View {
    let visible: Bool

    var body: some View {
        GeometryReader { g in
            band.frame(height: g.safeAreaInsets.top).offset(y: -g.safeAreaInsets.top)
        }
        .opacity(visible ? 1 : 0)
        .animation(.easeOut(duration: 0.15), value: visible)
        .allowsHitTesting(false)
    }

    /// The bar material is the titlebar's; the hairline is the one the window draws under its toolbar.
    /// A light blur, dimmed by half, ending at the hairline: what the window draws under its own toolbar, where
    /// the content stays visible through it.
    private var band: some View {
        BackdropBlur(radius: 5)
            .overlay(Color(nsColor: .windowBackgroundColor).opacity(0.5))
            .overlay(alignment: .bottom) { Divider() }
    }

}

/// A plain blur of whatever is behind it, without a material's tint: Core Animation's backdrop layer, which is what
/// the window draws under its own toolbar. Not public API; where the class is missing, the bar material stands in.
struct BackdropBlur: NSViewRepresentable {
    var radius: CGFloat

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        guard let backdrop = NSClassFromString("CABackdropLayer") as? CALayer.Type,
            let filterClass = NSClassFromString("CAFilter") as? NSObject.Type,
            let filter = filterClass.perform(NSSelectorFromString("filterWithType:"), with: "gaussianBlur")?
                .takeUnretainedValue() as? NSObject
        else {
            let e = NSVisualEffectView()
            e.material = .titlebar
            e.blendingMode = .withinWindow
            return e
        }
        filter.setValue(radius, forKey: "inputRadius")
        filter.setValue(true, forKey: "inputNormalizeEdges")
        let layer = backdrop.init()
        layer.filters = [filter]
        layer.setValue(0.5, forKey: "scale")  // blurred anyway: half resolution is half the work
        v.layer = layer
        v.wantsLayer = true
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {}
}

/// The fold chevron at the end of a card's title or a group's row: down while open, sideways while folded.
struct Disclosure: View {
    let collapsed: Bool
    @Environment(\.fold) private var fold
    var body: some View {
        Image(systemName: "chevron.down")
            .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            .rotationEffect(.degrees(collapsed ? -90 : 0))
            .frame(width: 18, height: 18)
            .accessibilityLabel(collapsed ? Text("Expand") : Text("Collapse"))
            .accessibilityAddTraits(.isButton)
            .accessibilityRemoveTraits(.isImage)
            .accessibilityAction { fold() }
    }
}

extension EnvironmentValues {
    /// The nearest `Foldable`'s fold, for its chevron's accessibility press (a click goes to the whole header).
    @Entry var fold: () -> Void = {}
}

/// Which cards and groups are folded, per issue ("CON-12|comments"), kept on this Mac across launches.
enum Folds {
    private static let key = "foldedSections"
    static func load() -> Set<String> { Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }
    static func save(_ folded: Set<String>) {
        // ponytail: an unbounded list in defaults; 1000 folded sections is a few tens of kilobytes.
        UserDefaults.standard.set(Array(folded.prefix(1000)), forKey: key)
    }
}

/// Arrow keys, Page Up and Down (fn-↑↓), Home and End (fn-←→), ⌥/⌘ with the arrows and Space scroll an issue page as
/// they scroll a web page, once the page has the keyboard: in the preview column after a click on the page or → from
/// the list (← goes back to the list), in an issue window whenever no editor has it. Sits behind the page's content.
struct PageKeys: NSViewRepresentable {
    let standalone: Bool
    var reveal: PageReveal?
    func makeNSView(context: Context) -> PageKeyView { PageKeyView() }
    func updateNSView(_ v: PageKeyView, context: Context) {
        v.standalone = standalone
        reveal?.page = v
    }
}

/// Brings what a key acts on into view, with room around it, before the key's action runs: on a long page the target
/// was often off screen, and a popover or editor opening there looked as if the key did nothing. Layout records where
/// each target is (`pageTarget`); a class, so neither that nor scrolling redraws the page.
@MainActor final class PageReveal {
    /// The page's coordinate space, set on the page that `PageKeys` sits behind.
    static let space = "page"
    /// The margin a target keeps from the toolbar and the window's bottom.
    nonisolated static let room: CGFloat = 48
    fileprivate var frames: [AnyHashable: CGRect] = [:]
    fileprivate weak var page: PageKeyView?

    enum Placement {
        /// A row a popover hangs from: centred, which leaves the popover room either way.
        case middle
        /// An editor that opens at the target's top: the page's top when that shows it, else the target's top a margin
        /// under the toolbar. Only its first 320 points need to show.
        case start
    }

    /// Where the page's clip view goes to show `r` (document coordinates, y down), or nil when `r` is in view with room
    /// around it already. `visible` is the clip's bounds; `top` and `bottom` are its insets (the toolbar), so the page's
    /// top is at -top; `page` is the document's height.
    nonisolated static func destination(
        showing r: CGRect, _ placement: Placement, visible: CGRect, top inset: CGFloat, bottom: CGFloat, page: CGFloat
    ) -> CGFloat? {
        var r = r
        if placement == .start { r.size.height = min(r.height, 320) }
        let top = visible.minY + inset
        let height = visible.height - inset - bottom
        if r.minY >= top + room, r.maxY <= top + height - room { return nil }
        var y: CGFloat
        switch placement {
        case .middle where r.height < height - 2 * room: y = r.midY - height / 2 - inset
        case .start where r.maxY <= height - room: y = -inset
        default: y = r.minY - room - inset
        }
        y = min(max(y, -inset), max(-inset, page - visible.height))
        return abs(y - visible.minY) < 1 ? nil : y
    }

    /// Scrolls the first of `targets` that is laid out into view and then runs `action`; runs it at once when that is
    /// in view with room around it already, or none is on the page. A row in a lazy grid is laid out only on screen, so
    /// the grid itself comes after it.
    func reveal(_ targets: [AnyHashable], _ placement: Placement, then action: @escaping @MainActor () -> Void) {
        guard let rect = targets.lazy.compactMap({ self.frames[$0] }).first, let page else { return action() }
        page.reveal(rect, placement, then: action)
    }

    /// The page at its top, in the same frame: see `PageKeyView.toTop`.
    func toTop() { page?.toTop() }
}

extension View {
    /// Records where this sits on the page, for `PageReveal`.
    func pageTarget(_ key: AnyHashable, in reveal: PageReveal) -> some View {
        onGeometryChange(for: CGRect.self) {
            $0.frame(in: .named(PageReveal.space))
        } action: {
            reveal.frames[key] = $0
        }
        .onDisappear { reveal.frames[key] = nil }
    }
}

extension Notification.Name {
    /// Posted by the preview column's page when the keyboard enters or leaves it; `object` is the window.
    static let previewFocus = Notification.Name("previewFocus")
}

final class PageKeyView: NSView {
    var standalone = false
    nonisolated(unsafe) private var monitors: [Any] = []
    private var responderWatch: NSKeyValueObservation?
    private var hadFocus = false

    override var acceptsFirstResponder: Bool { true }
    /// As the page's SwiftUI coordinates: y grows downwards from the page's top.
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        responderWatch = nil
        guard let window else { return }
        // A click on the page's background or its text takes the keyboard from the list, as a click into a web page
        // does; a click on a control or into an editor keeps what that gives it.
        monitors.append(
            NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] e in
                guard let self, let w = self.window, e.window === w, let sv = self.enclosingScrollView,
                    sv.bounds.contains(sv.convert(e.locationInWindow, from: nil))
                else { return e }
                DispatchQueue.main.async {
                    if w.firstResponder is NSTableView || w.firstResponder === w { w.makeFirstResponder(self) }
                }
                return e
            } as Any)
        monitors.append(
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                guard let self, e.window === self.window, self.hasKeyboard, self.handle(e) else { return e }
                return nil
            } as Any)
        // The list greys its selection while the keyboard is in the preview, as Mail's does.
        responderWatch = window.observe(\.firstResponder, options: [.initial, .new]) { [weak self] w, _ in
            MainActor.assumeIsolated {
                // In a window of its own the page takes a keyboard nothing holds (a new window, after Escape or a
                // popover): only a responder in the page reaches its ⌘C, which copies the key.
                if w.firstResponder === w {
                    DispatchQueue.main.async {
                        if let self, self.standalone, self.window === w, w.firstResponder === w {
                            w.makeFirstResponder(self)
                        }
                    }
                }
                guard let self, !self.standalone, let sv = self.enclosingScrollView else { return }
                let on = (w.firstResponder as? NSView).map { $0 === self || $0.isDescendant(of: sv) } ?? false
                guard on != self.hadFocus else { return }
                self.hadFocus = on
                NotificationCenter.default.post(name: .previewFocus, object: w, userInfo: ["on": on])
            }
        }
    }

    deinit { monitors.forEach(NSEvent.removeMonitor) }

    /// The page has the keyboard: this view or the page's selectable text has it, or, in a window of its own,
    /// anything but an editor. An editor, the list and the search field keep their arrows.
    private var hasKeyboard: Bool {
        guard let w = window, w.isKeyWindow, let sv = enclosingScrollView else { return false }
        let fr = w.firstResponder
        if fr === self { return true }
        // A description or comment being read is the page's; one being written keeps its arrows.
        if (fr as? NSTextView)?.isEditable == true || fr is NSTableView { return false }
        if let v = fr as? NSView, v.isDescendant(of: sv) { return true }
        return standalone
    }

    /// The page's top at the toolbar's inset, where it rests, in the update that shows the next issue: no frame of it
    /// at the last one's scroll position, as `ScrollViewProxy.scrollTo` left.
    func toTop() {
        guard let sv = enclosingScrollView else { return }
        let clip = sv.contentView
        let y = -sv.contentInsets.top
        guard abs(clip.bounds.minY - y) >= 0.5 else { return }
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.minX, y: y))
        sv.reflectScrolledClipView(clip)
    }

    /// `rect` is in the page's coordinates. See `PageReveal`.
    func reveal(_ rect: CGRect, _ placement: PageReveal.Placement, then action: @escaping @MainActor () -> Void) {
        guard let sv = enclosingScrollView, let doc = sv.documentView,
            let y = PageReveal.destination(
                showing: convert(rect, to: doc), placement, visible: sv.contentView.bounds, top: sv.contentInsets.top,
                bottom: sv.contentInsets.bottom, page: doc.frame.height)
        else { return action() }
        let clip = sv.contentView
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            clip.animator().setBoundsOrigin(NSPoint(x: clip.bounds.minX, y: y))
        } completionHandler: {
            MainActor.assumeIsolated {
                action()
            }
        }
        sv.reflectScrolledClipView(clip)
    }

    private func handle(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .option, .shift, .control])
        // ← in the preview (→ right to left) hands the keyboard back to the list beside it.
        let towardList: UInt16 = NSApp.userInterfaceLayoutDirection == .rightToLeft ? 124 : 123
        if !standalone, mods.isEmpty, e.keyCode == towardList, let w = window {
            w.focusList()
            return true
        }
        guard let sv = enclosingScrollView else { return false }
        return sv.scrollAnimated(for: e, line: 96, arrows: true)
    }
}

extension NSScrollView {
    /// Scrolls for a key as a web page does, animated: ↑↓ by `line` (when `arrows`), ⌥↑↓, Page Up/Down and Space by a
    /// screen, ⌘↑↓, Home and End to the ends. False for any other key.
    func scrollAnimated(for e: NSEvent, line: CGFloat, arrows: Bool) -> Bool {
        guard let doc = documentView else { return false }
        let clip = contentView
        let mods = e.modifierFlags.intersection([.command, .option, .shift, .control])
        let page = max(40, clip.bounds.height - contentInsets.top - 48)
        let top = -contentInsets.top
        let bottom = doc.frame.height - clip.bounds.height
        let y = clip.bounds.origin.y
        let target: CGFloat
        switch (e.keyCode, mods) {
        case (125, []) where arrows: target = y + line  // ↓
        case (126, []) where arrows: target = y - line  // ↑
        case (125, .option) where arrows, (121, []),
            (49, []) where arrows:
            target = y + page  // ⌥↓, page down, space
        case (126, .option) where arrows, (116, []),
            (49, .shift) where arrows:
            target = y - page  // ⌥↑, page up, ⇧space
        case (125, .command) where arrows, (119, []): target = bottom  // ⌘↓, end
        case (126, .command) where arrows, (115, []): target = top  // ⌘↑, home
        default: return false
        }
        glide(to: target)
        return true
    }

    /// Scrolls to `y`, kept within the document, over 0.2 s or at once; a call while one runs takes it on from where it
    /// is. `then` runs where it lands.
    func glide(to y: CGFloat, animated: Bool = true, then: (@MainActor () -> Void)? = nil) {
        guard let doc = documentView else { return }
        let clip = contentView
        let top = -contentInsets.top
        // SwiftUI's scroll views and tables are flipped: y grows downwards.
        let to = NSPoint(x: clip.bounds.origin.x, y: min(max(y, top), max(top, doc.frame.height - clip.bounds.height)))
        // From afar (End on a list of thousands), a glide set up and drew a screen of other rows every frame: it starts
        // a screen short of where it lands.
        let far = to.y - clip.bounds.origin.y
        if animated, abs(far) > 2 * clip.bounds.height {
            clip.scroll(to: NSPoint(x: to.x, y: to.y - (far > 0 ? clip.bounds.height : -clip.bounds.height)))
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = animated ? 0.2 : 0
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = true
            clip.animator().setBoundsOrigin(to)
        } completionHandler: {
            MainActor.assumeIsolated { then?() }
        }
        reflectScrolledClipView(clip)
    }

    /// Scrolls the least that shows `rect()`, in the clip view's coordinates, with `room` to spare above and below it;
    /// nil stops. A table gives rows it has not laid out yet an estimated height, so where the scroll lands it looks
    /// again: on a list just loaded, rows a few steps past the edge counted 24 points high and the glide fell short.
    func reveal(_ rect: @escaping @MainActor () -> NSRect?, room: CGFloat, animated: Bool, tries: Int = 3) {
        guard tries > 0, let r = rect()?.insetBy(dx: 0, dy: -room) else { return }
        let clip = contentView.bounds
        let y: CGFloat
        if r.minY < clip.minY + contentInsets.top {
            y = r.minY - contentInsets.top
        } else if r.maxY > clip.maxY - contentInsets.bottom {
            y = r.maxY - clip.height + contentInsets.bottom
        } else {
            return
        }
        glide(to: y, animated: animated) { self.reveal(rect, room: room, animated: animated, tries: tries - 1) }
    }
}

extension NSWindow {
    /// Puts the keyboard on the preview column's page, as → from the list does.
    func focusPreviewPage() -> Bool {
        func find(_ v: NSView) -> PageKeyView? {
            if let p = v as? PageKeyView, !p.standalone { return p }
            for s in v.subviews { if let p = find(s) { return p } }
            return nil
        }
        guard let page = contentView.flatMap(find) else { return false }
        return makeFirstResponder(page)
    }
}
