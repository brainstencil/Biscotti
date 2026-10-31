import AppShellUI
import SwiftUI

/// View > Ask About This Meeting (⌘J), after Show Live Transcript (⌘T).
struct MeetingChatCommands: Commands {
    let model: ChatCommandModel

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            AskAboutMeetingMenuItem(model: model)
        }
    }
}

/// Reads the model in a view `body`, where observation tracking is reliable
/// (scene and command builders do not track it reliably).
private struct AskAboutMeetingMenuItem: View {
    let model: ChatCommandModel

    var body: some View {
        Button("Ask About This Meeting") {
            model.perform()
        }
        .keyboardShortcut("j", modifiers: .command)
        .disabled(!model.isAvailable)
    }
}
