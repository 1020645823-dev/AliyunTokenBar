import Foundation

// MARK: - DeepSeek API 余额服务
//
// 数据源:官方公开接口 GET https://api.deepseek.com/user/balance(Authorization: Bearer <apiKey>)。
// 官方只提供余额,不提供用量/账单明细接口——「当日使用费用」由 DeepSeekDailyLedger
// 用余额差快照法计算(见 DeepSeekDailyLedger.swift)。
//
// 认证错误语义与 BlUsageService/KimiUsageService 对齐:authExpired / network / parse /
// invalidResponse / unknown。401/403 = API Key 无效或已吊销 → authExpired。

public enum DeepSeekUsageService {
    public static let balanceURL = URL(string: "https://api.deepseek.com/user/balance")!

    /// 余额(官方样例:{"is_available":true,"balance_infos":[{"currency":"CNY",
    /// "total_balance":"110.00","granted_balance":"10.00","topped_up_balance":"100.00"}]})
    public struct DeepSeekBalance: Equatable {
        /// 当前账户是否有余额可供 API 调用
        public let isAvailable: Bool
        /// 货币(CNY / USD)
        public let currency: String
        /// 总的可用余额,包括赠金和充值余额
        public let totalBalance: Double
        /// 未过期的赠金余额
        public let grantedBalance: Double
        /// 充值余额
        public let toppedUpBalance: Double

        public init(isAvailable: Bool, currency: String, totalBalance: Double,
                    grantedBalance: Double, toppedUpBalance: Double) {
            self.isAvailable = isAvailable
            self.currency = currency
            self.totalBalance = totalBalance
            self.grantedBalance = grantedBalance
            self.toppedUpBalance = toppedUpBalance
        }
    }

    // MARK: - API Key 存储(Keychain)

    /// 读取 Keychain 中的 API Key(未配置返回 nil)。
    public static func loadAPIKey() -> String? {
        let raw = KeychainCredentialStore(service: KeychainAccounts.service)
            .read(account: KeychainAccounts.deepSeekAPIKey) ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 保存 API Key(trim 后非空才写)。
    @discardableResult
    public static func saveAPIKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        KeychainCredentialStore(service: KeychainAccounts.service)
            .write(trimmed, account: KeychainAccounts.deepSeekAPIKey)
        return true
    }

    /// 清除 API Key。
    public static func clearAPIKey() {
        KeychainCredentialStore(service: KeychainAccounts.service)
            .delete(account: KeychainAccounts.deepSeekAPIKey)
    }

    // MARK: - Fetch

    /// 拉取余额。失败语义同其他 Provider。
    public static func fetchBalance(apiKey: String) async -> Result<DeepSeekBalance, UsageError> {
        var request = URLRequest(url: balanceURL)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(.invalidResponse)
            }
            if let classified = classifyBalanceError(statusCode: http.statusCode) {
                return .failure(classified)
            }
            guard let balance = parseBalance(data) else { return .failure(.parse) }
            return .success(balance)
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }

    /// HTTP 状态 → 错误分类(纯函数,Verify 有断言)。200 → nil(成功)。
    /// 401/403:API Key 无效/吊销;402:余额不足(官方计费错误码);其余 4xx/5xx 视为网络/服务错误。
    public static func classifyBalanceError(statusCode: Int) -> UsageError? {
        switch statusCode {
        case 200: return nil
        case 401, 403: return .authExpired
        case 402: return .unknown("账户余额不足,无法调用 API")
        default: return .network("HTTP \(statusCode)")
        }
    }

    // MARK: - Parse(纯函数,fixture 测试覆盖)

    /// 解析 /user/balance 响应。金额字段为字符串或数字,宽容解析;
    /// 多币种时优先 CNY(面向中文用户),无 CNY 取第一条。
    public static func parseBalance(_ data: Data) -> DeepSeekBalance? {
        guard let root = try? JSONDecoder().decode(BalanceResponseDTO.self, from: data),
              let infos = root.balanceInfos, !infos.isEmpty else { return nil }
        let picked = infos.first(where: { ($0.currency ?? "").uppercased() == "CNY" }) ?? infos[0]
        return DeepSeekBalance(
            isAvailable: root.isAvailable ?? false,
            currency: (picked.currency ?? "").uppercased(),
            totalBalance: max(0, picked.totalBalance ?? 0),
            grantedBalance: max(0, picked.grantedBalance ?? 0),
            toppedUpBalance: max(0, picked.toppedUpBalance ?? 0)
        )
    }

    // MARK: - DTO(宽容 Codable:金额字段字符串/数字均可)

    fileprivate struct BalanceResponseDTO: Decodable {
        var isAvailable: Bool?
        var balanceInfos: [BalanceInfoDTO]?

        struct BalanceInfoDTO: Decodable {
            var currency: String?
            var totalBalance: Double?
            var grantedBalance: Double?
            var toppedUpBalance: Double?

            enum CodingKeys: String, CodingKey {
                case currency, totalBalance = "total_balance"
                case grantedBalance = "granted_balance"
                case toppedUpBalance = "topped_up_balance"
            }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                currency = try c.decodeIfPresent(String.self, forKey: .currency)
                totalBalance = try c.decodeIfPresent(FlexibleDouble.self, forKey: .totalBalance)?.wrappedValue
                grantedBalance = try c.decodeIfPresent(FlexibleDouble.self, forKey: .grantedBalance)?.wrappedValue
                toppedUpBalance = try c.decodeIfPresent(FlexibleDouble.self, forKey: .toppedUpBalance)?.wrappedValue
            }
        }

        enum CodingKeys: String, CodingKey {
            case isAvailable = "is_available", balanceInfos = "balance_infos"
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            isAvailable = try c.decodeIfPresent(Bool.self, forKey: .isAvailable)
            balanceInfos = try c.decodeIfPresent([BalanceInfoDTO].self, forKey: .balanceInfos)
        }
    }
}

// MARK: - 金额格式化(面板完整格式 + 菜单栏紧凑格式)

public enum DeepSeekMoneyFormat {
    /// 面板完整格式:恒两位小数("¥110.00" / "¥0.00")。
    public static func full(_ v: Double) -> String {
        "¥" + String(format: "%.2f", max(0, v))
    }

    /// 菜单栏紧凑格式(契约:≤7 字符,渲染层据此定值域宽):
    /// - v < 100       → ¥9.99(两位小数)
    /// - 100 ≤ v < 1万 → ¥9999(整数)
    /// - 1万 ≤ v < 1亿 → ¥12.3万(1 位小数)
    /// - v ≥ 1亿       → ¥1.2亿(1 位小数)
    public static func compact(_ v: Double) -> String {
        let x = max(0, v)
        if x >= 100_000_000 { return "¥" + String(format: "%.1f亿", x / 100_000_000) }
        if x >= 10_000 { return "¥" + String(format: "%.1f万", x / 10_000) }
        if x >= 100 { return "¥" + String(format: "%.0f", x) }
        return "¥" + String(format: "%.2f", x)
    }
}
