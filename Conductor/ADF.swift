import SwiftUI

// MARK: - Atlassian Document Format model

enum JSONValue: Codable, Hashable, Sendable {
    case string(String), number(Double), bool(Bool), null
    case array([JSONValue]), object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        // Strings first: ADF attributes are mostly strings, and every failed attempt throws.
        if let s = try? c.decode(String.self) { self = .string(s) }
        else if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
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

    var string: String? { if case .string(let s) = self { return s }; return nil }
    var number: Double? { if case .number(let n) = self { return n }; return nil }
    var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
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

    /// Plain-text document from user input: one paragraph per line.
    static func document(text: String) -> ADFNode {
        let paragraphs = text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            ADFNode(type: "paragraph", content: line.isEmpty ? [] : [ADFNode(type: "text", text: String(line))])
        }
        return ADFNode(type: "doc", version: 1, content: paragraphs)
    }

    var plainText: String {
        if let text { return text }
        return (content ?? []).map(\.plainText).joined(separator: type == "paragraph" ? "" : "\n")
    }
}

// MARK: - Inline rendering

extension ADFNode {
    /// `base` is the block's font: headings pass theirs, so bold and code runs keep the heading size.
    func inlineAttributed(base: Font = .body) -> AttributedString {
        var out = AttributedString()
        for n in content ?? [] { out += n.inlineRun(base: base) }
        return out
    }

    private func inlineRun(base: Font) -> AttributedString {
        switch type {
        case "text":
            var s = AttributedString(text ?? "")
            var bold = false, italic = false, code = false
            for m in marks ?? [] {
                switch m.type {
                case "strong": bold = true
                case "em": italic = true
                case "code": code = true
                case "strike": s.strikethroughStyle = .single
                case "underline": s.underlineStyle = .single
                case "link": if let u = m.attrs?["href"]?.string.flatMap(URL.init) { s.link = u }
                case "textColor": if let hex = m.attrs?["color"]?.string { s.foregroundColor = Color(hex: hex) }
                default: break
                }
            }
            var font: Font = code ? base.monospaced() : base
            if bold { font = font.weight(.semibold) }
            if italic { font = font.italic() }
            s.font = font
            if code { s.backgroundColor = Color.primary.opacity(0.08) }
            return s
        case "hardBreak":
            return AttributedString("\n")
        case "mention":
            var s = AttributedString(attr("text") ?? "@someone")
            s.foregroundColor = .accentColor
            s.font = .body.weight(.medium)
            return s
        case "inlineCard":
            let url = attr("url") ?? ""
            var s = AttributedString(url.replacingOccurrences(of: "https://", with: ""))
            s.link = URL(string: url)
            return s
        case "emoji":
            return AttributedString(attr("text") ?? attr("shortName") ?? "")
        case "status":
            var s = AttributedString(" \(attr("text")?.uppercased() ?? "") ")
            s.font = .caption.weight(.bold)
            let tint: Color = switch attr("color") {   // Jira's lozenge colours
            case "green": .green
            case "red": .red
            case "blue": .blue
            case "yellow": .orange
            case "purple": .purple
            default: .secondary
            }
            s.foregroundColor = tint
            s.backgroundColor = tint.opacity(0.15)
            return s
        case "date":
            if let ms = attrs?["timestamp"]?.string.flatMap(Double.init) {
                return AttributedString(Date(timeIntervalSince1970: ms / 1000).formatted(date: .abbreviated, time: .omitted))
            }
            return AttributedString()
        case "mediaInline":
            return AttributedString("📎")
        default:
            return inlineAttributed()
        }
    }
}

extension Color {
    init(hex: String) {
        var h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        let v = UInt64(h, radix: 16) ?? 0
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

// MARK: - Block rendering

struct ADFView: View {
    let node: ADFNode
    /// Off where a click starts editing: selectable text swallows the click before any tap gesture sees it.
    var selectable = true
    @ViewBuilder var body: some View {
        let blocks = VStack(alignment: .leading, spacing: 10) { ADFBlocks(nodes: node.content ?? []) }
        if selectable { blocks.textSelection(.enabled) } else { blocks.textSelection(.disabled) }
    }
}

struct ADFBlocks: View {
    let nodes: [ADFNode]
    var body: some View {
        ForEach(Array(nodes.enumerated()), id: \.offset) { _, n in
            ADFBlock(node: n)
        }
    }
}

struct ADFBlock: View {
    let node: ADFNode
    @Environment(\.adfAttachments) private var attachments
    @Environment(\.adfHeaderCell) private var headerCell

    var body: some View {
        switch node.type {
        case "paragraph":
            Text(node.inlineAttributed(base: headerCell ? .body.weight(.semibold) : .body)).fixedSize(horizontal: false, vertical: true)
        case "heading":
            Text(node.inlineAttributed(base: headingFont)).font(headingFont).padding(.top, 4).fixedSize(horizontal: false, vertical: true)
        case "bulletList":
            list(ordered: false)
        case "orderedList":
            list(ordered: true)
        case "codeBlock":
            // Jira wraps a block when its `wrap` attr is set; otherwise it scrolls sideways. Pasted logs often
            // start with a newline, which would leave a blank first line and the content out of view.
            let code = node.plainText.trimmingCharacters(in: .newlines)
            if case .bool(true)? = node.attrs?["wrap"] {
                Text(code).font(.body.monospaced()).padding(10).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
            } else {
                ScrollView(.horizontal) {
                    Text(code).font(.body.monospaced()).padding(10)
                }
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
            }
        case "blockquote":
            VStack(alignment: .leading, spacing: 8) { ADFBlocks(nodes: node.content ?? []) }
                .padding(.leading, 13)
                .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 2).fill(.tertiary).frame(width: 3) }
        case "rule":
            Divider()
        case "panel":
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: panelIcon).foregroundStyle(panelColor)
                VStack(alignment: .leading, spacing: 8) { ADFBlocks(nodes: node.content ?? []) }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(panelColor.opacity(0.1), in: .rect(cornerRadius: 10))
        case "table":
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(Array((node.content ?? []).enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array((row.content ?? []).enumerated()), id: \.offset) { _, cell in
                            VStack(alignment: .leading, spacing: 6) { ADFBlocks(nodes: cell.content ?? []) }
                                .environment(\.adfHeaderCell, cell.type == "tableHeader")   // text runs set their own font
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .topLeading)   // no maxHeight: a scroll view would stretch every row
                                .background(cell.type == "tableHeader" ? Color.primary.opacity(0.06) : .clear)
                                .border(Color.primary.opacity(0.12), width: 0.5)
                        }
                    }
                }
            }
        case "mediaSingle", "mediaGroup":
            HStack(alignment: .top, spacing: 8) {
                ForEach(Array((node.content ?? []).enumerated()), id: \.offset) { _, m in
                    if let a = attachments.first(where: { $0.filename == m.attr("alt") }), (a.mimeType ?? "").hasPrefix("image/") {
                        InlineImage(attachment: a)
                    } else {
                        Label(m.attr("alt") ?? String(localized: "Attached media"), systemImage: "photo")
                            .font(.callout).foregroundStyle(.secondary)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.quaternary.opacity(0.5), in: .capsule)
                    }
                }
            }
        case "taskList":
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array((node.content ?? []).enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: item.attr("state") == "DONE" ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(item.attr("state") == "DONE" ? .green : .secondary)
                        Text(item.inlineAttributed()).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case "expand", "nestedExpand":
            DisclosureGroup(node.attr("title") ?? String(localized: "Details")) {
                VStack(alignment: .leading, spacing: 8) { ADFBlocks(nodes: node.content ?? []) }.padding(.top, 6)
            }
        case "layoutSection":
            HStack(alignment: .top, spacing: 16) {
                ForEach(Array((node.content ?? []).enumerated()), id: \.offset) { _, col in
                    VStack(alignment: .leading, spacing: 8) { ADFBlocks(nodes: col.content ?? []) }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        default:
            // Unknown block: render children if any, else inline text.
            if node.content != nil, node.type != "text" {
                VStack(alignment: .leading, spacing: 8) { ADFBlocks(nodes: node.content ?? []) }
            } else {
                Text(node.inlineAttributed())
            }
        }
    }

    private func list(ordered: Bool) -> some View {
        let start = Int(node.attrs?["order"]?.number ?? 1)
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(Array((node.content ?? []).enumerated()), id: \.offset) { i, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(ordered ? "\(start + i)." : "•")
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 16, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 4) { ADFBlocks(nodes: item.content ?? []) }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.leading, 4)
    }

    private var headingFont: Font {
        switch Int(node.attrs?["level"]?.number ?? 3) {
        case 1: .title.weight(.semibold)
        case 2: .title2.weight(.semibold)
        case 3: .title3.weight(.semibold)
        default: .headline
        }
    }

    private var panelColor: Color {
        switch node.attr("panelType") {
        case "warning": .orange
        case "error": .red
        case "success": .green
        case "note": .purple
        default: .blue
        }
    }

    private var panelIcon: String {
        switch node.attr("panelType") {
        case "warning": "exclamationmark.triangle.fill"
        case "error": "xmark.octagon.fill"
        case "success": "checkmark.circle.fill"
        case "note": "note.text"
        default: "info.circle.fill"
        }
    }
}

// MARK: - Inline media

extension EnvironmentValues {
    /// Attachments of the issue being rendered, so inline media can resolve to real images by filename.
    @Entry var adfAttachments: [Attachment] = []
    /// Set by the issue view: the Quick Look URL an inline image writes to when clicked.
    @Entry var previewURL: Binding<URL?>? = nil
}

struct InlineImage: View {
    let attachment: Attachment
    @Environment(Session.self) private var session
    @Environment(\.jira) private var jira
    @Environment(\.previewURL) private var previewURL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.4)).frame(width: 240, height: 140)
                    .overlay { ProgressView().controlSize(.small) }
            }
        }
        .frame(maxWidth: 520, maxHeight: 360, alignment: .leading)
        .clipShape(.rect(cornerRadius: 10))
        .task(id: attachment.id) {
            let url = attachment.content
            if let cached = ImageCache.shared.object(forKey: url as NSURL) { image = cached; return }
            if let data = await DiskCache.imageData(for: url), let img = await DiskCache.decodeImage(data) {
                ImageCache.shared.setObject(img, forKey: url as NSURL)
                image = img
                return
            }
            guard let client = session.client(for: url), let data = try? await client.data(for: url),
                  let img = await DiskCache.decodeImage(data) else { return }
            DiskCache.saveImage(data, for: url)
            ImageCache.shared.setObject(img, forKey: url as NSURL)
            image = img
        }
        .onTapGesture {
            guard let c = jira?.client, let previewURL else { return }
            Task { if let url = await AttachmentOpener.download(attachment, client: c) { previewURL.wrappedValue = url } }
        }
        .onHover { inside in inside ? NSCursor.pointingHand.push() : NSCursor.pop() }
        .help("\(attachment.filename) — click to preview")
    }
}

extension EnvironmentValues {
    /// Inside a table header cell, where every run is bold.
    @Entry var adfHeaderCell = false
}
