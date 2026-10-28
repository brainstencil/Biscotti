import AppLinks
import DesignSystem
import PeopleUI
import SwiftUI

// MARK: - People section

extension SettingsView {
    var peopleSection: some View {
        Section(Self.sectionTitles[5]) {
            HStack {
                VStack(alignment: .leading, spacing: Tokens.spacingXS) {
                    Text("People")
                    Text("Rename, merge, and clean up the people Biscotti has identified.")
                        .font(Tokens.metadataFont)
                        .foregroundStyle(Tokens.secondaryText)
                }

                Spacer()

                Button("Manage (\(viewModel.peopleCount))") {
                    peopleListModel = PeopleListModel(core: viewModel.appCore)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .task { await viewModel.reloadPeopleCount() }
        .sheet(item: $peopleListModel, onDismiss: {
            Task { await viewModel.reloadPeopleCount() }
        }, content: { model in
            PeopleListSheet(model: model) { meetingID in
                peopleListModel = nil
                let core = viewModel.appCore
                Task { await core.apply(.meeting(id: meetingID, target: .tab(.transcript))) }
            }
        })
    }
}
