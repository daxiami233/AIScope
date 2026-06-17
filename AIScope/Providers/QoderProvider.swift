import Foundation

// MARK: - QoderProvider

/// Qoder / Qoder CN 本地状态提供者。
///
/// Qoder 的浏览器登录凭证保存在本地私有格式中；额度优先读取本地日志中
/// getQuotaUsage 的最近一次真实响应，避免直接处理私有 auth 格式。
final class QoderProvider: AIToolProvider, Sendable {

    let id = "qoder"
    let displayName = "Qoder"
    let dashboardURL = URL(string: "https://qoder.com")!

    private static let cnRoot = NSString(string: "~/.qoder-cn").expandingTildeInPath
    private static let cliRoot = NSString(string: "~/.qoder-cli").expandingTildeInPath

    func detect() async -> Bool {
        FileManager.default.fileExists(atPath: Self.cnRoot)
            || FileManager.default.fileExists(atPath: Self.cliRoot)
    }

    func fetchUsage() async throws -> UsageSnapshot {
        let state = loadState()
        guard state.isInstalled else {
            throw ProviderError.notInstalled
        }

        var pools: [UsagePool] = []
        var extras: [UsageExtra] = []

        if let quota = state.quota {
            pools.append(UsagePool(
                label: "套餐额度",
                used: quota.userQuota.used,
                limit: quota.userQuota.total,
                unit: quota.userQuota.unit,
                resetsAt: quota.expiresAtDate
            ))
            if let fetchedAt = quota.fetchedAt {
                extras.append(UsageExtra(label: "额度时间", value: relativeTimeString(from: fetchedAt)))
            }
        } else {
            extras.append(UsageExtra(label: "额度", value: "等待 Qoder 同步"))
        }

        extras.append(UsageExtra(label: "版本", value: state.variant))
        if let model = state.model, !model.isEmpty {
            extras.append(UsageExtra(label: "模型", value: model))
        }
        extras.append(UsageExtra(label: "会话", value: "\(state.sessionCount) 个本地会话"))
        if let lastUsed = state.lastUsed {
            extras.append(UsageExtra(label: "最近使用", value: relativeTimeString(fromMilliseconds: lastUsed)))
        }
        if state.hasBrowserAuth {
            extras.append(UsageExtra(label: "登录", value: "浏览器账号"))
        }

        return UsageSnapshot(
            providerID: id,
            fetchedAt: Date(),
            windows: [],
            pools: pools,
            extras: extras,
            planName: state.quota?.planName ?? "本地状态",
            accountEmail: nil,
            billingCycleEnd: state.quota?.expiresAtDate
        )
    }

    private func loadState() -> QoderState {
        let fm = FileManager.default
        let hasCN = fm.fileExists(atPath: Self.cnRoot)
        let hasCLI = fm.fileExists(atPath: Self.cliRoot)
        let model = readDefaultModel()
        let sessionFiles = listSessionFiles()
        let lastUsed = sessionFiles.compactMap { modificationTimeMilliseconds(atPath: $0) }.max()
        let authPath = "\(Self.cnRoot)/.auth/user"
        let quota = readLatestQuotaUsage()

        return QoderState(
            isInstalled: hasCN || hasCLI,
            variant: hasCN ? "Qoder CN" : "Qoder CLI",
            model: model,
            sessionCount: sessionFiles.count,
            lastUsed: lastUsed,
            hasBrowserAuth: fm.fileExists(atPath: authPath),
            quota: quota
        )
    }

    private func readDefaultModel() -> String? {
        let path = "\(Self.cnRoot)/.models/default"
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONDecoder().decode(DefaultModel.self, from: data)
        else { return nil }
        if json.key == "auto" { return "Auto" }
        return json.key
    }

    private func listSessionFiles() -> [String] {
        let roots = [
            "\(Self.cnRoot)/projects",
            "\(Self.cliRoot)/ai-stats"
        ]
        var files: [String] = []
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(atPath: root) else { continue }
            for case let item as String in enumerator where item.hasSuffix(".jsonl") {
                files.append((root as NSString).appendingPathComponent(item))
            }
        }
        return files
    }

    private func readLatestQuotaUsage() -> QoderQuotaUsage? {
        let logRoot = "\(Self.cnRoot)/logs/runs"
        guard let enumerator = FileManager.default.enumerator(atPath: logRoot) else { return nil }

        let logFiles = enumerator
            .compactMap { $0 as? String }
            .filter { $0.hasSuffix("qodercli.log") }
            .map { (logRoot as NSString).appendingPathComponent($0) }
            .sorted {
                (modificationTimeMilliseconds(atPath: $0) ?? 0) >
                (modificationTimeMilliseconds(atPath: $1) ?? 0)
            }

        let decoder = JSONDecoder()
        for file in logFiles {
            guard let data = FileManager.default.contents(atPath: file),
                  let text = String(data: data, encoding: .utf8)
            else { continue }

            let lines = text.split(separator: "\n", omittingEmptySubsequences: true).reversed()
            for line in lines {
                guard line.contains("quota/usage response:"),
                      let jsonStart = line.firstIndex(of: "{")
                else { continue }

                let jsonText = String(line[jsonStart...])
                guard let jsonData = jsonText.data(using: .utf8),
                      var quota = try? decoder.decode(QoderQuotaUsage.self, from: jsonData)
                else { continue }
                quota.fetchedAt = modificationTimeMilliseconds(atPath: file).map {
                    Date(timeIntervalSince1970: $0 / 1000.0)
                }
                return quota
            }
        }
        return nil
    }

    private func modificationTimeMilliseconds(atPath path: String) -> Double? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let date = attrs[.modificationDate] as? Date else { return nil }
        return date.timeIntervalSince1970 * 1000
    }

    private func relativeTimeString(fromMilliseconds ms: Double) -> String {
        let date = Date(timeIntervalSince1970: ms / 1000.0)
        return relativeTimeString(from: date)
    }

    private func relativeTimeString(from date: Date) -> String {
        let elapsed = Date().timeIntervalSince(date)
        switch elapsed {
        case ..<60:        return "刚刚"
        case 60..<3600:    return "\(Int(elapsed / 60)) 分钟前"
        case 3600..<86400: return "\(Int(elapsed / 3600)) 小时前"
        default:           return "\(Int(elapsed / 86400)) 天前"
        }
    }
}

private struct QoderState {
    let isInstalled: Bool
    let variant: String
    let model: String?
    let sessionCount: Int
    let lastUsed: Double?
    let hasBrowserAuth: Bool
    let quota: QoderQuotaUsage?
}

private struct DefaultModel: Decodable {
    let key: String
}

private struct QoderQuotaUsage: Decodable {
    let userType: String?
    let expiresAt: Double?
    let userQuota: UserQuota
    var fetchedAt: Date?

    enum CodingKeys: String, CodingKey {
        case userType
        case expiresAt
        case userQuota
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        userType = try container.decodeIfPresent(String.self, forKey: .userType)
        expiresAt = container.decodeFlexibleDoubleIfPresent(forKey: .expiresAt)
        userQuota = try container.decode(UserQuota.self, forKey: .userQuota)
        fetchedAt = nil
    }

    var planName: String? {
        guard let userType, !userType.isEmpty else { return nil }
        return userType
            .split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    var expiresAtDate: Date? {
        guard let expiresAt, expiresAt > 0 else { return nil }
        return Date(timeIntervalSince1970: expiresAt / 1000.0)
    }

    struct UserQuota: Decodable {
        let total: Double
        let used: Double
        let remaining: Double?
        let unit: String

        enum CodingKeys: String, CodingKey {
            case total
            case used
            case remaining
            case unit
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            total = container.decodeFlexibleDoubleIfPresent(forKey: .total) ?? 0
            used = container.decodeFlexibleDoubleIfPresent(forKey: .used) ?? {
                guard let total = container.decodeFlexibleDoubleIfPresent(forKey: .total),
                      let remaining = container.decodeFlexibleDoubleIfPresent(forKey: .remaining)
                else { return 0 }
                return max(total - remaining, 0)
            }()
            remaining = container.decodeFlexibleDoubleIfPresent(forKey: .remaining)
            unit = (try? container.decodeIfPresent(String.self, forKey: .unit)) ?? "Credits"
        }
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
