import Foundation

// MARK: - ZCodeProvider

/// ZCode / Z.ai GLM 本地额度提供者。
///
/// ZCode 的账号凭证保存在本地私有加密存储中；额度读取 ZCode 日志里
/// billing/balance 的最近一次真实响应，避免直接处理私有 auth 格式。
final class ZCodeProvider: AIToolProvider, Sendable {

    let id = "zcode-glm"
    let displayName = "ZCode GLM"
    let dashboardURL = URL(string: "https://zcode.z.ai")!

    private static let zcodeRoot = NSString(string: "~/.zcode").expandingTildeInPath
    private static let v2Root = NSString(string: "~/.zcode/v2").expandingTildeInPath
    private static let logsRoot = NSString(string: "~/.zcode/v2/logs").expandingTildeInPath
    private static let appSupportRoot = NSString(string: "~/Library/Application Support/ZCode").expandingTildeInPath

    func detect() async -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: Self.v2Root)
            || fm.fileExists(atPath: Self.zcodeRoot)
            || fm.fileExists(atPath: Self.appSupportRoot)
    }

    func fetchUsage() async throws -> UsageSnapshot {
        guard let balance = readLatestBalance() else {
            throw ProviderError.actionRequired("请先打开 ZCode 的 Model settings，让 ZCode 同步一次 GLM 额度")
        }

        let plan = readLatestPlan()
        let pools = balance.balances.map { item in
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
        extras.append(UsageExtra(label: "来源", value: "ZCode 本地日志"))
        if let fetchedAt = balance.fetchedAt {
            extras.append(UsageExtra(label: "额度时间", value: relativeTimeString(from: fetchedAt)))
        }
        if let connectionMode = balance.providerDisplayName {
            extras.append(UsageExtra(label: "连接模式", value: connectionMode))
        }

        let resetDate = pools.compactMap(\.resetsAt).min()

        return UsageSnapshot(
            providerID: id,
            fetchedAt: Date(),
            windows: [],
            pools: pools,
            extras: extras,
            planName: plan?.planName ?? balance.planName,
            accountEmail: nil,
            billingCycleEnd: resetDate ?? plan?.endsAt
        )
    }

    private func readLatestBalance() -> ZCodeBalanceState? {
        let decoder = JSONDecoder()
        for file in latestLogFiles() {
            guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true).reversed()

            for line in lines where line.contains("billing/balance") && line.contains("请求完成") {
                guard let jsonText = jsonText(in: line),
                      let data = jsonText.data(using: .utf8),
                      let log = try? decoder.decode(ZCodeBalanceLog.self, from: data),
                      let balances = log.payload?.data?.balances,
                      !balances.isEmpty
                else { continue }

                return ZCodeBalanceState(
                    providerID: log.providerID,
                    providerDisplayName: displayName(forProviderID: log.providerID),
                    planName: fallbackPlanName(from: balances.first?.planID),
                    balances: balances,
                    fetchedAt: logDate(in: line) ?? modificationDate(atPath: file)
                )
            }
        }
        return nil
    }

    private func readLatestPlan() -> ZCodePlanState? {
        let decoder = JSONDecoder()
        for file in latestLogFiles() {
            guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true).reversed()

            for line in lines where line.contains("billing/current") && line.contains("请求完成") {
                guard let jsonText = jsonText(in: line),
                      let data = jsonText.data(using: .utf8),
                      let log = try? decoder.decode(ZCodeCurrentLog.self, from: data),
                      let plan = log.payload?.data?.plans.first
                else { continue }

                return ZCodePlanState(planName: normalizePlanName(plan.name), endsAt: plan.endsAtDate)
            }
        }
        return nil
    }

    private func latestLogFiles() -> [String] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: Self.logsRoot) else { return [] }
        return items
            .filter { $0.hasSuffix(".log") || $0.hasSuffix(".jsonl") }
            .map { (Self.logsRoot as NSString).appendingPathComponent($0) }
            .sorted {
                (modificationDate(atPath: $0) ?? .distantPast) >
                (modificationDate(atPath: $1) ?? .distantPast)
            }
    }

    private func jsonText(in line: Substring) -> String? {
        guard let start = line.firstIndex(of: "{") else { return nil }
        return String(line[start...])
    }

    private func logDate(in line: Substring) -> Date? {
        guard line.first == "[",
              let end = line.firstIndex(of: "]")
        else { return nil }

        let raw = String(line[line.index(after: line.startIndex)..<end])
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter.date(from: raw)
    }

    private func modificationDate(atPath path: String) -> Date? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return attrs[.modificationDate] as? Date
    }

    private func relativeTimeString(from date: Date) -> String {
        let elapsed = Date().timeIntervalSince(date)
        if elapsed < 0 { return "刚刚" }
        switch elapsed {
        case ..<60:        return "刚刚"
        case 60..<3600:    return "\(Int(elapsed / 60)) 分钟前"
        case 3600..<86400: return "\(Int(elapsed / 3600)) 小时前"
        default:           return "\(Int(elapsed / 86400)) 天前"
        }
    }

    private func displayName(forProviderID providerID: String?) -> String? {
        guard let providerID else { return nil }
        if providerID.contains("zai") { return "Z.ai Coding Plan" }
        if providerID.contains("bigmodel") { return "BigModel Coding Plan" }
        return nil
    }

    private func fallbackPlanName(from planID: String?) -> String? {
        guard let planID else { return nil }
        if planID.contains("start") { return "Start Plan" }
        if planID.contains("coding") { return "Coding Plan" }
        return nil
    }

    private func normalizePlanName(_ name: String) -> String {
        name
            .replacingOccurrences(of: "ZCode ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct ZCodeBalanceState {
    let providerID: String?
    let providerDisplayName: String?
    let planName: String?
    let balances: [ZCodeBalanceItem]
    let fetchedAt: Date?
}

private struct ZCodePlanState {
    let planName: String
    let endsAt: Date?
}

private struct ZCodeBalanceLog: Decodable {
    let providerID: String?
    let payload: Payload?

    enum CodingKeys: String, CodingKey {
        case providerID = "provider_id"
        case payload
    }

    struct Payload: Decodable {
        let data: BalanceData?
    }

    struct BalanceData: Decodable {
        let balances: [ZCodeBalanceItem]
    }
}

private struct ZCodeCurrentLog: Decodable {
    let payload: Payload?

    struct Payload: Decodable {
        let data: CurrentData?
    }

    struct CurrentData: Decodable {
        let plans: [Plan]
    }

    struct Plan: Decodable {
        let name: String
        let endsAt: Double?

        enum CodingKeys: String, CodingKey {
            case name
            case endsAt = "ends_at"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? "Start Plan"
            endsAt = container.decodeFlexibleDoubleIfPresent(forKey: .endsAt)
        }

        var endsAtDate: Date? {
            guard let endsAt, endsAt > 0 else { return nil }
            return Date(timeIntervalSince1970: endsAt)
        }
    }
}

private struct ZCodeBalanceItem: Decodable {
    let showName: String
    let totalUnits: Double
    let usedUnits: Double
    let remainingUnits: Double
    let periodEnd: Double?
    let expiresAt: Double?
    let planID: String?

    enum CodingKeys: String, CodingKey {
        case showName = "show_name"
        case totalUnits = "total_units"
        case usedUnits = "used_units"
        case remainingUnits = "remaining_units"
        case periodEnd = "period_end"
        case expiresAt = "expires_at"
        case planID = "plan_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        showName = (try? container.decodeIfPresent(String.self, forKey: .showName)) ?? "GLM"
        totalUnits = container.decodeFlexibleDoubleIfPresent(forKey: .totalUnits) ?? 0
        remainingUnits = container.decodeFlexibleDoubleIfPresent(forKey: .remainingUnits) ?? 0
        usedUnits = container.decodeFlexibleDoubleIfPresent(forKey: .usedUnits) ?? max(totalUnits - remainingUnits, 0)
        periodEnd = container.decodeFlexibleDoubleIfPresent(forKey: .periodEnd)
        expiresAt = container.decodeFlexibleDoubleIfPresent(forKey: .expiresAt)
        planID = try? container.decodeIfPresent(String.self, forKey: .planID)
    }

    var resetDate: Date? {
        let timestamp = expiresAt ?? periodEnd
        guard let timestamp, timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp)
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
        if let value = try? decodeIfPresent(Int64.self, forKey: key) {
            return Double(value)
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Double(value.replacingOccurrences(of: ",", with: ""))
        }
        return nil
    }
}
