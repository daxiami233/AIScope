import Foundation

// MARK: - CopilotProvider

/// GitHub Copilot 用量提供者。
///
/// 使用 AIScope 自己的 GitHub Device Flow 登录态读取 Copilot 内部用量接口。
final class CopilotProvider: AIToolProvider, Sendable {

    // MARK: - AIToolProvider 标识

    let id           = "github-copilot"
    let displayName  = "GitHub Copilot"
    let dashboardURL = URL(string: "https://github.com/settings/copilot")!

    static let tokenService = "AIScope.GitHubCopilot"
    static let oauthTokenAccount = "oauthToken"
    static let usernameAccount = "username"
    private static let githubOAuthClientID = "01ab8ac9400c4e429b23"
    private static let githubOAuthScopes = "user:email"
    private static let oauthTokenCache = KeychainValueCache()
    private static let usernameCache = KeychainValueCache()

    // MARK: - AIToolProvider 实现

    func detect() async -> Bool {
        Self.readOAuthToken(allowUserInteraction: false) != nil
    }

    func fetchUsage() async throws -> UsageSnapshot {
        guard let token = Self.readOAuthToken() else {
            throw ProviderError.actionRequired("请在设置中点击“登录 GitHub”，完成 Copilot 授权后刷新")
        }

        do {
            return try await fetchInternalUsage(token: token)
        } catch ProviderError.credentialExpired {
            try? Self.clearOAuthToken()
            throw ProviderError.actionRequired("GitHub 登录已过期，请在设置中重新登录 Copilot")
        }
    }

    // MARK: - GitHub 登录

    static func readOAuthToken(allowUserInteraction: Bool = true) -> String? {
        if let cached = oauthTokenCache.read() {
            return cached
        }
        let credentials = AIScopeCredentialStore.read(allowUserInteraction: allowUserInteraction)
        if let token = credentials.copilotOAuthToken?.trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty {
            oauthTokenCache.write(token)
            return token
        }
        return nil
    }

    static func saveOAuthToken(_ token: String) throws {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw ProviderError.credentialMissing }
        try AIScopeCredentialStore.update { $0.copilotOAuthToken = token }
        oauthTokenCache.write(token)
    }

    static func clearOAuthToken() throws {
        try AIScopeCredentialStore.update { $0.copilotOAuthToken = nil }
        try? KeychainService.deleteGenericPassword(service: tokenService, account: oauthTokenAccount)
        oauthTokenCache.write(nil)
    }

    static func readAccountUsername(allowUserInteraction: Bool = true) -> String? {
        if let cached = usernameCache.read() {
            return cached
        }
        let credentials = AIScopeCredentialStore.read(allowUserInteraction: allowUserInteraction)
        if let username = credentials.copilotUsername?.trimmingCharacters(in: .whitespacesAndNewlines),
           !username.isEmpty {
            usernameCache.write(username)
            return username
        }
        return nil
    }

    static func saveAccountUsername(_ username: String) throws {
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else { return }
        try AIScopeCredentialStore.update { $0.copilotUsername = username }
        usernameCache.write(username)
    }

    static func beginDeviceLogin() async throws -> CopilotDeviceLogin {
        let response: GitHubDeviceCodeResponse = try await postForm(
            URL(string: "https://github.com/login/device/code")!,
            form: [
                "client_id": githubOAuthClientID,
                "scope": githubOAuthScopes
            ]
        )

        guard let verificationURL = URL(string: response.verification_uri) else {
            throw ProviderError.parseError("GitHub 登录地址无效")
        }

        return CopilotDeviceLogin(
            deviceCode: response.device_code,
            userCode: response.user_code,
            verificationURL: verificationURL,
            expiresAt: Date().addingTimeInterval(TimeInterval(response.expires_in)),
            interval: TimeInterval(response.interval ?? 5)
        )
    }

    static func pollDeviceLogin(_ login: CopilotDeviceLogin) async throws -> String {
        var interval = max(login.interval, 5)

        while Date() < login.expiresAt {
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))

            let response: GitHubDeviceTokenResponse = try await postForm(
                URL(string: "https://github.com/login/oauth/access_token")!,
                form: [
                    "client_id": githubOAuthClientID,
                    "device_code": login.deviceCode,
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
                ]
            )

            if let token = response.access_token, !token.isEmpty {
                return token
            }

            switch response.error {
            case "authorization_pending":
                continue
            case "slow_down":
                interval += 5
            case "expired_token":
                throw ProviderError.actionRequired("GitHub 登录验证码已过期，请重新登录")
            case "access_denied":
                throw ProviderError.actionRequired("GitHub 登录已取消")
            case let error?:
                throw ProviderError.actionRequired(response.error_description ?? "GitHub 登录失败: \(error)")
            case nil:
                throw ProviderError.parseError("GitHub 登录响应缺少 token")
            }
        }

        throw ProviderError.actionRequired("GitHub 登录验证码已过期，请重新登录")
    }

    private static func postForm<T: Decodable>(_ url: URL, form: [String: String]) async throws -> T {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("AIScope/1.0", forHTTPHeaderField: "User-Agent")

        var components = URLComponents()
        components.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.networkError(URLError(.badServerResponse))
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ProviderError.apiError(statusCode: http.statusCode)
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ProviderError.parseError(error.localizedDescription)
        }
    }

    private func fetchInternalUsage(token: String) async throws -> UsageSnapshot {
        let url = URL(string: "https://api.github.com/copilot_internal/user")!
        let headers: [String: String] = [
            "Authorization":        "token \(token)",
            "Accept":               "application/json",
            "X-Github-Api-Version": "2025-04-01",
            "User-Agent":           "AIScope/1.0"
        ]
        let response: CopilotUserResponse = try await URLSession.shared.fetchJSON(url, headers: headers)
        return buildSnapshot(from: response)
    }

    static func lookupUsername(token: String) async throws -> String {
        let headers = [
            "Authorization": "token \(token)",
            "Accept": "application/json",
            "User-Agent": "AIScope/1.0"
        ]
        let response: GitHubUserResponse = try await URLSession.shared.fetchJSON(
            URL(string: "https://api.github.com/user")!,
            headers: headers
        )
        return response.login
    }

    // MARK: - Snapshot 构建

    private func buildSnapshot(from response: CopilotUserResponse) -> UsageSnapshot {
        var pools:  [UsagePool]  = []
        var extras: [UsageExtra] = []
        let billingCycleEnd = extractBillingCycleEnd(from: response)

        if let credits = response.ai_credits {
            let used = credits.used ?? credits.total.flatMap { t in
                credits.remaining.map { max(t - $0, 0) }
            } ?? 0
            pools.append(UsagePool(
                label: "AI Credits", used: used,
                limit: credits.total, unit: "Credits",
                resetsAt: billingCycleEnd
            ))
            if let budget = response.overage_budget_usd, budget > 0 {
                extras.append(UsageExtra(label: "额外预算", value: String(format: "$%.2f 已启用", budget)))
            }
            extras.append(UsageExtra(label: "说明", value: "代码补全不计入 Credits"))

        } else if let quota = response.quota_snapshots?.preferredQuota {
            if let pct = quota.percent_remaining {
                let used = max(1.0 - normalizedPercent(pct), 0) * 100
                pools.append(UsagePool(
                    label: "Credits", used: used,
                    limit: 100, unit: "%",
                    resetsAt: billingCycleEnd
                ))
            } else {
                let ent = quota.entitlement ?? 0, rem = quota.remaining ?? 0
                pools.append(UsagePool(
                    label: "Credits", used: max(ent - rem, 0),
                    limit: ent > 0 ? ent : nil, unit: "Credits",
                    resetsAt: billingCycleEnd
                ))
            }
            if let n = quota.overage_count, n > 0 {
                extras.append(UsageExtra(label: "额外用量", value: String(format: "%.0f", n)))
            }
            if quota.overage_permitted == true {
                extras.append(UsageExtra(label: "额外计费", value: "已启用"))
            }
        }

        if let end = billingCycleEnd {
            extras.append(UsageExtra(label: "账单周期", value: formatMonthDay(end) + " 重置"))
        }

        return UsageSnapshot(
            providerID: id, fetchedAt: Date(),
            windows: [], pools: pools, extras: extras,
            planName: response.planDisplayName,
            accountEmail: response.username,
            billingCycleEnd: billingCycleEnd
        )
    }

    private func extractBillingCycleEnd(from response: CopilotUserResponse) -> Date? {
        response.ai_credits?.reset_date.flatMap(parseISO8601)
            ?? response.quota_snapshots?.preferredQuota?.reset_date.flatMap(parseISO8601)
            ?? response.quota_reset_date.flatMap(parseISO8601)
    }

    private func formatMonthDay(_ date: Date) -> String {
        let cal = Calendar.current
        return "\(cal.component(.month, from: date))/\(cal.component(.day, from: date))"
    }

    private func normalizedPercent(_ value: Double) -> Double {
        min(max(value > 1 ? value / 100 : value, 0), 1)
    }
}

// MARK: - 响应模型

struct CopilotDeviceLogin: Sendable {
    let deviceCode: String
    let userCode: String
    let verificationURL: URL
    let expiresAt: Date
    let interval: TimeInterval
}

private struct GitHubDeviceCodeResponse: Decodable {
    let device_code: String
    let user_code: String
    let verification_uri: String
    let expires_in: Int
    let interval: Int?
}

private struct GitHubDeviceTokenResponse: Decodable {
    let access_token: String?
    let error: String?
    let error_description: String?
}

private struct GitHubUserResponse: Decodable {
    let login: String
}

private struct CopilotUserResponse: Decodable {
    let username: String?
    let copilot_plan: String?
    let ai_credits: AICreditBlock?
    let overage_budget_usd: Double?
    let quota_reset_date: String?
    let quota_snapshots: QuotaSnapshots?

    var planDisplayName: String? {
        guard let copilot_plan else { return nil }
        switch copilot_plan {
        case "individual_pro", "pro":
            return "Copilot Pro"
        case "individual":
            return "Copilot Individual"
        case "business":
            return "Copilot Business"
        case "enterprise":
            return "Copilot Enterprise"
        case "free":
            return "Copilot Free"
        default:
            return copilot_plan
                .split(separator: "_")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }

    enum CodingKeys: String, CodingKey {
        case username
        case copilot_plan
        case ai_credits
        case overage_budget_usd
        case quota_reset_date
        case quota_snapshots
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        username = try container.decodeIfPresent(String.self, forKey: .username)
        copilot_plan = try container.decodeIfPresent(String.self, forKey: .copilot_plan)
        ai_credits = try container.decodeIfPresent(AICreditBlock.self, forKey: .ai_credits)
        overage_budget_usd = container.decodeFlexibleDoubleIfPresent(forKey: .overage_budget_usd)
        quota_reset_date = try container.decodeIfPresent(String.self, forKey: .quota_reset_date)
        quota_snapshots = try container.decodeIfPresent(QuotaSnapshots.self, forKey: .quota_snapshots)
    }
}

private struct AICreditBlock: Decodable {
    let used: Double?
    let total: Double?
    let remaining: Double?
    let reset_date: String?

    enum CodingKeys: String, CodingKey {
        case used
        case total
        case remaining
        case reset_date
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        used = container.decodeFlexibleDoubleIfPresent(forKey: .used)
        total = container.decodeFlexibleDoubleIfPresent(forKey: .total)
        remaining = container.decodeFlexibleDoubleIfPresent(forKey: .remaining)
        reset_date = try container.decodeIfPresent(String.self, forKey: .reset_date)
    }
}

private struct QuotaSnapshots: Decodable {
    let premium_models: CopilotQuotaBlock?
    let premium_interactions: CopilotQuotaBlock?
    let chat: CopilotQuotaBlock?

    var preferredQuota: CopilotQuotaBlock? {
        premium_models ?? premium_interactions ?? chat
    }
}

private struct CopilotQuotaBlock: Decodable {
    let entitlement: Double?
    let remaining: Double?
    let percent_remaining: Double?
    let reset_date: String?
    let overage_count: Double?
    let overage_permitted: Bool?

    enum CodingKeys: String, CodingKey {
        case entitlement
        case remaining
        case percent_remaining
        case reset_date
        case overage_count
        case overage_permitted
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entitlement = container.decodeFlexibleDoubleIfPresent(forKey: .entitlement)
        remaining = container.decodeFlexibleDoubleIfPresent(forKey: .remaining)
        percent_remaining = container.decodeFlexibleDoubleIfPresent(forKey: .percent_remaining)
        reset_date = try container.decodeIfPresent(String.self, forKey: .reset_date)
        overage_count = container.decodeFlexibleDoubleIfPresent(forKey: .overage_count)
        overage_permitted = try container.decodeIfPresent(Bool.self, forKey: .overage_permitted)
    }
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
            return Double(value.replacingOccurrences(of: ",", with: ""))
        }
        return nil
    }
}

private final class KeychainValueCache: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    func read() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func write(_ newValue: String?) {
        lock.lock()
        value = newValue?.isEmpty == true ? nil : newValue
        lock.unlock()
    }
}
