import Foundation
import Security

// MARK: - 凭据存储(OpenCode cookie 等)

/// 凭据读写抽象。逻辑层只依赖协议——Keychain 是 macOS 专属 API,
/// 注入到 executable 层用真实实现、Verify 层用内存实现。
public protocol CredentialStore {
    func read(account: String) -> String?
    func write(_ value: String, account: String)
    func delete(account: String)
}

/// 内存实现(测试用)。
public final class InMemoryCredentialStore: CredentialStore {
    public private(set) var store: [String: String] = [:]
    public init(_ initial: [String: String] = [:]) { self.store = initial }
    public func read(account: String) -> String? { store[account] }
    public func write(_ value: String, account: String) { store[account] = value }
    public func delete(account: String) { store.removeValue(forKey: account) }
}

/// macOS Keychain 实现。service 区分不同用途,account 区分不同凭据。
public final class KeychainCredentialStore: CredentialStore {
    public let service: String
    public init(service: String) { self.service = service }

    public func read(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data,
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    public func write(_ value: String, account: String) {
        guard let data = value.data(using: .utf8) else { return }
        var query = baseQuery(account: account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(query as CFDictionary, nil)
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        if status == errSecDuplicateItem {
            // 已存在 → 更新
            SecItemUpdate(baseQuery(account: account) as CFDictionary, attrs as CFDictionary)
        }
    }

    public func delete(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

// MARK: - UserDefaults → Keychain 一次性迁移

/// 把旧的明文 UserDefaults 值迁到 CredentialStore,迁完删除明文键。
/// 幂等:迁移源不存在则 no-op;目标已有值时以目标为准(不覆盖)。
public enum CredentialMigration {
    /// - Returns: 是否发生了迁移(读了旧值并写入新存储)。
    @discardableResult
    public static func migrate(
        legacyKey: String, account: String,
        from defaults: UserDefaults = .standard,
        to store: CredentialStore
    ) -> Bool {
        guard let legacy = defaults.string(forKey: legacyKey), !legacy.isEmpty else {
            return false   // 旧值不存在
        }
        // 目标已有 → 不覆盖,但仍清掉明文
        if store.read(account: account) == nil {
            store.write(legacy, account: account)
        }
        defaults.removeObject(forKey: legacyKey)
        return true
    }
}
