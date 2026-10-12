import Foundation

// Jira Server / Data Center keeps descriptions, comments and work-log notes as wiki markup where Cloud keeps ADF.
// Read, the markup becomes the same document the Cloud path renders; written, a document goes back as markup.
// What it covers: headings, lists (nested, mixed), {code}/{noformat}, {quote}/bq., {panel}, ----, tables, images,
// *bold* _italic_ -strike- +underline+ {{monospace}} ^sup^ ~sub~ ??cite??, {color}, links, mentions, \\ breaks.

extension ADFNode {
    /// Wiki markup → ADF.
    static func document(wiki: String) -> ADFNode {
        let lines = wiki.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        return ADFNode(type: "doc", version: 1, content: WikiParser.blocks(lines[...]))
    }

    /// ADF → wiki markup, for a description, comment or work-log note sent to Jira Server.
    var wiki: String {
        (content ?? []).compactMap { $0.wikiBlock(prefix: "") }.joined(separator: "\n\n")
    }

    private func wikiBlock(prefix: String) -> String? {
        switch type {
        case "paragraph":
            return wikiInline(lineStart: true)
        case "heading":
            return "h\(max(1, min(6, Int(attrs?["level"]?.number ?? 1)))). " + wikiInline(lineStart: false)
        case "bulletList", "orderedList", "taskList":
            let marker = type == "orderedList" ? "#" : "*"
            return (content ?? []).map { item -> String in
                let p = prefix + marker
                if item.type == "taskItem" {
                    return p + (item.attr("state") == "DONE" ? " \\[x\\] " : " \\[ \\] ")
                        + item.wikiInline(lineStart: false)
                }
                var lines: [String] = []
                var text: [String] = []
                for child in item.content ?? [] {
                    if ["bulletList", "orderedList", "taskList"].contains(child.type) {
                        if let nested = child.wikiBlock(prefix: p) { lines.append(nested) }
                    } else if let t = child.wikiBlock(prefix: "") {
                        text.append(t.replacingOccurrences(of: "\n", with: " \\\\ "))
                    }
                }
                return ([p + " " + text.joined(separator: " \\\\ ")] + lines).joined(separator: "\n")
            }.joined(separator: "\n")
        case "codeBlock":
            let lang = attr("language").map { ":" + $0 } ?? ""
            let tag = lang.isEmpty ? "{noformat}" : "{code\(lang)}"
            return tag + "\n" + plainText + "\n" + (lang.isEmpty ? "{noformat}" : "{code}")
        case "blockquote":
            return "{quote}\n" + ADFNode(type: "doc", content: content).wiki + "\n{quote}"
        case "panel", "expand", "nestedExpand":
            let title = attr("title").map { ":title=" + $0 } ?? ""
            return "{panel\(title)}\n" + ADFNode(type: "doc", content: content).wiki + "\n{panel}"
        case "rule":
            return "----"
        case "table":
            return (content ?? []).map { row in
                (row.content ?? []).map { cell in
                    let sep = cell.type == "tableHeader" ? "||" : "|"
                    let text = (cell.content ?? []).compactMap { $0.wikiBlock(prefix: "") }.joined(separator: " \\\\ ")
                    return sep + (text.isEmpty ? " " : text.replacingOccurrences(of: "\n", with: " \\\\ "))
                }.joined() + ((row.content?.last?.type == "tableHeader") ? "||" : "|")
            }.joined(separator: "\n")
        case "mediaSingle", "mediaGroup":
            return (content ?? []).compactMap { $0.attr("alt").map { "!\($0)!" } }.joined(separator: " ")
        case "layoutSection", "layoutColumn", "doc":
            return ADFNode(type: "doc", content: content).wiki
        default:
            if let content, content.contains(where: { $0.type != "text" && !Self.inlineTypes.contains($0.type) }) {
                return ADFNode(type: "doc", content: content).wiki
            }
            return wikiInline(lineStart: true)
        }
    }

    /// Usernames of the people a Server document mentions.
    var mentionIDs: Set<String> {
        var ids = Set((content ?? []).flatMap(\.mentionIDs))
        if type == "mention", let id = attr("id") { ids.insert(id) }
        return ids
    }

    /// Mentions read from markup show "@username"; this puts the person's name there instead.
    func namingMentions(_ names: [String: String]) -> ADFNode {
        var n = self
        if type == "mention", let id = attr("id"), let name = names[id], attr("text") == "@" + id {
            n.attrs?["text"] = .string("@" + name)
        }
        n.content = content?.map { $0.namingMentions(names) }
        return n
    }

    private static let inlineTypes: Set<String> = [
        "text", "hardBreak", "mention", "emoji", "inlineCard", "status", "date", "mediaInline",
    ]

    private func wikiInline(lineStart: Bool) -> String {
        var out = ""
        for n in content ?? [] {
            let atStart = lineStart && (out.isEmpty || out.hasSuffix("\n"))
            switch n.type {
            case "text":
                let marks = n.marks ?? []
                // Monospace takes the text as typed; every other mark wraps what is already there.
                var t =
                    marks.contains { $0.type == "code" }
                    ? "{{\(n.text ?? "")}}" : WikiParser.escape(n.text ?? "", lineStart: atStart)
                var link: String?
                for m in marks {
                    switch m.type {
                    case "strong": t = "*\(t)*"
                    case "em": t = "_\(t)_"
                    case "strike": t = "-\(t)-"
                    case "underline": t = "+\(t)+"
                    case "subsup": t = m.attrs?["type"]?.string == "sub" ? "~\(t)~" : "^\(t)^"
                    case "textColor": if let c = m.attrs?["color"]?.string { t = "{color:\(c)}\(t){color}" }
                    case "link": link = m.attrs?["href"]?.string
                    default: break
                    }
                }
                if let link { t = link == n.text ? "[\(link)]" : "[\(t)|\(link)]" }
                out += t
            case "hardBreak": out += "\n"
            case "mention": out += "[~\(n.attr("id") ?? "")]"
            case "inlineCard": out += n.attr("url").map { "[\($0)]" } ?? ""
            case "emoji": out += n.attr("text") ?? n.attr("shortName") ?? ""
            case "status": out += WikiParser.escape(n.attr("text") ?? "", lineStart: false)
            case "date":
                if let ms = n.attrs?["timestamp"]?.string.flatMap(Double.init) {
                    out += Date(timeIntervalSince1970: ms / 1000).formatted(date: .abbreviated, time: .omitted)
                }
            case "mediaInline": out += n.attr("alt").map { "!\($0)!" } ?? ""
            default: out += n.wikiInline(lineStart: atStart)
            }
        }
        return out
    }
}

private enum WikiParser {
    // MARK: Blocks

    static func blocks(_ lines: ArraySlice<String>) -> [ADFNode] {
        var out: [ADFNode] = []
        var paragraph: [String] = []
        var i = lines.startIndex

        func flush() {
            guard !paragraph.isEmpty else { return }
            out += paragraphs(paragraph)
            paragraph = []
        }

        while i < lines.endIndex {
            let line = lines[i]
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty {
                flush()
                i += 1
                continue
            }
            // {code}, {noformat}, {quote} and {panel} run to their closing tag, which may share a line with them.
            if let m = t.firstMatch(of: /^\{(code|noformat|quote|panel)(?::([^}]*))?\}(.*)$/) {
                flush()
                let tag = String(m.1)
                var body: [String] = []
                var rest = String(m.3)
                var j = i
                while true {
                    if let r = rest.range(of: "{\(tag)}") {
                        body.append(String(rest[..<r.lowerBound]))
                        let after = String(rest[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                        j += 1
                        if !after.isEmpty { paragraph.append(after) }
                        break
                    }
                    body.append(rest)
                    j += 1
                    guard j < lines.endIndex else { break }
                    rest = lines[j]
                }
                i = j
                // The opening line's remainder is empty for a tag on a line of its own; so is the closing line's start.
                if body.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { body.removeFirst() }
                if body.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { body.removeLast() }
                let params = m.2.map(String.init) ?? ""
                switch tag {
                case "code", "noformat":
                    let lang = tag == "code" ? language(params) : nil
                    out.append(
                        ADFNode(
                            type: "codeBlock", attrs: lang.map { ["language": .string($0)] },
                            content: body.isEmpty ? [] : [ADFNode(type: "text", text: body.joined(separator: "\n"))]))
                case "quote":
                    out.append(ADFNode(type: "blockquote", content: blocks(body[...])))
                default:
                    var inner = blocks(body[...])
                    if let title = parameters(params)["title"], !title.isEmpty {
                        inner.insert(
                            ADFNode(
                                type: "paragraph",
                                content: [
                                    ADFNode(type: "text", text: title, marks: [ADFMark(type: "strong", attrs: nil)])
                                ]
                            ), at: 0)
                    }
                    out.append(ADFNode(type: "panel", attrs: ["panelType": .string("info")], content: inner))
                }
                continue
            }
            if let m = t.firstMatch(of: /^h([1-6])\.\s*(.*)$/) {
                flush()
                out.append(
                    ADFNode(type: "heading", attrs: ["level": .number(Double(Int(m.1)!))], content: inline(String(m.2)))
                )
                i += 1
                continue
            }
            if let m = t.firstMatch(of: /^bq\.\s*(.*)$/) {
                flush()
                out.append(ADFNode(type: "blockquote", content: paragraphs([String(m.1)])))
                i += 1
                continue
            }
            if t.firstMatch(of: /^-{4,}$/) != nil {
                flush()
                out.append(ADFNode(type: "rule"))
                i += 1
                continue
            }
            if t.hasPrefix("|") {
                flush()
                var rows: [ADFNode] = []
                while i < lines.endIndex, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(row(lines[i].trimmingCharacters(in: .whitespaces)))
                    i += 1
                }
                out.append(
                    ADFNode(
                        type: "table", attrs: ["isNumberColumnEnabled": .bool(false), "layout": .string("default")],
                        content: rows))
                continue
            }
            if listMarker(t) != nil {
                flush()
                var items: [(String, String)] = []
                while i < lines.endIndex, let m = listMarker(lines[i].trimmingCharacters(in: .whitespaces)) {
                    items.append(m)
                    i += 1
                }
                out += list(items[...], depth: 1)
                continue
            }
            paragraph.append(t)
            i += 1
        }
        flush()
        return out
    }

    /// "*", "#", "**", "#*", "-" followed by a space: the marker and the item's text.
    private static func listMarker(_ t: String) -> (String, String)? {
        guard let m = t.firstMatch(of: /^([*#]+|-)\s+(.*)$/) else { return nil }
        return (m.1 == "-" ? "*" : String(m.1), String(m.2))
    }

    /// Consecutive items at `depth` and deeper; a deeper run nests in the item before it.
    private static func list(_ items: ArraySlice<(String, String)>, depth: Int) -> [ADFNode] {
        var out: [ADFNode] = []
        var i = items.startIndex
        while i < items.endIndex {
            let kind = items[i].0.dropFirst(depth - 1).first
            var listItems: [ADFNode] = []
            while i < items.endIndex, items[i].0.count >= depth, items[i].0.dropFirst(depth - 1).first == kind {
                if items[i].0.count > depth {
                    // A deeper run with no item above it at this depth: an item of its own holds it.
                    var j = i
                    while j < items.endIndex, items[j].0.count > depth { j += 1 }
                    listItems.append(ADFNode(type: "listItem", content: list(items[i..<j], depth: depth + 1)))
                    i = j
                    continue
                }
                var content = paragraphs([items[i].1])
                if content.isEmpty { content = [ADFNode(type: "paragraph", content: [])] }
                i += 1
                var j = i
                while j < items.endIndex, items[j].0.count > depth { j += 1 }
                if j > i {
                    content += list(items[i..<j], depth: depth + 1)
                    i = j
                }
                listItems.append(ADFNode(type: "listItem", content: content))
            }
            if listItems.isEmpty {
                i += 1
                continue
            }
            out.append(ADFNode(type: kind == "#" ? "orderedList" : "bulletList", content: listItems))
        }
        return out
    }

    /// "||h1||h2||" or "|a|b|", mixed within a row; a pipe inside [a|b] or {x|y} belongs to the cell.
    private static func row(_ line: String) -> ADFNode {
        var cells: [ADFNode] = []
        var text = ""
        var header = false
        var started = false
        var depth = 0
        var chars = Array(line)[...]
        func close() {
            guard started else { return }
            let t = text.trimmingCharacters(in: .whitespaces)
            let content = paragraphs(t.components(separatedBy: "\\\\").map { $0.trimmingCharacters(in: .whitespaces) })
            cells.append(
                ADFNode(
                    type: header ? "tableHeader" : "tableCell",
                    content: content.isEmpty ? [ADFNode(type: "paragraph", content: [])] : content))
            text = ""
        }
        while let c = chars.first {
            chars = chars.dropFirst()
            if c == "\\", let next = chars.first {
                text += "\\\(next)"
                chars = chars.dropFirst()
                continue
            }
            if c == "[" || c == "{" { depth += 1 }
            if c == "]" || c == "}" { depth = max(0, depth - 1) }
            if c == "|", depth == 0 {
                close()
                header = chars.first == "|"
                if header { chars = chars.dropFirst() }
                started = true
                continue
            }
            text.append(c)
        }
        if !text.trimmingCharacters(in: .whitespaces).isEmpty { close() }
        return ADFNode(type: "tableRow", content: cells)
    }

    /// Lines of one paragraph, joined by breaks; an image on its own becomes a media block between paragraphs.
    private static func paragraphs(_ lines: [String]) -> [ADFNode] {
        var out: [ADFNode] = []
        var runs: [ADFNode] = []
        func flush() {
            while runs.last?.type == "hardBreak" { runs.removeLast() }
            if !runs.isEmpty { out.append(ADFNode(type: "paragraph", content: runs)) }
            runs = []
        }
        for (n, line) in lines.enumerated() {
            if n > 0, !runs.isEmpty { runs.append(ADFNode(type: "hardBreak")) }
            for node in inline(line) {
                if node.type == "mediaSingle" {
                    flush()
                    out.append(node)
                } else {
                    runs.append(node)
                }
            }
        }
        flush()
        return out
    }

    // MARK: Inline

    private struct Token {
        let range: Range<String.Index>
        let make: () -> [ADFNode]
    }

    /// One line of inline markup. The earliest token wins; a marked run is parsed again inside, so marks nest.
    static func inline(_ text: String, marks: [ADFMark] = []) -> [ADFNode] {
        var out: [ADFNode] = []
        var rest = text[...]
        var plain = ""
        func emitPlain() {
            guard !plain.isEmpty else { return }
            out.append(ADFNode(type: "text", text: plain, marks: marks.isEmpty ? nil : marks))
            plain = ""
        }
        while !rest.isEmpty {
            if rest.hasPrefix("\\\\") {
                emitPlain()
                out.append(ADFNode(type: "hardBreak"))
                rest = rest.dropFirst(2)
                continue
            }
            if rest.hasPrefix("\\"), rest.count > 1 {
                plain.append(rest.dropFirst().first!)
                rest = rest.dropFirst(2)
                continue
            }
            if let token = next(in: rest, marks: marks) {
                plain += rest[rest.startIndex..<token.range.lowerBound]
                emitPlain()
                out += token.make()
                rest = rest[token.range.upperBound...]
                continue
            }
            // Nothing before the next backslash; what follows it is read on the next pass.
            guard let slash = rest.firstIndex(of: "\\"), slash > rest.startIndex else {
                plain += rest
                break
            }
            plain += rest[..<slash]
            rest = rest[slash...]
        }
        emitPlain()
        return out
    }

    /// The earliest markup token in `s`, skipping escaped characters.
    private static func next(in s: Substring, marks: [ADFMark]) -> Token? {
        var best: Token?
        func consider(_ r: Range<String.Index>?, _ make: @escaping () -> [ADFNode]) {
            guard let r else { return }
            if best == nil || r.lowerBound < best!.range.lowerBound { best = Token(range: r, make: make) }
        }
        func with(_ type: String, _ attrs: [String: JSONValue]? = nil) -> [ADFMark] {
            marks + [ADFMark(type: type, attrs: attrs)]
        }
        // Stop at a backslash: whatever follows it is literal, and `inline` handles it.
        let scan = s.firstIndex(of: "\\").map { s[..<$0] } ?? s

        if let m = scan.firstMatch(of: /\{\{(.+?)\}\}/) {
            consider(m.range) { [ADFNode(type: "text", text: String(m.1), marks: with("code", nil))] }
        }
        if let m = scan.firstMatch(of: /\{color:([^}]+)\}(.*?)\{color\}/) {
            let hex = color(String(m.1))
            consider(m.range) {
                inline(String(m.2), marks: hex.map { with("textColor", ["color": .string($0)]) } ?? marks)
            }
        }
        if let m = scan.firstMatch(of: /\[~(?:accountid:)?([^\]]+)\]/) {
            consider(m.range) {
                [ADFNode(type: "mention", attrs: ["id": .string(String(m.1)), "text": .string("@\(m.1)")])]
            }
        }
        if let m = scan.firstMatch(of: /\[([^\]|]*)\|([^\]]+)\]/) {
            let href = String(m.2).trimmingCharacters(in: .whitespaces)
            consider(m.range) {
                let label = String(m.1)
                return inline(label.isEmpty ? href : label, marks: with("link", ["href": .string(href)]))
            }
        }
        if let m = scan.firstMatch(of: /\[((?:https?|mailto|ftp|file):[^\]]+)\]/) {
            let href = String(m.1)
            consider(m.range) { [ADFNode(type: "text", text: href, marks: with("link", ["href": .string(href)]))] }
        }
        if let m = scan.firstMatch(of: /\[\^([^\]]+)\]/) {
            consider(m.range) { [ADFNode(type: "text", text: String(m.1), marks: marks.isEmpty ? nil : marks)] }
        }
        if let m = scan.firstMatch(of: /!([^!\s|][^!|]*?)(?:\|[^!]*)?!/) {
            let name = String(m.1)
            consider(m.range) {
                if name.contains("://") {
                    return [ADFNode(type: "text", text: name, marks: with("link", ["href": .string(name)]))]
                }
                return [
                    ADFNode(
                        type: "mediaSingle", attrs: ["layout": .string("center")],
                        content: [ADFNode(type: "media", attrs: ["type": .string("file"), "alt": .string(name)])])
                ]
            }
        }
        if let m = scan.firstMatch(of: /(?:https?|ftp):\/\/[^\s<>\]|]+/) {
            let u = String(m.0)
            consider(m.range) { [ADFNode(type: "text", text: u, marks: with("link", ["href": .string(u)]))] }
        }
        for (symbol, mark, attrs) in phrases {
            if let r = phrase(symbol, in: scan) {
                let inner = String(
                    scan[
                        scan.index(
                            r.lowerBound, offsetBy: symbol.count)..<scan.index(r.upperBound, offsetBy: -symbol.count)])
                consider(r) { inline(inner, marks: with(mark, attrs)) }
            }
        }
        return best
    }

    private static let phrases: [(String, String, [String: JSONValue]?)] = [
        ("*", "strong", nil), ("_", "em", nil), ("??", "em", nil), ("-", "strike", nil), ("+", "underline", nil),
        ("^", "subsup", ["type": .string("sup")]), ("~", "subsup", ["type": .string("sub")]),
    ]

    /// `*text*`-style phrase: the opening symbol starts a word and the closing one ends it, as Jira renders them,
    /// so snake_case, a-b-c and 2*3*4 stay as typed.
    private static func phrase(_ symbol: String, in s: Substring) -> Range<String.Index>? {
        var from = s.startIndex
        while let open = s[from...].range(of: symbol) {
            defer { from = open.upperBound }
            let before = open.lowerBound > s.startIndex ? s[s.index(before: open.lowerBound)] : " "
            guard !before.isLetter, !before.isNumber, open.upperBound < s.endIndex, !s[open.upperBound].isWhitespace,
                String(s[open.upperBound]) != String(symbol.first!)
            else { continue }
            var search = s.index(after: open.upperBound)
            while search <= s.endIndex, let close = s[search...].range(of: symbol) {
                let last = s[s.index(before: close.lowerBound)]
                let after = close.upperBound < s.endIndex ? s[close.upperBound] : " "
                if !last.isWhitespace, !after.isLetter, !after.isNumber {
                    return open.lowerBound..<close.upperBound
                }
                search = close.upperBound
            }
        }
        return nil
    }

    // MARK: Helpers

    /// `{code:swift}` or `{code:title=A.java|language=java}`.
    private static func language(_ params: String) -> String? {
        let p = parameters(params)
        if let l = p["language"] { return l }
        return params.split(separator: "|").first.map(String.init).flatMap { $0.contains("=") || $0.isEmpty ? nil : $0 }
    }

    private static func parameters(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        for part in s.split(separator: "|") {
            let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2 { out[kv[0]] = kv[1] }
        }
        return out
    }

    /// The colour names Jira's editor offers, as the hex ADF stores.
    private static func color(_ s: String) -> String? {
        if s.hasPrefix("#") { return s }
        let named = [
            "red": "#de350b", "green": "#00875a", "blue": "#0052cc", "yellow": "#ff991f", "orange": "#ff8b00",
            "purple": "#5243aa", "gray": "#97a0af", "grey": "#97a0af", "black": "#172b4d", "white": "#ffffff",
            "teal": "#00b8d9",
        ]
        return named[s.lowercased()]
    }

    /// Text as it must be typed to come back as itself: markup characters are escaped where Jira would read them.
    static func escape(_ text: String, lineStart: Bool) -> String {
        var out = ""
        let chars = Array(text)
        for (i, c) in chars.enumerated() {
            let prev: Character = i > 0 ? chars[i - 1] : " "
            let next: Character = i + 1 < chars.count ? chars[i + 1] : " "
            let wordStart = !prev.isLetter && !prev.isNumber
            let wordEnd = !next.isLetter && !next.isNumber
            let lineHead = lineStart && (i == 0 || prev == "\n")
            switch c {
            case "\\", "[", "{", "|": out += "\\\(c)"
            case "!" where !next.isWhitespace: out += "\\!"
            // Jira reads *x* as bold only where the opening symbol starts a word and the closing one ends it.
            case _ where "*_+^~-".contains(c) && ((wordStart && !next.isWhitespace) || (wordEnd && !prev.isWhitespace)):
                out += "\\\(c)"
            // A list marker or a numbered item at the start of a line.
            case _ where lineHead && "*#-".contains(c): out += "\\\(c)"
            default: out.append(c)
            }
        }
        return out
    }
}
