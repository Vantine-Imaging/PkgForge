import Observation
import SwiftUI

enum SettingsTab: String, Hashable, CaseIterable {
    case general
    case jamfPro
    case profiles
}

/// Lets a button elsewhere in the app open Settings *on a particular tab*.
/// `openSettings()` alone reopens whichever tab was last shown, which is rarely
/// the one the button was about.
@MainActor
@Observable
final class SettingsNavigator {
    var selection: SettingsTab = .general

    func show(_ tab: SettingsTab) {
        selection = tab
    }
}
