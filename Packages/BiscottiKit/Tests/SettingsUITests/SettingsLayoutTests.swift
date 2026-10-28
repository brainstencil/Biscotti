import BiscottiTestSupport
import Foundation
import Testing
@testable import SettingsUI

@Suite("SettingsView -- layout")
struct SettingsLayoutTests {
    /// sectionTitles drives the rendered Section headers via indexed lookup
    /// (e.g. Section(Self.sectionTitles[0])), so this assertion verifies
    /// the titles AND their order as they appear on screen. The physical
    /// section ordering in `body` (which computed property appears first)
    /// is verified in the Phase 12 manual pass.
    @Test("section titles match spec order: General, Permissions, Notifications, AI, Vocab, People, Import/Export, Calendars")
    func sectionTitlesMatchSpec() {
        let expected = [
            "General",
            "Permissions",
            "Notifications",
            "AI Enhancements",
            "Custom Vocabulary",
            "People",
            "Import/Export",
            "Calendars"
        ]
        #expect(SettingsView.sectionTitles == expected)
    }

    /// aiEnhancementsHeaderCaption is used directly in the header HStack,
    /// so this assertion verifies the rendered caption text.
    @Test("AI Enhancements header caption renders correct text")
    func aiEnhancementsHeaderCaption() {
        #expect(
            SettingsView.aiEnhancementsHeaderCaption
                == "AI runs locally on your Mac."
        )
    }

    /// customVocabularyHeaderCaption is used directly in the header HStack,
    /// so this assertion verifies the rendered caption text. Remove the
    /// caption (and this test) when the feature leaves beta.
    @Test("Custom Vocabulary header caption marks the feature as beta")
    func customVocabularyHeaderCaption() {
        #expect(SettingsView.customVocabularyHeaderCaption == "Beta")
    }

    /// The Import/Export row titles and subtitles render directly in the
    /// section, and the "Learn more" link opens the user-facing guide.
    @Test("Import/Export row copy and guide URL match the spec")
    func importExportRowCopy() {
        #expect(SettingsView.importRowTitle == "Import Meetings")
        #expect(SettingsView.importRowSubtitle == "Import meetings from other apps, via CSV.")
        #expect(SettingsView.exportRowTitle == "Export Meetings")
        #expect(SettingsView.exportRowSubtitle == "Export all meetings to CSV.")
        #expect(
            SettingsView.importExportGuideURL
                == URL(
                    string: "https://github.com/scosman/Biscotti/blob/main/App/ImportingExporting.md"
                )
        )
    }
}

@Suite("SettingsViewModel -- People")
@MainActor
struct SettingsPeopleCountTests {
    @Test("reloadPeopleCount reflects the number of people")
    func peopleCount() async throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }
        let viewModel = SettingsViewModel(core: fixture.core)
        await viewModel.reloadPeopleCount()
        #expect(viewModel.peopleCount == 0)
        _ = try await fixture.store.findOrCreatePerson(name: "Paul", email: nil)
        _ = try await fixture.store.findOrCreatePerson(name: "Ann", email: nil)
        await viewModel.reloadPeopleCount()
        #expect(viewModel.peopleCount == 2)
    }
}
