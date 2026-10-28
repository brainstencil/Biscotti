import Foundation

/// One block of an answer, as the chat card draws it.
public enum ChatBlock: Sendable, Equatable {
    case paragraph(AttributedString)
    case bullet(level: Int, AttributedString)
    case numbered(number: Int, AttributedString)
    case heading(AttributedString)
}

/// AttributedString attribute marking a valid cited time; its value is the target second.
public enum ChatTimeAttribute: CodableAttributedStringKey, MarkdownDecodableAttributedStringKey {
    public typealias Value = TimeInterval
    public static let name = "biscottiChatTime"
}

/// Splits an answer's Markdown into blocks and turns the times it cites into
/// links, when they match a line the model was given.
///
/// Runs on every redraw while an answer streams, so it makes one pass over
/// the lines and never fails: whatever it cannot parse stays plain text.
public enum ChatAnswerParser {
    /// A cited time links to the nearest evidence line within this.
    static let citationTolerance: TimeInterval = 15

    /// Parses the whole answer text (call again as it streams).
    public static func blocks(_ answer: String, evidenceTimes: [TimeInterval]) -> [ChatBlock] {
        var collector = BlockCollector(evidenceTimes: evidenceTimes)
        // `\r\n` is one `Character`, so lines split on any newline character.
        for line in answer.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            collector.add(AnswerLine(line))
        }
        return collector.finish()
    }

    /// The block text's inline Markdown, with valid citations linked.
    static func inline(_ text: String, evidenceTimes: [TimeInterval]) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        var attributed = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        linkCitations(in: &attributed, evidenceTimes: evidenceTimes)
        return attributed
    }

    /// The evidence time nearest `time`, if it is within `citationTolerance`.
    /// `evidenceTimes` is ascending.
    static func nearestEvidence(to time: TimeInterval, in evidenceTimes: [TimeInterval]) -> TimeInterval? {
        var low = 0
        var high = evidenceTimes.count
        while low < high {
            let middle = (low + high) / 2
            if evidenceTimes[middle] < time {
                low = middle + 1
            } else {
                high = middle
            }
        }
        let nearest = [low - 1, low]
            .filter { evidenceTimes.indices.contains($0) }
            .map { evidenceTimes[$0] }
            .min { abs($0 - time) < abs($1 - time) }
        guard let nearest, abs(nearest - time) <= citationTolerance else { return nil }
        return nearest
    }

    // MARK: - Citations

    /// Replaces each bracketed citation with its times alone, keeping the
    /// text's other attributes, and marks each time with `ChatTimeAttribute`
    /// when it matches evidence.
    private static func linkCitations(in attributed: inout AttributedString, evidenceTimes: [TimeInterval]) {
        // `[4:05]`, `[1:02:09]`, a range such as `[12:34–13:10]`, or a group of
        // them, `[0:21, 1:05]` or `[0:21; 1:05]`. The spec names single times only;
        // models also group them, and each time in a group is judged on its own.
        let citation = #/
            \[
            \d{1,2}:\d{2}(?::\d{2})? (?:\s*[–—-]\s*\d{1,2}:\d{2}(?::\d{2})?)?
            (?: \s*[,;]\s* \d{1,2}:\d{2}(?::\d{2})? (?:\s*[–—-]\s*\d{1,2}:\d{2}(?::\d{2})?)? )*
            \]
        /#
        let plain = String(attributed.characters)
        // Last first, so the offsets of earlier matches stay valid.
        for match in plain.matches(of: citation).reversed() {
            let offset = plain.unicodeScalars.distance(from: plain.startIndex, to: match.range.lowerBound)
            let length = plain.unicodeScalars.distance(from: match.range.lowerBound, to: match.range.upperBound)
            let start = attributed.unicodeScalars.index(attributed.startIndex, offsetBy: offset)
            let range = start ..< attributed.unicodeScalars.index(start, offsetBy: length)
            let attributes = attributed[range].runs.first?.attributes ?? AttributeContainer()
            let times = linkedTimes(plain[match.range].dropFirst().dropLast(), attributes: attributes, evidenceTimes: evidenceTimes)
            attributed.replaceSubrange(range, with: times)
        }
    }

    /// The citation's text without brackets, each time (or range, by its
    /// start) linked when it is near evidence.
    private static func linkedTimes(_ label: Substring, attributes: AttributeContainer, evidenceTimes: [TimeInterval]) -> AttributedString {
        let citedTime = /(\d{1,2}):(\d{2})(?::(\d{2}))?(?:\s*[–—-]\s*\d{1,2}:\d{2}(?::\d{2})?)?/
        var result = AttributedString()
        var rest = label.startIndex
        for item in label.matches(of: citedTime) {
            result += AttributedString(String(label[rest ..< item.range.lowerBound]), attributes: attributes)
            var time = AttributedString(String(label[item.range]), attributes: attributes)
            let (_, first, second, third) = item.output
            if let target = nearestEvidence(to: seconds(first, second, third), in: evidenceTimes) {
                time[ChatTimeAttribute.self] = target
            }
            result += time
            rest = item.range.upperBound
        }
        result += AttributedString(String(label[rest...]), attributes: attributes)
        return result
    }

    /// `m:ss`, or `h:mm:ss` when there is a third part.
    private static func seconds(_ first: Substring, _ second: Substring, _ third: Substring?) -> TimeInterval {
        let parts = [first, second] + (third.map { [$0] } ?? [])
        return parts.reduce(0) { $0 * 60 + (TimeInterval($1) ?? 0) }
    }
}

/// One line of an answer, by what it starts with.
private enum AnswerLine {
    case blank
    case text(String)
    case bullet(level: Int, String)
    case numbered(Int, String)
    case heading(String)

    /// A marker with nothing after it already counts, so a list item that is
    /// still streaming never shows as a paragraph first.
    init(_ line: Substring) {
        let indent = line.prefix { $0 == " " }.count
        let content = line.drop(while: \.isWhitespace)
        let trimmed = content.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            self = .blank
        } else if let text = Self.text(after: ["- ", "* "], in: content) {
            self = .bullet(level: 1 + indent / 2, text)
        } else if let item = Self.numberedItem(content) {
            self = .numbered(item.number, item.text)
        } else if let text = Self.text(after: ["### ", "## ", "# "], in: content) {
            self = .heading(text)
        } else {
            self = .text(trimmed)
        }
    }

    /// The text after the first of `markers` that starts `content`, or after
    /// a marker that ends the line without its space.
    private static func text(after markers: [String], in content: Substring) -> String? {
        let bare = content.trimmingCharacters(in: .whitespaces)
        for marker in markers {
            if content.hasPrefix(marker) {
                return content.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
            }
            if bare == marker.trimmingCharacters(in: .whitespaces) {
                return ""
            }
        }
        return nil
    }

    /// `N. text` or `N) text`, with at most three digits so a year is not a list.
    private static func numberedItem(_ content: Substring) -> (number: Int, text: String)? {
        let digits = content.prefix(while: \.isASCIIDigit)
        guard (1 ... 3).contains(digits.count), let number = Int(digits) else { return nil }
        let rest = content.dropFirst(digits.count)
        guard let marker = rest.first, marker == "." || marker == ")" else { return nil }
        let afterMarker = rest.dropFirst()
        guard afterMarker.isEmpty || afterMarker.first?.isWhitespace == true else { return nil }
        return (number, afterMarker.trimmingCharacters(in: .whitespaces))
    }
}

/// Gathers lines into blocks: consecutive text lines form one paragraph.
private struct BlockCollector {
    let evidenceTimes: [TimeInterval]
    private var blocks: [ChatBlock] = []
    private var paragraph: [String] = []

    init(evidenceTimes: [TimeInterval]) {
        self.evidenceTimes = evidenceTimes
    }

    mutating func add(_ line: AnswerLine) {
        switch line {
        case .blank:
            flushParagraph()
        case let .text(text):
            paragraph.append(text)
        case let .bullet(level, text):
            append(.bullet(level: level, inline(text)))
        case let .numbered(number, text):
            append(.numbered(number: number, inline(text)))
        case let .heading(text):
            append(.heading(inline(text)))
        }
    }

    mutating func finish() -> [ChatBlock] {
        flushParagraph()
        return blocks
    }

    private mutating func append(_ block: ChatBlock) {
        flushParagraph()
        blocks.append(block)
    }

    private mutating func flushParagraph() {
        guard !paragraph.isEmpty else { return }
        blocks.append(.paragraph(inline(paragraph.joined(separator: "\n"))))
        paragraph = []
    }

    private func inline(_ text: String) -> AttributedString {
        ChatAnswerParser.inline(text, evidenceTimes: evidenceTimes)
    }
}

private extension Character {
    var isASCIIDigit: Bool {
        isASCII && isNumber
    }
}
