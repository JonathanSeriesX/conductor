import Foundation

// MARK: - Atlassian Document Format model

enum JSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        // Strings first: ADF attributes are mostly strings, and every failed attempt throws.
        if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else {
            self = .object(try c.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }
    var number: Double? {
        if case .number(let n) = self { return n }
        return nil
    }
    var bool: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }
}

struct ADFMark: Codable, Hashable, Sendable {
    let type: String
    let attrs: [String: JSONValue]?
}

struct ADFNode: Codable, Hashable, Sendable {
    var type: String
    var version: Int?
    var text: String?
    var attrs: [String: JSONValue]?
    var marks: [ADFMark]?
    var content: [ADFNode]?

    func attr(_ k: String) -> String? { attrs?[k]?.string }

    /// The task item with this localId flipped between done and to do.
    mutating func flipTask(_ id: String) {
        if type == "taskItem", attr("localId") == id {
            let done = attr("state") == "DONE"
            attrs?["state"] = .string(done ? "TODO" : "DONE")
        } else {
            for i in (content ?? []).indices { content?[i].flipTask(id) }
        }
    }

    /// Jira Server sends a description or comment as wiki-markup text, not a document.
    init(from decoder: Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            self = .document(wiki: s)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        version = try c.decodeIfPresent(Int.self, forKey: .version)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        attrs = try c.decodeIfPresent([String: JSONValue].self, forKey: .attrs)
        marks = try c.decodeIfPresent([ADFMark].self, forKey: .marks)
        content = try c.decodeIfPresent([ADFNode].self, forKey: .content)
    }

    init(
        type: String, version: Int? = nil, text: String? = nil, attrs: [String: JSONValue]? = nil,
        marks: [ADFMark]? = nil, content: [ADFNode]? = nil
    ) {
        self.type = type
        self.version = version
        self.text = text
        self.attrs = attrs
        self.marks = marks
        self.content = content
    }

    var plainText: String {
        if let text { return text }
        return (content ?? []).map(\.plainText).joined(separator: type == "paragraph" ? "" : "\n")
    }
}
