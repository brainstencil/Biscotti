import Foundation

/// What the chat load driver (`Debug/ChatLoadDriver.swift`) hears from the
/// service: the recording's start and stop, and each answer's milestones.
/// Reported in debug builds only.
enum ChatLoadEvent {
    case recordingStarted(meetingID: UUID)
    case recordingStopped(meetingID: UUID)
    /// The broker lent the model to the answer. Reported when the model starts
    /// loading (`loadingModel`) and again when the answer gets the model; the
    /// first report is the lease's start.
    case leaseStarted(AnswerRun, loadingModel: Bool)
    case firstToken(AnswerRun)
    /// The answer ended, saved or not, and the answer slot is free.
    case ended(AnswerRun)
}

extension MeetingChatService {
    /// Tells the chat load driver, if one listens. Does nothing in release builds.
    func report(_ event: ChatLoadEvent) {
        #if DEBUG
            loadObserver?(event)
        #endif
    }
}
