//
//  MarkdownRenderer.swift
//  Ari
//
//  Created by Chen Jin Shen on 22/05/2026.
//

import SwiftUI
import SwiftMath
import AppKit

// MARK: - Math Image Cache
@MainActor
private var _mathImageCache: [String: (NSImage, CGFloat)] = [:]

// MARK: - Native Math Image Rendering

@MainActor
func renderMathImage(latex: String, fontSize: CGFloat, isBlock: Bool, textColor: NSColor) -> (NSImage, CGFloat)? {
    var sanitized = latex
    for cmd in ["\\Large", "\\large", "\\LARGE", "\\small", "\\normalsize",
                "\\huge", "\\HUGE", "\\tiny", "\\scriptsize", "\\footnotesize"] {
        sanitized = sanitized.replacingOccurrences(of: cmd, with: "")
    }
    sanitized = sanitized.replacingOccurrences(of: "\\text{", with: "\\mathrm{")
    sanitized = sanitized.replacingOccurrences(of: "\\dots", with: "\\ldots")

    // Cache lookup — avoids creating NSWindow on every updateNSView call
    let cacheKey = "\(sanitized)|\(fontSize)|\(isBlock)"
    if let cached = _mathImageCache[cacheKey] { return cached }

    let label = MTMathUILabel()
    label.latex = sanitized
    label.fontSize = fontSize
    label.labelMode = isBlock ? .display : .text
    label.textColor = textColor

    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 2000, height: 2000),
        styleMask: .borderless,
        backing: .buffered,
        defer: false
    )
    window.isOpaque = false
    window.backgroundColor = .clear
    window.setFrameOrigin(NSPoint(x: -10000, y: -10000))

    let host = NSView(frame: NSRect(x: 0, y: 0, width: 2000, height: 2000))
    window.contentView = host
    host.addSubview(label)
    label.frame = host.bounds
    label.layoutSubtreeIfNeeded()
    window.displayIfNeeded()

    var size = label.intrinsicContentSize
    if size.width <= 0 || size.height <= 0 { size = label.fittingSize }
    guard size.width > 0 && size.height > 0 else {
        label.removeFromSuperview()
        return nil
    }

    label.frame = CGRect(origin: .zero, size: size)
    label.layoutSubtreeIfNeeded()
    window.displayIfNeeded()

    guard let rep = label.bitmapImageRepForCachingDisplay(in: label.bounds) else {
        label.removeFromSuperview()
        return nil
    }
    label.cacheDisplay(in: label.bounds, to: rep)

    // Fully construct the image BEFORE touching the window
    let image = NSImage(size: size)
    image.addRepresentation(rep)
    let descent = size.height * 0.15

    // Explicitly detach label before releasing window to avoid ARC churn in SwiftMath internals
    label.removeFromSuperview()
    window.orderOut(nil)

    let result = (image, descent)
    _mathImageCache[cacheKey] = result
    return result
}

// MARK: - Global Chat Parser

enum ChatBlock: Identifiable {
    var id: UUID { UUID() }
    case text(String)
    case code(lang: String, code: String)
    case table(headers: [String], rows: [[String]])
    case list(items: [String])
}

func parseMarkdown(_ text: String) -> [ChatBlock] {
    var blocks: [ChatBlock] = []
    var currentText = ""
    var inCode = false
    var codeLang = ""
    var codeCode = ""
    var inTable = false
    var tableLines: [String] = []
    var inList = false
    var listIsNumbered = false
    var listItems: [String] = []

    func flushText() {
        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { blocks.append(.text(trimmed)) }
        currentText = ""
    }

    func flushTable() {
        guard !tableLines.isEmpty else { return }
        var headers: [String] = []; var rows: [[String]] = []
        for (_, line) in tableLines.enumerated() {
            var cleanLine = line.trimmingCharacters(in: .whitespaces)
            if cleanLine.hasPrefix("|") { cleanLine.removeFirst() }
            if cleanLine.hasSuffix("|") { cleanLine.removeLast() }

            let isSeparator = cleanLine.replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: "|", with: "")
                .replacingOccurrences(of: ":", with: "")
                .trimmingCharacters(in: .whitespaces)
                .isEmpty
            if isSeparator { continue }

            let cells = cleanLine.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            if headers.isEmpty { headers = cells } else { rows.append(cells) }
        }
        if !headers.isEmpty || !rows.isEmpty {
            blocks.append(.table(headers: headers, rows: rows))
        } else {
            blocks.append(.text(tableLines.joined(separator: "\n")))
        }
        tableLines = []; inTable = false
    }

    func flushList() {
        guard !listItems.isEmpty else { return }
        blocks.append(.list(items: listItems))
        listItems = []; inList = false
    }

    let lines = text.components(separatedBy: .newlines)
    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if line.hasPrefix("```") {
            if inCode {
                inCode = false
                blocks.append(.code(lang: codeLang, code: codeCode.trimmingCharacters(in: .whitespacesAndNewlines)))
                codeCode = ""
            } else {
                flushText(); flushTable(); flushList()
                inCode = true
                codeLang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces).lowercased()
            }
            continue
        }

        if inCode {
            codeCode += line + "\n"
            continue
        }

        if trimmed.hasPrefix("|") && trimmed.hasSuffix("|") {
            flushText(); flushList(); inTable = true; tableLines.append(trimmed); continue
        } else if inTable {
            flushTable()
        }

        let isNumberedItem = trimmed.range(of: #"^\d+\.\s+"#, options: .regularExpression) != nil
        let isBulletItem = trimmed.range(of: #"^[-*+]\s+"#, options: .regularExpression) != nil
        let isListItem = isNumberedItem || isBulletItem

        if isListItem {
            if inList && isNumberedItem != listIsNumbered { flushList() }
            flushText(); flushTable()
            inList = true; listIsNumbered = isNumberedItem
            listItems.append(trimmed); continue
        } else if inList && !trimmed.isEmpty {
            flushList()
        }

        currentText += line + "\n"
    }
    flushText(); flushTable(); flushList()

    if inCode {
        blocks.append(.code(lang: codeLang, code: codeCode.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    return blocks
}

// MARK: - Native Text Component (Replaces NSTextView)
class SelfSizingTextView: NSTextView {
    override var intrinsicContentSize: NSSize {
        guard let layoutManager = self.layoutManager,
              let textContainer = self.textContainer else { return super.intrinsicContentSize }
        if frame.width > 0 {
            textContainer.containerSize = NSSize(width: frame.width, height: .greatestFiniteMagnitude)
        }
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(usedRect.height))
    }
    override func layout() {
        super.layout()
        invalidateIntrinsicContentSize()
    }
}

struct NativeMarkdownText: NSViewRepresentable {
    let text: String

    class Coordinator {
        var lastText: String = ""
        var cachedAttrStr: NSAttributedString? = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SelfSizingTextView {
        let tv = SelfSizingTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return tv
    }

    func updateNSView(_ nsView: SelfSizingTextView, context: Context) {
        if text == context.coordinator.lastText, context.coordinator.cachedAttrStr != nil { return }
        let built = buildAttributedString(from: text)
        let nsAttr = NSAttributedString(built)
        context.coordinator.lastText = text
        context.coordinator.cachedAttrStr = nsAttr
        nsView.textStorage?.setAttributedString(nsAttr)
        nsView.invalidateIntrinsicContentSize()
    }

    @MainActor
    private func buildAttributedString(from input: String) -> AttributedString {
        var processingString = input
        var mathMatches: [(id: String, latex: String, isBlock: Bool)] = []
        
        // Fix headings: normalise missing space AND strip malformed ** inside heading lines
        if let headingRx = try? NSRegularExpression(pattern: #"^(#{1,6})([^ #\n])"#, options: .anchorsMatchLines) {
            processingString = headingRx.stringByReplacingMatches(
                in: processingString,
                range: NSRange(processingString.startIndex..., in: processingString),
                withTemplate: "$1 $2"
            )
        }
        if let headingLineRx = try? NSRegularExpression(pattern: #"^(#{1,6} )(.+)$"#, options: .anchorsMatchLines) {
            let matches = headingLineRx.matches(
                in: processingString,
                range: NSRange(processingString.startIndex..., in: processingString)
            ).reversed()
            for match in matches {
                if let fullRange = Range(match.range, in: processingString),
                   let prefixRange = Range(match.range(at: 1), in: processingString),
                   let contentRange = Range(match.range(at: 2), in: processingString) {
                    let prefix = String(processingString[prefixRange])
                    let content = String(processingString[contentRange])
                        .replacingOccurrences(of: "**", with: "")
                        .replacingOccurrences(of: "__", with: "")
                        .trimmingCharacters(in: .whitespaces)
                    processingString.replaceSubrange(fullRange, with: prefix + content)
                }
            }
        }
        
        let blockRegex = try! NSRegularExpression(
            pattern: #"(?:\$\$|\\\[)(.*?)(?:\$\$|\\\])"#,
            options: [.dotMatchesLineSeparators]
        )
        for match in blockRegex.matches(
            in: processingString,
            range: NSRange(processingString.startIndex..., in: processingString)
        ).reversed() {
            if let range = Range(match.range, in: processingString),
               let innerRange = Range(match.range(at: 1), in: processingString) {
                let id = "MATHBLOCK\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
                mathMatches.append((id, String(processingString[innerRange]), true))
                processingString.replaceSubrange(range, with: id)
            }
        }

        let inlineRegex = try! NSRegularExpression(
            pattern: #"(?:\$|\\\()(.*?)(?:\$|\\\))"#,
            options: [.dotMatchesLineSeparators]
        )
        for match in inlineRegex.matches(
            in: processingString,
            range: NSRange(processingString.startIndex..., in: processingString)
        ).reversed() {
            if let range = Range(match.range, in: processingString),
               let innerRange = Range(match.range(at: 1), in: processingString) {
                let latex = String(processingString[innerRange]).trimmingCharacters(in: .whitespaces)
                if !latex.isEmpty {
                    let id = "MATHINLINE\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
                    mathMatches.append((id, latex, false))
                    processingString.replaceSubrange(range, with: id)
                }
            }
        }

        let mdOptions = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .full
        )
        var attrStr = (try? AttributedString(markdown: processingString, options: mdOptions))
            ?? AttributedString(processingString)
        attrStr.foregroundColor = NSColor.textColor

        for match in mathMatches {
            if let range = attrStr.range(of: match.id) {
                if let (image, _) = renderMathImage(
                    latex: match.latex,
                    fontSize: 13,
                    isBlock: match.isBlock,
                    textColor: .textColor
                ) {
                    let attachment = NSTextAttachment()
                    attachment.image = image
                    attachment.bounds = CGRect(
                        x: 0,
                        y: match.isBlock ? 0 : -3,
                        width: image.size.width,
                        height: image.size.height
                    )

                    let attrDict: [NSAttributedString.Key: Any] = [.attachment: attachment]
                    let nsAttr = NSAttributedString(string: "\u{FFFC}", attributes: attrDict)
                    let replacement = AttributedString(nsAttr)

                    if match.isBlock {
                        var block = AttributedString("\n")
                        block.append(replacement)
                        block.append(AttributedString("\n"))
                        attrStr.replaceSubrange(range, with: block)
                    } else {
                        attrStr.replaceSubrange(range, with: replacement)
                    }
                } else {
                    var fallback = AttributedString(
                        match.isBlock ? "$$\(match.latex)$$" : "$\(match.latex)$"
                    )
                    fallback.font = .system(size: 13, design: .monospaced)
                    fallback.foregroundColor = .secondary
                    attrStr.replaceSubrange(range, with: fallback)
                }
            }
        }

        let nsAttr = NSMutableAttributedString()
        nsAttr.append(NSAttributedString(attrStr))
        let fullRange = NSRange(location: 0, length: nsAttr.length)
        
        nsAttr.enumerateAttribute(NSAttributedString.Key.font, in: fullRange, options: []) { value, range, _ in
            if let font = value as? NSFont {
                if font.pointSize < 13 {
                    let descriptor = font.fontDescriptor
                    let traits = descriptor.symbolicTraits
                    let isBold = traits.contains(.bold)
                    let weight: NSFont.Weight = isBold ? .bold : .regular
                    let adjusted = NSFont(descriptor: descriptor, size: 13)
                        ?? NSFont.systemFont(ofSize: 13, weight: weight)
                    nsAttr.removeAttribute(NSAttributedString.Key.font, range: range)
                    nsAttr.addAttribute(NSAttributedString.Key.font, value: adjusted, range: range)
                }
            } else {
                nsAttr.addAttribute(NSAttributedString.Key.font, value: NSFont.systemFont(ofSize: 13), range: range)
            }
        }

        return AttributedString(nsAttr)
    }
}

// MARK: - Markdown Renderer View

struct MarkdownRendererView: View {
    let text: String

    var body: some View {
        let components = text.components(separatedBy: "zcze")

        VStack(alignment: .leading, spacing: 12) {
            if components.count > 0 && !components[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                renderParsedBlocks(parseMarkdown(components[0]))
            }

            if components.count > 1 {
                let subComps = components[1].components(separatedBy: "zczc")
                ThinkingBlockView(content: subComps[0].trimmingCharacters(in: .whitespacesAndNewlines))

                if subComps.count > 1 && !subComps[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    renderParsedBlocks(parseMarkdown(subComps[1]))
                }
            }
        }
    }

    private func stripListMarker(_ item: String) -> String {
        if let range = item.range(of: #"^[-*+]\s+"#, options: .regularExpression) {
            return String(item[range.upperBound...])
        }
        if let range = item.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
            return String(item[range.upperBound...])
        }
        return item
    }

    private func splitParagraphs(_ text: String) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return normalized.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    @ViewBuilder
    private func renderParsedBlocks(_ parsedBlocks: [ChatBlock]) -> some View {
        ForEach(parsedBlocks) { block in
            switch block {
            case .text(let content):
                let paragraphs = splitParagraphs(content)
                if paragraphs.count > 1 {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(paragraphs.indices, id: \.self) { i in
                            NativeMarkdownText(text: paragraphs[i])
                        }
                    }
                } else if let first = paragraphs.first {
                    NativeMarkdownText(text: first)
                } else {
                    EmptyView()
                }
            case .code(let lang, let code):
                codeBlockView(language: lang, code: code)
            case .table(let headers, let rows):
                tableView(headers: headers, rows: rows)
            case .list(let items):
                let isNumbered = items.first?.range(of: #"^\d+\."#, options: .regularExpression) != nil
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(items.indices, id: \.self) { i in
                        HStack(alignment: .top, spacing: 6) {
                            if isNumbered {
                                Text("\(i + 1).")
                                    .font(.system(size: 13))
                                    .frame(width: 20, alignment: .trailing)
                            } else {
                                Text("•")
                                    .font(.system(size: 13))
                            }
                            NativeMarkdownText(text: stripListMarker(items[i]))
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func codeBlockView(language: String, code: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    Circle().fill(Color.red.opacity(0.85)).frame(width: 7, height: 7)
                    Circle().fill(Color.yellow.opacity(0.85)).frame(width: 7, height: 7)
                    Circle().fill(Color.green.opacity(0.85)).frame(width: 7, height: 7)
                }
                Text(language.isEmpty ? "code" : language)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.55))
                    .textCase(.uppercase)
                Spacer()
                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: "doc.on.doc").font(.system(size: 9))
                        Text("Copy").font(.system(size: 9, weight: .medium))
                    }
                    .foregroundColor(.white.opacity(0.4))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.35))

            Text(code)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white.opacity(0.92))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.black.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func tableView(headers: [String], rows: [[String]]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                if !headers.isEmpty {
                    GridRow {
                        ForEach(0..<headers.count, id: \.self) { i in
                            Text(LocalizedStringKey(headers[i]))
                                .font(.system(size: 13, weight: .semibold))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Divider()
                }
                ForEach(0..<rows.count, id: \.self) { rowIndex in
                    GridRow {
                        ForEach(0..<rows[rowIndex].count, id: \.self) { colIndex in
                            Text(LocalizedStringKey(rows[rowIndex][colIndex]))
                                .font(.system(size: 13))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if rowIndex < rows.count - 1 {
                        Divider().opacity(0.5)
                    }
                }
            }
            .padding(10)
            .background(Color.white.opacity(0.05))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Live Streaming Renderer

struct LiveStreamingRendererView: View {
    let text: String

    // Compiled once at struct type level — never recompiled per token
    private static let blockMathRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"(?:\$\$|\\\[).*?(?:\$\$|\\\])"#,
        options: [.dotMatchesLineSeparators]
    )
    private static let inlineMathRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"(?:\$|\\\().*?(?:\$|\\\))"#,
        options: [.dotMatchesLineSeparators]
    )

    var body: some View {
        let components = text.components(separatedBy: "zcze")

        VStack(alignment: .leading, spacing: 6) {
            if components.count > 0 && !components[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Plain Text — no markdown parsing overhead during stream
                Text(cleanForLiveView(components[0]))
                    .font(.system(size: 13))
                    .lineSpacing(2)
                    
            }

            if components.count > 1 {
                let subComps = components[1].components(separatedBy: "zczc")
                ThinkingBlockView(content: subComps[0].trimmingCharacters(in: .whitespacesAndNewlines))

                if subComps.count > 1 && !subComps[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(cleanForLiveView(subComps[1]))
                        .font(.system(size: 13))
                        .lineSpacing(2)
                        
                }
            }
        }
    }

    private func cleanForLiveView(_ raw: String) -> String {
        var result = raw

        if let rx = Self.blockMathRegex {
            result = rx.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "⌈math⌋"
            )
        }
        if let rx = Self.inlineMathRegex {
            result = rx.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "⌈math⌋"
            )
        }

        // Strip leftover markdown syntax that would show raw during stream
        return result
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "##", with: "")
            .replacingOccurrences(of: "###", with: "")
            .replacingOccurrences(of: "# ", with: "")
    }
}

// MARK: - Collapsible Thinking Block

struct ThinkingBlockView: View {
    let content: String
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                    Text(content.isEmpty ? "Thinking..." : "Thought Process")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)

            if isExpanded && !content.isEmpty {
                Text(content)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary.opacity(0.9))
                    .lineSpacing(2)
                    .padding(.leading, 14)
                    .padding(.top, 2)
                    .padding(.bottom, 6)
            }
        }
        .padding(.vertical, 4)
    }
}
