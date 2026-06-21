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

        // 优先走新版 API，失败后回退到 Cursor 本地 accessToken 可用的旧版接口。
        // cursor.com/api/usage-summary 依赖网页会话 Cookie；本地库里的
        // cursorAuth/accessToken 是 Bearer token，不能当 WorkOS Cookie 使用。
        do {
            let snapshot = try await fetchFromSummaryAPI(token: token)
            return snapshot
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
            throw ProviderError.apiError(statusCode: http.statusCode)
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
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.networkError(URLError(.badServerResponse))
        }
        if http.statusCode == 401 || http.statusCode == 403 { throw cursorSessionExpiredError() }
        guard http.statusCode == 200 else { throw ProviderError.apiError(statusCode: http.statusCode) }

        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ProviderError.parseError("旧版 API 响应格式不符合预期")
        }

        let startOfMonth = (json["startOfMonth"] as? String).flatMap(parseISO8601)
        let resetDate = startOfMonth.flatMap(nextMonthlyResetDate)

        let nonModelKeys: Set<String> = ["startOfMonth"]
        var totalUsed = 0
        var totalLimit = 0
        for (key, value) in json {
            guard !nonModelKeys.contains(key), let obj = value as? [String: Any] else { continue }
            totalUsed  += intValue(obj["numRequests"]) ?? 0
            totalLimit += intValue(obj["maxRequestUsage"]) ?? 0
        }

        let pools: [UsagePool]
        if totalLimit > 0 {
            pools = [UsagePool(
                label: "请求总量",
                used: Double(totalUsed),
                limit: Double(totalLimit),
                unit: "请求",
                resetsAt: resetDate
            )]
        } else if totalUsed == 0 {
            pools = [UsagePool(
                label: "套餐用量",
                used: 0,
                limit: 100,
                unit: "%",
                resetsAt: resetDate,
                displayRemainingPercentOnly: true
            )]
        } else {
            pools = [UsagePool(
                label: "请求总量",
                used: Double(totalUsed),
                limit: nil,
                unit: "请求",
                resetsAt: resetDate
            )]
        }

        return UsageSnapshot(
            providerID:      id,
            fetchedAt:       Date(),
            windows:         [],
            pools:           pools,
            extras:          [],
            planName:        formattedLocalMembershipType(),
            accountEmail:    nil,
            billingCycleEnd: resetDate
        )
    }

    private func readLocalMembershipType() -> String? {
        try? SQLiteService.readItemTableValue(dbPath: Self.dbPath, key: Self.membershipTypeKey)
    }

    private func formattedLocalMembershipType() -> String? {
        readLocalMembershipType().map { t in
            String(t.prefix(1)).uppercased() + String(t.dropFirst())
        }
    }

    private func nextMonthlyResetDate(after startDate: Date) -> Date? {
        Calendar(identifier: .gregorian).date(byAdding: .month, value: 1, to: startDate)
    }

    private func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double) }
        if let string = value as? String { return Int(string) }
        return nil
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
