import CoreServices
import Quartz
import SwiftUI
import UniformTypeIdentifiers

struct AttachmentTile: View {
    let attachment: Attachment
    var onPreview: (URL) -> Void
    @Environment(Session.self) private var session
    @State private var busy = false
    private var client: JiraClient? { session.client(for: attachment.content) }

    var body: some View {
        Button(action: preview) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    if attachment.thumbnail != nil {
                        // Behind a clear colour, so a wide thumbnail cannot widen the tile into its neighbour.
                        Color.clear.overlay { RemoteImage(url: attachment.thumbnail, fit: true) }.clipped()
                    } else {
                        Image(systemName: icon).font(.title).foregroundStyle(.secondary)
                    }
                    if busy { ProgressView().controlSize(.small) }
                }
                .frame(height: 90)
                .frame(maxWidth: .infinity)
                .background(.quaternary.opacity(0.4))
                .clipShape(.rect(cornerRadius: 10))
                Text(attachment.filename).font(.caption).lineLimit(1).truncationMode(.middle)
                Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("\(attachment.filename) — click to preview")
        // ponytail: a hover fetches files under 25 MB so a drag out has the file; a bigger one only drags once
        // it was previewed, opened or copied.
        .onHover { inside in
            guard inside, attachment.size < 25_000_000, let client else { return }
            Task { _ = await AttachmentOpener.download(attachment, client: client) }
        }
        .onDrag { AttachmentOpener.dragItem(attachment) ?? NSItemProvider() }
    }

    private var icon: String {
        let mime = attachment.mimeType ?? ""
        if mime.hasPrefix("image/") { return "photo" }
        if mime.hasPrefix("video/") { return "film" }
        if mime.contains("zip") { return "doc.zipper" }
        if mime.contains("pdf") { return "doc.richtext" }
        return "doc"
    }

    private func preview() {
        guard let client, !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            if let url = await AttachmentOpener.download(attachment, client: client) { onPreview(url) }
        }
    }
}

enum AttachmentOpener {
    private static func file(for attachment: Attachment) -> URL {
        // The name is Jira's: its last component alone, so it cannot reach outside the attachment's own folder.
        let name = (attachment.filename as NSString).lastPathComponent.replacingOccurrences(of: "/", with: "_")
        return FileManager.default.temporaryDirectory.appending(path: "attachments/\(attachment.id)/\(name)")
    }

    private static func store(_ data: Data, for attachment: Attachment) -> URL {
        let file = file(for: attachment)
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file)
        quarantine(file)
        return file
    }

    /// Marks the bytes as downloaded, as a browser does, so Gatekeeper checks a script or an app before it runs.
    private static func quarantine(_ file: URL) {
        var file = file
        var values = URLResourceValues()
        values.quarantineProperties = [kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String]
        try? file.setResourceValues(values)
    }

    /// Downloads with auth into the app's temp folder; the same file is reused on later calls.
    static func download(_ attachment: Attachment, client: JiraClient) async -> URL? {
        let file = file(for: attachment)
        if FileManager.default.fileExists(atPath: file.path) { return file }
        // An inline image already has its bytes in the image cache; reuse them instead of fetching again.
        var data = await DiskCache.imageData(for: attachment.content)
        if data == nil { data = try? await client.data(for: attachment.content) }
        guard let data else { return nil }
        return store(data, for: attachment)
    }

    static func open(_ attachment: Attachment, client: JiraClient) async {
        if let file = await download(attachment, client: client) { NSWorkspace.shared.open(file) }
    }

    /// A save panel, then the bytes to where it says; a failed write is said in an alert.
    @MainActor static func saveAs(_ attachment: Attachment, client: JiraClient) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = attachment.filename
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        Task {
            do {
                try await client.data(for: attachment.content).write(to: dest)
                quarantine(dest)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    static func type(_ attachment: Attachment) -> UTType {
        UTType(mimeType: attachment.mimeType ?? "")
            ?? UTType(filenameExtension: (attachment.filename as NSString).pathExtension) ?? .data
    }

    /// For a drag out of the app: the file, once it is here (downloaded, or shown inline from the image cache).
    /// SwiftUI turns a provider's file into a promise only when the file exists, so a tile fetches on hover.
    static func dragItem(_ attachment: Attachment) -> NSItemProvider? {
        var file = file(for: attachment)
        if !FileManager.default.fileExists(atPath: file.path) {
            guard let data = DiskCache.imageDataNow(for: attachment.content) else { return nil }
            file = store(data, for: attachment)
        }
        let p = NSItemProvider(contentsOf: file)
        p?.suggestedName = attachment.filename
        return p
    }

    /// The file onto the pasteboard, and a picture's bytes beside it: Finder pastes the file, an editor the picture.
    @MainActor static func copy(file: URL) {
        let item = NSPasteboardItem()
        item.setString(file.absoluteString, forType: .fileURL)
        if let type = UTType(filenameExtension: file.pathExtension), type.conforms(to: .image),
            let data = try? Data(contentsOf: file)
        {
            item.setData(data, forType: NSPasteboard.PasteboardType(type.identifier))
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
    }

    static func copy(_ attachment: Attachment, client: JiraClient) async {
        if let file = await download(attachment, client: client) { await copy(file: file) }
    }

    /// ⌘C while a Quick Look panel is up copies what it shows: the panel takes the keys, and nothing behind it
    /// knows what is on view.
    static func installQuickLookCopy() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            guard e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                e.charactersIgnoringModifiers == "c"
            else { return e }
            let copied = MainActor.assumeIsolated {  // delivered on the main thread
                guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(),
                    panel.isKeyWindow, let url = panel.currentPreviewItem?.previewItemURL
                else { return false }
                copy(file: url)
                return true
            }
            return copied ? nil : e
        }
    }
}

/// A file promised to the drop target: the attachment downloads as it lands. Its own delegate, so the session
/// keeps it alive.
final class AttachmentPromise: NSFilePromiseProvider, NSFilePromiseProviderDelegate {
    private let attachment: Attachment
    private let client: JiraClient

    init(_ attachment: Attachment, client: JiraClient) {
        self.attachment = attachment
        self.client = client
        super.init()
        fileType = AttachmentOpener.type(attachment).identifier
        delegate = self
    }

    func filePromiseProvider(_ p: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        attachment.filename
    }

    func filePromiseProvider(
        _ p: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void
    ) {
        nonisolated(unsafe) let done = completionHandler
        let attachment = attachment
        let client = client
        Task {
            guard let file = await AttachmentOpener.download(attachment, client: client) else {
                return done(CocoaError(.fileNoSuchFile))
            }
            do {
                try FileManager.default.copyItem(at: file, to: url)
                done(nil)
            } catch {
                done(error)
            }
        }
    }
}
