import Foundation

// MARK: - CodexProvider

/// OpenAI Codex CLI 用量提供者。
///
/// 2026 年 6 月：Codex CLI 使用 ChatGPT 账户登录时，用量计入 agentic usage 共享池
/// （与 Codex Web、Codex IDE、ChatGPT for Excel 等产品共享）。
///
/// 额度计量：Token 级别（输入 + 缓存输入 + 输出）。
/// 两个独立滚动窗口，任意一个达到上限都会阻止新任务启动：
///   • 5h 窗口（primary）   — 短周期资源预算
///   • 7d 窗口（secondary） — 周级累计上限
///
/// 凭证来源（优先级从高到低）：
///   1. macOS Keychain，服务名 "Codex Auth"
///   2. 本地文件 ~/.codex/auth.json
///
/// API：GET https://chatgpt.com/backend-api/wham/usage（非官方逆向接口）
final class CodexProvider: AIToolProvider, Sendable {

    // MARK: - AIToolProvider 标识

    let id           = "openai-codex"
    let displayName  = "Codex"
    let dashboardURL = URL(string: "https://chatgpt.com")!

    // MARK: - AIToolProvider 实现

    func detect() async -> Bool {
        (try? loadCredential()) != nil
    }

    func fetchUsage() async throws -> UsageSnapshot {
        let token = try loadCredential()
        let url = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
        let headers: [String: String] = [
            "Authorization": "Bearer \(token)",
            "Accept":        "application/json",
            "User-Agent":    "AIScope/1.0"
        ]
        let response: CodexUsageResponse = try await URLSession.shared.fetchJSON(url, headers: headers)
        return buildSnapshot(from: response)
    }

    // MARK: - 凭证读取

    private func loadCredential() throws -> String {
        // 优先读取本地文件，避免只做状态检测时触发 macOS Keychain 授权弹窗。
        let filePath = NSString(string: "~/.codex/auth.json").expandingTildeInPath
        if let data = FileManager.default.contents(atPath: filePath),
           let auth = try? JSONDecoder().decode(AuthFile.self, from: data),
           let token = auth.tokens?.access_token,
           !token.isEmpty {
            return token
        }

        // 回退：macOS Keychain
        let keychainAuth: AuthFile? = KeychainService.readGenericPasswordJSON(service: "Codex Auth")
        if let token = keychainAuth?.tokens?.access_token, !token.isEmpty {
            return token
        }

        throw ProviderError.credentialMissing
    }

    // MARK: - Snapshot 构建

    private func buildSnapshot(from response: CodexUsageResponse) -> UsageSnapshot {
        var windows: [UsageWindow] = []
        var extras:  [UsageExtra]  = []

        if let rateLimit = response.rate_limit {
            // 5h 短周期窗口
            if let primary = rateLimit.primary_window {
                windows.append(makeWindow(label: "5h", info: primary))
            }
            // 7d 周累计窗口
            if let secondary = rateLimit.secondary_window {
                windows.append(makeWindow(label: "7d", info: secondary))
            }
        }

        // Credits 余额（有限额账户才展示）
        if let credits = response.credits,
           credits.has_credits == true,
           credits.unlimited != true,
           let balance = credits.balance {
            extras.append(UsageExtra(
                label: "Credits 余额",
                value: String(format: "%.2f 积分", balance)
            ))
        }

        return UsageSnapshot(
            providerID: id, fetchedAt: Date(),
            windows: windows, pools: [], extras: extras,
            planName: response.plan_type.map(capitalized),
            accountEmail: response.email, billingCycleEnd: nil
        )
    }

    // MARK: - 工具方法

    private func makeWindow(label: String, info: WindowInfo) -> UsageWindow {
        UsageWindow(
            label:         label,
            utilization:   min(max((info.used_percent ?? 0) / 100.0, 0), 1.0),
            resetsAt:      info.reset_at.map { Date(timeIntervalSince1970: $0) },
            isHighlighted: false
        )
    }

    private func capitalized(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }
}

// MARK: - 响应模型

private struct AuthFile: Decodable {
    let auth_mode: String?
    let tokens:    TokenBlock?
    struct TokenBlock: Decodable {
        let access_token:  String?
        let refresh_token: String?
    }
}

private struct CodexUsageResponse: Decodable {
    let plan_type:  String?
    let email:      String?
    let rate_limit: RateLimit?
    let credits:    CreditsBlock?
}

private struct RateLimit: Decodable {
    let primary_window:   WindowInfo?
    let secondary_window: WindowInfo?
}

/// used_percent / reset_at 可能在数字与字符串之间变化，使用宽松解析。
private struct WindowInfo: Decodable {
    let used_percent:         Double?
    let reset_at:             Double?
    let limit_window_seconds: Int?

    enum CodingKeys: String, CodingKey {
        case used_percent
        case reset_at
        case limit_window_seconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        used_percent = container.decodeFlexibleDoubleIfPresent(forKey: .used_percent)
        reset_at = container.decodeFlexibleDoubleIfPresent(forKey: .reset_at)
        limit_window_seconds = try container.decodeIfPresent(Int.self, forKey: .limit_window_seconds)
    }
}

/// balance 实测可能为字符串 "0" 或 JSON number，使用宽松解析。
private struct CreditsBlock: Decodable {
    let has_credits: Bool?
    let unlimited:   Bool?
    let balance:     Double?

    enum CodingKeys: String, CodingKey {
        case has_credits
        case unlimited
        case balance
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        has_credits = try container.decodeIfPresent(Bool.self, forKey: .has_credits)
        unlimited = try container.decodeIfPresent(Bool.self, forKey: .unlimited)
        balance = container.decodeFlexibleDoubleIfPresent(forKey: .balance)
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
            return Double(value)
        }
        return nil
    }
}
