import Foundation
import Combine

@MainActor
final class AppSettings: ObservableObject {

    // MARK: Refresh interval (seconds)
    @Published var refreshInterval: Double {
        didSet { UserDefaults.standard.set(refreshInterval, forKey: Keys.refreshInterval) }
    }

    // MARK: Alert threshold (0.0 – 1.0)
    @Published var alertThreshold: Double {
        didSet { UserDefaults.standard.set(alertThreshold, forKey: Keys.alertThreshold) }
    }

    // MARK: Notifications enabled
    @Published var notificationsEnabled: Bool {
        didSet { UserDefaults.standard.set(notificationsEnabled, forKey: Keys.notificationsEnabled) }
    }

    // MARK: Refresh notifications enabled
    @Published var refreshNotificationsEnabled: Bool {
        didSet { UserDefaults.standard.set(refreshNotificationsEnabled, forKey: Keys.refreshNotificationsEnabled) }
    }

    // MARK: Per-provider muted notifications
    @Published var mutedProviders: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(mutedProviders), forKey: Keys.mutedProviders)
        }
    }

    // MARK: Disabled providers (not shown in popover, not fetched)
    @Published var disabledProviders: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(disabledProviders), forKey: Keys.disabledProviders)
        }
    }

    // MARK: Custom provider display order
    @Published var providerOrder: [String] {
        didSet {
            UserDefaults.standard.set(providerOrder, forKey: Keys.providerOrder)
        }
    }

    // MARK: Settings window size
    @Published var settingsWindowWidth: CGFloat {
        didSet { UserDefaults.standard.set(Double(settingsWindowWidth), forKey: Keys.settingsWindowWidth) }
    }
    @Published var settingsWindowHeight: CGFloat {
        didSet { UserDefaults.standard.set(Double(settingsWindowHeight), forKey: Keys.settingsWindowHeight) }
    }

    init() {
        let ud = UserDefaults.standard
        refreshInterval     = ud.object(forKey: Keys.refreshInterval) as? Double ?? 1800
        alertThreshold      = ud.object(forKey: Keys.alertThreshold)  as? Double ?? 0.80
        notificationsEnabled = ud.object(forKey: Keys.notificationsEnabled) as? Bool ?? true
        refreshNotificationsEnabled = ud.object(forKey: Keys.refreshNotificationsEnabled) as? Bool ?? false
        mutedProviders      = Set(ud.stringArray(forKey: Keys.mutedProviders) ?? [])
        disabledProviders   = Set(ud.stringArray(forKey: Keys.disabledProviders) ?? [])
        providerOrder       = ud.stringArray(forKey: Keys.providerOrder) ?? []
        settingsWindowWidth  = ud.object(forKey: Keys.settingsWindowWidth) as? CGFloat ?? 960
        settingsWindowHeight = ud.object(forKey: Keys.settingsWindowHeight) as? CGFloat ?? 700
    }

    // MARK: Notification mute helpers

    func isMuted(_ providerID: String) -> Bool { mutedProviders.contains(providerID) }

    func toggleMute(_ providerID: String) {
        if mutedProviders.contains(providerID) {
            mutedProviders.remove(providerID)
        } else {
            mutedProviders.insert(providerID)
        }
    }

    // MARK: Provider enable/disable helpers

    func isEnabled(_ providerID: String) -> Bool {
        !disabledProviders.contains(providerID)
    }

    func setEnabled(_ enabled: Bool, for providerID: String) {
        if enabled {
            disabledProviders.remove(providerID)
        } else {
            disabledProviders.insert(providerID)
        }
    }

    private enum Keys {
        static let refreshInterval      = "refreshInterval"
        static let alertThreshold       = "alertThreshold"
        static let notificationsEnabled = "notificationsEnabled"
        static let refreshNotificationsEnabled = "refreshNotificationsEnabled"
        static let mutedProviders       = "mutedProviders"
        static let disabledProviders    = "disabledProviders"
        static let providerOrder        = "providerOrder"
        static let settingsWindowWidth  = "settingsWindowWidth"
        static let settingsWindowHeight = "settingsWindowHeight"
    }
}
