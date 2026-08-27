import SwiftUI

@main
struct PkgForgeApp: App {
    @State private var profiles: ProfileStore
    @State private var defaults: DefaultsStore
    @State private var jamf = JamfSession()
    @State private var help = HelpNavigator()
    @State private var settingsNavigator = SettingsNavigator()
    @State private var controller: BuildController

    init() {
        // One store, shared: the controller writes profiles after a build and
        // the Settings window lists them.
        let store = ProfileStore()
        let defaultsStore = DefaultsStore()
        _profiles = State(initialValue: store)
        _defaults = State(initialValue: defaultsStore)
        _controller = State(initialValue: BuildController(profiles: store, defaults: defaultsStore))
    }

    var body: some Scene {
        Window("PkgForge", id: "main") {
            ContentView()
                .environment(controller)
                .environment(profiles)
                .environment(jamf)
                .environment(help)
                .environment(defaults)
                .environment(settingsNavigator)
                // P-5 — single window, 760 × 620 floor.
                .frame(minWidth: 760, minHeight: 620)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .newItem) {
                Button("Choose Application") { controller.chooseFile() }
                    .keyboardShortcut("o")
                Divider()
                Button("Build Package") { controller.startBuild() }
                    .keyboardShortcut("b")
                    .disabled(!controller.canBuild)
            }

            // Without this the Help menu holds one item that opens a
            // "help isn't available" dialog, which is worse than no menu.
            CommandGroup(replacing: .help) {
                HelpMenuItems()
                    .environment(help)
            }
        }

        Window("PkgForge Help", id: "help") {
            HelpView()
                .environment(help)
        }
        .defaultSize(width: 900, height: 620)
        .keyboardShortcut("?", modifiers: .command)

        Settings {
            SettingsView()
                .environment(profiles)
                .environment(jamf)
                .environment(defaults)
                .environment(settingsNavigator)
                .environment(settingsNavigator)
        }
    }
}
