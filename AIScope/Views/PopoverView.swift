import SwiftUI

// MARK: - PopoverView

/// 从 NSPopover 弹出的主面板。
struct PopoverView: View {

    @ObservedObject var dataManager: DataManager
    @ObservedObject var settings: AppSettings
    let openSettingsAction: () -> Void

    @State private var animateRefresh = false

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            if dataManager.activeProviders.isEmpty {
                if dataManager.isDetectingProviders {
                    detectingPlaceholder
                } else {
                    emptyPlaceholder
                }
            } else {
                toolList
            }

            footerBar
        }
        .background(.regularMaterial)
        .frame(width: 330)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - 标题栏

    private var headerBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("AIScope")
                    .font(.headline)
                    .fontWeight(.semibold)

                Text(refreshStateText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer()

            Button {
                Task { await dataManager.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(dataManager.isRefreshing ? Color.accentColor : Color.primary)
                    .rotationEffect(.degrees(animateRefresh ? 360 : 0))
                    .animation(
                        dataManager.isRefreshing
                            ? .linear(duration: 0.9).repeatForever(autoreverses: false)
                            : .easeOut(duration: 0.25),
                        value: animateRefresh
                    )
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(refreshButtonBackground))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(dataManager.isRefreshing)
            .onChange(of: dataManager.isRefreshing) { _, newValue in
                animateRefresh = newValue
            }
            .help(dataManager.isRefreshing ? "正在刷新..." : "刷新")

            // 齿轮：点击打开独立 Settings 窗口（不再是 popover 内的 sheet）
            Button { openSettingsAction() } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.secondary.opacity(0.15)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("设置…")

            // 退出按钮
            Button { NSApplication.shared.terminate(nil) } label: {
                Image(systemName: "power")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.red)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.red.opacity(0.15)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("退出 AIScope")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    // MARK: - 工具卡片列表

    private var toolList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 8) {
                ForEach(Array(dataManager.activeProviders.enumerated()), id: \.element.id) { index, provider in
                    let snapshot = dataManager.snapshots[provider.id]
                        ?? errorPlaceholderSnapshot(for: provider)
                    let status: ToolStatus = snapshot.isError
                        ? .offline
                        : ToolStatus.from(utilization: snapshot.maxUtilization)

                    ToolCardView(
                        snapshot: snapshot,
                        provider: provider,
                        status: status,
                        reauthenticateAction: reauthenticateAction(for: provider)
                    )
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color(nsColor: .controlBackgroundColor))
                        )
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .frame(maxHeight: 500)
    }

    // MARK: - 空状态占位

    private var detectingPlaceholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("正在检测工具...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var emptyPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass.circle")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)

            VStack(spacing: 4) {
                Text("还没有发现可用账号")
                    .font(.subheadline.weight(.semibold))
                Text("请先在对应工具中登录，然后点击刷新重新检测。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(dataManager.supportedProviderNames.joined(separator: " · "))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 34)
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack {
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    // MARK: - 辅助方法

    private var refreshButtonBackground: Color {
        dataManager.isRefreshing
            ? Color.accentColor.opacity(0.16)
            : Color.secondary.opacity(0.15)
    }

    private var refreshStateText: String {
        if dataManager.isRefreshing { return "正在刷新..." }
        guard let date = dataManager.lastRefreshed else { return "尚未刷新" }
        return "刷新于 \(relativeTimeString(from: date))"
    }

    private func relativeTimeString(from date: Date) -> String {
        let elapsed = Date().timeIntervalSince(date)
        switch elapsed {
        case ..<60:        return "刚刚"
        case 60..<3600:    return "\(Int(elapsed / 60)) 分钟前"
        case 3600..<86400: return "\(Int(elapsed / 3600)) 小时前"
        default:           return "\(Int(elapsed / 86400)) 天前"
        }
    }

    private func errorPlaceholderSnapshot(for provider: any AIToolProvider) -> UsageSnapshot {
        UsageSnapshot(
            providerID: provider.id, fetchedAt: Date(),
            windows: [], pools: [], extras: [],
            planName: nil, accountEmail: nil, billingCycleEnd: nil,
            errorMessage: "尚未获取到数据"
        )
    }

    private func reauthenticateAction(for provider: any AIToolProvider) -> (() -> Void)? {
        {
            if provider.id == "mimocode" {
                showMimoPlatformLogin()
            } else {
                openSettingsAction()
            }
        }
    }

    private func saveMimoPlatformCookie(_ cookie: String) {
        do {
            try MimocodeProvider.savePlatformCookie(cookie)
            Task { await dataManager.refresh() }
        } catch {
            openSettingsAction()
        }
    }

    private func showMimoPlatformLogin() {
        MimoPlatformLoginWindowController.shared.show { cookie in
            saveMimoPlatformCookie(cookie)
        }
    }
}
