import Foundation

// MARK: - ClaudeCodeProvider

/// Claude Code CLI 用量提供者。
///
/// 凭证来源：macOS Keychain（服务名 "Claude Code-credentials"）
///
/// 重要说明：claude.ai、Claude Desktop、Claude Code 共享同一套餐用量池。
///
/// seven_day_oauth_apps 桶说明：
///   官方 UI 不展示此桶，但它对 OAuth 应用（含 Claude Code CLI）独立限速。
///   当套餐整体用量仍低但 Claude Code 突然被限速时，通常是这个隐藏桶已耗尽。
///   本 Provider 将该桶标记为 isHighlighted = true，在 UI 中显眼提示。
final class ClaudeCodeProvider: AIToolProvider, Sendable {

    // MARK: - AIToolProvider 标识

    let id           = "claude-code"
    let displayName  = "Claude"
    let dashboardURL = URL(string: "https://claude.ai/settings")!

    private static let keychainService = "Claude Code-credentials"

    // MARK: - AIToolProvider 实现

    func detect() async -> Bool {
        readAccessToken() != nil
    }

    func fetchUsage() async throws -> UsageSnapshot {
        guard let token = readAccessToken() else {
            throw ProviderError.credentialMissing
        }
        let orgID = try await fetchOrgID(token: token)

        // 并发请求用量桶与超额信息，超额接口失败时静默忽略
        async let bucketsTask = fetchWindowUsage(token: token, orgID: orgID)
        async let overageTask = fetchOverageInfo(token: token, orgID: orgID)

        let buckets = try await bucketsTask
        let overage = try? await overageTask

        return buildSnapshot(buckets: buckets, overage: overage)
    }

    // MARK: - 凭证读取

    private func readAccessToken() -> String? {
        let items = KeychainService.readAllGenericPasswords(service: Self.keychainService)
        guard let first = items.first else { return nil }
        return (try? JSONDecoder().decode(ClaudeCodeCredentials.self, from: first.data))?.accessToken
    }

    // MARK: - API 调用

    /// GET /api/account → 获取组织 UUID
    private func fetchOrgID(token: String) async throws -> String {
        let url = URL(string: "https://claude.ai/api/account")!
        let response: AccountResponse = try await URLSession.shared.fetchJSON(
            url, headers: ["Authorization": "Bearer \(token)"]
        )
        guard let orgID = response.memberships?.first?.account?.id, !orgID.isEmpty else {
            throw ProviderError.parseError("无法从账号信息中获取组织 ID")
        }
        return orgID
    }

    /// GET /api/organizations/{orgID}/usage → 各时间窗口用量桶
    ///
    /// 宽松解析：整个响应解码为 [String: BucketInfo]，未知桶键自动忽略。
    private func fetchWindowUsage(token: String, orgID: String) async throws -> [String: BucketInfo] {
        let url = URL(string: "https://claude.ai/api/organizations/\(orgID)/usage")!
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try await URLSession.shared.fetchJSON(
            url, headers: ["Authorization": "Bearer \(token)"], decoder: decoder
        )
    }

    /// GET /api/organizations/{orgID}/overage_spend_limit → 超额消费信息（可选）
    private func fetchOverageInfo(token: String, orgID: String) async throws -> OverageInfo {
        let url = URL(string: "https://claude.ai/api/organizations/\(orgID)/overage_spend_limit")!
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try await URLSession.shared.fetchJSON(
            url, headers: ["Authorization": "Bearer \(token)"], decoder: decoder
        )
    }

    // MARK: - 构造 UsageSnapshot

    private func buildSnapshot(buckets: [String: BucketInfo], overage: OverageInfo?) -> UsageSnapshot {
        var windows: [UsageWindow] = []

        // 5h 短周期资源预算
        if let b = buckets["five_hour"] {
            windows.append(UsageWindow(
                label: "5h", utilization: normalizedUtilization(b.utilization),
                resetsAt: b.resetsAt.flatMap(parseISO8601), isHighlighted: false
            ))
        }

        // 7d 全模型周级累计
        if let b = buckets["seven_day"] {
            windows.append(UsageWindow(
                label: "7d 总量", utilization: normalizedUtilization(b.utilization),
                resetsAt: b.resetsAt.flatMap(parseISO8601), isHighlighted: false
            ))
        }

        // 7d Sonnet 专项（有数据且 > 0 才加入）
        if let b = buckets["seven_day_sonnet"], normalizedUtilization(b.utilization) > 0 {
            windows.append(UsageWindow(
                label: "7d Sonnet", utilization: normalizedUtilization(b.utilization),
                resetsAt: b.resetsAt.flatMap(parseISO8601), isHighlighted: false
            ))
        }

        // 7d Opus 专项（有数据且 > 0 才加入）
        if let b = buckets["seven_day_opus"], normalizedUtilization(b.utilization) > 0 {
            windows.append(UsageWindow(
                label: "7d Opus", utilization: normalizedUtilization(b.utilization),
                resetsAt: b.resetsAt.flatMap(parseISO8601), isHighlighted: false
            ))
        }

        // ⚠️ 7d OAuth 桶：专门计量通过 OAuth 应用（含 Claude Code CLI）的请求。
        // 官方 UI 不展示此桶，但它独立限速 → 必须加入（即使 utilization == 0），标记高亮。
        if let b = buckets["seven_day_oauth_apps"] {
            windows.append(UsageWindow(
                label: "7d OAuth", utilization: normalizedUtilization(b.utilization),
                resetsAt: b.resetsAt.flatMap(parseISO8601), isHighlighted: true
            ))
        }

        var extras: [UsageExtra] = []
        if let ov = overage, ov.usedCredits > 0 {
            extras.append(UsageExtra(label: "额外用量", value: String(format: "$%.2f", ov.usedCredits)))
        }
        // 固定说明：提醒用户多端共享同一套餐额度
        extras.append(UsageExtra(label: "共享额度", value: "claude.ai / Desktop / Code 共用"))

        return UsageSnapshot(
            providerID: id, fetchedAt: Date(),
            windows: windows, pools: [], extras: extras,
            planName: nil, accountEmail: nil, billingCycleEnd: nil
        )
    }

    private func normalizedUtilization(_ value: Double) -> Double {
        let ratio = value > 1 ? value / 100.0 : value
        return min(max(ratio, 0), 1)
    }
}

// MARK: - 响应模型

private struct ClaudeCodeCredentials: Decodable {
    let accessToken:  String
    let refreshToken: String?
    let expiresAt:    String?
}

private struct AccountResponse: Decodable {
    let memberships: [Membership]?
    struct Membership: Decodable {
        let account: Account?
        struct Account: Decodable {
            let id: String?
        }
    }
}

/// 单个时间窗口桶（convertFromSnakeCase: resets_at → resetsAt）
private struct BucketInfo: Decodable {
    let utilization: Double
    let resetsAt:    String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        utilization = container.decodeFlexibleDoubleIfPresent(forKey: .utilization) ?? 0
        resetsAt = try container.decodeIfPresent(String.self, forKey: .resetsAt)
    }
}

private struct OverageInfo: Decodable {
    let usedCredits:         Double
    let monthlyCreditLimit:  Double?
    let outOfCredits:        Bool?
}

private extension KeyedDecodingContainer {
    func decodeFlexibleDoubleIfPresent(forKey key: Key) -> Double? {
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return Double(value)
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Double(value)
        }
        return nil
    }
}
