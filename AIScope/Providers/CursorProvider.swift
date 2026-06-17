import Foundation

// MARK: - CursorProvider

/// Cursor AI 编辑器的用量提供者。
///
/// 凭证来源：~/Library/Application Support/Cursor/User/globalStorage/state.vscdb
/// API 优先走 cursor.com/api/usage-summary（2026 新版），失败时回退到 api2.cursor.sh/auth/usage。
final class CursorProvider: AIToolProvider, Sendable {

    // MARK: - AIToolProvider 标识

    let id           = "cursor"
    let displayName  = "Cursor"
    let dashboardURL = URL(string: "https://cursor.com/settings")!

    // MARK: - 私有常量

    private static let dbPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
    }()

    private static let tokenKey = "cursorAuth/accessToken"
    private static let membershipTypeKey = "cursorAuth/stripeMembershipType"

    // MARK: - AIToolProvider 实现

    func detect() async -> Bool {
        guard FileManager.default.fileExists(atPath: Self.dbPath) else { return false }
        return (try? SQLiteService.readItemTableValue(dbPath: Self.dbPath, key: Self.tokenKey)) != nil
    }

    func fetchUsage() async throws -> UsageSnapshot {
        let token: String
        do {
            token = try SQLiteService.readItemTableValue(dbPath: Self.dbPath, key: Self.tokenKey)
        } catch {
            throw ProviderError.credentialMissing
        }

        // 优先走新版 API，认证类错误直接暴露；其它异常再回退旧版接口。
        do {
            let snapshot = try await fetchFromSummaryAPI(token: token)
            return snapshot
        } catch let providerError as ProviderError {
            switch providerError {
            case .credentialExpired:
                throw cursorSessionExpiredError()
            case .actionRequired:
                throw providerError
            default:
                return try await fetchFromLegacyAPI(token: token)
            }
        } catch {
            return try await fetchFromLegacyAPI(token: token)
        }
    }

    // MARK: - 新版 API（cursor.com/api/usage-summary）

    private func fetchFromSummaryAPI(token: String) async throws -> UsageSnapshot {
        let url = URL(string: "https://cursor.com/api/usage-summary")!
        let headers = ["Cookie": "WorkosCursorSessionToken=\(token)"]

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        var request = URLRequest(url: url, timeoutInterval: 15)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.networkError(URLError(.badServerResponse))
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw cursorSessionExpiredError()
        }
        guard http.statusCode == 200 else {
            throw ProviderError.apiError(statusCode: http.statusCode)
        }
        let summary: CursorSummaryResponse
        do {
            summary = try decoder.decode(CursorSummaryResponse.self, from: data)
        } catch {
            throw ProviderError.parseError(error.localizedDescription)
        }
        return buildSnapshotFromSummary(summary)
    }

    private func buildSnapshotFromSummary(_ summary: CursorSummaryResponse) -> UsageSnapshot {
        var pools:  [UsagePool]  = []
        var extras: [UsageExtra] = []

        if let plan = summary.individualUsage?.plan {
            pools.append(UsagePool(
                label: "套餐额度",
                used:  Double(plan.used),
                limit: plan.limit.map { Double($0) },
                unit:  "额度"
            ))
            if let autoPct = plan.autoPercentUsed {
                pools.append(UsagePool(
                    label: "Auto 占比",
                    used:  Double(autoPct),
                    limit: 100.0,
                    unit:  "%"
                ))
            }
        }

        if let od = summary.individualUsage?.onDemand, od.enabled == true {
            extras.append(UsageExtra(label: "按量付费", value: String(format: "$%.2f", od.used)))
        }

        let cycleStart = summary.billingCycleStart.flatMap(parseISO8601)
        let cycleEnd   = summary.billingCycleEnd.flatMap(parseISO8601)
        if let start = cycleStart, let end = cycleEnd {
            let fmt = DateFormatter()
            fmt.dateFormat = "M/d"
            extras.append(UsageExtra(
                label: "账单周期",
                value: "\(fmt.string(from: start)) – \(fmt.string(from: end))"
            ))
        }

        let planName = (summary.membershipType ?? readLocalMembershipType()).map { t in
            String(t.prefix(1)).uppercased() + String(t.dropFirst())
        }

        return UsageSnapshot(
            providerID:      id,
            fetchedAt:       Date(),
            windows:         [],
            pools:           pools,
            extras:          extras,
            planName:        planName,
            accountEmail:    nil,
            billingCycleEnd: cycleEnd
        )
    }

    // MARK: - 旧版 API 回退（api2.cursor.sh/auth/usage）

    /// 旧版响应是混合 JSON（模型键 → 对象，startOfMonth → 字符串），用 JSONSerialization 解析。
    private func fetchFromLegacyAPI(token: String) async throws -> UsageSnapshot {
        let url = URL(string: "https://api2.cursor.sh/auth/usage")!
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("WorkosCursorSessionToken=\(token)", forHTTPHeaderField: "Cookie")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.networkError(URLError(.badServerResponse))
        }
        if http.statusCode == 401 || http.statusCode == 403 { throw cursorSessionExpiredError() }
        guard http.statusCode == 200 else { throw ProviderError.apiError(statusCode: http.statusCode) }

        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ProviderError.parseError("旧版 API 响应格式不符合预期")
        }

        let nonModelKeys: Set<String> = ["startOfMonth"]
        var totalUsed = 0, totalLimit = 0
        for (key, value) in json {
            guard !nonModelKeys.contains(key), let obj = value as? [String: Any] else { continue }
            totalUsed  += obj["numRequests"]     as? Int ?? 0
            totalLimit += obj["maxRequestUsage"] as? Int ?? 0
        }

        return UsageSnapshot(
            providerID:      id,
            fetchedAt:       Date(),
            windows:         [],
            pools:           [UsagePool(label: "请求总量", used: Double(totalUsed), limit: totalLimit > 0 ? Double(totalLimit) : nil, unit: "请求")],
            extras:          [],
            planName:        nil,
            accountEmail:    nil,
            billingCycleEnd: nil
        )
    }

    private func readLocalMembershipType() -> String? {
        try? SQLiteService.readItemTableValue(dbPath: Self.dbPath, key: Self.membershipTypeKey)
    }

    private func cursorSessionExpiredError() -> ProviderError {
        let planText = readLocalMembershipType()
            .map { "（检测到本地 \($0.capitalized) plan）" }
            ?? ""
        return .actionRequired("Cursor 本地会话已失效\(planText)。请在 Cursor 中退出账号并重新登录，然后点击刷新。")
    }
}

// MARK: - 响应模型

private struct CursorSummaryResponse: Decodable {
    let billingCycleStart: String?
    let billingCycleEnd:   String?
    let membershipType:    String?
    let isUnlimited:       Bool?
    let individualUsage:   IndividualUsage?

    struct IndividualUsage: Decodable {
        let plan:     PlanUsage?
        let onDemand: OnDemandUsage?
    }
    struct PlanUsage: Decodable {
        let used:            Int
        let limit:           Int?
        let remaining:       Int?
        let autoPercentUsed: Int?
        let apiPercentUsed:  Int?
    }
    struct OnDemandUsage: Decodable {
        let enabled: Bool?
        let used:    Double
    }
}
