import Foundation

// Minimal Markdown ⇄ Atlassian Document Format, enough for comments and descriptions
// written by hand: headings, lists (nested), quotes, fenced code, rules, pipe tables, bold/italic/code/strike,
// links, bare URLs and @mentions. Anything fancier survives a read but not an edit round-trip.

extension ADFNode {
    /// Markdown → ADF. `mentions` maps a display name to an accountId; "@Name" in the text becomes a mention node.
    static func document(markdown: String, mentions: [String: String] = [:]) -> ADFNode {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [ADFNode] = []
        var paragraph: [String] = []
        var i = 0

        func flush() {
            guard !paragraph.isEmpty else { return }
            blocks.append(ADFNode(type: "paragraph", content: joinedInline(paragraph, mentions: mentions)))
            paragraph = []
        }

        while i < lines.count {
            let line = lines[i]
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") {
                flush()
                let lang = String(t.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i])
                    i += 1
                }
                i += 1
                blocks.append(
                    ADFNode(
                        type: "codeBlock",
                        attrs: lang.isEmpty ? nil : ["language": .string(lang)],
                        content: code.isEmpty ? [] : [ADFNode(type: "text", text: code.joined(separator: "\n"))]))
                continue
            }
            if t.isEmpty {
                flush()
                i += 1
                continue
            }
            if t == "---" || t == "***" {
                flush()
                blocks.append(ADFNode(type: "rule"))
                i += 1
                continue
            }
            if let m = t.firstMatch(of: /^(#{1,6})\s+(.+)$/) {
                flush()
                blocks.append(
                    ADFNode(
                        type: "heading", attrs: ["level": .number(Double(m.1.count))],
                        content: inlineNodes(String(m.2), mentions: mentions)))
                i += 1
                continue
            }
            if t.hasPrefix(">") {
                flush()
                var quote: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quote.append(
                        String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(
                            in: .whitespaces))
                    i += 1
                }
                blocks.append(
                    ADFNode(
                        type: "blockquote",
                        content: [ADFNode(type: "paragraph", content: joinedInline(quote, mentions: mentions))]))
                continue
            }
            // A pipe table: a header row, a |---| rule, then rows. The one block the editor shows that way.
            if t.hasPrefix("|"), i + 1 < lines.count,
                lines[i + 1].trimmingCharacters(in: .whitespaces).firstMatch(of: /^\|(\s*:?-+:?\s*\|)+$/) != nil
            {
                flush()
                var rows: [ADFNode] = []
                var r = 0
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    let row = lines[i].trimmingCharacters(in: .whitespaces)
                    i += 1
                    if r == 1 {
                        r += 1
                        continue
                    }  // the rule line
                    let cells = row.dropFirst().dropLast(row.hasSuffix("|") ? 1 : 0).split(
                        separator: "|", omittingEmptySubsequences: false
                    )
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    rows.append(
                        ADFNode(
                            type: "tableRow",
                            content: cells.map {
                                ADFNode(
                                    type: r == 0 ? "tableHeader" : "tableCell",
                                    content: [ADFNode(type: "paragraph", content: inlineNodes($0, mentions: mentions))])
                            }))
                    r += 1
                }
                blocks.append(
                    ADFNode(
                        type: "table", attrs: ["isNumberColumnEnabled": .bool(false), "layout": .string("default")],
                        content: rows))
                continue
            }
            if let marker = listMarker(line) {
                flush()
                let (node, next) = parseList(
                    lines, from: i, ordered: marker.ordered, task: marker.done != nil, indent: indent(of: line),
                    mentions: mentions)
                blocks.append(node)
                i = next
                continue
            }
            paragraph.append(t)
            i += 1
        }
        flush()
        return ADFNode(type: "doc", version: 1, content: blocks)
    }

    private static func joinedInline(_ lines: [String], mentions: [String: String]) -> [ADFNode] {
        var out: [ADFNode] = []
        for (n, line) in lines.enumerated() {
            if n > 0 { out.append(ADFNode(type: "hardBreak")) }
            out += inlineNodes(line, mentions: mentions)
        }
        return out
    }

    /// A bullet, a number, or a task ("- [ ]" open, "- [x]" done: `done` is nil for the other two).
    private static func listMarker(_ line: String) -> (ordered: Bool, done: Bool?, text: String)? {
        let t = line.trimmingCharacters(in: .whitespaces)
        if let m = t.firstMatch(of: /^[-*+]\s+\[([ xX])\]\s+(.*)$/) { return (false, m.1 != " ", String(m.2)) }
        if let m = t.firstMatch(of: /^[-*+]\s+(.*)$/) { return (false, nil, String(m.1)) }
        if let m = t.firstMatch(of: /^\d+[.)]\s+(.*)$/) { return (true, nil, String(m.1)) }
        return nil
    }

    private static func indent(of line: String) -> Int { line.prefix { $0 == " " || $0 == "\t" }.count }

    /// Consecutive items of one kind at one indent. A task list's items hold inline text only (ADF allows
    /// nothing else), so a list nested under a task starts a list of its own.
    private static func parseList(
        _ lines: [String], from start: Int, ordered: Bool, task: Bool, indent level: Int, mentions: [String: String]
    ) -> (ADFNode, Int) {
        var items: [ADFNode] = []
        var i = start
        while i < lines.count, let marker = listMarker(lines[i]), marker.ordered == ordered,
            (marker.done != nil) == task, indent(of: lines[i]) == level
        {
            let inline = inlineNodes(marker.text, mentions: mentions)
            i += 1
            if task {
                items.append(
                    ADFNode(
                        type: "taskItem",
                        attrs: [
                            "localId": .string(UUID().uuidString), "state": .string(marker.done! ? "DONE" : "TODO"),
                        ],
                        content: inline))
                continue
            }
            var content = [ADFNode(type: "paragraph", content: inline)]
            if i < lines.count, let nested = listMarker(lines[i]), indent(of: lines[i]) > level {
                let (child, next) = parseList(
                    lines, from: i, ordered: nested.ordered, task: nested.done != nil, indent: indent(of: lines[i]),
                    mentions: mentions)
                content.append(child)
                i = next
            }
            items.append(ADFNode(type: "listItem", content: content))
        }
        if task {
            return (ADFNode(type: "taskList", attrs: ["localId": .string(UUID().uuidString)], content: items), i)
        }
        return (ADFNode(type: ordered ? "orderedList" : "bulletList", content: items), i)
    }

    private static func marked(_ text: String, _ mark: String) -> ADFNode {
        ADFNode(type: "text", text: text, marks: [ADFMark(type: mark, attrs: nil)])
    }

    /// One line of inline Markdown into text/mention nodes. Earliest token wins; no nesting.
    static func inlineNodes(_ text: String, mentions: [String: String]) -> [ADFNode] {
        var nodes: [ADFNode] = []
        var rest = Substring(text)
        let names = mentions.keys.sorted { $0.count > $1.count }

        while !rest.isEmpty {
            var best: (range: Range<Substring.Index>, node: ADFNode)?
            func consider(_ r: Range<Substring.Index>?, _ make: () -> ADFNode) {
                guard let r else { return }
                if best == nil || r.lowerBound < best!.range.lowerBound { best = (r, make()) }
            }
            if let m = rest.firstMatch(of: /`([^`]+)`/) { consider(m.range) { marked(String(m.1), "code") } }
            if let m = rest.firstMatch(of: /\*\*(.+?)\*\*/) { consider(m.range) { marked(String(m.1), "strong") } }
            if let m = rest.firstMatch(of: /~~(.+?)~~/) { consider(m.range) { marked(String(m.1), "strike") } }
            if let m = rest.firstMatch(of: /\*(?!\*)([^*]+)\*/) { consider(m.range) { marked(String(m.1), "em") } }
            if let m = rest.firstMatch(of: /\b_([^_]+)_\b/) { consider(m.range) { marked(String(m.1), "em") } }
            if let m = rest.firstMatch(of: /\[([^\]]+)\]\(([^)\s]+)\)/) {
                consider(m.range) {
                    ADFNode(
                        type: "text", text: String(m.1),
                        marks: [ADFMark(type: "link", attrs: ["href": .string(String(m.2))])])
                }
            }
            if let m = rest.firstMatch(of: /https?:\/\/[^\s<>)\]]+/) {
                consider(m.range) {
                    let u = String(m.0)
                    return ADFNode(type: "text", text: u, marks: [ADFMark(type: "link", attrs: ["href": .string(u)])])
                }
            }
            for name in names {
                consider(rest.range(of: "@" + name)) {
                    ADFNode(type: "mention", attrs: ["id": .string(mentions[name]!), "text": .string("@" + name)])
                }
            }
            guard let b = best else {
                nodes.append(ADFNode(type: "text", text: String(rest)))
                break
            }
            if b.range.lowerBound > rest.startIndex {
                nodes.append(ADFNode(type: "text", text: String(rest[rest.startIndex..<b.range.lowerBound])))
            }
            nodes.append(b.node)
            rest = rest[b.range.upperBound...]
        }
        return nodes
    }

    // MARK: ADF → Markdown

    /// Markdown for editing. Mentions found on the way are recorded so they survive the trip back.
    func markdown(mentions: inout [String: String]) -> String {
        (content ?? []).map { $0.blockMarkdown(indent: "", mentions: &mentions) }.joined(separator: "\n\n")
    }

    /// Node types the Markdown round-trip would flatten or drop.
    var hasLossyNodes: Bool {
        let lossy: Set<String> = [
            "media", "mediaSingle", "mediaGroup", "mediaInline", "panel", "expand", "nestedExpand", "layoutSection",
            "decisionList",
        ]
        if lossy.contains(type) { return true }
        return (content ?? []).contains { $0.hasLossyNodes }
    }

    private func blockMarkdown(indent: String, mentions: inout [String: String]) -> String {
        switch type {
        case "paragraph":
            return indent + inlineMarkdown(&mentions).replacingOccurrences(of: "\n", with: "\n" + indent)
        case "heading":
            let level = Int(attrs?["level"]?.number ?? 1)
            return indent + String(repeating: "#", count: max(1, min(6, level))) + " " + inlineMarkdown(&mentions)
        case "bulletList", "orderedList":
            var lines: [String] = []
            for (i, item) in (content ?? []).enumerated() {
                let marker = type == "orderedList" ? "\(i + 1). " : "- "
                let parts = (item.content ?? []).map { $0.blockMarkdown(indent: indent + "  ", mentions: &mentions) }
                guard let first = parts.first else {
                    lines.append(indent + marker)
                    continue
                }
                lines.append(indent + marker + String(first.dropFirst(indent.count + 2)))
                lines += parts.dropFirst()
            }
            return lines.joined(separator: "\n")
        case "taskList":
            return (content ?? []).map {
                indent + ($0.attr("state") == "DONE" ? "- [x] " : "- [ ] ") + $0.inlineMarkdown(&mentions)
            }.joined(separator: "\n")
        case "codeBlock":
            let body = plainText.split(separator: "\n", omittingEmptySubsequences: false).map { indent + $0 }.joined(
                separator: "\n")
            return indent + "```" + (attr("language") ?? "") + "\n" + body + "\n" + indent + "```"
        case "blockquote":
            let inner = (content ?? []).map { $0.blockMarkdown(indent: "", mentions: &mentions) }.joined(
                separator: "\n\n")
            return inner.split(separator: "\n", omittingEmptySubsequences: false).map { indent + "> " + $0 }.joined(
                separator: "\n")
        case "rule":
            return indent + "---"
        case "table":
            var rows: [String] = []
            for (r, row) in (content ?? []).enumerated() {
                let cells = (row.content ?? []).map { cell in
                    (cell.content ?? []).map { $0.blockMarkdown(indent: "", mentions: &mentions) }.joined(
                        separator: " "
                    ).replacingOccurrences(of: "\n", with: " ")
                }
                rows.append(indent + "| " + cells.joined(separator: " | ") + " |")
                if r == 0 { rows.append(indent + "|" + cells.map { _ in " --- |" }.joined()) }
            }
            return rows.joined(separator: "\n")
        case "mediaSingle", "mediaGroup":
            return indent + (content ?? []).map { "(image: \($0.attr("alt") ?? "attachment"))" }.joined(separator: " ")
        default:
            if let content, !content.isEmpty, content.first?.type != "text" {
                return content.map { $0.blockMarkdown(indent: indent, mentions: &mentions) }.joined(separator: "\n\n")
            }
            return indent + inlineMarkdown(&mentions)
        }
    }

    private func inlineMarkdown(_ mentions: inout [String: String]) -> String {
        var out = ""
        for n in content ?? [] {
            switch n.type {
            case "text":
                var t = n.text ?? ""
                for m in n.marks ?? [] {
                    switch m.type {
                    case "strong": t = "**\(t)**"
                    case "em": t = "*\(t)*"
                    case "code": t = "`\(t)`"
                    case "strike": t = "~~\(t)~~"
                    case "link": if let h = m.attrs?["href"]?.string, h != t { t = "[\(t)](\(h))" }
                    default: break
                    }
                }
                out += t
            case "hardBreak": out += "\n"
            case "mention":
                let text = n.attr("text") ?? "@someone"
                let name = text.hasPrefix("@") ? String(text.dropFirst()) : text
                if let id = n.attr("id") { mentions[name] = id }
                out += "@" + name
            case "inlineCard": out += n.attr("url") ?? ""
            case "emoji": out += n.attr("text") ?? n.attr("shortName") ?? ""
            case "status": out += n.attr("text") ?? ""
            case "date":
                if let ms = n.attrs?["timestamp"]?.string.flatMap(Double.init) {
                    out += Date(timeIntervalSince1970: ms / 1000).formatted(date: .abbreviated, time: .omitted)
                }
            default: out += n.inlineMarkdown(&mentions)
            }
        }
        return out
    }
}
