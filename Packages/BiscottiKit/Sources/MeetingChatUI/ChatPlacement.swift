/// Where a question field or chat card sits. It decides the field's shadow
/// and what the card's footer holds.
public enum ChatPlacement: Sendable {
    /// The recording screen's bottom row, beside the live transcript's toggle.
    case recordingRow
    /// The chat card in the live transcript drawer's place.
    case recordingCard
    /// The band above the saved meeting page's playback bar.
    case meetingPage
    /// The chat card rising from the meeting page's field.
    case meetingCard

    /// The field inside a card has no shadow.
    var isInCard: Bool {
        self == .recordingCard || self == .meetingCard
    }
}

/// What the question field asks its host to do.
public enum ChatFieldAction: Sendable, Equatable {
    /// "Open Settings": Settings → AI Enhancements, to download the AI model.
    case openSettings
    /// "Turn On": the live transcript, during a recording.
    case turnOnLiveTranscript
    /// A click in a "Continue chat" field: reopen the card on its thread.
    /// The host opens it before returning; the field then asks for the
    /// cursor (`MeetingChatState.focusRequest`), which the card's field takes.
    case openCard
}
