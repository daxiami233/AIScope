import AppKit
import SwiftUI
import Combine
import UserNotifications
import OSLog

private let appDelegateLogger = Logger(subsystem: "com.aiscope.app", category: "AppDelegate")

// MARK: - AppDelegate

/// 管理 NSStatusItem（Menu Bar 图标）与 NSPopover（弹出面板）的完整生命周期。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    var statusItem: NSStatusItem?
    var popover: NSPopover?

    /// 由 AIScopeApp 在 init 中注入，与 Settings 场景共享同一实例
    var dataManager: DataManager?
    var settings: AppSettings?

    private var cancellables = Set<AnyCancellable>()

    /// 用于监听 popover 外部点击并自动收起的监控器句柄
    private var outsideClickMonitor: Any?
    private var localClickMonitor: Any?

    private var settingsWindow: NSWindow?

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        if terminateDuplicateInstanceIfNeeded() { return }

        guard let dm = dataManager else { return }

        setupStatusItem()
        setupPopover()
        requestNotificationPermission()
        setupMenuBarIconUpdates()

        Task {
            await dm.detectProviders()
            await dm.refresh(redetect: false)
        }
        dm.startAutoRefresh()
    }

    private func terminateDuplicateInstanceIfNeeded() -> Bool {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return false }

        let currentPID = ProcessInfo.processInfo.processIdentifier
        let currentBundlePath = Bundle.main.bundleURL.standardizedFileURL.path
        let currentIsInstalledApp = currentBundlePath == "/Applications/AIScope.app"

        let duplicates = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == bundleIdentifier && $0.processIdentifier != currentPID
        }
        guard !duplicates.isEmpty else { return false }

        if currentIsInstalledApp {
            for duplicate in duplicates {
                duplicate.terminate()
            }
            appDelegateLogger.info("发现重复 AIScope 实例，已保留 /Applications 版本并请求退出其他实例")
            return false
        }

        if let installedApp = duplicates.first(where: {
            $0.bundleURL?.standardizedFileURL.path == "/Applications/AIScope.app"
        }) {
            installedApp.activate()
            appDelegateLogger.info("检测到 /Applications 中的 AIScope 已在运行，当前副本退出")
            NSApp.terminate(nil)
            return true
        }

        duplicates.first?.activate()
        appDelegateLogger.info("检测到 AIScope 已在运行，当前副本退出")
        NSApp.terminate(nil)
        return true
    }

    // MARK: - StatusItem 配置

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem?.button else { return }

        if let image = NSImage(named: "statusbar-icon") {
            image.size = NSSize(width: 18, height: 18)
            button.image = image
        }

        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.action = #selector(handleStatusItemClick(_:))
        button.target = self
    }

    // MARK: - Popover 配置

    private func setupPopover() {
        guard let dm = dataManager, let appSettings = settings else { return }

        let popover = NSPopover()
        popover.contentSize = NSSize(width: 330, height: 500)
        // .applicationDefined：不依赖系统 transient 启发式，由我们自己通过
        // outside-click monitor 控制何时关闭，确保「点击其他区域自动收起」稳定生效。
        popover.behavior = .applicationDefined

        let rootView = PopoverView(
            dataManager: dm,
            settings: appSettings,
            openSettingsAction: { [weak self] in
                self?.openSettings()
            }
        )
        popover.contentViewController = NSHostingController(rootView: rootView)
        self.popover = popover
    }

    // MARK: - 通知权限申请

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error { appDelegateLogger.error("通知权限请求失败：\(error.localizedDescription)") }
        }
    }

    // MARK: - Menu Bar 图标颜色更新

    private func setupMenuBarIconUpdates() {
        guard let dm = dataManager else { return }
        dm.$snapshots
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateStatusItemIcon() }
            .store(in: &cancellables)
    }

    private func updateStatusItemIcon() {
        guard let button = statusItem?.button, let dm = dataManager else { return }
        let nsColor: NSColor
        switch dm.overallStatus {
        case .normal:   nsColor = .systemGreen
        case .warning:  nsColor = .systemOrange
        case .critical: nsColor = .systemRed
        case .offline:  nsColor = .secondaryLabelColor
        }
        button.contentTintColor = nsColor
    }

    // MARK: - 点击分发

    @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showContextMenu(on: sender)
        } else {
            togglePopover(sender)
        }
    }

    private func togglePopover(_ sender: NSStatusBarButton) {
        guard let popover else { return }
        if popover.isShown {
            closePopover()
        } else {
            Task { [weak self] in await self?.dataManager?.refreshIfStale() }
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.becomeKey()
            NSApp.activate(ignoringOtherApps: true)
            installOutsideClickMonitor()
        }
    }

    private func closePopover() {
        guard let popover, popover.isShown else { return }
        popover.performClose(nil)
        removeOutsideClickMonitor()
    }

    // MARK: - 外部点击监控

    /// 在 popover 显示期间安装全局鼠标监控：一旦点击落在 popover 窗口之外，自动收起。
    private func installOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self, let popover = self.popover, popover.isShown else { return }
            let popoverWindow = popover.contentViewController?.view.window
            if let window = popoverWindow, event.window !== window {
                Task { @MainActor in self.closePopover() }
            } else if popoverWindow == nil {
                Task { @MainActor in self.closePopover() }
            }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, let popover = self.popover, popover.isShown else { return event }
            if let settingsWindow = self.settingsWindow, settingsWindow.isVisible, event.window === settingsWindow {
                self.closePopover()
            }
            return event
        }
    }

    private func removeOutsideClickMonitor() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
        if let monitor = localClickMonitor {
            NSEvent.removeMonitor(monitor)
            localClickMonitor = nil
        }
    }

    // MARK: - 右键上下文菜单

    private func showContextMenu(on sender: NSStatusBarButton) {
        let menu = buildContextMenu()
        // popUpContextMenu 是阻塞式调用，菜单关闭后才返回，
        // 无需维护 statusItem.menu 状态，也无需 NSMenuDelegate。
        // 调用链上 NSApp.currentEvent 已被 guard let 校验过非空。
        NSMenu.popUpContextMenu(menu, with: NSApp.currentEvent!, for: sender)
    }

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()

        let refreshItem = NSMenuItem(title: "刷新", action: #selector(refreshAction), keyEquivalent: "")
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "退出 AIScope", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
        return menu
    }

    @objc private func refreshAction() {
        guard let dm = dataManager else { return }
        Task { await dm.refresh() }
    }

    @objc func openSettings() {
        closePopover()
        showSettingsWindow()
    }

    func showSettingsWindow() {
        guard let dm = dataManager, let appSettings = settings else { return }

        if let settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            settingsWindow.makeKeyAndOrderFront(nil)
            settingsWindow.orderFrontRegardless()
            return
        }

        let width = max(appSettings.settingsWindowWidth, 900)
        let height = max(appSettings.settingsWindowHeight, 640)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AIScope 设置"
        window.minSize = NSSize(width: 900, height: 640)
        window.contentViewController = NSHostingController(
            rootView: SettingsView(settings: appSettings, dataManager: dm)
        )
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        settingsWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    // MARK: - NSWindowDelegate

    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === settingsWindow else { return }
        let size = window.frame.size
        settings?.settingsWindowWidth = size.width
        settings?.settingsWindowHeight = size.height
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === settingsWindow else { return }
        let size = window.frame.size
        settings?.settingsWindowWidth = size.width
        settings?.settingsWindowHeight = size.height
    }
}
