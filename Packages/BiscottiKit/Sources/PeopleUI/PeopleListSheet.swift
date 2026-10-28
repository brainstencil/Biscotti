import DataStore
import DesignSystem
import SwiftUI

/// The People sheet opened from Settings (ui_design.md §3).
public struct PeopleListSheet: View {
    @Bindable var model: PeopleListModel
    /// Opens a meeting. The host closes its sheets first.
    let onOpenMeeting: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var filterFocused: Bool

    public init(model: PeopleListModel, onOpenMeeting: @escaping (UUID) -> Void) {
        self.model = model
        self.onOpenMeeting = onOpenMeeting
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spacingMD) {
            PeopleSheetHeader(
                kicker: "Settings", title: "People",
                subtitle: "Everyone Biscotti has identified in your meetings."
            )
            TextField("Filter by name or email\u{2026}", text: $model.filter)
                .textFieldStyle(.roundedBorder)
                .focused($filterFocused)
            list
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Tokens.spacingLG)
        .frame(width: 560)
        .task {
            await model.load()
            filterFocused = true
        }
        .sheet(item: $model.editor, onDismiss: {
            Task { await model.editorDidClose() }
        }, content: { editor in
            PersonEditorSheet(model: editor) { meetingID in
                model.editor = nil
                onOpenMeeting(meetingID)
            }
        })
    }

    // MARK: - List

    @ViewBuilder
    private var list: some View {
        if model.isLoaded, model.rows.isEmpty {
            placeholder(model.emptyText)
        } else if model.isLoaded, model.filteredRows.isEmpty {
            placeholder(model.noMatchText)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.filteredRows) { row in
                        personRow(row)
                        if row.id != model.filteredRows.last?.id {
                            Divider()
                        }
                    }
                }
            }
            .frame(maxHeight: 400)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(Tokens.metadataFont)
            .foregroundStyle(Tokens.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, Tokens.spacingMD)
    }

    private func personRow(_ row: PersonOverviewData) -> some View {
        HStack(spacing: Tokens.spacingSM) {
            VStack(alignment: .leading, spacing: 1) {
                Text(row.person.name)
                    .font(.system(size: 14))
                    .foregroundStyle(.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let email = row.person.email {
                    Text(email)
                        .font(.caption)
                        .foregroundStyle(.inkSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Tokens.spacingSM)
            Text(model.metaText(row))
                .font(Tokens.metadataFont)
                .foregroundStyle(.inkSecondary)
                .lineLimit(1)
            Button {
                model.edit(row)
            } label: {
                Image(systemName: "pencil")
                    .foregroundStyle(.inkSecondary)
            }
            .buttonStyle(.plain)
            .help("Edit\u{2026}")
            Button {
                Task { await model.delete(row) }
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(row.meetingCount == 0 ? Color.signalRedText : Color.inkTertiary)
            }
            .buttonStyle(.plain)
            .disabled(row.meetingCount > 0)
            .help(model.deleteHelp(row))
        }
        .padding(.vertical, 6)
        .padding(.horizontal, Tokens.spacingSM)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.edit(row) }
    }
}
