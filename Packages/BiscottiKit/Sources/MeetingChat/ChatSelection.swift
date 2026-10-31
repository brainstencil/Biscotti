import Foundation

/// The passages of a long meeting that its prompt keeps: the opening, the
/// newest part of a live transcript, and the windows sharing the most
/// distinctive words with the question.
struct ChatSelection {
    /// A window ends at the first line starting this long after its first line.
    static let windowLength: TimeInterval = 60
    /// Windows starting this soon after the transcript's first line are always kept.
    static let openingLength: TimeInterval = 120
    /// For a live transcript, windows reaching into this last stretch are always kept.
    static let liveEndLength: TimeInterval = 300
    /// Characters per token when the transcript's own ratio is not known: on the safe side for English.
    static let defaultCharactersPerToken = 3.5
    /// The share of the transcript budget the estimate may fill; the real count checks the rest.
    static let budgetFill = 0.9

    struct Window {
        let entries: [ChatEvidenceEntry]
        let isAlwaysKept: Bool
        let score: Double

        var start: TimeInterval {
            entries.first?.start ?? 0
        }

        /// The window's lines as the transcript joins them, one line break each.
        var characters: Int {
            entries.reduce(0) { $0 + $1.formatted.count + 1 }
        }
    }

    private let windows: [Window]
    private(set) var kept: Set<Int>
    /// Kept windows that may be dropped, in the order they were added: highest score first.
    private var optionalKept: [Int]

    /// Selects windows for a transcript whose prompt must fit `transcriptBudget` tokens,
    /// estimating a window's tokens from its characters.
    static func select(
        entries: [ChatEvidenceEntry],
        question: String,
        isLive: Bool,
        transcriptBudget: Int,
        charactersPerToken: Double = defaultCharactersPerToken
    ) -> ChatSelection {
        let groups = windowEntries(entries)
        let terms = queryTerms(in: question)
        let windowTerms = groups.map { terms.intersection(words(in: $0.compactMap(\.line).map(searchText).joined(separator: " "))) }
        let documentFrequency = windowTerms.reduce(into: [String: Int]()) { counts, present in
            for term in present {
                counts[term, default: 0] += 1
            }
        }
        let windowCount = Double(groups.count)
        let alwaysKept = alwaysKeptWindows(groups, isLive: isLive)
        let windows = groups.indices.map { index in
            Window(
                entries: groups[index],
                isAlwaysKept: alwaysKept.contains(index),
                score: windowTerms[index].reduce(0) { $0 + log(1 + windowCount / Double(1 + documentFrequency[$1, default: 0])) }
            )
        }
        return ChatSelection(windows: windows, characterBudget: Double(transcriptBudget) * budgetFill * charactersPerToken)
    }

    /// Keeps the always-kept windows, then the others by score while their characters fit.
    private init(windows: [Window], characterBudget: Double) {
        self.windows = windows
        kept = Set(windows.indices.filter { windows[$0].isAlwaysKept })
        optionalKept = []
        var used = Double(kept.reduce(0) { $0 + windows[$1].characters })
        // Highest score first; ties go to the later window.
        let candidates = windows.indices
            .filter { !windows[$0].isAlwaysKept }
            .sorted { (windows[$0].score, $0) > (windows[$1].score, $1) }
        for index in candidates {
            let size = Double(windows[index].characters)
            guard used + size <= characterBudget else { break }
            used += size
            kept.insert(index)
            optionalKept.append(index)
        }
    }

    /// Drops the lowest-scoring window that is not always kept.
    /// - Returns: False when there is none left to drop.
    mutating func dropLowestScoringOptional() -> Bool {
        guard let index = optionalKept.popLast() else { return false }
        kept.remove(index)
        return true
    }

    /// The kept windows in time order. Each dropped stretch is marked
    /// `[12:30–18:45 not included]`, from its first line to the next kept
    /// line, or to its own last line at the end of the transcript.
    var transcript: String {
        var lines: [String] = []
        var droppedFrom: TimeInterval?
        for (index, window) in windows.enumerated() {
            guard kept.contains(index) else {
                droppedFrom = droppedFrom ?? window.start
                continue
            }
            if let start = droppedFrom {
                lines.append(ChatEvidence.rangeMarker(start ... window.start, note: "not included"))
                droppedFrom = nil
            }
            lines += window.entries.map(\.formatted)
        }
        if let start = droppedFrom, let end = windows.last?.entries.last?.start {
            // The spec marks only stretches between kept windows; a dropped end is marked too,
            // so the model knows the meeting goes on past the last line it sees.
            lines.append(ChatEvidence.rangeMarker(start ... end, note: "not included"))
        }
        return lines.joined(separator: "\n")
    }

    /// Starts of the kept lines, ascending.
    var evidenceTimes: [TimeInterval] {
        windows.indices.filter(kept.contains).flatMap { windows[$0].entries.compactMap(\.line?.start) }
    }

    // MARK: - Query terms

    /// The question's distinctive words: lowercased, letters and digits only,
    /// at least 3 characters, not a stopword.
    static func queryTerms(in question: String) -> Set<String> {
        words(in: question).filter { $0.count >= 3 && !stopwords.contains($0) }
    }

    static func words(in text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }

    /// Common English words, and words every question about a meeting uses.
    /// Words under 3 characters never count, so they are not listed.
    static let stopwords: Set<String> = [
        "about", "above", "after", "again", "against", "all", "also", "and", "any", "anyone", "anything",
        "are", "aren", "because", "been", "before", "being", "below", "between", "both", "but", "can",
        "could", "did", "didn", "discuss", "discussed", "does", "doesn", "doing", "don", "down", "during",
        "each", "else", "ever", "everyone", "few", "for", "from", "further", "get", "got", "had", "has",
        "have", "having", "her", "here", "hers", "herself", "him", "himself", "his", "how", "however", "into",
        "isn", "its", "itself", "just", "know", "let", "like", "made", "make", "many", "may", "meeting",
        "mention", "mentioned", "might", "more", "most", "much", "must", "myself", "nor", "not", "now", "off",
        "once", "only", "other", "our", "ours", "ourselves", "out", "over", "own", "please", "really", "said",
        "same", "say", "says", "shall", "she", "should", "some", "someone", "something", "such", "talk",
        "talked", "tell", "than", "that", "the", "their", "theirs", "them", "themselves", "then", "there",
        "these", "they", "thing", "things", "this", "those", "through", "too", "under", "until", "very",
        "want", "was", "wasn", "were", "weren", "what", "whats", "when", "where", "whether", "which", "while",
        "who", "whom", "whose", "why", "will", "with", "won", "would", "yes", "yet", "you", "your", "yours",
        "yourself", "yourselves"
    ]

    // MARK: - Private

    /// Lines in windows of about `windowLength`.
    private static func windowEntries(_ entries: [ChatEvidenceEntry]) -> [[ChatEvidenceEntry]] {
        var groups: [[ChatEvidenceEntry]] = []
        for entry in entries {
            if let first = groups.last?.first, entry.start < first.start + windowLength {
                groups[groups.count - 1].append(entry)
            } else {
                groups.append([entry])
            }
        }
        return groups
    }

    /// The opening, measured from the transcript's first line so a recording
    /// that starts in silence still keeps its first words; and for a live
    /// transcript, every window reaching into the last stretch before its last line.
    private static func alwaysKeptWindows(_ groups: [[ChatEvidenceEntry]], isLive: Bool) -> Set<Int> {
        guard let firstStart = groups.first?.first?.start, let lastStart = groups.last?.last?.start else { return [] }
        var indices = Set(groups.indices.filter { (groups[$0].first?.start ?? 0) < firstStart + openingLength })
        if isLive {
            let endFrom = lastStart - liveEndLength
            indices.formUnion(groups.indices.filter { index in
                index == groups.count - 1 || (groups[index + 1].first?.start ?? 0) > endFrom
            })
        }
        return indices
    }

    private static func searchText(_ line: ChatEvidenceLine) -> String {
        line.text + " " + line.unsettled
    }
}
