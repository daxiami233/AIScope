import Foundation
import Security
import LocalAuthentication

/// Thin wrapper around macOS Keychain for read-only access to existing credentials.
enum KeychainService {
    private static let genericPasswordCache = KeychainDataCache()
    private static let allGenericPasswordsCache = KeychainAllDataCache()
    private static let genericPasswordReadLock = NSLock()

    // MARK: - Generic Password

    /// Reads a generic password item by service name.
    /// Returns the raw Data stored in kSecValueData.
    static func readGenericPassword(
        service: String,
        account: String? = nil,
        allowUserInteraction: Bool = true
    ) -> Data? {
        let cacheKey = genericCacheKey(service: service, account: account)
        if let cached = genericPasswordCache.read(cacheKey) {
            return cached
        }

        genericPasswordReadLock.lock()
        defer { genericPasswordReadLock.unlock() }

        if let cached = genericPasswordCache.read(cacheKey) {
            return cached
        }

        let context = LAContext()
        context.interactionNotAllowed = !allowUserInteraction

        var query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecReturnData:  true,
            kSecMatchLimit:  kSecMatchLimitOne,
            kSecUseAuthenticationContext: context
        ]
        if let account { query[kSecAttrAccount] = account }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        genericPasswordCache.write(data, for: cacheKey)
        return data
    }

    /// Convenience: reads a generic password and decodes it as a UTF-8 string.
    static func readGenericPasswordString(
        service: String,
        account: String? = nil,
        allowUserInteraction: Bool = true
    ) -> String? {
        guard let data = readGenericPassword(
            service: service,
            account: account,
            allowUserInteraction: allowUserInteraction
        ) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Writes or updates a generic password item.
    static func writeGenericPasswordString(_ value: String, service: String, account: String) throws {
        let data = Data(value.utf8)
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]

        let update: [CFString: Any] = [kSecValueData: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess {
            genericPasswordCache.write(data, for: genericCacheKey(service: service, account: account))
            allGenericPasswordsCache.remove(service)
            return
        }
        guard status == errSecItemNotFound else { throw KeychainError(status: status) }

        var item = query
        item[kSecValueData] = data
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        genericPasswordCache.write(data, for: genericCacheKey(service: service, account: account))
        allGenericPasswordsCache.remove(service)
    }

    /// Deletes a generic password item if present.
    static func deleteGenericPassword(service: String, account: String? = nil) throws {
        var query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service
        ]
        if let account { query[kSecAttrAccount] = account }

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
        genericPasswordCache.remove(genericCacheKey(service: service, account: account))
        allGenericPasswordsCache.remove(service)
    }

    /// Reads all generic password items for a given service.
    /// Useful when the account name is unknown.
    static func readAllGenericPasswords(
        service: String,
        allowUserInteraction: Bool = true
    ) -> [(account: String, data: Data)] {
        if let cached = allGenericPasswordsCache.read(service) {
            return cached
        }

        genericPasswordReadLock.lock()
        defer { genericPasswordReadLock.unlock() }

        if let cached = allGenericPasswordsCache.read(service) {
            return cached
        }

        let context = LAContext()
        context.interactionNotAllowed = !allowUserInteraction

        let query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrService:      service,
            kSecReturnData:       true,
            kSecReturnAttributes: true,
            kSecMatchLimit:       kSecMatchLimitAll,
            kSecUseAuthenticationContext: context
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let items = result as? [[CFString: Any]] else { return [] }

        let passwords: [(account: String, data: Data)] = items.compactMap { item -> (account: String, data: Data)? in
            guard let data    = item[kSecValueData]    as? Data,
                  let account = item[kSecAttrAccount]  as? String else { return nil }
            return (account, data)
        }
        allGenericPasswordsCache.write(passwords, for: service)
        for item in passwords {
            genericPasswordCache.write(item.data, for: genericCacheKey(service: service, account: item.account))
        }
        return passwords
    }

    // MARK: - JSON helper

    /// Reads a generic password and attempts to decode it as JSON into the given Decodable type.
    static func readGenericPasswordJSON<T: Decodable>(
        service: String,
        account: String? = nil,
        allowUserInteraction: Bool = true
    ) -> T? {
        guard let data = readGenericPassword(
            service: service,
            account: account,
            allowUserInteraction: allowUserInteraction
        ) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func genericCacheKey(service: String, account: String?) -> String {
        "\(service)\u{1F}\(account ?? "")"
    }

    struct KeychainError: LocalizedError {
        let status: OSStatus

        var errorDescription: String? {
            "Keychain 操作失败 (OSStatus \(status))"
        }
    }
}

// MARK: - AIScope Credential Vault

struct AIScopeCredentials: Codable, Sendable {
    var mimoPlatformCookie: String?
    /// OpenCode 官网登录会话。仅用于读取 Go 控制台中的实时用量。
    var openCodeGoCookie: String?
    var copilotOAuthToken: String?
    var copilotUsername: String?
}

enum AIScopeCredentialStore {
    private static let service = "AIScope.Credentials"
    private static let account = "main"

    static func read(allowUserInteraction: Bool = true) -> AIScopeCredentials {
        guard let text = KeychainService.readGenericPasswordString(
            service: service,
            account: account,
            allowUserInteraction: allowUserInteraction
        ),
              let data = text.data(using: .utf8),
              let credentials = try? JSONDecoder().decode(AIScopeCredentials.self, from: data)
        else { return AIScopeCredentials() }
        return credentials
    }

    static func update(_ mutate: (inout AIScopeCredentials) -> Void) throws {
        var credentials = read(allowUserInteraction: true)
        mutate(&credentials)
        let data = try JSONEncoder().encode(credentials)
        guard let text = String(data: data, encoding: .utf8) else {
            throw KeychainService.KeychainError(status: errSecParam)
        }
        try KeychainService.writeGenericPasswordString(text, service: service, account: account)
    }
}

private final class KeychainDataCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func read(_ key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func write(_ data: Data, for key: String) {
        lock.lock()
        values[key] = data
        lock.unlock()
    }

    func remove(_ key: String) {
        lock.lock()
        values.removeValue(forKey: key)
        lock.unlock()
    }
}

private final class KeychainAllDataCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: [(account: String, data: Data)]] = [:]

    func read(_ service: String) -> [(account: String, data: Data)]? {
        lock.lock()
        defer { lock.unlock() }
        return values[service]
    }

    func write(_ items: [(account: String, data: Data)], for service: String) {
        lock.lock()
        values[service] = items
        lock.unlock()
    }

    func remove(_ service: String) {
        lock.lock()
        values.removeValue(forKey: service)
        lock.unlock()
    }
}
