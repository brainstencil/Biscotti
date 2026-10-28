#if DEBUG
    import DataStore
    import Foundation
    import Intelligence
    import LiveTranscriptionService
    import LocalLLM

    public extension MeetingChatState {
        /// A meeting's chat as SwiftUI previews show it: a fixed availability
        /// and the given threads, messages and flags. Not connected to a service.
        static func preview(
            meetingID: UUID = UUID(),
            availability: ChatAvailability = .available,
            threads: [ChatThreadSummary] = [],
            openThreadID: UUID? = nil,
            messages: [ChatMessageView] = [],
            isAnswering: Bool = false,
            isCardOpen: Bool = false,
            draft: String = ""
        ) -> MeetingChatState {
            let state = MeetingChatState(meetingID: meetingID) { _ in availability }
            state.threads = threads
            state.openThreadID = openThreadID
            state.messages = messages
            state.isAnswering = isAnswering
            state.isCardOpen = isCardOpen
            state.draft = draft
            return state
        }
    }

    public extension MeetingChatService {
        /// A service for SwiftUI previews, for the views' actions to call: an
        /// in-memory store, no AI model and an inert live transcript.
        static func preview() -> MeetingChatService {
            MeetingChatService(
                store: try! DataStore(storage: .inMemory), // swiftlint:disable:this force_try
                broker: LLMBroker(opener: PreviewChatOpener()),
                modelURL: { nil },
                live: .preview(drawerExpanded: false),
                recordingMeetingID: { nil },
                isTranscribing: { _ in false }
            )
        }
    }

    /// Previews never load a model.
    private struct PreviewChatOpener: LLMConnectionOpening {
        func open(model _: URL, config _: EngineConfig) async throws -> any LLMOpenSession {
            throw CancellationError()
        }
    }
#endif
