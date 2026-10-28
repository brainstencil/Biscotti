/// What a failed answer says. Short sentences: they show under the answer, with Retry.
enum ChatErrorText {
    static let noTranscript = "There's no transcript to answer from yet."
    static let stoppedEarly = "The AI stopped before finishing."
    static let modelFailed = "The AI model couldn't start."
    static let tooLong = "This meeting is too long to answer from."
    static let unexpected = "Something went wrong while answering."
}
