import Foundation
import Intelligence

/// How chat shares this Mac with a recording: whether a question asked during
/// a recording waits for it to stop, and whether the AI model stays loaded
/// after an answer.
public struct ChatResourcePolicy: Sendable, Equatable {
    public enum Mode: Sendable, Equatable {
        /// Answers run beside the recording and the live transcript.
        case concurrent
        /// A question asked during a recording waits until it stops.
        case waitForStop
    }

    public var physicalMemory: UInt64
    /// Macs with this much memory or less answer only after a recording
    /// stops.
    ///
    /// 8 GB is a proposal that waits for the user's review, and it departs
    /// from the measurement's decision rule
    /// (specs/projects/meeting_chat/research/chat_measurement). The rule
    /// keeps chat during recordings on a tier whose measured peak fits its
    /// budget, and Gemma 4 E2B with the live transcript peaked at 2.96 GB
    /// against an 8 GB Mac's 3 GB. The proposal makes 8 GB Macs wait anyway:
    /// the 0.04 GB margin is smaller than the figure's known error, which
    /// leaves out the live model's Neural Engine memory (about 0.2 to 0.3 GB)
    /// and samples once a second; and 8 GB Macs start with the live
    /// transcript off, so waiting costs them little.
    public var waitForStopMaximumMemory: UInt64
    /// During a recording, Macs with less memory than this close the model
    /// after each answer, to free its memory for the rest of the meeting.
    public var closeAfterAnswerBelowMemory: UInt64
    /// How long the model stays loaded after an answer otherwise.
    public var idleKeepAlive: Duration

    public init(
        physicalMemory: UInt64,
        waitForStopMaximumMemory: UInt64 = 8 << 30,
        closeAfterAnswerBelowMemory: UInt64 = 24 << 30,
        idleKeepAlive: Duration = .seconds(180)
    ) {
        self.physicalMemory = physicalMemory
        self.waitForStopMaximumMemory = waitForStopMaximumMemory
        self.closeAfterAnswerBelowMemory = closeAfterAnswerBelowMemory
        self.idleKeepAlive = idleKeepAlive
    }

    /// The policy for this Mac's memory.
    public static func forThisMac() -> ChatResourcePolicy {
        ChatResourcePolicy(physicalMemory: ProcessInfo.processInfo.physicalMemory)
    }

    /// What a question asked during a recording does. Outside a recording the
    /// mode does not apply.
    public func mode() -> Mode {
        physicalMemory <= waitForStopMaximumMemory ? .waitForStop : .concurrent
    }

    /// What the broker does with the model after an answer.
    public func keepAlive(isRecording: Bool) -> LLMKeepAlive {
        closesAfterAnswer(isRecording: isRecording) ? .close : .keepOpen(idleKeepAlive)
    }

    /// Whether the model is closed after each answer.
    func closesAfterAnswer(isRecording: Bool) -> Bool {
        isRecording && physicalMemory < closeAfterAnswerBelowMemory
    }
}
