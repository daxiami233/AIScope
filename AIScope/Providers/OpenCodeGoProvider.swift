import Foundation

// MARK: - OpenCode Go Provider

/// OpenCode Go 用量提供者。
///
/// 优先读取已登录 OpenCode 官网工作区返回的实时百分比与刷新时间；本机
/// `opencode.db` 仅在官网会话不可用时作为估算兜底。
final class OpenCodeGoProvider: AIToolProvider, Sendable {

    let id = "opencode-go"
    let displayName = "OpenCode Go"
    let dashboardURL = URL(string: "https://opencode.ai/go")!

    private static let baseURL = URL(string: "https://opencode.ai")!
    private static let serverURL = URL(string: "https://opencode.ai/_server")!
    private static let workspaceServerID = "def39973159c7f0483d8793a822b8dbb10d067e12c65455fcb4608459ba0234f"
    private static let authPath = NSString(string: "~/.local/share/opencode/auth.json").expandingTildeInPath
    private static let databasePath = NSString(string: "~/.local/share/opencode/opencode.db").expandingTildeInPath
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"

    private static let fiveHourLimit = 12.0
    private static let weeklyLimit = 30.0
    private static let monthlyLimit = 60.0

    func detect() async -> Bool {
        Self.hasOfficialSession || Self.hasLocalCredentials
    }

    func fetchUsage() async throws -> UsageSnapshot {
        if let cookie = Self.readOfficialCookie() {
            do {
                return try await Self.fetchOfficialUsage(cookie: cookie)
            } catch {
                // 控制台内部接口变动、离线或 Cookie 过期时仍保留本机历史兜底，
                // 但通过数据来源明确告诉用户这不是官网实时数据。
                if let fallback = try? fetchLocalUsage(source: "本机历史估算（官网实时获取失败）") {
                    return fallback
                }
                if let providerError = error as? ProviderError {
                    throw providerError
                }
                throw ProviderError.networkError(error)
            }
        }

        return try fetchLocalUsage(source: "OpenCode 本机历史估算")
    }

    // MARK: - 官网实时额度

    /// 用于登录页验证。只有已能读取工作区的官网实时额度时才保存 Cookie。
    static func validateOfficialSession(cookie: String) async -> Bool {
        do {
            _ = try await fetchOfficialUsage(cookie: cookie)
            return true
        } catch {
            return false
        }
    }

    static func readOfficialCookie(allowUserInteraction: Bool = true) -> String? {
        let cookie = AIScopeCredentialStore.read(
            allowUserInteraction: allowUserInteraction
        ).openCodeGoCookie?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (cookie?.isEmpty == false) ? cookie : nil
    }

    static func saveOfficialCookie(_ cookie: String) throws {
        let cookie = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cookie.isEmpty else { return }
        try AIScopeCredentialStore.update { $0.openCodeGoCookie = cookie }
    }

    static var hasOfficialSession: Bool {
        readOfficialCookie(allowUserInteraction: false) != nil
    }

    private static func fetchOfficialUsage(cookie: String) async throws -> UsageSnapshot {
        let workspaceID = try await fetchWorkspaceID(cookie: cookie)
        guard let url = URL(string: "https://opencode.ai/workspace/\(workspaceID)/go") else {
            throw ProviderError.parseError("OpenCode 工作区地址无效")
        }

        let page = try await fetchText(url: url, cookie: cookie, referer: baseURL)
        let usage = try parseOfficialUsage(from: page)
        let now = Date()

        return UsageSnapshot(
            providerID: "opencode-go",
            fetchedAt: now,
            windows: [],
            pools: [
                officialPool(label: "5h", usage: usage.rolling, now: now),
                officialPool(label: "7d", usage: usage.weekly, now: now),
                officialPool(label: "月度", usage: usage.monthly, now: now)
            ],
            extras: [
                UsageExtra(label: "数据来源", value: "OpenCode 官网实时"),
                UsageExtra(label: "工作区", value: workspaceID)
            ],
            planName: "Go",
            accountEmail: nil,
            billingCycleEnd: now.addingTimeInterval(TimeInterval(usage.monthly.resetInSeconds))
        )
    }

    private static func officialPool(label: String, usage: OfficialWindow, now: Date) -> UsagePool {
        UsagePool(
            label: label,
            used: usage.usedPercent,
            limit: 100,
            unit: "%",
            resetsAt: now.addingTimeInterval(TimeInterval(usage.resetInSeconds)),
            displayRemainingPercentOnly: true
        )
    }

    private static func fetchWorkspaceID(cookie: String) async throws -> String {
        let getResult = try await fetchServerText(cookie: cookie, method: "GET", args: nil)
        if let workspaceID = parseWorkspaceID(from: getResult) {
            return workspaceID
        }

        // OpenCode 的服务端函数在部分会话中只接受 POST 调用。
        let postResult = try await fetchServerText(cookie: cookie, method: "POST", args: "[]")
        if let workspaceID = parseWorkspaceID(from: postResult) {
            return workspaceID
        }
        throw ProviderError.parseError("未能从 OpenCode 账号识别工作区")
    }

    private static func fetchServerText(cookie: String, method: String, args: String?) async throws -> String {
        var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)
        if method == "GET" {
            components?.queryItems = [
                URLQueryItem(name: "id", value: workspaceServerID)
            ]
        }
        guard let url = components?.url else {
            throw ProviderError.parseError("OpenCode 工作区接口地址无效")
        }

        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = method
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(workspaceServerID, forHTTPHeaderField: "X-Server-Id")
        request.setValue("server-fn:\(UUID().uuidString)", forHTTPHeaderField: "X-Server-Instance")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(baseURL.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue(baseURL.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue("text/javascript, application/json;q=0.9, */*;q=0.8", forHTTPHeaderField: "Accept")
        if method != "GET", let args {
            request.httpBody = Data(args.utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return try await perform(request)
    }

    private static func fetchText(url: URL, cookie: String, referer: URL) async throws -> String {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        return try await perform(request)
    }

    private static func perform(_ request: URLRequest) async throws -> String {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ProviderError.networkError(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.networkError(URLError(.badServerResponse))
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        if looksSignedOut(text) {
            throw ProviderError.actionRequired("OpenCode 官网登录已过期，请在设置中重新登录")
        }
        guard http.statusCode == 200 else {
            throw ProviderError.fromHTTP(
                statusCode: http.statusCode,
                data: data,
                authMessage: "OpenCode 官网登录已过期，请在设置中重新登录"
            )
        }
        guard !text.isEmpty else {
            throw ProviderError.parseError("OpenCode 官网返回了空数据")
        }
        return text
    }

    private static func looksSignedOut(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("auth/authorize") ||
            lower.contains("sign in") ||
            lower.contains("not associated with an account") ||
            lower.contains("actor of type \"public\"")
    }

    private static func parseWorkspaceID(from text: String) -> String? {
        let normalized = normalize(text)
        let pattern = #"[\"']?id[\"']?\s*:\s*[\"'](wrk_[A-Za-z0-9]+)[\"']"#
        return firstCapture(in: normalized, pattern: pattern)
    }

    private static func parseOfficialUsage(from text: String) throws -> OfficialUsage {
        let normalized = normalize(text)
        guard let rolling = parseWindow(named: "rollingUsage", in: normalized),
              let weekly = parseWindow(named: "weeklyUsage", in: normalized),
              let monthly = parseWindow(named: "monthlyUsage", in: normalized)
        else {
            throw ProviderError.parseError("OpenCode 官网页面未返回完整的 Go 用量字段")
        }
        return OfficialUsage(rolling: rolling, weekly: weekly, monthly: monthly)
    }

    private static func parseWindow(named name: String, in text: String) -> OfficialWindow? {
        guard let range = text.range(of: name, options: [.caseInsensitive]) else { return nil }
        // 官网水合数据可能是压缩 JS 或 JSON；在名称后的有限范围内读取同一窗口字段。
        let fragment = String(text[range.lowerBound...].prefix(1_600))
        let percentPatterns = [
            #"[\"']?usagePercent[\"']?\s*:\s*([0-9]+(?:\.[0-9]+)?)"#,
            #"[\"']?usedPercent[\"']?\s*:\s*([0-9]+(?:\.[0-9]+)?)"#
        ]
        let resetPatterns = [
            #"[\"']?resetInSec(?:onds)?[\"']?\s*:\s*([0-9]+(?:\.[0-9]+)?)"#,
            #"[\"']?resetSeconds[\"']?\s*:\s*([0-9]+(?:\.[0-9]+)?)"#
        ]
        guard var percent = firstDouble(in: fragment, patterns: percentPatterns),
              let reset = firstDouble(in: fragment, patterns: resetPatterns)
        else { return nil }
        if (0...1).contains(percent) { percent *= 100 }
        return OfficialWindow(
            usedPercent: min(100, max(0, percent)),
            resetInSeconds: max(0, Int(reset.rounded()))
        )
    }

    private static func normalize(_ text: String) -> String {
        var result = text
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "\\u0022", with: "\"")
            .replacingOccurrences(of: "\\u0027", with: "'")
        // 流式 SSR 有时会将 JSON 再转义一层。
        for _ in 0..<2 {
            result = result.replacingOccurrences(of: "\\\"", with: "\"")
        }
        return result
    }

    private static func firstCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let capture = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[capture])
    }

    private static func firstDouble(in text: String, patterns: [String]) -> Double? {
        for pattern in patterns {
            if let capture = firstCapture(in: text, pattern: pattern), let value = Double(capture) {
                return value
            }
        }
        return nil
    }

    private struct OfficialUsage {
        let rolling: OfficialWindow
        let weekly: OfficialWindow
        let monthly: OfficialWindow
    }

    private struct OfficialWindow {
        let usedPercent: Double
        let resetInSeconds: Int
    }

    // MARK: - 本机估算兜底

    private func fetchLocalUsage(source: String) throws -> UsageSnapshot {
        guard Self.loadAPIKey() != nil else {
            throw ProviderError.actionRequired("请在设置中登录 OpenCode 官网，或先在 OpenCode 中连接 OpenCode Go")
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
                UsagePool(label: "5h", used: sum(rollingRows), limit: Self.fiveHourLimit, unit: "USD", resetsAt: rollingReset, displayRemainingPercentOnly: true),
                UsagePool(label: "7d", used: sum(rows.filter { $0.createdAt >= weekStart && $0.createdAt < (nextWeek ?? now) }), limit: Self.weeklyLimit, unit: "USD", resetsAt: nextWeek, displayRemainingPercentOnly: true),
                UsagePool(label: "月度", used: sum(rows.filter { $0.createdAt >= monthlyBounds.start && $0.createdAt < monthlyBounds.end }), limit: Self.monthlyLimit, unit: "USD", resetsAt: monthlyBounds.end, displayRemainingPercentOnly: true)
            ],
            extras: [UsageExtra(label: "数据来源", value: source)],
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

    private static func subscriptionStartedAt() -> Date? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: authPath) else { return nil }
        return attributes[.modificationDate] as? Date ?? attributes[.creationDate] as? Date
    }

    private static func monthlyBounds(now: Date, subscribedAt: Date) -> (start: Date, end: Date) {
        let calendar = utcCalendar
        let subscribed = calendar.dateComponents([.day, .hour, .minute, .second, .nanosecond], from: subscribedAt)
        func anchor(year: Int, month: Int) -> Date {
            let firstDay = calendar.date(from: DateComponents(calendar: calendar, timeZone: calendar.timeZone, year: year, month: month, day: 1))!
            let maximumDay = calendar.range(of: .day, in: .month, for: firstDay)!.count
            return calendar.date(from: DateComponents(calendar: calendar, timeZone: calendar.timeZone, year: year, month: month, day: min(subscribed.day ?? 1, maximumDay), hour: subscribed.hour, minute: subscribed.minute, second: subscribed.second, nanosecond: subscribed.nanosecond))!
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
