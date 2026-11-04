import ServiceManagement
import SwiftUI

@main
struct AppVolumeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("AppVolume", systemImage: "slider.vertical.3") {
            ContentView()
                .environment(appDelegate.controller)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = AudioController()

    func applicationWillTerminate(_ notification: Notification) {
        // Taps sauber entfernen, damit keine App stumm bleibt.
        controller.shutdown()
    }
}

/// „Bei Anmeldung starten“ über SMAppService (macOS 13+).
@MainActor @Observable
final class LoginItem {
    private(set) var isEnabled = SMAppService.mainApp.status == .enabled
    private(set) var error: String?

    func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        isEnabled = SMAppService.mainApp.status == .enabled
        if enabled, SMAppService.mainApp.status == .requiresApproval {
            error = "Bitte in den Systemeinstellungen → Anmeldeobjekte erlauben."
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}
