import SwiftUI
import UniformTypeIdentifiers
import AppKit
import WebKit

// MARK: - SettingsView

struct SettingsView: View {

    @ObservedObject var settings: AppSettings
    @ObservedObject var dataManager: DataManager

    @State private var selectedPane: SettingsPane = .platforms
    @State private var draggedProviderID: String?

    @State private var mimoCookieMessage: String?
    @State private var isShowingMimoPlatformLogin = false
    @State private var copilotLoginMessage: String?
    @State private var copilotLoginCode: String?
    @State private var isCopilotLoggingIn = false
    @State private var configRefreshID = 0

    private let refreshOptions: [(Double, String)] = [
        (900,  "15 分钟"),
        (1800, "30 分钟"),
        (3600, "1 小时"),
        (0,    "手动"),
    ]
    private let sidebarHorizontalPadding: CGFloat = 18
    private let sidebarItemHorizontalPadding: CGFloat = 12
    private let sidebarIconSize: CGFloat = 32
    private let sidebarHeaderIconSize: CGFloat = 44
    private let sidebarItemSpacing: CGFloat = 12
    private let sidebarHeaderSpacing: CGFloat = 12

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detailPane
        }
        .frame(minWidth: 980, idealWidth: 1040, minHeight: 680, idealHeight: 760)
        .background(Color(nsColor: .underPageBackgroundColor))
        .onAppear {
            loadMimoPlatformCookie()
        }
        .sheet(isPresented: $isShowingMimoPlatformLogin) {
            MimoPlatformLoginView { cookie in
                saveMimoPlatformCookie(cookie)
                isShowingMimoPlatformLogin = false
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            sidebarHeader
                .padding(.horizontal, sidebarHorizontalPadding)
                .padding(.top, 24)
                .padding(.bottom, 18)

            VStack(spacing: 2) {
                ForEach(SettingsPane.allCases) { pane in
                    sidebarRow(pane)
                }
            }
            .padding(.horizontal, sidebarHorizontalPadding)

            Spacer()

            Text("AIScope v1.0")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .padding(.bottom, 16)
        }
        .frame(width: 255)
        .background(.regularMaterial)
    }

    private var sidebarHeader: some View {
        HStack(spacing: sidebarHeaderSpacing) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: sidebarHeaderIconSize, height: sidebarHeaderIconSize)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 2) {
                Text("AIScope")
                    .font(.system(size: 22, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text("额度监控")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            
            Spacer()
        }
        .padding(.horizontal, sidebarItemHorizontalPadding)
    }

    private func sidebarRow(_ pane: SettingsPane) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedPane = pane
            }
        } label: {
            HStack(spacing: sidebarItemSpacing) {
                Image(systemName: pane.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(selectedPane == pane ? Color.secondary : .white)
                    .frame(width: sidebarIconSize, height: sidebarIconSize)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(selectedPane == pane ? AnyShapeStyle(Color.white.opacity(0.92)) : AnyShapeStyle(pane.color.gradient))
                            .shadow(color: Color.black.opacity(selectedPane == pane ? 0.16 : 0.10), radius: 2, y: 1)
                    )

                Text(pane.title)
                    .font(.system(size: 16, weight: selectedPane == pane ? .semibold : .medium))
                    .foregroundStyle(selectedPane == pane ? Color.white : Color.primary)

                Spacer()
            }
            .padding(.horizontal, selectedPane == pane ? 12 : sidebarItemHorizontalPadding)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(selectedPane == pane ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(Color.clear))
                    .shadow(color: Color.accentColor.opacity(selectedPane == pane ? 0.18 : 0), radius: 8, y: 3)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Detail Pane

    private var detailPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                detailHeader

                switch selectedPane {
                case .platforms:
                    platformsContent
                case .notifications:
                    refreshAndNotificationContent
                case .integrations:
                    integrationsContent
                }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 26)
            .frame(maxWidth: 860, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var detailHeader: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 10) {
                Image(systemName: selectedPane.icon)
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 82, height: 82)
                    .background(
                        RoundedRectangle(cornerRadius: 21)
                            .fill(selectedPane.color.gradient)
                    )
                    .shadow(color: Color.black.opacity(0.22), radius: 8, y: 3)

                Text(selectedPane.title)
                    .font(.system(size: 34, weight: .bold))
                Text(selectedPane.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 34)

            if selectedPane == .platforms {
                Button {
                    Task { await dataManager.refresh() }
                } label: {
                    Label("刷新全部", systemImage: "arrow.clockwise")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.bordered)
                .disabled(dataManager.isRefreshing || dataManager.isDetectingProviders)
                .padding(18)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.white.opacity(0.55))
        )
        .shadow(color: Color.black.opacity(0.035), radius: 12, y: 6)
    }

    // MARK: - Platforms

    private var platformsContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            settingsGroup {
                ForEach(Array(dataManager.orderedProviders.enumerated()), id: \.element.id) { index, provider in
                    platformRow(provider)
                        .contentShape(Rectangle())
                        .onDrop(
                            of: [.plainText],
                            delegate: ProviderDropDelegate(
                                targetID: provider.id,
                                draggedID: $draggedProviderID,
                                settings: settings,
                                allProviderIDs: dataManager.orderedProviders.map(\.id)
                            )
                        )

                    if index < dataManager.orderedProviders.count - 1 {
                        rowDivider
                    }
                }
            }

            Text("按住左侧拖动按钮调整顺序。关闭开关后，该工具不会出现在菜单栏面板中。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        }
    }

    private func platformRow(_ provider: any AIToolProvider) -> some View {
        let isDetected = dataManager.detectedProviderIDs.contains(provider.id)
        let isEnabled = settings.isEnabled(provider.id)
        let snapshot = dataManager.snapshots[provider.id]
        let visual = visual(for: provider.id)
        let isDragging = draggedProviderID == provider.id

        return HStack(alignment: .center, spacing: 12) {
            dragHandle(for: provider.id)

            providerIcon(visual: visual, isEnabled: isEnabled)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(provider.displayName)
                        .font(.body.weight(.medium))
                        .foregroundStyle(isEnabled ? Color.primary : Color.secondary)

                    if let plan = snapshot?.planName, isEnabled && isDetected {
                        Text(plan)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(visual.color)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(visual.color.opacity(0.12))
                            )
                    }
                    Spacer()
                    Toggle(isOn: Binding(
                        get: { isEnabled },
                        set: { newValue in
                            settings.setEnabled(newValue, for: provider.id)
                            Task { await dataManager.refresh() }
                        }
                    )) {
                        EmptyView()
                    }
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }

                if isEnabled && isDetected, let snapshot, snapshot.hasDisplayData {
                    QuotaInfoSection(snapshot: snapshot)
                } else {
                    Text(platformSummary(snapshot: snapshot, isDetected: isDetected, isEnabled: isEnabled))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isDragging ? Color.accentColor.opacity(0.10) : Color.clear)
        )
        .opacity(isDragging ? 0.82 : 1)
        .scaleEffect(isDragging ? 0.995 : 1)
        .animation(.snappy(duration: 0.18), value: dataManager.orderedProviders.map(\.id))
        .animation(.snappy(duration: 0.14), value: isDragging)
    }

    private func dragHandle(for providerID: String) -> some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 28, height: 30)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.08))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .onDrag {
                draggedProviderID = providerID
                return NSItemProvider(object: providerID as NSString)
            } preview: {
                Color.clear
                    .frame(width: 1, height: 1)
            }
            .help("拖动排序")
    }

    private func platformSummary(snapshot: UsageSnapshot?, isDetected: Bool, isEnabled: Bool) -> String {
        guard isEnabled else { return "已禁用" }
        guard isDetected else { return "未安装或未登录" }
        guard let snapshot else { return "等待刷新" }
        if snapshot.isError && !snapshot.hasDisplayData {
            return snapshot.errorMessage ?? "获取失败"
        }
        var parts: [String] = []
        if let pool = snapshot.pools.first {
            if pool.limit != nil {
                if pool.unit == "%" {
                    parts.append("剩余 \(pool.remainingDisplay)")
                } else {
                    parts.append("剩余 \(pool.remainingDisplay) / \(pool.limitDisplay) \(pool.unit)")
                }
            } else {
                parts.append(pool.unit == "%" ? pool.usedDisplay : "\(pool.usedDisplay) \(pool.unit)")
            }
            if let reset = pool.resetsInDescription {
                parts.append(reset)
            }
        } else if let window = snapshot.windows.first {
            parts.append("剩余 \(window.remainingPercent)%")
            if let reset = window.resetsInDescription {
                parts.append(reset)
            }
        }
        if snapshot.isError { parts.append("显示上次成功数据") }
        return parts.isEmpty ? "已连接" : parts.joined(separator: " · ")
    }

    // MARK: - Refresh & Notifications

    private var refreshAndNotificationContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsGroup {
                settingRow(icon: "timer", title: "自动刷新", subtitle: "控制后台同步频率") {
                    Picker("", selection: $settings.refreshInterval) {
                        ForEach(refreshOptions, id: \.0) { seconds, label in
                            Text(label).tag(seconds)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 120)
                }

                rowDivider

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        settingLabel(icon: "exclamationmark.triangle", title: "告警阈值", subtitle: "使用量超过阈值时提醒")
                        Spacer()
                        Text("\(Int((settings.alertThreshold * 100).rounded()))%")
                            .font(.callout.monospacedDigit().weight(.medium))
                            .foregroundStyle(thresholdColor)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(thresholdColor.opacity(0.12))
                            )
                    }
                    Slider(value: $settings.alertThreshold, in: 0.60...0.95, step: 0.05)
                        .tint(thresholdColor)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

                rowDivider

                settingRow(icon: "bell.badge", title: "额度告警通知", subtitle: "通过 macOS 通知提醒") {
                    Toggle("", isOn: $settings.notificationsEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                rowDivider

                settingRow(icon: "arrow.triangle.2.circlepath", title: "额度重置通知", subtitle: "额度周期到期重置时发送通知") {
                    Toggle("", isOn: $settings.refreshNotificationsEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }

            if !dataManager.activeProviders.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("各工具通知")
                        .font(.headline)
                        .padding(.horizontal, 4)

                    settingsGroup {
                        ForEach(Array(dataManager.activeProviders.enumerated()), id: \.element.id) { index, provider in
                            providerNotificationRow(provider)
                            if index < dataManager.activeProviders.count - 1 {
                                rowDivider
                            }
                        }
                    }
                    .disabled(!settings.notificationsEnabled)
                }
            }
        }
    }

    private func providerNotificationRow(_ provider: any AIToolProvider) -> some View {
        let v = visual(for: provider.id)
        return HStack(spacing: 12) {
            providerSmallIcon(visual: v)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                    .font(.body)
                Text("单独控制该工具的通知")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { !settings.isMuted(provider.id) },
                set: { newValue in
                    let currentlyMuted = settings.isMuted(provider.id)
                    if newValue == currentlyMuted {
                        settings.toggleMute(provider.id)
                    }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private func providerSmallIcon(visual v: ProviderVisual) -> some View {
        Group {
            if let assetName = v.assetName, let nsImage = NSImage(named: assetName) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: v.fallbackIcon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 30, height: 30)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    // MARK: - Integrations

    private var integrationsContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsGroup {
                ForEach(Array(dataManager.orderedProviders.enumerated()), id: \.element.id) { index, provider in
                    providerConfigRow(provider)
                    if index < dataManager.orderedProviders.count - 1 {
                        rowDivider
                    }
                }
            }
            .id(configRefreshID)

            if dataManager.orderedProviders.contains(where: { $0.id == "github-copilot" }) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("GitHub Copilot 授权")
                        .font(.headline)
                        .padding(.horizontal, 4)
                    settingsGroup { copilotConfigView }
                }
            }

            if dataManager.orderedProviders.contains(where: { $0.id == "mimocode" }) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("MiMo Token Plan 授权")
                        .font(.headline)
                        .padding(.horizontal, 4)
                    settingsGroup { mimoConfigView }
                }
            }
        }
    }

    private func providerConfigRow(_ provider: any AIToolProvider) -> some View {
        let isDetected = dataManager.detectedProviderIDs.contains(provider.id)
        let (source, status) = providerConfigSummary(provider.id)
        let v = visual(for: provider.id)
        let isActive = status.contains("已登录") || status.contains("已检测")

        return HStack(spacing: 12) {
            providerIcon(visual: v, isEnabled: isDetected)

            VStack(alignment: .leading, spacing: 3) {
                Text(provider.displayName)
                    .font(.body.weight(.medium))
                Text(source)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Text(status)
                .font(.caption.weight(.medium))
                .foregroundStyle(isActive ? .green : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isActive ? Color.green.opacity(0.12) : Color.secondary.opacity(0.10))
                )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private func providerConfigSummary(_ id: String) -> (source: String, status: String) {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        switch id {
        case "cursor":
            let path = home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb").path
            return ("本地 SQLite (Cursor)", fm.fileExists(atPath: path) ? "已检测" : "未检测")
        case "claude-code":
            let hasKeychain = !KeychainService.readAllGenericPasswords(
                service: "Claude Code-credentials",
                allowUserInteraction: false
            ).isEmpty
            return ("macOS Keychain", hasKeychain ? "已登录" : "未登录")
        case "github-copilot":
            return ("GitHub OAuth (AIScope)", CopilotProvider.readOAuthToken(allowUserInteraction: false) != nil ? "已登录" : "未登录")
        case "openai-codex":
            let authPath = home.appendingPathComponent(".codex/auth.json").path
            let hasFile = fm.fileExists(atPath: authPath)
            let hasKeychain = KeychainService.readGenericPasswordString(
                service: "Codex Auth",
                account: "Codex Auth",
                allowUserInteraction: false
            ) != nil
            if hasKeychain { return ("macOS Keychain", "已登录") }
            if hasFile { return ("~/.codex/auth.json", "已登录") }
            return ("Keychain 或 auth.json", "未登录")
        case "mimocode":
            let authPath = home.appendingPathComponent(".local/share/mimocode/auth.json").path
            let hasAuth = fm.fileExists(atPath: authPath)
            let hasCookie = MimocodeProvider.readPlatformCookie(allowUserInteraction: false) != nil
            if hasCookie { return ("平台 Cookie (Keychain)", "已登录") }
            if hasAuth { return ("本地 auth.json", "已检测 (需登录平台)") }
            return ("auth.json + 平台 Cookie", "未登录")
        case "qoder":
            let cnExists = fm.fileExists(atPath: NSString(string: "~/.qoder-cn").expandingTildeInPath)
            let cliExists = fm.fileExists(atPath: NSString(string: "~/.qoder-cli").expandingTildeInPath)
            if cnExists { return ("本地日志 (~/.qoder-cn)", "已检测") }
            if cliExists { return ("本地日志 (~/.qoder-cli)", "已检测") }
            return ("本地日志", "未安装")
        case "zcode-glm":
            let logsPath = home.appendingPathComponent(".zcode/v2/logs").path
            let cachePath = home.appendingPathComponent(".zcode/v2/coding-plan-cache.json").path
            if fm.fileExists(atPath: logsPath) { return ("本地日志 (~/.zcode)", "已检测") }
            if fm.fileExists(atPath: cachePath) { return ("ZCode 本地缓存", "已检测") }
            return ("ZCode 本地日志", "未安装")
        default:
            return ("未知", "未知")
        }
    }

    private var copilotConfigView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button {
                    startCopilotLogin()
                } label: {
                    Label(isCopilotLoggingIn ? "等待 GitHub" : "登录 GitHub", systemImage: "person.crop.circle.badge.checkmark")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(isCopilotLoggingIn)

                if isCopilotLoggingIn {
                    ProgressView()
                        .controlSize(.small)
                }

                statusMessage(copilotLoginMessage)
                Spacer()
            }

            if let copilotLoginCode {
                HStack(spacing: 10) {
                    Text(copilotLoginCode)
                        .font(.system(.title3, design: .monospaced).weight(.semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.accentColor.opacity(0.12))
                        )

                    Text("验证码已复制，请在浏览器中确认。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("将在系统浏览器打开 GitHub 授权，登录完成后自动刷新 Copilot 额度。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    private var mimoConfigView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button {
                    isShowingMimoPlatformLogin = true
                } label: {
                    Label("登录 MiMo", systemImage: "globe")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)

                statusMessage(mimoCookieMessage)
                Spacer()
            }

            Text("将在内置窗口打开 MiMo Token Plan，登录完成后自动保存平台登录态并刷新额度。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    // MARK: - Shared UI

    private var rowDivider: some View {
        Divider()
            .padding(.leading, 62)
    }

    private func settingsGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.white.opacity(0.55))
        )
        .shadow(color: Color.black.opacity(0.035), radius: 10, y: 5)
    }

    private func settingRow<Accessory: View>(
        icon: String,
        iconColor: Color = .accentColor,
        title: String,
        subtitle: String,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(spacing: 14) {
            settingIcon(icon, color: iconColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            accessory()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private func settingLabel(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 14) {
            settingIcon(icon, color: .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func settingIcon(_ icon: String, color: Color) -> some View {
        Image(systemName: icon)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 34, height: 34)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(color.gradient)
                    .shadow(color: Color.black.opacity(0.14), radius: 3, y: 1)
            )
    }

    private func providerIcon(visual v: ProviderVisual, isEnabled: Bool) -> some View {
        Group {
            if let assetName = v.assetName, let nsImage = NSImage(named: assetName) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 25, height: 25)
            } else {
                Image(systemName: v.fallbackIcon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isEnabled ? .white : .secondary)
            }
        }
        .frame(width: 36, height: 36)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: Color.black.opacity(0.12), radius: 3, y: 1)
        )
    }

    @ViewBuilder
    private func statusMessage(_ message: String?) -> some View {
        if let message {
            Text(message)
                .font(.caption)
                .foregroundStyle(message == "已保存" || message == "已登录" || message == "已检测用户名" || message == "Cookie 已保存" ? .green : .secondary)
        }
    }

    private struct ProviderVisual {
        let assetName: String?
        let fallbackIcon: String
        let color: Color
    }

    private func visual(for providerID: String) -> ProviderVisual {
        switch providerID {
        case "cursor":          return .init(assetName: "cursor", fallbackIcon: "pencil.and.scribble", color: .blue)
        case "claude-code":     return .init(assetName: "claude-code", fallbackIcon: "terminal", color: .orange)
        case "github-copilot":  return .init(assetName: "github-copilot", fallbackIcon: "chevron.left.forwardslash.chevron.right", color: .purple)
        case "openai-codex":    return .init(assetName: "openai-codex", fallbackIcon: "sparkles", color: .teal)
        case "mimocode":        return .init(assetName: "mimocode", fallbackIcon: "cube.fill", color: .pink)
        case "qoder":           return .init(assetName: "qoder", fallbackIcon: "q.square.fill", color: .indigo)
        case "zcode-glm":       return .init(assetName: "zai", fallbackIcon: "z.square.fill", color: .green)
        default:                return .init(assetName: nil, fallbackIcon: "questionmark.circle", color: .gray)
        }
    }

    private var thresholdColor: Color {
        let t = settings.alertThreshold
        if t >= 0.9 { return .red }
        if t >= 0.8 { return .orange }
        return .green
    }

    // MARK: - Config Actions

    private func startCopilotLogin() {
        guard !isCopilotLoggingIn else { return }

        isCopilotLoggingIn = true
        copilotLoginMessage = "正在启动登录..."
        copilotLoginCode = nil

        Task {
            do {
                let login = try await CopilotProvider.beginDeviceLogin()

                await MainActor.run {
                    copilotLoginCode = login.userCode
                    copilotLoginMessage = "等待浏览器授权..."
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(login.userCode, forType: .string)
                    NSWorkspace.shared.open(login.verificationURL)
                }

                let token = try await CopilotProvider.pollDeviceLogin(login)
                try CopilotProvider.saveOAuthToken(token)

                await MainActor.run {
                    isCopilotLoggingIn = false
                    copilotLoginCode = nil
                    copilotLoginMessage = "已登录"
                    configRefreshID += 1
                    Task { await dataManager.refresh() }
                }
            } catch {
                await MainActor.run {
                    isCopilotLoggingIn = false
                    copilotLoginCode = nil
                    copilotLoginMessage = error.localizedDescription
                }
            }
        }
    }

    private func loadMimoPlatformCookie() {
        if MimocodeProvider.readPlatformCookie(allowUserInteraction: false)?.isEmpty == false {
            mimoCookieMessage = "Cookie 已保存"
        } else {
            mimoCookieMessage = nil
        }
    }

    private func saveMimoPlatformCookie(_ cookie: String) {
        do {
            try MimocodeProvider.savePlatformCookie(cookie)
            mimoCookieMessage = "Cookie 已保存"
            configRefreshID += 1
            Task { await dataManager.refresh() }
        } catch {
            mimoCookieMessage = error.localizedDescription
        }
    }

}

// MARK: - MiMo Platform Login

private struct MimoPlatformLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var status = "登录后会自动保存 Cookie"

    let onCookie: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("MiMo 平台登录")
                        .font(.headline)
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("关闭") {
                    dismiss()
                }
            }
            .padding(14)

            Divider()

            MimoPlatformWebView(
                onCookie: onCookie,
                onStatus: { status = $0 }
            )
        }
        .frame(width: 980, height: 720)
    }
}

private struct MimoPlatformWebView: NSViewRepresentable {
    let onCookie: (String) -> Void
    let onStatus: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCookie: onCookie, onStatus: onStatus)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        context.coordinator.startPolling(webView)

        if let url = URL(string: "https://platform.xiaomimimo.com/token-plan") {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.stopPolling()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let onCookie: (String) -> Void
        private let onStatus: (String) -> Void
        private var timer: Timer?
        private var isChecking = false
        private var didSave = false

        init(onCookie: @escaping (String) -> Void, onStatus: @escaping (String) -> Void) {
            self.onCookie = onCookie
            self.onStatus = onStatus
        }

        func startPolling(_ webView: WKWebView) {
            stopPolling()
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self, weak webView] _ in
                guard let webView else { return }
                DispatchQueue.main.async {
                    self?.captureAndValidateCookie(from: webView)
                }
            }
        }

        func stopPolling() {
            timer?.invalidate()
            timer = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            captureAndValidateCookie(from: webView)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.targetFrame == nil, let requestURL = navigationAction.request.url {
                webView.load(URLRequest(url: requestURL))
            }
            return nil
        }

        private func captureAndValidateCookie(from webView: WKWebView) {
            guard !didSave, !isChecking else { return }

            isChecking = true
            onStatus("检测平台登录状态...")

            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self else { return }
                let header = Self.cookieHeader(from: cookies)
                guard !header.isEmpty else {
                    DispatchQueue.main.async {
                        self.isChecking = false
                        self.onStatus("等待平台登录...")
                    }
                    return
                }

                Task {
                    let isValid = await Self.validateCookieHeader(header)
                    await MainActor.run {
                        self.isChecking = false
                        guard !self.didSave else { return }
                        if isValid {
                            self.didSave = true
                            self.stopPolling()
                            self.onStatus("Cookie 已验证")
                            self.onCookie(header)
                        } else {
                            self.onStatus("等待平台登录...")
                        }
                    }
                }
            }
        }

        private static func cookieHeader(from cookies: [HTTPCookie]) -> String {
            cookies
                .filter { cookie in
                    cookie.domain.localizedCaseInsensitiveContains("xiaomimimo.com")
                        && (cookie.expiresDate == nil || cookie.expiresDate! > Date())
                }
                .sorted { $0.name < $1.name }
                .map { "\($0.name)=\($0.value)" }
                .joined(separator: "; ")
        }

        private static func validateCookieHeader(_ cookieHeader: String) async -> Bool {
            guard let url = URL(string: "https://platform.xiaomimimo.com/api/v1/tokenPlan/detail") else {
                return false
            }

            var request = URLRequest(url: url, timeoutInterval: 15)
            request.httpMethod = "GET"
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(Locale.preferredLanguages.first ?? "zh-CN", forHTTPHeaderField: "Accept-Language")
            request.setValue(TimeZone.current.identifier, forHTTPHeaderField: "x-timeZone")

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    return false
                }

                guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return false
                }
                if let code = root["code"] as? Int {
                    return code == 0 || code == 200
                }
                return root["data"] != nil
            } catch {
                return false
            }
        }
    }
}

// MARK: - Settings Pane

private enum SettingsPane: String, CaseIterable, Identifiable {
    case platforms
    case integrations
    case notifications

    var id: String { rawValue }

    var title: String {
        switch self {
        case .platforms:     return "平台管理"
        case .notifications: return "刷新与通知"
        case .integrations:  return "工具配置"
        }
    }

    var subtitle: String {
        switch self {
        case .platforms:     return "管理显示顺序、启用状态和本机检测结果。"
        case .notifications: return "设置刷新频率、告警阈值和通知开关。"
        case .integrations:  return "查看各工具的凭证来源与登录状态。"
        }
    }

    var icon: String {
        switch self {
        case .platforms:     return "square.grid.2x2"
        case .notifications: return "bell.and.waves.left.and.right"
        case .integrations:  return "key"
        }
    }

    var color: Color {
        switch self {
        case .platforms:     return .blue
        case .notifications: return .orange
        case .integrations:  return .purple
        }
    }
}

// MARK: - Drag Reordering

private struct ProviderDropDelegate: DropDelegate {
    let targetID: String
    @Binding var draggedID: String?
    let settings: AppSettings
    let allProviderIDs: [String]

    func validateDrop(info: DropInfo) -> Bool {
        draggedID != nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropEntered(info: DropInfo) {
        guard let draggedID, draggedID != targetID else { return }

        var ids = normalizedOrder()
        guard let fromIndex = ids.firstIndex(of: draggedID),
              let toIndex = ids.firstIndex(of: targetID)
        else { return }

        withAnimation(.snappy(duration: 0.18)) {
            ids.move(
                fromOffsets: IndexSet(integer: fromIndex),
                toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex
            )
            settings.providerOrder = ids
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedID = nil
        return true
    }

    private func normalizedOrder() -> [String] {
        let saved = settings.providerOrder.filter { allProviderIDs.contains($0) }
        return saved + allProviderIDs.filter { !saved.contains($0) }
    }
}
