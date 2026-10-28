import DataStore
import DesignSystem
import Formatting
import SwiftUI

/// The person editor (ui_design.md §4): name and email fields, the
/// summary/title replacement choice, the person's meetings, the collision
/// banner, and merge mode. Shared by the speaker sheet and the People sheet.
public struct PersonEditorSheet: View {
    @Bindable var model: PersonEditorModel
    /// Opens a meeting. The host closes its sheets first.
    let onOpenMeeting: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss

    private enum Field: Hashable {
        case name, email
    }

    @FocusState private var focusedField: Field?

    public init(model: PersonEditorModel, onOpenMeeting: @escaping (UUID) -> Void) {
        self.model = model
        self.onOpenMeeting = onOpenMeeting
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spacingMD) {
            if model.mergeDraft != nil {
                MergeModeView(model: model, onDone: { dismiss() })
            } else {
                editMode
            }
        }
        .padding(Tokens.spacingLG)
        .frame(width: 520)
        .task {
            await model.load()
            focusedField = .name
        }
    }

    // MARK: - Edit mode

    private var editMode: some View {
        VStack(alignment: .leading, spacing: Tokens.spacingMD) {
            PeopleSheetHeader(kicker: "Person", title: model.savedName)
            fields
            if let title = model.collisionTitle {
                collisionBanner(title: title)
            }
            meetingsSection
            if let message = model.errorMessage {
                Text(message)
                    .font(Tokens.metadataFont)
                    .foregroundStyle(.signalRedText)
            }
            Divider()
            footer
        }
    }

    private var fields: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Tokens.spacingSM,
             verticalSpacing: Tokens.spacingSM)
        {
            GridRow {
                fieldLabel("Name")
                VStack(alignment: .leading, spacing: Tokens.spacingXS) {
                    TextField("", text: $model.nameText)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .name)
                        .onSubmit { save() }
                    inlineError(model.nameError)
                    replaceToggle
                }
            }
            GridRow {
                fieldLabel("Email")
                VStack(alignment: .leading, spacing: Tokens.spacingXS) {
                    TextField("Optional", text: $model.emailText)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .email)
                        .onSubmit { save() }
                    inlineError(model.emailError)
                }
            }
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.inkSecondary)
            .gridColumnAlignment(.trailing)
    }

    @ViewBuilder
    private func inlineError(_ message: String?) -> some View {
        if let message {
            Text(message)
                .font(Tokens.metadataFont)
                .foregroundStyle(.signalRedText)
        }
    }

    @ViewBuilder
    private var replaceToggle: some View {
        if model.showsReplaceToggle {
            ReplaceToggle(
                isOn: $model.replaceInText,
                label: model.replaceLabel,
                offCaption: model.replaceOffCaption
            )
        }
    }

    // MARK: - Collision banner

    private func collisionBanner(title: String) -> some View {
        VStack(alignment: .leading, spacing: Tokens.spacingSM) {
            HStack(alignment: .firstTextBaseline, spacing: Tokens.spacingSM) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.warningOchre)
                VStack(alignment: .leading, spacing: Tokens.spacingXS) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.ink)
                    Text(model.collisionHelp)
                        .font(Tokens.metadataFont)
                        .foregroundStyle(.inkSecondary)
                }
            }
            HStack {
                Spacer()
                Button("Keep Editing") { keepEditing() }
                Button(model.mergeButtonTitle ?? "Merge\u{2026}") {
                    Task { await model.beginMerge() }
                }
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.neutralChip))
    }

    private func keepEditing() {
        let field: Field = if case .email = model.collision { .email } else { .name }
        model.keepEditing()
        focusedField = field
    }

    // MARK: - Meetings

    private var meetingsSection: some View {
        VStack(alignment: .leading, spacing: Tokens.spacingSM) {
            if model.isLoaded {
                if model.meetings.isEmpty {
                    Text("Not in any meetings.")
                        .font(Tokens.metadataFont)
                        .foregroundStyle(.inkSecondary)
                } else {
                    Text(model.meetingsHeading)
                        .kicker()
                        .foregroundStyle(.inkTertiary)
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(model.meetings) { meeting in
                                MeetingRow(meeting: meeting, roles: model.rolesText(meeting)) {
                                    onOpenMeeting(meeting.id)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            if model.isMissing {
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSave)
            }
        }
    }

    private func save() {
        guard model.canSave else { return }
        Task {
            if await model.save() { dismiss() }
        }
    }
}

// MARK: - Shared pieces

/// Kicker + serif title used by the people sheets.
struct PeopleSheetHeader: View {
    let kicker: String
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spacingXS) {
            Text(kicker)
                .kicker()
                .foregroundStyle(.sage)
            Text(title)
                .font(.biscottiSerif(27))
                .tracking(-0.27)
                .foregroundStyle(.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.inkSecondary)
            }
        }
    }
}

/// The "Also change … in N summaries" checkbox with its off caption.
struct ReplaceToggle: View {
    @Binding var isOn: Bool
    let label: String
    let offCaption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(label, isOn: $isOn)
                .toggleStyle(.checkbox)
                .font(.system(size: 13))
            if !isOn {
                Text(offCaption)
                    .font(Tokens.metadataFont)
                    .foregroundStyle(.inkSecondary)
                    .padding(.leading, 20)
            }
        }
    }
}

/// One meeting in the editor's list: title, date, roles, chevron.
private struct MeetingRow: View {
    let meeting: PersonMeetingData
    let roles: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Tokens.spacingSM) {
                Text(meeting.title)
                    .font(.system(size: 13))
                    .foregroundStyle(.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Tokens.spacingSM)
                Text("\(TimeFormatting.shortDate(meeting.date))  \(roles)")
                    .font(Tokens.metadataFont)
                    .foregroundStyle(.inkSecondary)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10))
                    .foregroundStyle(.inkTertiary)
            }
            .padding(.horizontal, Tokens.spacingSM)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color.neutralChip : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
