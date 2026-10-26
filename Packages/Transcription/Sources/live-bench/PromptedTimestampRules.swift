import CoreML
import WhisperKit

/// WhisperKit's timestamp rules for decodes that carry a prompt: a diagnostic
/// for `--whisper-prompt settled-text-timestamp-rules`.
///
/// argmax-oss-swift 1.1.0 applies `TimestampRulesFilter` to a multilingual
/// model only when the task token is among the first three tokens. A prompt
/// puts `<|startofprev|>` and the prompt text first, so prompted decodes run
/// with no timestamp rules. This filter hands the same rules the tokens from
/// `<|startoftranscript|>` on, as an unprompted decode sees them. It runs
/// before WhisperKit's own filters, which do nothing for prompted decodes.
/// The initial timestamp stays unconstrained, as WhisperKit leaves it.
final class PromptedTimestampRules: LogitsFiltering, @unchecked Sendable {
    private let startOfPrevious: Int
    private let startOfTranscript: Int
    private let rules: TimestampRulesFilter

    init(specialTokens: SpecialTokens, isModelMultilingual: Bool) {
        startOfPrevious = specialTokens.startOfPreviousToken
        startOfTranscript = specialTokens.startOfTranscriptToken
        // An unprompted decode starts sampling after <|startoftranscript|>,
        // the language and task tokens (multilingual models) and <|0.00|>.
        rules = TimestampRulesFilter(
            specialTokens: specialTokens,
            sampleBegin: isModelMultilingual ? 4 : 2,
            maxInitialTimestampIndex: nil,
            isModelMultilingual: isModelMultilingual
        )
    }

    func filterLogits(_ logits: MLMultiArray, withTokens tokens: [Int]) -> MLMultiArray {
        guard tokens.first == startOfPrevious, let start = tokens.firstIndex(of: startOfTranscript) else { return logits }
        return rules.filterLogits(logits, withTokens: Array(tokens[start...]))
    }
}
