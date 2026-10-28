import DataStore
import DesignSystem
import Formatting
import SwiftUI

/// Merge mode of the person editor (ui_design.md §4.3).
struct MergeModeView: View {
    @Bindable var model: PersonEditorModel
    let onDone: () -> Void

    var body: some View {
        if let draft = model.mergeDraft {
            VStack(alignment: .leading, spacing: Tokens.spacingMD) {
                PeopleSheetHeader(kicker: "Merge People", title: draft.title, subtitle: draft.subtitle)
                choices(draft)
                replaceToggles(draft)
                if !draft.sharedMeetings.isEmpty {
                    sharedWarning(draft)
                }
                if let message = model.errorMessage {
                    Text(message)
                        .font(Tokens.metadataFont)
                        .foregroundStyle(.signalRedText)
                }
                Text(draft.irreversibleNote)
                    .font(Tokens.metadataFont)
                    .foregroundStyle(.inkSecondary)
                Divider()
                footer
            }
        }
    }

    // MARK: - Choices

    private func choices(_ draft: MergeDraft) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Tokens.spacingSM,
             verticalSpacing: Tokens.spacingMD)
        {
            GridRow {
                label("Name")
                Picker("Name", selection: nameBinding) {
                    ForEach(draft.nameOptions, id: \.self) { option in
                        nameOptionLabel(option, draft: draft).tag(option)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }
            GridRow {
                label("Email")
                Picker("Email", selection: emailBinding) {
                    ForEach(draft.emailOptions, id: \.self) { option in
                        Text(option ?? "None").tag(option)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.inkSecondary)
            .gridColumnAlignment(.trailing)
    }

    private func nameOptionLabel(_ option: String, draft: MergeDraft) -> Text {
        if draft.isTypedName(option) {
            Text(option) + Text("  (typed)").foregroundStyle(.inkTertiary)
        } else {
            Text(option)
        }
    }

    private var nameBinding: Binding<String> {
        Binding(
            get: { model.mergeDraft?.name ?? "" },
            set: { newValue in Task { await model.chooseMergeName(newValue) } }
        )
    }

    private var emailBinding: Binding<String?> {
        Binding(
            get: { model.mergeDraft?.email },
            set: { model.mergeDraft?.email = $0 }
        )
    }

    // MARK: - Replacement

    @ViewBuilder
    private func replaceToggles(_ draft: MergeDraft) -> some View {
        if draft.showsSourceReplace {
            ReplaceToggle(
                isOn: Binding(
                    get: { model.mergeDraft?.replaceSource ?? false },
                    set: { model.mergeDraft?.replaceSource = $0 }
                ),
                label: draft.sourceReplaceLabel,
                offCaption: draft.replaceOffCaption(old: draft.source.name)
            )
        }
        if draft.showsTargetReplace {
            ReplaceToggle(
                isOn: Binding(
                    get: { model.mergeDraft?.replaceTarget ?? false },
                    set: { model.mergeDraft?.replaceTarget = $0 }
                ),
                label: draft.targetReplaceLabel,
                offCaption: draft.replaceOffCaption(old: draft.target.name)
            )
        }
    }

    // MARK: - Same-transcript warning

    private func sharedWarning(_ draft: MergeDraft) -> some View {
        VStack(alignment: .leading, spacing: Tokens.spacingXS) {
            HStack(spacing: Tokens.spacingSM) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.warningOchre)
                Text(draft.sharedHeading)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.ink)
            }
            Text(draft.sharedBody)
                .font(Tokens.metadataFont)
                .foregroundStyle(.inkSecondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(draft.sharedMeetings) { meeting in
                        Text("\(meeting.title) \u{00B7} \(TimeFormatting.shortDate(meeting.date))")
                            .font(Tokens.metadataFont)
                            .foregroundStyle(.ink)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 120)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Tokens.warningBackground))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            if model.isMissing {
                Button("Close") { onDone() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Back") { model.cancelMerge() }
                    .keyboardShortcut(.cancelAction)
                Button("Merge") {
                    Task {
                        if await model.confirmMerge() { onDone() }
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}
