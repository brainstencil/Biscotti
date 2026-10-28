import Foundation

/// Replaces a person's old name with the new one in stored text
/// (summaries, titles) after a rename.
///
/// An occurrence of `old` is replaceable when it matches exactly
/// (case-sensitive), sits on word boundaries, and is not part of an
/// occurrence of `new` or of any `protecting` name. The `new` rule keeps
/// `Paul` → `Paul Kowalski` from turning an existing "Paul Kowalski" into
/// "Paul Kowalski Kowalski"; `protecting` lets a merge keep the other
/// person's name intact.
public enum NameReplacement {
    /// The number of replaceable occurrences of `old` in `text`.
    public static func count(
        of old: String, replacingWith new: String, in text: String,
        protecting: [String] = []
    ) -> Int {
        replaceableRanges(of: old, new: new, in: text, protecting: protecting).count
    }

    /// `text` with every replaceable occurrence of `old` changed to `new`.
    public static func apply(
        old: String, new: String, to text: String, protecting: [String] = []
    ) -> String {
        let ranges = replaceableRanges(of: old, new: new, in: text, protecting: protecting)
        guard !ranges.isEmpty else { return text }
        // Build front to back from slices of the original text, so every
        // range is used against the string it was found in.
        var result = ""
        var cursor = text.startIndex
        for range in ranges {
            result += text[cursor ..< range.lowerBound]
            result += new
            cursor = range.upperBound
        }
        result += text[cursor...]
        return result
    }

    // MARK: - Private

    private static func replaceableRanges(
        of old: String, new: String, in text: String, protecting: [String]
    ) -> [Range<String.Index>] {
        guard !old.isEmpty, old != new else { return [] }
        let protected = ([new] + protecting)
            .filter { !$0.isEmpty && $0 != old }
            .flatMap { text.ranges(of: $0) }
        return text.ranges(of: old).filter { range in
            isWordBounded(range, in: text)
                && !protected.contains { $0.encloses(range) }
        }
    }

    private static func isWordBounded(
        _ range: Range<String.Index>, in text: String
    ) -> Bool {
        if range.lowerBound > text.startIndex,
           isWordCharacter(text[text.index(before: range.lowerBound)])
        {
            return false
        }
        if range.upperBound < text.endIndex,
           isWordCharacter(text[range.upperBound])
        {
            return false
        }
        return true
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }
}

private extension Range where Bound == String.Index {
    func encloses(_ other: Range<String.Index>) -> Bool {
        lowerBound <= other.lowerBound && other.upperBound <= upperBound
    }
}
