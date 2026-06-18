import Foundation

// MARK: - MimocodeProvider

/// Mimo 本地状态提供者。
///
/// Mimo Token Plan 本地保存 API key 与 OpenAI 兼容地址。
/// Mimo 自身通过 OAuth 登录写入 auth.json；额度接口使用 AIScope 统一凭证库中的控制台 Cookie。
final class MimocodeProvider: AIToolProvider, Sendable {

    let id = "mimocode"
    let displayName = "Mimo"
    let dashboardURL = URL(string: "https://mimo.xiaomi.com")!

    private static let authPath = NSString(string: "~/.local/share/mimocode/auth.json").expandingTildeInPath
    private static let dbPath = NSString(string: "~/.local/share/mimocode/mimocode.db").expandingTildeInPath

    func detect() async -> Bool {
        FileManager.default.fileExists(atPath: Self.authPath)
            || FileManager.default.fileExists(atPath: Self.dbPath)
    }

    func fetchUsage() async throws -> UsageSnapshot {
        guard let auth = loadAuth() else {
            throw ProviderError.actionRequired("请在设置中点击“登录 MiMo”，完成 Mimo 官方登录后刷新")
        }

        guard let cookie = Self.readPlatformCookie(), !cookie.isEmpty else {
            return buildLocalAuthSnapshot(from: auth)
        }

        let quota = try await fetchTokenPlanQuota(cookie: cookie)
        var extras: [UsageExtra] = [
            UsageExtra(label: "通道", value: auth.channelName),
            UsageExtra(label: "类型", value: auth.type.uppercased())
        ]
        if let uid = auth.uid {
            extras.append(UsageExtra(label: "账号", value: "UID \(uid)"))
        }
        if let host = auth.host {
            extras.append(UsageExtra(label: "接口", value: host))
        }
        if let updatedAt = modificationTimeMilliseconds(atPath: Self.dbPath) {
            extras.append(UsageExtra(label: "本地数据", value: relativeTimeString(fromMilliseconds: updatedAt)))
        }

        return UsageSnapshot(
            providerID: id,
            fetchedAt: Date(),
            windows: [],
            pools: quota.pools.map {
                UsagePool(
                    label: $0.label,
                    used: $0.used,
                    limit: $0.total,
                    unit: $0.unit,
                    resetsAt: quota.expiresAt,
                    displayRemainingPercentOnly: true
                )
            },
            extras: extras,
            planName: quota.planName ?? "Token Plan",
            accountEmail: auth.uid.map { "UID \($0)" },
            billingCycleEnd: quota.expiresAt
        )
    }

    private func buildLocalAuthSnapshot(from auth: MimocodeAuth) -> UsageSnapshot {
        var extras: [UsageExtra] = [
            UsageExtra(label: "通道", value: auth.channelName),
            UsageExtra(label: "类型", value: auth.type.uppercased()),
            UsageExtra(label: "额度", value: "已登录，等待官方额度接口")
        ]
        if let uid = auth.uid {
            extras.append(UsageExtra(label: "账号", value: "UID \(uid)"))
        }
        if let host = auth.host {
            extras.append(UsageExtra(label: "接口", value: host))
        }
        if let updatedAt = modificationTimeMilliseconds(atPath: Self.authPath) {
            extras.append(UsageExtra(label: "登录状态", value: relativeTimeString(fromMilliseconds: updatedAt)))
        }

        return UsageSnapshot(
            providerID: id,
            fetchedAt: Date(),
            windows: [],
            pools: [],
            extras: extras,
            planName: "已登录",
            accountEmail: auth.uid.map { "UID \($0)" },
            billingCycleEnd: nil
        )
    }

    static func readPlatformCookie(allowUserInteraction: Bool = true) -> String? {
        if let cookie = AIScopeCredentialStore.read(
            allowUserInteraction: allowUserInteraction
        ).mimoPlatformCookie?.trimmingCharacters(in: .whitespacesAndNewlines),
           !cookie.isEmpty {
            return cookie
        }
        return nil
    }

    static func savePlatformCookie(_ cookie: String) throws {
        let cookie = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cookie.isEmpty else { return }
        try AIScopeCredentialStore.update { $0.mimoPlatformCookie = cookie }
    }

    private func fetchTokenPlanQuota(cookie: String) async throws -> TokenPlanQuota {
        async let detailTask = fetchConsoleData(path: "/tokenPlan/detail", cookie: cookie)
        async let usageTask = fetchConsoleData(path: "/tokenPlan/usage", cookie: cookie)

        let detail = try await detailTask
        let usage = try? await usageTask

        guard let quota = TokenPlanQuotaParser.parse(detail: detail, usage: usage) else {
            throw ProviderError.parseError("MiMo Token Plan 未返回可识别的额度字段")
        }
        return quota
    }

    private func fetchConsoleData(path: String, cookie: String) async throws -> Any {
        guard let url = URL(string: "https://platform.xiaomimimo.com/api/v1\(path)") else {
            throw ProviderError.parseError("MiMo 控制台接口地址无效")
        }

        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(Locale.preferredLanguages.first ?? "zh-CN", forHTTPHeaderField: "Accept-Language")
        request.setValue(TimeZone.current.identifier, forHTTPHeaderField: "x-timeZone")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.networkError(URLError(.badServerResponse))
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw ProviderError.actionRequired("MiMo 平台登录态已失效，请重新登录 MiMo")
        }
        guard http.statusCode == 200 else {
            throw ProviderError.apiError(statusCode: http.statusCode)
        }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.parseError("MiMo 控制台响应不是 JSON")
        }
        if let code = root["code"] as? Int, code != 0 && code != 200 {
            if code == 401 || code == 403 {
                throw ProviderError.actionRequired("MiMo 平台登录态已失效，请重新登录 MiMo")
            }
            let message = root["message"] as? String ?? "code=\(code)"
            throw ProviderError.parseError(message)
        }
        return root["data"] ?? root
    }

    private func loadAuth() -> MimocodeAuth? {
        guard let data = FileManager.default.contents(atPath: Self.authPath),
              let root = try? JSONDecoder().decode([String: MimocodeAuthEntry].self, from: data),
              let first = root.sorted(by: { $0.key < $1.key }).first
        else { return nil }
        return MimocodeAuth(
            channelName: first.key,
            type: first.value.type,
            uid: first.value.metadata?.uid,
            host: first.value.metadata?.baseUrl.flatMap { URL(string: $0)?.host }
        )
    }

    private func modificationTimeMilliseconds(atPath path: String) -> Double? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let date = attrs[.modificationDate] as? Date else { return nil }
        return date.timeIntervalSince1970 * 1000
    }

    private func relativeTimeString(fromMilliseconds ms: Double) -> String {
        let date = Date(timeIntervalSince1970: ms / 1000.0)
        let elapsed = Date().timeIntervalSince(date)
        switch elapsed {
        case ..<60:        return "刚刚"
        case 60..<3600:    return "\(Int(elapsed / 60)) 分钟前"
        case 3600..<86400: return "\(Int(elapsed / 3600)) 小时前"
        default:           return "\(Int(elapsed / 86400)) 天前"
        }
    }
}

private struct MimocodeAuth {
    let channelName: String
    let type: String
    let uid: String?
    let host: String?
}

private struct MimocodeAuthEntry: Decodable {
    let type: String
    let metadata: Metadata?

    struct Metadata: Decodable {
        let uid: String?
        let baseUrl: String?

        enum CodingKeys: String, CodingKey {
            case uid
            case baseUrl = "base_url"
        }
    }
}

private struct TokenPlanQuota {
    let pools: [TokenPlanQuotaPool]
    let planName: String?
    let expiresAt: Date?
}

private struct TokenPlanQuotaPool {
    let label: String
    let used: Double
    let total: Double
    let unit: String
}

private struct TokenPlanQuotaCandidate {
    let text: String
    let total: Double?
    let used: Double?
    let remaining: Double?
    let percent: Double?

    func resolvedPool(label: String, fallbackTotal: Double?) -> TokenPlanQuotaPool? {
        let resolvedTotal = total ?? fallbackTotal ?? {
            guard let used, let remaining else { return nil }
            return used + remaining
        }()
        guard let totalValue = resolvedTotal, totalValue > 0 else { return nil }

        let resolvedUsed: Double
        if let used {
            resolvedUsed = used
        } else if let remaining {
            resolvedUsed = totalValue - remaining
        } else if let percent {
            resolvedUsed = totalValue * percent
        } else {
            return nil
        }

        return TokenPlanQuotaPool(
            label: label,
            used: Swift.min(Swift.max(resolvedUsed, 0), totalValue),
            total: totalValue,
            unit: ""
        )
    }
}

private enum TokenPlanQuotaParser {
    static func parse(detail: Any, usage: Any?) -> TokenPlanQuota? {
        let detailValues = flatten(detail)
        let usageValues = usage.map(flatten) ?? []

        let planName = firstString(in: detailValues + usageValues, matching: [
            "planname", "packagename", "productname", "subscriptionname", "plantype", "packagecode"
        ]).flatMap(normalizePlanName)

        let directTotal = firstNumber(in: detailValues, matchingAny: [
            ["total", "credit"], ["limit", "credit"], ["quota", "credit"], ["amount", "credit"]
        ])
        let mappedTotal = planName.flatMap(totalCreditsForPlan)
        let planTotal = directTotal ?? mappedTotal

        var pools = parsePools(from: usage ?? detail, planTotal: planTotal)
        if !pools.contains(where: { $0.label == "当前套餐用量" }),
           let current = parseFallbackPool(
            values: (usageValues + detailValues).filter { !isCompensationKey($0.key) },
            total: planTotal
           ) {
            pools.insert(current, at: 0)
        }
        if !pools.isEmpty {
            return TokenPlanQuota(
                pools: pools,
                planName: planName,
                expiresAt: firstDate(in: detailValues) ?? firstDate(in: usageValues)
            )
        }

        guard let fallback = parseFallbackPool(values: usageValues + detailValues, total: planTotal) else {
            return nil
        }

        return TokenPlanQuota(
            pools: [fallback],
            planName: planName,
            expiresAt: firstDate(in: detailValues) ?? firstDate(in: usageValues)
        )
    }

    private static func parsePools(from value: Any, planTotal: Double?) -> [TokenPlanQuotaPool] {
        let candidates = collectCandidates(from: value, path: "")
        var pools: [TokenPlanQuotaPool] = []

        if let current = bestCandidate(
            in: candidates,
            preferred: ["当前套餐", "套餐用量", "package", "subscription", "tokenplan"],
            requiredAny: ["套餐", "package", "subscription", "tokenplan", "current"],
            excluded: ["补偿", "compens"]
        )?.resolvedPool(label: "当前套餐用量", fallbackTotal: planTotal) {
            pools.append(current)
        } else if let current = candidates
            .filter({ !isCompensationKey($0.text) })
            .compactMap({ $0.resolvedPool(label: "当前套餐用量", fallbackTotal: planTotal) })
            .max(by: { $0.total < $1.total }) {
            pools.append(current)
        }

        if let compensation = bestCandidate(
            in: candidates,
            preferred: ["补偿积分", "补偿", "compens"],
            requiredAny: ["补偿", "compens"],
            excluded: []
        )?.resolvedPool(label: "补偿积分", fallbackTotal: nil) {
            pools.append(compensation)
        }

        if pools.isEmpty,
           let best = candidates
            .compactMap({ $0.resolvedPool(label: "当前套餐用量", fallbackTotal: planTotal) })
            .max(by: { $0.total < $1.total }) {
            pools.append(best)
        }

        return pools
    }

    private static func parseFallbackPool(
        values: [(key: String, value: Any)],
        total: Double?
    ) -> TokenPlanQuotaPool? {
        let used = firstNumber(in: values, matchingAny: [
            ["used", "credit"], ["usage", "credit"], ["consume", "credit"], ["consumed", "credit"],
            ["used", "quota"], ["usage", "quota"]
        ])
        let remaining = firstNumber(in: values, matchingAny: [
            ["remain", "credit"], ["remaining", "credit"], ["remain", "quota"], ["balance", "credit"]
        ])
        let percent = firstNumber(in: values, matchingAny: [
            ["usage", "percent"], ["used", "percent"], ["percent"], ["ratio"]
        ]).map(normalizePercent)

        guard let totalValue = total, totalValue > 0 else { return nil }

        let resolvedUsed: Double
        if let used {
            resolvedUsed = used
        } else if let remaining {
            resolvedUsed = Swift.max(totalValue - remaining, 0)
        } else if let percent {
            resolvedUsed = totalValue * percent
        } else {
            return nil
        }

        return TokenPlanQuotaPool(
            label: "当前套餐用量",
            used: Swift.min(Swift.max(resolvedUsed, 0), totalValue),
            total: totalValue,
            unit: ""
        )
    }

    private static func collectCandidates(from value: Any, path: String) -> [TokenPlanQuotaCandidate] {
        var result: [TokenPlanQuotaCandidate] = []
        if let dict = value as? [String: Any] {
            if let candidate = candidate(from: dict, path: path) {
                result.append(candidate)
            }
            for key in dict.keys.sorted() {
                guard let child = dict[key] else { continue }
                let childPath = path.isEmpty ? key : "\(path).\(key)"
                result += collectCandidates(from: child, path: childPath)
            }
        } else if let array = value as? [Any] {
            for (index, child) in array.enumerated() {
                result += collectCandidates(from: child, path: "\(path)[\(index)]")
            }
        }
        return result
    }

    private static func candidate(from dict: [String: Any], path: String) -> TokenPlanQuotaCandidate? {
        var total: Double?
        var used: Double?
        var remaining: Double?
        var percent: Double?
        var textParts = [path.lowercased()]

        for key in dict.keys.sorted() {
            guard let value = dict[key] else { continue }
            let normalizedKey = key.lowercased()

            if let text = string(from: value) {
                textParts.append(text.lowercased())
            }
            guard let number = number(from: value) else { continue }

            if isPercentKey(normalizedKey) {
                percent = percent ?? normalizePercent(number)
            } else if isRemainingKey(normalizedKey) {
                remaining = remaining ?? number
            } else if isUsedKey(normalizedKey) {
                used = used ?? number
            } else if isTotalKey(normalizedKey) {
                total = total ?? number
            }
        }

        guard total != nil || used != nil || remaining != nil || percent != nil else { return nil }
        guard used != nil || remaining != nil || percent != nil else { return nil }

        return TokenPlanQuotaCandidate(
            text: textParts.joined(separator: " "),
            total: total,
            used: used,
            remaining: remaining,
            percent: percent
        )
    }

    private static func bestCandidate(
        in candidates: [TokenPlanQuotaCandidate],
        preferred: [String],
        requiredAny: [String],
        excluded: [String]
    ) -> TokenPlanQuotaCandidate? {
        candidates
            .filter { candidate in
                let text = candidate.text
                let hasRequired = requiredAny.isEmpty || requiredAny.contains { text.contains($0.lowercased()) }
                let hasExcluded = excluded.contains { text.contains($0.lowercased()) }
                return hasRequired && !hasExcluded
            }
            .max { left, right in
                score(left, preferred: preferred) < score(right, preferred: preferred)
            }
    }

    private static func score(_ candidate: TokenPlanQuotaCandidate, preferred: [String]) -> Int {
        var score = 0
        for item in preferred where candidate.text.contains(item.lowercased()) {
            score += 10
        }
        if candidate.total != nil { score += 3 }
        if candidate.used != nil { score += 3 }
        if candidate.remaining != nil { score += 2 }
        if candidate.percent != nil { score += 1 }
        return score
    }

    private static func isTotalKey(_ key: String) -> Bool {
        let positive = [
            "total", "limit", "quota", "amount", "grant", "capacity",
            "总", "额度上限"
        ]
        let negative = [
            "used", "usage", "consume", "consumed", "remain", "remaining",
            "balance", "left", "available", "unused", "percent", "ratio", "rate",
            "已用", "已使用", "剩余", "可用", "余额", "比例"
        ]
        return positive.contains(where: { key.contains($0) })
            && !negative.contains(where: { key.contains($0) })
    }

    private static func isUsedKey(_ key: String) -> Bool {
        let positive = [
            "used", "usage", "consume", "consumed", "cost", "spent",
            "已用", "已使用", "使用量", "用量"
        ]
        return positive.contains(where: { key.contains($0) })
            && !isPercentKey(key)
            && !isRemainingKey(key)
    }

    private static func isRemainingKey(_ key: String) -> Bool {
        [
            "remain", "remaining", "balance", "left", "available", "unused", "surplus",
            "剩余", "可用", "余额"
        ].contains { key.contains($0) }
    }

    private static func isPercentKey(_ key: String) -> Bool {
        [
            "percent", "ratio", "rate", "百分比", "比例"
        ].contains { key.contains($0) }
    }

    private static func isCompensationKey(_ key: String) -> Bool {
        key.contains("补偿") || key.contains("compens")
    }

    private static func flatten(_ value: Any) -> [(key: String, value: Any)] {
        var result: [(String, Any)] = []
        func walk(_ value: Any, path: String) {
            if let dict = value as? [String: Any] {
                for key in dict.keys.sorted() {
                    guard let child = dict[key] else { continue }
                    walk(child, path: path.isEmpty ? key : "\(path).\(key)")
                }
            } else if let array = value as? [Any] {
                for (index, child) in array.enumerated() {
                    walk(child, path: "\(path)[\(index)]")
                }
            } else {
                result.append((path.lowercased(), value))
            }
        }
        walk(value, path: "")
        return result
    }

    private static func firstNumber(
        in values: [(key: String, value: Any)],
        matchingAny patterns: [[String]]
    ) -> Double? {
        for pattern in patterns {
            if let value = values.first(where: { item in
                pattern.allSatisfy { item.key.contains($0) } && number(from: item.value) != nil
            }).flatMap({ number(from: $0.value) }) {
                return value
            }
        }
        return nil
    }

    private static func firstString(in values: [(key: String, value: Any)], matching keys: [String]) -> String? {
        values.first { item in
            keys.contains { item.key.contains($0) } && string(from: item.value) != nil
        }.flatMap { string(from: $0.value) }
    }

    private static func firstDate(in values: [(key: String, value: Any)]) -> Date? {
        let keys = [
            "expire", "expiration", "expiredat", "expiretime",
            "endtime", "enddate", "validto", "validend", "validuntil",
            "reset", "renew", "periodend", "currentperiodend", "cycleend"
        ]
        for item in values where keys.contains(where: { item.key.contains($0) }) {
            if let number = number(from: item.value), number > 0 {
                return Date(timeIntervalSince1970: number > 10_000_000_000 ? number / 1000.0 : number)
            }
            if let text = string(from: item.value) {
                if let date = parseISO8601(text) { return date }
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
                    formatter.dateFormat = format
                    if let date = formatter.date(from: text) { return date }
                }
            }
        }
        return nil
    }

    private static func number(from value: Any) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? Int64 { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String {
            let cleaned = value.replacingOccurrences(of: ",", with: "")
            return Double(cleaned)
        }
        return nil
    }

    private static func string(from value: Any) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizePercent(_ value: Double) -> Double {
        value > 1 ? value / 100.0 : value
    }

    private static func normalizePlanName(_ raw: String) -> String? {
        let lower = raw.lowercased()
        let tier: String?
        if lower.contains("standard") { tier = "Standard" }
        else if lower.contains("lite") { tier = "Lite" }
        else if lower.contains("pro") { tier = "Pro" }
        else if lower.contains("max") { tier = "Max" }
        else { tier = nil }

        guard let tier else { return raw.isEmpty ? nil : raw }
        if lower.contains("year") || lower.contains("annual") || lower.contains("年度") {
            return "\(tier) 年度"
        }
        return "\(tier) 月度"
    }

    private static func totalCreditsForPlan(_ planName: String) -> Double? {
        let lower = planName.lowercased()
        let annual = lower.contains("年度") || lower.contains("year") || lower.contains("annual")
        if lower.contains("lite") { return annual ? 49_200_000_000 : 4_100_000_000 }
        if lower.contains("standard") { return annual ? 132_000_000_000 : 11_000_000_000 }
        if lower.contains("pro") { return annual ? 456_000_000_000 : 38_000_000_000 }
        if lower.contains("max") { return annual ? 984_000_000_000 : 82_000_000_000 }
        return nil
    }
}
