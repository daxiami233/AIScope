import Foundation

// MARK: - Usage Snapshot

enum UsageErrorKind: String, Codable, Sendable {
    case general
    case actionRequired
    case quotaUnavailable
}

struct UsageSnapshot: Identifiable, Codable, Sendable {
    var id: String { providerID }
    let providerID: String
    let fetchedAt: Date

    /// Rolling time-window limits (e.g. Claude's 5h / 7d budgets, Codex's 5h / 7d)
    var windows: [UsageWindow]

    /// Absolute pool quotas (e.g. Cursor agent pool, Copilot AI Credits)
    var pools: [UsagePool]

    /// Secondary spend info shown below the main metrics
    var extras: [UsageExtra]

    var planName: String?
    var accountEmail: String?
    var billingCycleEnd: Date?
    var errorMessage: String?
    var errorKind: UsageErrorKind? = nil

    var isError: Bool { errorMessage != nil }
    var requiresUserAction: Bool {
        if let errorKind {
            return errorKind == .actionRequired
        }
        return Self.requiresUserAction(errorMessage)
    }

    static func requiresUserAction(_ errorMessage: String?) -> Bool {
        guard let message = errorMessage?.lowercased() else { return false }
        let keywords = [
            "重新登录", "登录态", "登录凭证", "未找到登录凭证", "未登录",
            "已过期", "已失效", "请先", "登录", "授权", "认证", "鉴权",
            "cookie", "credential", "expired", "login", "unauthorized"
        ]
        return keywords.contains { message.contains($0) }
    }
    var hasDisplayData: Bool {
        !windows.isEmpty || !pools.isEmpty || !extras.isEmpty
    }

    /// Highest utilization across all quota sources (0.0 – 1.0)
    var maxUtilization: Double {
        let w = windows.map(\.utilization).max() ?? 0
        let p = pools.map(\.utilization).max() ?? 0
        return max(w, p)
    }
}

// MARK: - Usage Window
// Represents a rolling-window resource budget.
// Utilization is a ratio (0.0–1.0); the window resets after a fixed period.
//
// Examples:
//   Claude Code  5h session budget     → label "5h",       isHighlighted = false
//   Claude Code  7d all-models budget  → label "7d 总量",  isHighlighted = false
//   Claude Code  7d oauth-apps bucket  → label "7d OAuth", isHighlighted = true
//   Codex CLI    5h agentic window     → label "5h",       isHighlighted = false
//   Codex CLI    7d agentic window     → label "7d",       isHighlighted = false

struct UsageWindow: Identifiable, Codable, Sendable {
    var id: String { label }
    let label: String
    let utilization: Double          // 0.0 – 1.0
    let resetsAt: Date?
    /// Highlight in the UI (e.g. the hidden oauth_apps bucket that causes surprise rate-limits)
    let isHighlighted: Bool

    var usedUtilization: Double { min(max(utilization, 0), 1) }
    var percent: Int { Int((usedUtilization * 100).rounded()) }
    /// 剩余比例（%），用于 UI 显示
    var remainingPercent: Int { max(100 - percent, 0) }
    /// 剩余比例（0.0–1.0），供进度条按「剩余」填充
    var remainingUtilization: Double { max(1.0 - usedUtilization, 0) }

    var resetsInDescription: String? {
        guard let date = resetsAt else { return nil }
        let diff = date.timeIntervalSinceNow
        guard diff > 0 else { return "即将重置" }
        if diff < 3600      { return "\(Int(diff / 60)) 分钟后重置" }
        else if diff < 86400 {
            let hours = Int(diff / 3600)
            let minutes = Int(diff.truncatingRemainder(dividingBy: 3600) / 60)
            return minutes > 0 ? "\(hours) 小时 \(minutes) 分钟后重置" : "\(hours) 小时后重置"
        } else {
            let days = Int(diff / 86400)
            let hours = Int(diff.truncatingRemainder(dividingBy: 86400) / 3600)
            return hours > 0 ? "\(days) 天 \(hours) 小时后重置" : "\(days) 天后重置"
        }
    }
}

// MARK: - Usage Pool
// Represents a fixed-period usage pool with an absolute used / limit.
// Both values are Double to support credits (integers), dollar costs, and percentages.
//
// Examples:
//   Cursor      套餐 Agent 额度   used=450  limit=500   unit="额度"
//   Cursor      Auto 用量占比     used=90   limit=100   unit="%"
//   Copilot     AI Credits       used=300  limit=1500  unit="Credits"

struct UsagePool: Identifiable, Codable, Sendable {
    var id: String { label }
    let label: String
    let used: Double
    let limit: Double?      // nil → no hard limit displayed (e.g. on-demand)
    let unit: String        // display suffix: "Credits", "额度", "%", "USD"
    var resetsAt: Date? = nil
    /// Some providers should use the compact window-style text: reset time plus
    /// remaining percentage, without absolute values.
    var displayRemainingPercentOnly: Bool? = nil

    var resetsInDescription: String? {
        guard let date = resetsAt else { return nil }
        let diff = date.timeIntervalSinceNow
        guard diff > 0 else { return "即将重置" }
        if diff < 3600      { return "\(Int(diff / 60))分钟后重置" }
        else if diff < 86400 {
            let hours = Int(diff / 3600)
            let minutes = Int(diff.truncatingRemainder(dividingBy: 3600) / 60)
            return minutes > 0 ? "\(hours)小时\(minutes)分钟后重置" : "\(hours)小时后重置"
        } else {
            let days = Int(diff / 86400)
            let hours = Int(diff.truncatingRemainder(dividingBy: 86400) / 3600)
            return hours > 0 ? "\(days)天\(hours)小时后重置" : "\(days)天后重置"
        }
    }

    var utilization: Double {
        guard let limit, limit > 0 else { return 0 }
        return min(max(used / limit, 0), 1.0)
    }

    var percent: Int { Int((utilization * 100).rounded()) }

    var usedDisplay: String { formatValue(used) }
    var limitDisplay: String { limit.map { formatValue($0) } ?? "∞" }
    /// 剩余量（limit − used），limit 不存在时回退到 usedDisplay
    var remaining: Double {
        guard let limit else { return used }
        return max(limit - used, 0)
    }
    /// 剩余比例（0.0–1.0），供进度条按「剩余」填充；limit 缺失时填 0
    var remainingUtilization: Double {
        guard let limit, limit > 0 else { return 0 }
        return min(remaining / limit, 1.0)
    }
    var remainingDisplay: String { limit == nil ? usedDisplay : formatValue(remaining) }

    private func formatValue(_ v: Double) -> String {
        if unit == "%" { return "\(Int(v.rounded()))%" }
        if v >= 1_000_000_000 { return String(format: "%.1fB", v / 1_000_000_000) }
        if v >= 1_000_000 { return String(format: "%.1fM", v / 1_000_000) }
        if v >= 10_000 { return String(format: "%.1fK", v / 1000) }
        if v == v.rounded() { return "\(Int(v))" }
        return String(format: "%.2f", v)
    }
}

// MARK: - Usage Extra
// Supplementary information shown in a smaller row (no progress bar).
//
// Examples:
//   Cursor      按量付费已用   "$1.20"
//   Cursor      账单周期       "4/2 – 5/2"
//   Copilot     额外预算       "$0.00 已用"
//   Codex       套餐档位       "ChatGPT Plus"

struct UsageExtra: Identifiable, Codable, Sendable {
    var id: String { label }
    let label: String
    let value: String
}
