import Foundation
import CoreSpotlight
import CryptoKit

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

    static func save(_ value: some Encodable, account: Account, name: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: file(account, name), options: .atomic)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: root)
        CSSearchableIndex.default().deleteAllSearchableItems()
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
