import SwiftUI

// MARK: - AIScopeApp

/// 应用入口。
///
/// - Note: Info.plist 中须设置 `LSUIElement = YES`，应用仅显示 Menu Bar 图标，无 Dock 图标。
@main
struct AIScopeApp: App {

    @StateObject private var settings = AppSettings()
    @StateObject private var dataManager: DataManager
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        // DataManager 依赖 AppSettings，必须在构造时建立关联。
        // 使用 _property = StateObject(wrappedValue:) 完成 @StateObject 的外部初始化。
        let s = AppSettings()
        _settings = StateObject(wrappedValue: s)
        let dm = DataManager(settings: s)
        _dataManager = StateObject(wrappedValue: dm)

        // 把同一组实例注入到 AppDelegate，供 Menu Bar / Popover 使用
        appDelegate.dataManager = dm
        appDelegate.settings = s
    }

    var body: some Scene {
        // 真实 Settings 场景：SwiftUI 会自动接入菜单栏「AIScope → 设置...」与 ⌘, 快捷键
        Settings {
            SettingsView(settings: settings, dataManager: dataManager)
        }
    }
}
