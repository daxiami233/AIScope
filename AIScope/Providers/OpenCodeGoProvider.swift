import Foundation

// MARK: - OpenCode Go Provider

/// OpenCode Go 用量提供者。
///
/// Go 当前没有对外发布实时用量接口。OpenCode 会把每次已完成请求的成本写入本地
/// opencode.db；这里基于该历史记录和 Go 的公开窗口上限计算本机估算值。
final class OpenCodeGoProvider: AIToolProvider, Sendable {

    let id = "opencode-go"
    let displayName = "OpenCode Go"
    let dashboardURL = URL(string: "https://opencode.ai/go")!

    private static let authPath = NSString(string: "~/.local/share/opencode/auth.json").expandingTildeInPath
    private static let databasePath = NSString(string: "~/.local/share/opencode/opencode.db").expandingTildeInPath

    private static let fiveHourLimit = 12.0
    private static let weeklyLimit = 30.0
    private static let monthlyLimit = 60.0

    func detect() async -> Bool {
        Self.hasLocalCredentials
    }

    func fetchUsage() async throws -> UsageSnapshot {
        guard Self.loadAPIKey() != nil else {
            throw ProviderError.actionRequired("未检测到 OpenCode Go 登录态，请在 OpenCode 中连接 OpenCode Go 后刷新")
        }
        guard FileManager.default.fileExists(atPath: Self.databasePath) else {
            throw ProviderError.quotaUnavailable("尚未找到 OpenCode 本地使用记录；请先用 OpenCode Go 完成一次请求")
        }

        let rows: [SQLiteService.OpenCodeUsageRow]
        do {
            rows = try SQLiteService.readOpenCodeGoUsageRows(dbPath: Self.databasePath)
        } catch {
            throw ProviderError.parseError("无法读取 OpenCode 本地使用记录：\(error.localizedDescription)")
        }
        guard !rows.isEmpty else {
            throw ProviderError.quotaUnavailable("尚未找到 OpenCode Go 使用记录；请先完成一次请求")
        }

        let now = Date()
        let calendar = Self.utcCalendar
        let fiveHoursAgo = now.addingTimeInterval(-5 * 60 * 60)
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now
        let nextWeek = calendar.date(byAdding: .weekOfYear, value: 1, to: weekStart)
        let subscriptionStartedAt = Self.subscriptionStartedAt() ?? rows.map(\.createdAt).min() ?? now
        let monthlyBounds = Self.monthlyBounds(now: now, subscribedAt: subscriptionStartedAt)

        let rollingRows = rows.filter { $0.createdAt >= fiveHoursAgo && $0.createdAt <= now }
        let rollingReset = (rollingRows.map(\.createdAt).min() ?? now).addingTimeInterval(5 * 60 * 60)

        return UsageSnapshot(
            providerID: id,
            fetchedAt: now,
            windows: [],
            pools: [
                UsagePool(
                    label: "5h",
                    used: sum(rollingRows),
                    limit: Self.fiveHourLimit,
                    unit: "USD",
                    resetsAt: rollingReset,
                    displayRemainingPercentOnly: true
                ),
                UsagePool(
                    label: "7d",
                    used: sum(rows.filter { $0.createdAt >= weekStart && $0.createdAt < (nextWeek ?? now) }),
                    limit: Self.weeklyLimit,
                    unit: "USD",
                    resetsAt: nextWeek,
                    displayRemainingPercentOnly: true
                ),
                UsagePool(
                    label: "月度",
                    used: sum(rows.filter { $0.createdAt >= monthlyBounds.start && $0.createdAt < monthlyBounds.end }),
                    limit: Self.monthlyLimit,
                    unit: "USD",
                    resetsAt: monthlyBounds.end,
                    displayRemainingPercentOnly: true
                )
            ],
            extras: [UsageExtra(label: "数据来源", value: "OpenCode 本机历史估算")],
            planName: "Go",
            accountEmail: nil,
            billingCycleEnd: monthlyBounds.end
        )
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }

    private func sum(_ rows: [SQLiteService.OpenCodeUsageRow]) -> Double {
        rows.reduce(0) { $0 + $1.cost }
    }

    /// 官网月度窗口从 Go 订阅创建时刻开始滚动，而不是自然月 1 日。
    /// OpenCode 不在本机保存该时刻；Go 凭证最后更新时刻最接近订阅/连接时刻，
    /// 也能避免初始 auth.json 因其他提供商更早创建而造成错误锚点。
    private static func subscriptionStartedAt() -> Date? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: authPath) else {
            return nil
        }
        return attributes[.modificationDate] as? Date ?? attributes[.creationDate] as? Date
    }

    private static func monthlyBounds(now: Date, subscribedAt: Date) -> (start: Date, end: Date) {
        let calendar = utcCalendar
        let subscribed = calendar.dateComponents([.day, .hour, .minute, .second, .nanosecond], from: subscribedAt)

        func anchor(year: Int, month: Int) -> Date {
            let maximumDay = calendar.range(of: .day, in: .month, for: calendar.date(from: DateComponents(
                calendar: calendar, timeZone: calendar.timeZone, year: year, month: month, day: 1
            ))!)!.count
            return calendar.date(from: DateComponents(
                calendar: calendar,
                timeZone: calendar.timeZone,
                year: year,
                month: month,
                day: min(subscribed.day ?? 1, maximumDay),
                hour: subscribed.hour,
                minute: subscribed.minute,
                second: subscribed.second,
                nanosecond: subscribed.nanosecond
            ))!
        }

        let current = calendar.dateComponents([.year, .month], from: now)
        var start = anchor(year: current.year!, month: current.month!)
        if start > now {
            let previous = calendar.date(byAdding: .month, value: -1, to: start)!
            let components = calendar.dateComponents([.year, .month], from: previous)
            start = anchor(year: components.year!, month: components.month!)
        }
        return (start, calendar.date(byAdding: .month, value: 1, to: start)!)
    }

    private static func loadAPIKey() -> String? {
        guard let data = FileManager.default.contents(atPath: authPath),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = root["opencode-go"] as? [String: Any],
              let key = entry["key"] as? String
        else { return nil }
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedKey.isEmpty ? nil : trimmedKey
    }

    static var hasLocalCredentials: Bool {
        loadAPIKey() != nil
    }
}
