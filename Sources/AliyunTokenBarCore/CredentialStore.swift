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
        // 读永不应弹授权框:ad-hoc 签名每次构建 cdhash 都变,钥匙串 ACL 不认识
        // 新二进制,UI 允许模式下 SecItemCopyMatching 会弹「想要使用钥匙串中的
        // 机密信息」并阻塞(迁移期/启动期都可能中招)。改用 Fail 模式:读不到
        // 就返回 nil,迁移静默跳过该项(凭证文件才是事实源)。
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data,
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    public func write(_ value: String, account: String) {
        guard let data = value.data(using: .utf8) else { return }
        let existing = read(account: account)
        // 值未变则跳过写入:启动时 ensureCredentialLoaded 会把 Keychain 旧值读回
        // 属性, didSet 随之触发写回——对既有项做无谓的 SecItemUpdate。ad-hoc 签名
        // 每次构建 CDHash 都变,更新旧项会弹钥匙串授权框并阻塞主线程(已知问题),
        // 而读回的值本就与存储一致,跳过零副作用。空值且无既有项同样跳过
        // (init 读回/登出后不得留下空项)。
        if existing == value || (value.isEmpty && existing == nil) { return }
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

// MARK: - 应用内凭证文件(2026-10-17:全部登录态持久化在 .app 包内,支持维护/更新)

/// 全部登录态(AK/SK、OpenCode cookie、Kimi JWT、各 API Key、MiMo Cookie jar、
/// 阶跃 console token)统一持久化在 `.app/Contents/Resources/atb-credentials.json`
/// (2026-10-17 用户要求:应用文件中可维护、拷贝 .app 即迁移全部登录态)。
///
/// - 协议与 Keychain 实现一致(account → value 扁平映射),所有调用点零改动;
/// - 首次启动把 Keychain 既有值一次性迁入文件(读操作不触发授权弹窗),
///   之后 Keychain 只作回滚备份,不再读写;
/// - 文件权限 0600(仅属主可读);JSON 明文,可用任意文本编辑器维护;
/// - 更新由 `packaging/install-update.sh` 负责保留(替换 .app 前备份、装完写回)。
public final class AppFileCredentialStore: CredentialStore {
    /// 凭证文件名(位于 .app/Contents/Resources/ 或开发态的应用支持目录)。
    public static let fileName = "atb-credentials.json"

    private let fileURL: URL
    /// 一次性迁移来源(旧 Keychain 值)。
    private let keychain: KeychainCredentialStore
    private let queue = DispatchQueue(label: "com.zww.aliyuntokenbar.credentials")
    private var cache: [String: String]
    /// 迁移完成标记(文件内字段),防止移除凭据后被 Keychain 旧值复活。
    private var migrated = false

    public init(fileURL: URL? = nil, keychainService: String = KeychainAccounts.service,
                migrateFromKeychain: Bool = true) {
        self.fileURL = fileURL ?? Self.resolveFileURL()
        self.keychain = KeychainCredentialStore(service: keychainService)
        let (dict, migrated) = Self.load(from: self.fileURL)
        self.cache = dict
        self.migrated = migrated
        if migrateFromKeychain { migrateFromKeychainIfNeeded() }
    }

    /// 全 app 共享实例(登录态唯一事实源)。
    public static let shared = AppFileCredentialStore()

    // MARK: - 路径解析

    /// 生产(.app 安装态)→ 包内 Contents/Resources(用户要求的"应用文件中");
    /// 开发态(swift run/Verify 裸二进制)→ 应用支持目录(包不存在或不可写)。
    public static func resolveFileURL() -> URL {
        let bundleURL = Bundle.main.bundleURL
        if bundleURL.pathExtension == "app" {
            let resources = bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
            if FileManager.default.isWritableFile(atPath: resources.path) {
                return resources.appendingPathComponent(fileName)
            }
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AliyunTokenBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent(fileName)
    }

    /// 当前凭证文件位置(设置页展示/维护用)。
    public var credentialsFileURL: URL { fileURL }

    // MARK: - CredentialStore

    public func read(account: String) -> String? {
        queue.sync { cache[account] }
    }

    public func write(_ value: String, account: String) {
        queue.sync {
            // 与 Keychain 实现同语义:值未变跳过;空值且无既有项不落盘
            if cache[account] == value || (value.isEmpty && cache[account] == nil) { return }
            cache[account] = value
            saveLocked()
        }
    }

    public func delete(account: String) {
        queue.sync {
            guard cache.removeValue(forKey: account) != nil else { return }
            saveLocked()
        }
    }

    // MARK: - 持久化

    /// 落盘(JSON + 0600)。调用方须在 queue 内。
    private func saveLocked() {
        let payload: [String: Any] = [
            "schemaVersion": 1,
            "migratedFromKeychain": migrated,
            "credentials": cache,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]),
              let text = String(data: data, encoding: .utf8) else { return }
        do {
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            AppLog.error("凭证文件写入失败: \(error.localizedDescription)", category: .general)
        }
    }

    /// 读盘(宽容:文件不存在/坏 JSON → 空 + 未迁移)。
    private static func load(from url: URL) -> (dict: [String: String], migrated: Bool) {
        guard let data = FileManager.default.contents(atPath: url.path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let creds = root["credentials"] as? [String: String] else {
            return ([:], false)
        }
        return (creds, root["migratedFromKeychain"] as? Bool ?? false)
    }

    // MARK: - Keychain 一次性迁移

    /// 首次启动:把 Keychain 既有登录态并入文件(只读 Keychain,不触发授权弹窗),
    /// 打完标记后永不再迁(用户后续移除的凭据不会被旧值复活)。
    private func migrateFromKeychainIfNeeded() {
        guard !migrated else { return }
        let defaults = UserDefaults.standard
        var accounts: [String] = [
            KeychainAccounts.aliyunAKSK,
            KeychainAccounts.openCodeCookie,
            KeychainAccounts.kimiWebToken,
            KeychainAccounts.deepSeekAPIKey,
            KeychainAccounts.zhipuAPIKey,
            KeychainAccounts.mimoCookie,
            KeychainAccounts.mimoCookieJar,
            KeychainAccounts.minimaxAPIKey,
            KeychainAccounts.ollamaAPIKey,
            KeychainAccounts.stepfunConsoleToken,
        ]
        // 多账户分槽:id 来自各自 UserDefaults 账户列表(main 复用基础槽名)
        if let json = defaults.string(forKey: UserDefaultsKeys.kimiAccounts),
           let data = json.data(using: .utf8),
           let list = try? JSONDecoder().decode([KimiAccount].self, from: data) {
            accounts.append(contentsOf: list.map { "\(KeychainAccounts.kimiWebToken)-\($0.id)" })
        }
        if let json = defaults.string(forKey: UserDefaultsKeys.zhipuAccounts),
           let data = json.data(using: .utf8),
           let list = try? JSONDecoder().decode([ZhipuAccount].self, from: data) {
            accounts.append(contentsOf: list.map { "\(KeychainAccounts.zhipuAPIKey)-\($0.id)" })
        }
        var moved = 0
        for account in accounts where cache[account] == nil {
            if let value = keychain.read(account: account), !value.isEmpty {
                cache[account] = value
                moved += 1
            }
        }
        migrated = true
        saveLocked()
        if moved > 0 {
            AppLog.info("凭证文件已从 Keychain 迁移 \(moved) 项(文件不再依赖系统钥匙串)", category: .general)
        }
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
