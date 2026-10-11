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

@MainActor enum ImageCache {
    static let shared = NSCache<NSURL, NSImage>()
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
        guard let data = DiskCache.imageDataNow(for: url), let img = NSImage(data: data) else { return nil }
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
            guard let client = session.client(for: url), let data = try? await client.data(for: url),
                let img = await DiskCache.decodeImage(data, maxPixels: 256)
            else { return }
            DiskCache.saveImage(data, for: url)
            ImageCache.shared.setObject(img, forKey: url as NSURL)
            loaded = img
        }
    }
}

struct Avatar: View {
    let user: JiraUser?
    var size: CGFloat = 22
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        Group {
            if let user {
                RemoteImage(url: user.avatar, placeholder: "person.crop.circle.fill")
            } else {
                Image(systemName: "person.crop.circle.badge.questionmark").resizable().scaledToFit().foregroundStyle(
                    .tertiary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        // A ring on a selected row, so an orange avatar still reads on the orange selection.
        .overlay { if prominence == .increased { Circle().stroke(.white.opacity(0.9), lineWidth: 1.5) } }
        .help(user?.displayName ?? String(localized: "Unassigned"))
        .accessibilityLabel(user?.displayName ?? String(localized: "Unassigned"))
    }
}

extension View {
    /// Greys a coloured element while its window is inactive, as the system does with sidebar icons and the
    /// selection. Text stays as it is; pills, badges and every remote image (icons, avatars) lose their colour.
    func inactiveDim() -> some View { modifier(InactiveDim()) }
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
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        RemoteImage(url: priority.iconUrl, placeholder: "minus")
            .accessibilityLabel(priority.name)
            .frame(width: size, height: size)
            .padding(2)  // constant so the glyph does not shift when the disc appears
            .background(prominence == .increased ? .white.opacity(0.9) : .clear, in: .circle)
            .help(priority.name)
    }
}

struct GlassCard<Content: View>: View {
    var title: LocalizedStringKey?
    /// "• 1d 7h logged", in the title's weight, after it: a figure that belongs to the title.
    var detail: String?
    /// A control after the detail, in the hint's size: "• newest first ↓".
    var accessory: AnyView?
    /// "• M to add", faint, after the title: the key that acts on the card.
    var hint: String?
    /// Set for a card that folds away: a chevron at the title's trailing end, and a click on the title, fold it.
    var collapsed: Binding<Bool>?
    @ViewBuilder var content: Content
    /// The content's height while it folds or unfolds: from what is on screen to nothing, or back. Nil at rest.
    @State private var clip: CGFloat?
    /// Read only when the card folds, so kept where SwiftUI does not watch: as state, the window's edge changed on
    /// every frame of a scroll and re-rendered every card, a 250-comment thread included, each time.
    @State private var measured = Measured()
    private final class Measured {
        /// The content's own height, the title's, and the window's bottom edge from the card's top.
        var content: CGFloat = 0
        var header: CGFloat = 0
        var visibleBottom: CGFloat = .infinity
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                // The gap before the bullet equals the space after it.
                // One line in a narrow column: the title, the figure and the control stay whole, the key hint
                // gives way first.
                HStack(spacing: 3) {
                    Text(title).font(.headline).foregroundStyle(.secondary).fixedSize()
                    if let detail { Text(verbatim: detail).font(.headline).foregroundStyle(.secondary).fixedSize() }
                    if let accessory { accessory.fixedSize() }
                    if let hint { Text(hint).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
                    if let collapsed {
                        Spacer(minLength: 8)
                        Disclosure(collapsed: collapsed.wrappedValue)
                    }
                }
                .contentShape(.rect)
                .onTapGesture { fold() }
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.height
                } action: {
                    measured.header = $0
                }
            }
            if collapsed?.wrappedValue != true || clip != nil {
                // The gap under the title folds with the content, so nothing changes size once the fold is over.
                // Its own stack, as the card's was: several views in `content` sit 12 apart, leading. Its own glass
                // container too: glass (the composer's Comment button) is drawn by the nearest one, and the page's
                // ignored this clip and opacity, so the button hung below the card while it folded.
                GlassGroup(spacing: 0) { VStack(alignment: .leading, spacing: 12) { content } }
                    .padding(.top, title == nil ? 0 : 12)
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
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frosted(cornerRadius: 20)
        .onGeometryChange(for: CGFloat.self) {
            $0.bounds(of: .scrollView)?.maxY ?? .infinity
        } action: {
            measured.visibleBottom = $0
        }
    }

    /// Folds or unfolds over what is on screen only. Animated over its whole height, a long thread (thousands of
    /// points) spent the animation below the window's edge and showed only its last few frames, as a jump.
    private func fold() {
        guard let collapsed else { return }
        // How much of the content the window shows: the rest changes unseen.
        let m = measured
        let onScreen = { max(0, min(m.content, m.visibleBottom - 18 - m.header)) }
        var still = Transaction()
        still.disablesAnimations = true
        if collapsed.wrappedValue {
            withTransaction(still) { clip = 0 }
            collapsed.wrappedValue = false
            // A turn later the content is laid out, so its height is known.
            Task { @MainActor in
                withAnimation(.snappy(duration: 0.25)) {
                    clip = onScreen()
                } completion: {
                    withTransaction(still) { clip = nil }
                }
            }
        } else {
            withTransaction(still) { clip = onScreen() }
            Task { @MainActor in
                collapsed.wrappedValue = true
                withAnimation(.snappy(duration: 0.25)) {
                    clip = 0
                } completion: {
                    withTransaction(still) { clip = nil }
                }
            }
        }
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
    VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 2) {
            Text(name).textCase(.uppercase).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            if let hint { Text(hint).font(.caption2).foregroundStyle(.secondary) }  // "• A or ⇧⌘A to assign"
        }
        value()
    }
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
        private var monitor: Any?

        init(mask: NSEvent.EventTypeMask) {
            self.mask = mask
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

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

/// A reader's right-click on selectable text: with a selection, a menu with Copy alone; without one, nothing.
/// SwiftUI's selectable text would otherwise hand the click to the system's text menu (Cut, Paste, Font,
/// Spelling…, drawn out of process), which an app can neither trim nor replace with `.contextMenu`. So the click
/// is taken first: this view sits under the text and marks its area for the monitor `ReaderMenus.install`.
struct ReaderMenu: NSViewRepresentable {
    func makeNSView(context: Context) -> ReaderMenuArea { ReaderMenuArea() }
    func updateNSView(_ view: ReaderMenuArea, context: Context) {}
}

final class ReaderMenuArea: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }  // the text above takes every click
}

@MainActor enum ReaderMenus {
    static func install() {
        NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { e in
            guard let w = e.window, let root = w.contentView else { return e }
            let at = root.convert(e.locationInWindow, from: nil)
            // Only marked text: editors (the composer, a summary or comment being edited) are never marked, so
            // they keep their own menu. SwiftUI's selectable text is a text view that calls itself editable too,
            // so that cannot tell them apart.
            guard let area = areas(in: root).last(where: { $0.convert($0.bounds, to: root).contains(at) }) else {
                return e
            }
            // A selection in this text: SwiftUI's text interaction view holds it and has the keyboard, and says
            // whether Copy has anything to copy, as it does for the Edit menu. Anything else: no menu.
            let rect = area.convert(area.bounds, to: root)
            let copy = NSMenuItem(
                title: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "")
            if let holder = w.firstResponder as? NSView, holder.convert(holder.bounds, to: root).intersects(rect),
                holder.responds(to: #selector(NSText.copy(_:))),
                (holder as? NSMenuItemValidation)?.validateMenuItem(copy)
                    ?? (holder as? NSUserInterfaceValidations)?.validateUserInterfaceItem(copy) ?? true
            {
                copy.target = holder
                let menu = NSMenu()
                menu.autoenablesItems = false  // validation would look for a target from the area, and grey it
                menu.addItem(copy)
                NSMenu.popUpContextMenu(menu, with: e, for: area)
            }
            return nil
        }
    }

    /// Every marked area in the window, outermost first, so the innermost one under the pointer wins.
    private static func areas(in view: NSView) -> [ReaderMenuArea] {
        guard !view.isHidden else { return [] }
        var out: [ReaderMenuArea] = []
        if let a = view as? ReaderMenuArea { out.append(a) }
        for sub in view.subviews { out += areas(in: sub) }
        return out
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
    var body: some View {
        Image(systemName: "chevron.down")
            .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            .rotationEffect(.degrees(collapsed ? -90 : 0))
            .frame(width: 18, height: 18)
            .accessibilityLabel(collapsed ? Text("Expand") : Text("Collapse"))
    }
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
    func makeNSView(context: Context) -> PageKeyView { PageKeyView() }
    func updateNSView(_ v: PageKeyView, context: Context) { v.standalone = standalone }
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
        responderWatch = window.observe(\.firstResponder, options: [.new]) { [weak self] w, _ in
            MainActor.assumeIsolated {
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
        if fr is NSTextView || fr is NSTableView { return false }
        if let v = fr as? NSView, v.isDescendant(of: sv) { return true }
        return standalone
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
        // SwiftUI's scroll views and tables are flipped: y grows downwards.
        let to = NSPoint(x: clip.bounds.origin.x, y: min(max(target, top), max(top, bottom)))
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = true
            clip.animator().setBoundsOrigin(to)
        }
        reflectScrolledClipView(clip)
        return true
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
