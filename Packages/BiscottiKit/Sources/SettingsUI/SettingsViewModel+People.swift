import Foundation

// MARK: - People

public extension SettingsViewModel {
    /// Refreshes the People row's count. Called when the section appears
    /// and when the People sheet closes.
    func reloadPeopleCount() async {
        peopleCount = await (try? appCore.store.allPersonData().count) ?? 0
    }
}
