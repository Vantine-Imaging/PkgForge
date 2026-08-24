import Foundation
import Observation

/// The configuration a freshly dropped app starts from when it has no saved
/// profile.
///
/// Stock defaults suit the common case, but a site that always ships to a
/// different install location, or always wants a longer quit timeout, should
/// not have to correct the form on every new app.
@MainActor
@Observable
final class DefaultsStore {

    private static let key = "config.defaults"

    /// A `PackageConfiguration` used as a template. Its identifier and version
    /// are ignored — those always come from the bundle in front of you.
    var template: PackageConfiguration {
        didSet { persist() }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode(PackageConfiguration.self, from: data) {
            template = saved
        } else {
            template = PackageConfiguration()
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(template) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    /// The starting point for a bundle with no profile.
    func configuration(for bundle: AppBundle) -> PackageConfiguration {
        var configuration = template
        configuration.identifier = bundle.bundleIdentifier
        configuration.version = bundle.preferredVersion
        // Per-app rather than per-site: carrying these over would silently
        // apply one app's cleanup list to the next one dropped.
        configuration.rootStalePaths = template.rootStalePaths
        return configuration
    }

    func reset() {
        template = PackageConfiguration()
    }

    var isCustomised: Bool {
        template != PackageConfiguration()
    }
}
