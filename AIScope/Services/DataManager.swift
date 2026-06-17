import Foundation
import Combine
import UserNotifications
import OSLog

private let dataManagerLogger = Logger(subsystem: "com.aiscope.app", category: "DataManager")

// MARK: - FetchResult

/// TaskGroup 内部传递结果用，需要 Sendable（Swift 6）
private enum FetchResult: Sendable {
    case success(providerID: String, snapshot: UsageSnapshot)
    case failure(providerID: String, message: String)
}

// MARK: - DataManager

/// 数据管理器：持有所有 Provider 实例，负责刷新调度、快照聚合、本地缓存及系统通知。
/// 全部属性与方法隔离在主 actor 上，保证 @Published 属性的 UI 安全更新。
@MainActor
final class DataManager: ObservableObject {

    // MARK: - 对外发布的状态

    /// key = providerID，每个 AI 工具最新的使用快照
    @Published var snapshots: [String: UsageSnapshot] = [:]

    /// 经 detect() 确认已安装且有凭证的活跃 Provider 列表
    @Published var activeProviders: [any AIToolProvider] = []

    /// 所有通过 detect() 的 provider ID（包含被禁用的），供设置界面判断安装状态
    @Published var detectedProviderIDs: Set<String> = []

    /// 是否正在检测本机工具与凭证
    @Published var isDetectingProviders: Bool = false

    /// 是否正在执行刷新（防止并发重复触发）
    @Published var isRefreshing: Bool = false

    /// 上次刷新流程结束的时间
    @Published var lastRefreshed: Date?

    // MARK: - 公开属性

    let settings: AppSettings

    var supportedProviderNames: [String] {
        allProviders.map(\.displayName)
    }

    // MARK: - 内部属性

    let allProviders: [any AIToolProvider]

    /// 按用户自定义排序后的 provider 列表，未在 providerOrder 中的追加到末尾
    var orderedProviders: [any AIToolProvider] {
        let order = settings.providerOrder
        return allProviders.sorted { a, b in
            let ai = order.firstIndex(of: a.id) ?? Int.max
            let bi = order.firstIndex(of: b.id) ?? Int.max
            return ai < bi
        }
    }

    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()

    /// 已发送过告警通知的 providerID 集合，用于首次超阈值才通知的去重逻辑
    private var notifiedProviders: Set<String> = []

    private let cacheKey = "aiscope_cached_snapshots"

    // MARK: - 初始化

    init(settings: AppSettings) {
        self.settings = settings
        self.allProviders = [
            CursorProvider(),
            ClaudeCodeProvider(),
            CopilotProvider(),
            CodexProvider(),
            MimocodeProvider(),
            QoderProvider(),
            ZCodeProvider()
        ]
        loadCachedSnapshots()
        observeSettingsChanges()
    }

    // MARK: - Provider 检测

    /// 并发调用所有 Provider 的 detect()，将返回 true 的加入 activeProviders。
    func detectProviders() async {
        guard !isDetectingProviders else { return }
        isDetectingProviders = true
        defer { isDetectingProviders = false }

        let providers = allProviders
        var detectedIDs = Set<String>()
        await withTaskGroup(of: (String, Bool).self) { group in
            for provider in providers {
                group.addTask {
                    let available = await provider.detect()
                    return (provider.id, available)
                }
            }
            for await (providerID, available) in group {
                if available { detectedIDs.insert(providerID) }
            }
        }
        detectedProviderIDs = detectedIDs
        activeProviders = orderedProviders.filter {
            detectedIDs.contains($0.id) && settings.isEnabled($0.id)
        }
    }

    // MARK: - 刷新

    /// 并发刷新所有活跃 Provider，更新 snapshots，完成后写缓存并检查通知。
    /// 带有 20 秒硬超时兜底，避免 URLSession 在网络异常时 timeoutInterval 失效导致 UI 无限转圈。
    func refresh(redetect: Bool = true) async {
        guard !isRefreshing else { return }
        isRefreshing = true

        // 看门狗：20 秒后强制结束刷新状态。主流程正常完成时会 cancel 这个 task。
        // 两个 task 都跑在 MainActor 上，写 isRefreshing 无竞争。
        let watchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled, let self else { return }
            dataManagerLogger.warning("刷新超时 20s，强制结束")
            self.isRefreshing = false
            self.lastRefreshed = Date()
        }

        defer {
            watchdog.cancel()
            // 若主流程在 watchdog 触发前完成，确保 isRefreshing 复位
            if isRefreshing {
                isRefreshing = false
                lastRefreshed = Date()
            }
        }

        if redetect {
            await detectProviders()
        }

        let providers = activeProviders
        let snapshotsBeforeRefresh = snapshots

        // Swift 6: Result<T, any Error> 不满足 Sendable，改用自定义 Sendable 枚举传递结果
        await withTaskGroup(of: FetchResult.self) { group in
            for provider in providers {
                group.addTask {
                    do {
                        let snapshot = try await provider.fetchUsage()
                        return .success(providerID: provider.id, snapshot: snapshot)
                    } catch {
                        return .failure(providerID: provider.id, message: error.localizedDescription)
                    }
                }
            }

            for await result in group {
                switch result {
                case .success(let providerID, let snapshot):
                    snapshots[providerID] = snapshot

                case .failure(let providerID, let errorMessage):
                    let previous = snapshots[providerID]
                    snapshots[providerID] = UsageSnapshot(
                        providerID: providerID,
                        fetchedAt: previous?.fetchedAt ?? Date(),
                        windows: previous?.windows ?? [],
                        pools: previous?.pools ?? [],
                        extras: previous?.extras ?? [],
                        planName: previous?.planName,
                        accountEmail: previous?.accountEmail,
                        billingCycleEnd: previous?.billingCycleEnd,
                        errorMessage: errorMessage
                    )
                }
            }
        }

        saveSnapshotsToCache()
        checkAndSendNotifications()
        sendResetNotificationsIfNeeded(previousSnapshots: snapshotsBeforeRefresh)
    }

    /// 若距上次刷新超过 threshold 秒（默认 5 分钟），则触发一次刷新。
    func refreshIfStale(threshold: TimeInterval = 300) async {
        guard let last = lastRefreshed else {
            await refresh()
            return
        }
        if Date().timeIntervalSince(last) > threshold {
            await refresh()
        }
    }

    // MARK: - 定时器

    func startAutoRefresh() {
        stopAutoRefresh()
        let interval = settings.refreshInterval
        guard interval > 0 else { return }  // 0 = 手动模式
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refresh()
            }
        }
    }

    func stopAutoRefresh() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - 整体状态

    /// 取所有快照中优先级最高的 ToolStatus，用于 Menu Bar 图标着色。
    var overallStatus: ToolStatus {
        let statuses: [ToolStatus] = activeProviders.map { provider in
            guard let snapshot = snapshots[provider.id] else { return .offline }
            return snapshot.isError ? .offline : ToolStatus.from(utilization: snapshot.maxUtilization)
        }
        return statuses.max(by: { $0.priority < $1.priority }) ?? .offline
    }

    // MARK: - 缓存读写

    private func loadCachedSnapshots() {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            snapshots = try decoder.decode([String: UsageSnapshot].self, from: data)
        } catch {
            dataManagerLogger.error("缓存加载失败：\(error.localizedDescription)")
        }
    }

    private func saveSnapshotsToCache() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            let data = try encoder.encode(snapshots)
            UserDefaults.standard.set(data, forKey: cacheKey)
        } catch {
            dataManagerLogger.error("缓存保存失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 通知逻辑

    private func checkAndSendNotifications() {
        guard settings.notificationsEnabled else { return }
        let threshold = settings.alertThreshold

        for (providerID, snapshot) in snapshots {
            guard !settings.isMuted(providerID), !snapshot.isError else {
                notifiedProviders.remove(providerID)
                continue
            }
            let utilization = snapshot.maxUtilization
            if utilization >= threshold {
                guard !notifiedProviders.contains(providerID) else { continue }
                notifiedProviders.insert(providerID)
                let name = activeProviders.first(where: { $0.id == providerID })?.displayName ?? providerID
                let remainingPercent = max(100 - Int((utilization * 100).rounded()), 0)
                sendLocalNotification(
                    providerID: providerID,
                    displayName: name,
                    remainingPercent: remainingPercent
                )
            } else {
                notifiedProviders.remove(providerID)
            }
        }
    }

    private func sendLocalNotification(providerID: String, displayName: String, remainingPercent: Int) {
        let content = UNMutableNotificationContent()
        content.title = "\(displayName) 剩余额度偏低"
        content.body  = "当前剩余额度约 \(remainingPercent)%，建议留意使用节奏"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "aiscope-alert-\(providerID)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error { dataManagerLogger.error("通知发送失败：\(error.localizedDescription)") }
        }
    }

    private func sendResetNotificationsIfNeeded(previousSnapshots: [String: UsageSnapshot]) {
        guard settings.refreshNotificationsEnabled else { return }

        let now = Date()
        for (providerID, current) in snapshots where !current.isError && !settings.isMuted(providerID) {
            guard let previous = previousSnapshots[providerID], !previous.isError else { continue }
            guard didQuotaCycleReset(previous: previous, current: current, now: now) else { continue }

            let displayName = activeProviders.first(where: { $0.id == providerID })?.displayName ?? providerID
            sendResetNotification(providerID: providerID, displayName: displayName)
        }
    }

    private func didQuotaCycleReset(previous: UsageSnapshot, current: UsageSnapshot, now: Date) -> Bool {
        let previousResetDates = resetDatesByKey(for: previous)
        let currentResetDates = resetDatesByKey(for: current)

        for (key, oldDate) in previousResetDates {
            guard oldDate <= now, let newDate = currentResetDates[key] else { continue }
            if newDate.timeIntervalSince(oldDate) > 60 {
                return true
            }
        }
        return false
    }

    private func resetDatesByKey(for snapshot: UsageSnapshot) -> [String: Date] {
        var dates: [String: Date] = [:]
        if let billingCycleEnd = snapshot.billingCycleEnd {
            dates["billingCycle"] = billingCycleEnd
        }
        for window in snapshot.windows {
            if let resetsAt = window.resetsAt {
                dates["window:\(window.label)"] = resetsAt
            }
        }
        for pool in snapshot.pools {
            if let resetsAt = pool.resetsAt {
                dates["pool:\(pool.label)"] = resetsAt
            }
        }
        return dates
    }

    private func sendResetNotification(providerID: String, displayName: String) {
        let content = UNMutableNotificationContent()
        content.title = "\(displayName) 额度已重置"
        content.body  = "额度周期已进入新的重置周期"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "aiscope-reset-\(providerID)-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error { dataManagerLogger.error("重置通知发送失败：\(error.localizedDescription)") }
        }
    }

    // MARK: - 监听设置变化

    private func observeSettingsChanges() {
        settings.$refreshInterval
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.startAutoRefresh() }
            }
            .store(in: &cancellables)
    }
}
