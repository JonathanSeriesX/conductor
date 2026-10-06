import AppKit
import CoreSpotlight
import CryptoKit
import ImageIO

/// Last-known copies of what the UI shows, so launch and navigation are instant and the network only refreshes.
/// One folder per account; lists are keyed by a hash of their JQL. ponytail: JSON files, no eviction; add an age sweep if it ever matters.
enum DiskCache {
    private static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "Conductor/cache", directoryHint: .isDirectory)
    }()

    private static func file(_ account: Account, _ name: String) -> URL {
        let folder = root.appending(path: safe("\(account.site.host() ?? "site")|\(account.email)"), directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: safe(name) + ".json")
    }

    private static func safe(_ s: String) -> String {
        s.count > 80 ? hash(s) : s.map { $0.isLetter || $0.isNumber || "-_.@|".contains($0) ? String($0) : "_" }.joined()
    }

    static func hash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
    }

    static func load<T: Decodable>(_ type: T.Type = T.self, account: Account, name: String) -> T? {
        guard let data = try? Data(contentsOf: file(account, name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Same as `load`, but the read and decode happen off the main thread.
    static func loadAsync<T: Decodable & Sendable>(_ type: T.Type = T.self, account: Account, name: String) async -> T? {
        await Task.detached(priority: .userInitiated) { load(T.self, account: account, name: name) }.value
    }

    static func save(_ value: some Encodable, account: Account, name: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: file(account, name), options: .atomic)
    }

    /// Encodes and writes in the background; a cache never needs to wait for the disk.
    static func saveAsync(_ value: some Encodable & Sendable, account: Account, name: String) {
        Task.detached(priority: .utility) { save(value, account: account, name: name) }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: imageRoot)
        CSSearchableIndex.default().deleteAllSearchableItems()
    }

    // MARK: Images

    private static let imageRoot: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appending(path: "Conductor/images", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func imageData(for url: URL) async -> Data? {
        let file = imageRoot.appending(path: hash(url.absoluteString))
        return await Task.detached(priority: .userInitiated) { try? Data(contentsOf: file) }.value
    }

    static func saveImage(_ data: Data, for url: URL) {
        let file = imageRoot.appending(path: hash(url.absoluteString))
        Task.detached(priority: .utility) { try? data.write(to: file, options: .atomic) }
    }

    /// Decodes off the main thread; big attachments are shrunk so scrolling a description stays smooth.
    static func decodeImage(_ data: Data, maxPixels: Int = 1600) async -> NSImage? {
        await Task.detached(priority: .userInitiated) { () -> NSImage? in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return NSImage(data: data) }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                                            kCGImageSourceCreateThumbnailWithTransform: true]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return NSImage(data: data) }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value
    }
}

/// Spotlight knows every issue the app has seen: search "ES-123" or a summary from anywhere and land in Conductor.
enum Spotlight {
    static func index(_ issues: [Issue], host: String) {
        guard !issues.isEmpty else { return }
        let items = issues.map { issue -> CSSearchableItem in
            let a = CSSearchableItemAttributeSet(contentType: .text)
            a.title = "\(issue.key)  \(issue.fields.summary)"
            a.contentDescription = [issue.fields.status.name, issue.fields.assignee?.displayName, issue.fields.project?.name].compactMap { $0 }.joined(separator: " · ")
            a.keywords = [issue.key, issue.fields.project?.key ?? "", issue.fields.issuetype.name]
            a.identifier = issue.key
            let item = CSSearchableItem(uniqueIdentifier: "\(host)|\(issue.key)", domainIdentifier: host, attributeSet: a)
            item.expirationDate = .distantFuture
            return item
        }
        CSSearchableIndex.default().indexSearchableItems(items)
    }

    static func forget(host: String) {
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [host])
    }
}
