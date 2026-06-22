import Foundation

// MARK: - ZCodeProvider

/// ZCode / Z.ai GLM 额度提供者。
///
/// 直接调用 Z.ai API 获取实时额度数据，不依赖本地日志。
/// API Key 从 ~/.zcode/v2/config.json 中读取。
final class ZCodeProvider: AIToolProvider, Sendable {

    let id = "zcode-glm"
    let displayName = "ZCode GLM"
    let dashboardURL = URL(string: "https://zcode.z.ai")!

    private static let configPath = NSString(string: "~/.zcode/v2/config.json").expandingTildeInPath
    private static let apiURL = URL(string: "https://zcode.z.ai/api/v1/zcode-plan/billing/balance?app_version=3.1.2")!

    func detect() async -> Bool {
        FileManager.default.fileExists(atPath: Self.configPath)
    }

    func fetchUsage() async throws -> UsageSnapshot {
        guard let apiKey = readAPIKey() else {
            throw ProviderError.actionRequired("未找到 ZCode API Key，请先安装并登录 ZCode")
        }

        let response = try await fetchBalance(apiKey: apiKey)
        guard !response.data.balances.isEmpty else {
            throw ProviderError.quotaUnavailable("ZCode 当前没有有效套餐或可显示额度，Start Plan 体验额度可能已到期")
        }

        let pools = response.data.balances.map { item in
            UsagePool(
                label: item.showName,
                used: item.usedUnits,
                limit: item.totalUnits,
                unit: "",
                resetsAt: item.resetDate,
                displayRemainingPercentOnly: true
            )
        }

        var extras: [UsageExtra] = []
        extras.append(UsageExtra(label: "来源", value: "Z.ai API"))

        let resetDate = pools.compactMap(\.resetsAt).min()
        let planName = response.data.balances.first?.planID.flatMap(normalizePlanName)

        return UsageSnapshot(
            providerID: id,
            fetchedAt: Date(),
            windows: [],
            pools: pools,
            extras: extras,
            planName: planName,
            accountEmail: nil,
            billingCycleEnd: resetDate
        )
    }

    // MARK: - API 调用

    private func readAPIKey() -> String? {
        guard let data = FileManager.default.contents(atPath: Self.configPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let providers = json["provider"] as? [String: Any]
        else { return nil }

        // 尝试读取 zai-start-plan 的 API Key
        if let zaiStart = providers["builtin:zai-start-plan"] as? [String: Any],
           let options = zaiStart["options"] as? [String: Any],
           let apiKey = options["apiKey"] as? String,
           !apiKey.isEmpty {
            return apiKey
        }

        // 尝试读取 zai-coding-plan 的 API Key
        if let zaiCoding = providers["builtin:zai-coding-plan"] as? [String: Any],
           let options = zaiCoding["options"] as? [String: Any],
           let apiKey = options["apiKey"] as? String,
           !apiKey.isEmpty {
            return apiKey
        }

        return nil
    }

    private func fetchBalance(apiKey: String) async throws -> ZCodeAPIResponse {
        var request = URLRequest(url: Self.apiURL, timeoutInterval: 15)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, http) = try await URLSession.shared.dataForProvider(request)

        if http.statusCode == 401 || http.statusCode == 403 {
            throw ProviderError.actionRequired("ZCode API Key 已过期，请重新登录 ZCode")
        }
        guard http.statusCode == 200 else {
            throw ProviderError.fromHTTP(
                statusCode: http.statusCode,
                data: data,
                authMessage: "ZCode API Key 已过期，请重新登录 ZCode"
            )
        }

        do {
            let decoded = try JSONDecoder().decode(ZCodeAPIResponse.self, from: data)
            if decoded.code != 0 {
                throw ProviderError.fromServiceError(
                    code: decoded.code,
                    message: decoded.msg.isEmpty ? "ZCode 接口返回业务错误 code=\(decoded.code)" : decoded.msg,
                    authMessage: "ZCode API Key 已过期，请重新登录 ZCode"
                )
            }
            return decoded
        } catch let providerError as ProviderError {
            throw providerError
        } catch {
            throw ProviderError.parseError(error.localizedDescription)
        }
    }

    // MARK: - 辅助方法

    private func normalizePlanName(_ planID: String) -> String {
        if planID.contains("start") { return "Start Plan" }
        if planID.contains("coding") { return "Coding Plan" }
        return planID
    }
}

// MARK: - API 响应模型

private struct ZCodeAPIResponse: Decodable {
    let code: Int
    let msg: String
    let data: ZCodeAPIData
}

private struct ZCodeAPIData: Decodable {
    let serverTime: Double
    let balances: [ZCodeAPIBalance]

    enum CodingKeys: String, CodingKey {
        case serverTime = "server_time"
        case balances
    }
}

private struct ZCodeAPIBalance: Decodable {
    let showName: String
    let totalUnits: Double
    let usedUnits: Double
    let remainingUnits: Double
    let periodStart: Double?
    let periodEnd: Double?
    let expiresAt: Double?
    let planID: String?

    enum CodingKeys: String, CodingKey {
        case showName = "show_name"
        case totalUnits = "total_units"
        case usedUnits = "used_units"
        case remainingUnits = "remaining_units"
        case periodStart = "period_start"
        case periodEnd = "period_end"
        case expiresAt = "expires_at"
        case planID = "plan_id"
    }

    var resetDate: Date? {
        let timestamp = expiresAt ?? periodEnd
        guard let timestamp, timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }
}
