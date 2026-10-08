import Foundation
import ServiceManagement

/// "Launch at login" via SMAppService. Needs the app to run from a bundle, ideally in /Applications.
@MainActor
final class LoginItem: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var message: String?

    init() { reload() }

    func reload() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled
        message = status == .requiresApproval ? "Approve ChromeWatch in System Settings › Login Items." : nil
    }

    func set(_ enabled: Bool) {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            message = "Run the bundled ChromeWatch.app to use this."
            return
        }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            reload()
        } catch {
            reload()
            message = error.localizedDescription
        }
    }

    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}
