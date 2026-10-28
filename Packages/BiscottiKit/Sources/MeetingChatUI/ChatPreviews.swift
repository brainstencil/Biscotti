#if DEBUG
    import DataStore
    import DesignSystem
    import MeetingChat
    import SwiftUI

    // MARK: - Field

    #Preview("Field states") {
        ChatFieldGallery()
            .frame(width: 560)
            .background(Tokens.contentBackground)
    }

    #Preview("Field states, dark") {
        ChatFieldGallery()
            .frame(width: 560)
            .background(Tokens.contentBackground)
            .preferredColorScheme(.dark)
    }

    // MARK: - Card

    #Preview("Card, meeting page, complete with chips") {
        ChatCardPreview(state: ChatPreviewData.state(messages: ChatPreviewData.completeThread), placement: .meetingCard)
            .frame(width: 640, height: 560)
    }

    #Preview("Card, recording, streaming") {
        ChatCardPreview(
            state: ChatPreviewData.state(messages: ChatPreviewData.streamingThread, isAnswering: true),
            placement: .recordingCard
        )
        .frame(width: 760, height: 460)
    }

    #Preview("Card, before the first word") {
        ChatCardPreview(
            state: ChatPreviewData.state(messages: ChatPreviewData.statusThread, isAnswering: true),
            placement: .meetingCard
        )
        .frame(width: 640, height: 640)
    }

    #Preview("Card, stopped, failed, interrupted, unsaved") {
        ChatCardPreview(state: ChatPreviewData.state(messages: ChatPreviewData.endingsThread), placement: .meetingCard)
            .frame(width: 640, height: 760)
    }

    #Preview("Card, empty thread") {
        ChatCardPreview(state: ChatPreviewData.state(messages: [], hasThread: false), placement: .recordingCard)
            .frame(width: 760, height: 360)
    }

    #Preview("Card, unavailable") {
        ChatCardPreview(
            state: ChatPreviewData.state(messages: ChatPreviewData.completeThread, availability: .liveTranscriptOff),
            placement: .recordingCard
        )
        .frame(width: 760, height: 460)
    }

    #Preview("Card, dark") {
        ChatCardPreview(state: ChatPreviewData.state(messages: ChatPreviewData.completeThread), placement: .recordingCard)
            .frame(width: 760, height: 520)
            .preferredColorScheme(.dark)
    }

    // MARK: - History

    // Click the History button to open the menu: three threads, the second open.
    #Preview("History menu") {
        ChatCardPreview(
            state: ChatPreviewData.state(messages: ChatPreviewData.completeThread, openThread: 1),
            placement: .meetingCard
        )
        .frame(width: 640, height: 420)
    }

    // MARK: - Harnesses

    /// Every field state, in its placements.
    private struct ChatFieldGallery: View {
        var body: some View {
            VStack(alignment: .leading, spacing: Tokens.spacingSM + 2) {
                row("No thread", ChatPreviewData.state(messages: [], hasThread: false))
                row("Thread, card closed", ChatPreviewData.state(messages: ChatPreviewData.completeThread, isCardOpen: false))
                row("Card open (inside the card)", ChatPreviewData.state(messages: ChatPreviewData.completeThread), placement: .meetingCard)
                row("Text typed", ChatPreviewData.state(messages: [], hasThread: false, draft: "Who owns the release notes?"))
                row("Long text", ChatPreviewData.state(messages: [], hasThread: false, draft: ChatPreviewData.longDraft))
                row("Answering", ChatPreviewData.state(messages: ChatPreviewData.streamingThread, isAnswering: true, isCardOpen: false))
                ForEach(ChatPreviewData.unavailable, id: \.self) { availability in
                    row("\(availability)", ChatPreviewData.state(messages: [], hasThread: false, availability: availability))
                }
            }
            .padding(Tokens.spacingLG)
        }

        private func row(_ title: String, _ state: MeetingChatState, placement: ChatPlacement = .meetingPage) -> some View {
            VStack(alignment: .leading, spacing: Tokens.spacingXS) {
                Text(title).font(.monoCaption).foregroundStyle(.inkTertiary)
                ChatFieldPreview(state: state, placement: placement)
            }
        }
    }

    private struct ChatFieldPreview: View {
        let state: MeetingChatState
        let placement: ChatPlacement
        @State private var service = MeetingChatService.preview()
        @FocusState private var focus: Bool

        var body: some View {
            ChatQuestionField(state: state, service: service, placement: placement, focus: $focus) { action in
                if action == .openCard { state.isCardOpen = true }
            }
        }
    }

    /// The card over the page's paper, the recording placement with a stand-in toggle.
    private struct ChatCardPreview: View {
        let state: MeetingChatState
        let placement: ChatPlacement
        @State private var service = MeetingChatService.preview()
        @FocusState private var focus: Bool

        var body: some View {
            ChatCard(
                state: state, service: service, placement: placement, focus: $focus,
                onTime: { _ in }, onAction: { _ in },
                footerLeading: {
                    if placement == .recordingCard {
                        PreviewLiveToggle()
                    }
                }
            )
            .padding(.horizontal, Tokens.spacingMD)
            .padding(.top, Tokens.spacingMD)
            .padding(.bottom, Tokens.spacingMD + 4)
            .background(Tokens.contentBackground)
        }
    }

    /// Stands in for the recording screen's level-meter toggle.
    private struct PreviewLiveToggle: View {
        var body: some View {
            HStack(spacing: Tokens.spacingXS) {
                HStack(spacing: 2) {
                    ForEach([10.0, 16, 13, 8], id: \.self) { height in
                        Capsule().fill(Color.sage).frame(width: 3, height: height)
                    }
                }
                Image(systemName: "chevron.up")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.inkSecondary)
            }
            .frame(width: 44, height: 44)
        }
    }

    // MARK: - Data

    @MainActor
    private enum ChatPreviewData {
        static let meetingID = UUID()
        static let evidence: [TimeInterval] = [0, 4.5, 7.5, 11.5, 15.5, 42]
        static let unavailable: [ChatAvailability] = [.noModel, .liveTranscriptOff, .noTranscript, .transcribing, .answeringElsewhere]
        static let longDraft = String(repeating: "Can you list every decision about the beta, who owns it, and when it is due? ", count: 24)

        static let threads: [ChatThreadSummary] = {
            let now = Date()
            return [
                ChatThreadSummary(id: UUID(), meetingID: meetingID, title: "What did we decide about the beta?", createdAt: now, updatedAt: now.addingTimeInterval(-600)),
                ChatThreadSummary(id: UUID(), meetingID: meetingID, title: "Draft a follow-up email to the QA team about the crash fix and…", createdAt: now, updatedAt: now.addingTimeInterval(-3600)),
                ChatThreadSummary(id: UUID(), meetingID: meetingID, title: "Who owns the release notes?", createdAt: now, updatedAt: now.addingTimeInterval(-3 * 86400))
            ]
        }()

        static func state(
            messages: [ChatMessageView],
            hasThread: Bool = true,
            openThread: Int = 0,
            availability: ChatAvailability = .available,
            isAnswering: Bool = false,
            isCardOpen: Bool = true,
            draft: String = ""
        ) -> MeetingChatState {
            .preview(
                meetingID: meetingID,
                availability: availability,
                threads: hasThread ? threads : [],
                openThreadID: hasThread ? threads[openThread].id : nil,
                messages: messages,
                isAnswering: isAnswering,
                isCardOpen: isCardOpen,
                draft: draft
            )
        }

        static func question(_ text: String) -> (ChatMessageView, UUID) {
            let id = UUID()
            return (ChatMessageView(id: id, questionID: id, role: .question, text: text), id)
        }

        static func answer(
            to questionID: UUID,
            _ text: String,
            state: ChatMessageView.State = .complete,
            footer: String? = "Based on the transcript through 0:46",
            isUnsaved: Bool = false
        ) -> ChatMessageView {
            ChatMessageView(
                id: UUID(), questionID: questionID, role: .answer, text: text,
                blocks: ChatAnswerParser.blocks(text, evidenceTimes: evidence),
                state: state, footer: footer, isUnsaved: isUnsaved
            )
        }

        static let betaAnswer = """
        The beta goes out on **Monday** to the first fifty customers [0:00]. Two things were confirmed:

        - The crash fix from Friday is in the build [0:04].
        - QA signed off this morning [0:07, 0:11].

        The pricing page stays hidden until the Thursday review [0:11]. A time the transcript does not hold stays plain: [9:59].
        """

        static let emailAnswer = """
        ## Follow-up email

        1. Thank QA for signing off on the build [0:07].
        2. Confirm the release notes draft goes out tonight [0:15].
        3. Ask for the crash dashboard link before Monday.
        """

        static var completeThread: [ChatMessageView] {
            let (first, firstID) = question("What did we decide about the beta?")
            let (second, secondID) = question("Draft a short follow-up email to QA.")
            return [first, answer(to: firstID, betaAnswer), second, answer(to: secondID, emailAnswer, footer: nil)]
        }

        static var streamingThread: [ChatMessageView] {
            let (first, firstID) = question("What did we decide about the beta?")
            let (second, secondID) = question("And the pricing page?")
            return [
                first, answer(to: firstID, betaAnswer),
                second, answer(to: secondID, "It stays hidden until the **Thursday** review [0:11], and", state: .streaming(.streaming), footer: nil)
            ]
        }

        static var statusThread: [ChatMessageView] {
            let statuses: [ChatAnswerStatus] = [.loadingModel, .waitingForSummary, .waitingForRecordingToEnd, .thinking]
            return statuses.flatMap { status in
                let (asked, id) = question("Who owns the release notes?")
                return [asked, answer(to: id, "", state: .streaming(status), footer: nil)]
            }
        }

        static var endingsThread: [ChatMessageView] {
            let (stopped, stoppedID) = question("Summarize the whole meeting.")
            let (failed, failedID) = question("What did Priya say about the crash fix?")
            let (noBasis, noBasisID) = question("What happened before the break?")
            let (interrupted, interruptedID) = question("List the open questions.")
            let (unsaved, unsavedID) = question("When is the Thursday review?")
            return [
                stopped, answer(to: stoppedID, "The team agreed to ship the beta on Monday [0:00], and", state: .stopped),
                failed, answer(to: failedID, "Priya merged the crash fix [0:07]", state: .failed("The AI stopped before finishing.")),
                noBasis, answer(to: noBasisID, "", state: .failed("The AI model couldn't start."), footer: nil),
                interrupted, answer(to: interruptedID, "", state: .interrupted, footer: nil),
                unsaved, answer(to: unsavedID, "On Thursday, after the pricing review [0:11].", isUnsaved: true)
            ]
        }
    }
#endif
