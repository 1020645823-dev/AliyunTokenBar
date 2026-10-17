import Foundation
import SwiftUI
import Combine
import Network

@MainActor
public final class TokenPlanModel: ObservableObject {
    public static let shared = TokenPlanModel()

    @Published public var quota: TokenPlanQuota?
    @Published public var isLoading = false
    @Published public var authState: AuthState = .unknown
    @Published public var lastError: String?
    @Published public var lastUpdated: Date?

    /// 已安装的 bl 版本(如 "1.13.0");未装为 nil
    @Published public var blInstalledVersion: String?
    /// npm 上最新 bl 版本;查询失败为 nil
    @Published public var blLatestVersion: String?
    /// bl 是否可更新(installed < latest)
    public var blUpdateAvailable: Bool {
        guard let i = blInstalledVersion, let l = blLatestVersion else { return false }
        return compareVersions(i, l) < 0
    }

    // MARK: - OpenCode Go

    /// OpenCode Go 用量(三窗口,多 workspace 聚合值);未配置/未拉取为 nil。
    /// 菜单栏/历史/图标/告警单口径继续读此值(单 workspace 聚合=原值,零行为变化)。
    @Published public var openCodeQuota: OpenCodeQuota?
    /// OpenCode 是否已登录(opencode.ai 账户的 auth cookie;一个账户一份,
    /// 该账户下全部 workspace 共用此 cookie,2026-10-17 多 workspace)。
    @Published public var openCodeCookie: String {
        didSet { credentialStore.write(openCodeCookie, account: Self.openCodeCookieAccount) }
    }
    /// OpenCode 是否已配置(已登录且 ≥1 个受监控 workspace)。
    public var openCodeConfigured: Bool { !openCodeCookie.isEmpty && !openCodeWorkspaces.isEmpty }
    @Published public var openCodeError: String?
    /// 受监控的 workspace 列表(2026-10-17;id = wrk_xxx/org_xxx,label 可重命名)。
    /// 持久化到 UserDefaults;列表键存在=已迁移(防止移除全部后被凭据复活)。
    @Published public var openCodeWorkspaces: [OpenCodeWorkspace] {
        didSet { persistOpenCodeWorkspaces() }
    }
    /// 单 workspace 用量快照(模型层聚合后按 workspace 展示/告警)
    @Published public var openCodeWorkspaceQuotas: [OpenCodeWorkspaceSnapshot] = []
    /// 逐 workspace 错误明细(面板按行显示,可移除)
    @Published public var openCodeWorkspaceErrors: [String: String] = [:]
    /// OpenCode 最近一次成功拉取时间(任一 workspace 成功即更新)
    @Published public var openCodeLastUpdated: Date?

    // MARK: - Kimi Code

    /// Kimi Code 套餐用量(5h/周/月度总额 + 加油包)
    @Published public var kimiQuota: KimiQuota?
    /// Kimi 是否已配置(本机 KimiCodeBar / Kimi CLI 凭证,或任一已登录账户的 web JWT)
    public var kimiConfigured: Bool {
        !kimiAccounts.isEmpty || KimiUsageService.tokenExists() || KimiUsageService.loadWebToken() != nil
    }
    /// Kimi 网页控制台是否已登录(提供月度总额度数据;main 账户的 legacy 槽)
    public var kimiWebLoggedIn: Bool {
        KimiUsageService.loadWebToken() != nil
    }
    /// Kimi 已登录账户列表(2026-10-04 多账户;main=旧单账户路径,零迁移)
    @Published public var kimiAccounts: [KimiAccount] {
        didSet { persistKimiAccounts() }
    }
    /// Kimi 单账户用量快照(模型层聚合后按账户展示/告警)
    @Published public var kimiAccountQuotas: [KimiAccountSnapshot] = []
    /// Kimi 逐账户错误明细(面板按账户显示重登入口)
    @Published public var kimiAccountErrors: [String: String] = [:]
    /// Kimi 最近一次成功拉取时间(任一账户成功即更新)
    @Published public var kimiLastUpdated: Date?
    @Published public var kimiError: String?

    // MARK: - DeepSeek API

    /// DeepSeek 总余额(官方 /user/balance 接口)
    @Published public var deepSeekBalance: DeepSeekUsageService.DeepSeekBalance?
    /// 当日使用费用(0点→当前,余额差快照法;见 DeepSeekDailyLedger)
    @Published public var deepSeekTodayCost: DeepSeekDailyCost?
    @Published public var deepSeekError: String?
    @Published public var deepSeekLoading = false
    /// DeepSeek 最近一次成功拉取时间(状态行展示;失败保留旧值)
    @Published public var deepSeekLastUpdated: Date?
    /// DeepSeek API Key(Keychain 存储,didSet 同步回写;敏感凭据不入 UserDefaults)
    @Published public var deepSeekAPIKey: String {
        didSet { credentialStore.write(deepSeekAPIKey, account: Self.deepSeekAPIKeyAccount) }
    }
    /// DeepSeek 是否已配置 API Key。
    public var deepSeekConfigured: Bool { !deepSeekAPIKey.isEmpty }
    /// CredentialStore 里 DeepSeek API Key 的 account 名。
    public static let deepSeekAPIKeyAccount = KeychainAccounts.deepSeekAPIKey
    /// 当日费用账本(余额差快照,跨重启持久化)。
    public let deepSeekDailyStore: DeepSeekDailyStore

    // MARK: - 智谱 GLM Coding Plan

    /// 智谱 Coding Plan 用量(5h/周 + MCP 月度);未配置/未拉取为 nil
    @Published public var zhipuQuota: ZhipuQuota?
    /// 智谱 API Key(Keychain 存储,设置页粘贴;留空则自动发现 opencode 配置)。
    @Published public var zhipuAPIKey: String {
        didSet {
            credentialStore.write(zhipuAPIKey, account: Self.zhipuAPIKeyAccount)
            // 粘贴新 Key 且当前无账户(用户曾移除全部)→ 顺手登记首账户,免得刷新空转
            if !zhipuAPIKey.isEmpty, zhipuAccounts.isEmpty {
                zhipuAccounts = [ZhipuAccount(id: "main", label: "账户1")]
            }
        }
    }
    /// 智谱是否已配置(Keychain 手动配置 或 自动发现 opencode 的 coding-plan key)。
    public var zhipuConfigured: Bool { zhipuEffectiveAPIKey != nil || !zhipuAccounts.isEmpty }
    @Published public var zhipuError: String?
    /// 实际生效的 key:手动配置优先,其次自动发现(均空为未配置)。
    public var zhipuEffectiveAPIKey: String? {
        if !zhipuAPIKey.isEmpty { return zhipuAPIKey }
        return ZhipuUsageService.discoveredAPIKey()
    }
    /// CredentialStore 里智谱 API Key 的 account 名。
    public static let zhipuAPIKeyAccount = KeychainAccounts.zhipuAPIKey
    /// 智谱多账户(2026-10-04):账户列表;Key 按 id 分槽,main 复用旧槽+自动发现兜底
    @Published public var zhipuAccounts: [ZhipuAccount] {
        didSet { persistZhipuAccounts() }
    }
    /// 智谱单账户用量快照(模型层聚合后按账户展示/告警)
    @Published public var zhipuAccountQuotas: [ZhipuAccountSnapshot] = []
    /// 智谱逐账户错误明细
    @Published public var zhipuAccountErrors: [String: String] = [:]
    /// 智谱最近一次成功拉取时间(任一账户成功即更新)
    @Published public var zhipuLastUpdated: Date?

    // MARK: - 小米 MiMo API

    /// MiMo 余额 + Token 套餐用量(控制台 Cookie 认证);未配置/未拉取为 nil
    @Published public var mimoUsage: MiMoUsageService.MiMoUsage?
    @Published public var mimoError: String?
    @Published public var mimoLoading = false
    /// MiMo 最近一次成功拉取时间(状态行展示;失败保留旧值)
    @Published public var mimoLastUpdated: Date?
    /// MiMo 控制台两域 Cookie jar(Keychain 存储,didSet 同步回写)。
    /// platform 段供控制台 API 认证;account 段的 `passToken` 供会话静默续期。
    @Published public var mimoJar: MiMoCookieJar? {
        didSet {
            persistMiMoJar()
            // 凭据已更新:清掉鉴权退避,让下一次刷新立刻生效(用户重登后无需等冷却)
            mimoAuthFailures = 0
            mimoRetryNotBefore = nil
        }
    }
    /// 控制台 API 的 Cookie 请求头(由 jar 的 platform 段派生;保留旧版单键语义)。
    /// 赋值即按"旧版单段 Cookie"迁移(无 account 段 → 不可自动续期,但行为不劣化)。
    public var mimoCookie: String {
        get { mimoJar?.platformHeader ?? "" }
        set { mimoJar = MiMoCookieJar.legacy(newValue) }
    }
    /// 连续鉴权失败次数 + 冷却截止时刻(会话过期时不按正常间隔打无效请求)
    private var mimoAuthFailures = 0
    private var mimoRetryNotBefore: Date?
    /// 本机 CLI 用量账本(零凭据兜底;控制台拿不到时给下限与趋势)
    @Published public var mimoLocalUsage: MiMoLocalUsage?
    /// 上次**控制台成功**快照(跨重启保留;控制台不可用时展示 + 标注时间)
    @Published public var mimoLastSnapshot: MiMoLastUsage?
    private let mimoLocalStore = MiMoLocalUsageStore()
    private let mimoLastStore = MiMoLastUsageStore()
    private var mimoLocalCollectedAt: Date?
    /// MiMo 是否已配置 Cookie。
    public var mimoConfigured: Bool { !(mimoJar?.platformHeader.isEmpty ?? true) }
    /// 是否具备自动续期能力(account 段含 passToken)。
    public var mimoAutoRenewEnabled: Bool { mimoJar?.canRenew ?? false }
    /// CredentialStore 里 MiMo Cookie 的 account 名(旧版单键)。
    public static let mimoCookieAccount = KeychainAccounts.mimoCookie
    /// CredentialStore 里 MiMo Cookie jar 的 account 名。
    public static let mimoJarAccount = KeychainAccounts.mimoCookieJar

    /// 阶跃账户列表落盘(JSON;id=会话仓库标识,label=展示名)。
    private func persistStepFunAccounts() {
        guard let data = try? JSONEncoder().encode(stepfunAccounts),
              let json = String(data: data, encoding: .utf8) else { return }
        UserDefaults.standard.set(json, forKey: UserDefaultsKeys.stepfunAccounts)
    }

    private static func loadStepFunAccounts(defaults: UserDefaults) -> [StepFunAccount] {
        guard let json = defaults.string(forKey: UserDefaultsKeys.stepfunAccounts),
              let data = json.data(using: .utf8),
              let accounts = try? JSONDecoder().decode([StepFunAccount].self, from: data) else {
            return []
        }
        return accounts
    }

    /// 登录成功后登记新账户(登录窗调用;App 层同时建对应会话仓库)。
    public func addStepFunAccount(_ account: StepFunAccount) {
        guard !stepfunAccounts.contains(where: { $0.id == account.id }) else { return }
        stepfunAccounts.append(account)
        stepfunSessionActive = true
        stepfunAuthFailures[account.id] = 0
        stepfunRetryNotBefore[account.id] = nil
        stepfunLastGood[account.id] = nil
    }

    /// 移除某账户(UI 层同时调 StepFunSessionController.logout(accountID:) 清该仓库)。
    public func removeStepFunAccount(id: String) {
        stepfunAccounts.removeAll { $0.id == id }
        stepfunAccountQuotas.removeAll { $0.id == id }
        stepfunAccountErrors[id] = nil
        stepfunAuthFailures[id] = nil
        stepfunRetryNotBefore[id] = nil
        stepfunLastGood[id] = nil
        notificationTracker.clear(provider: "stepfun")
        if stepfunAccounts.isEmpty {
            stepfunSessionActive = false
            stepfunQuota = nil
            stepfunError = nil
        } else {
            Task { await refreshStepFun(force: true) }
        }
    }

    /// 同一 oasis_id 的多个会话 = 同一个阶跃账户(重复登录)。返回**重复项**的
    /// 账户 id 集合(每组保留第一个;oasis_id 为 nil 的账户不参与判定)。
    public var stepfunDuplicateAccountIDs: Set<String> {
        var seen = Set<String>()
        var duplicates = Set<String>()
        for account in stepfunAccounts {
            guard let oasis = account.oasisID, !oasis.isEmpty else { continue }
            if seen.contains(oasis) {
                duplicates.insert(account.id)
            } else {
                seen.insert(oasis)
            }
        }
        return duplicates
    }

    /// 某 oasis_id 对应的首个账户标签(重复提示「与账户N 是同一账户」用)。
    public func stepfunFirstAccountLabel(oasisID: String?) -> String? {
        guard let oasisID, !oasisID.isEmpty else { return nil }
        return stepfunAccounts.first { $0.oasisID == oasisID }?.label
    }

    /// 记录某账户的 oasis_id(登录时/首次成功拉取时识别;持久化随账户列表)。
    public func setStepFunAccountOasisID(_ accountID: String, _ oasisID: String) {
        guard let i = stepfunAccounts.firstIndex(where: { $0.id == accountID }),
              stepfunAccounts[i].oasisID != oasisID else { return }
        stepfunAccounts[i].oasisID = oasisID
    }

    /// 记录某账户的手机号尾4位(登录成功/惰性补抓时识别;持久化随账户列表)。
    public func setStepFunAccountPhoneTail(_ accountID: String, _ phoneTail: String) {
        guard let i = stepfunAccounts.firstIndex(where: { $0.id == accountID }),
              stepfunAccounts[i].phoneTail != phoneTail else { return }
        stepfunAccounts[i].phoneTail = phoneTail
    }

    /// 移除全部重复账户(同 oasis_id 只保留第一个);返回被移除的 id
    /// (调用方需同时清各自会话仓库)。
    @discardableResult
    public func removeStepFunDuplicateAccounts() -> [String] {
        let duplicates = stepfunDuplicateAccountIDs
        guard !duplicates.isEmpty else { return [] }
        for id in duplicates { removeStepFunAccount(id: id) }
        return Array(duplicates)
    }

    // MARK: - 智谱多账户(2026-10-04;API Key 按 id 分槽,main 复用旧槽+自动发现)

    /// 智谱 Key 的 Keychain 槽位:main 复用旧槽(零迁移),其余按 id 分槽。
    static func zhipuKeySlot(accountID: String) -> String {
        accountID == "main" ? KeychainAccounts.zhipuAPIKey : "\(KeychainAccounts.zhipuAPIKey)-\(accountID)"
    }

    /// 某账户生效的 Key:main = 手动优先 + opencode 自动发现兜底;其余 = 分槽手动 Key。
    public func zhipuKey(accountID: String) -> String? {
        if accountID == "main" { return zhipuEffectiveAPIKey }
        guard let k = credentialStore.read(account: Self.zhipuKeySlot(accountID: accountID)),
              !k.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return k
    }

    /// 新增智谱账户(设置/面板调用;Key 写入该账户专属 Keychain 槽)。
    public func addZhipuAccount(label: String, apiKey: String) {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        let id = UUID().uuidString
        credentialStore.write(key, account: Self.zhipuKeySlot(accountID: id))
        zhipuAccounts.append(ZhipuAccount(id: id, label: label))
        zhipuAccountErrors[id] = nil
        Task { await refreshZhipu(force: true) }
    }

    public func removeZhipuAccount(id: String) {
        zhipuAccounts.removeAll { $0.id == id }
        if id != "main" { credentialStore.delete(account: Self.zhipuKeySlot(accountID: id)) }
        zhipuAccountQuotas.removeAll { $0.id == id }
        zhipuAccountErrors[id] = nil
        notificationTracker.clear(provider: "zhipu")
        if zhipuAccounts.isEmpty {
            zhipuQuota = nil
            zhipuError = nil
        } else {
            Task { await refreshZhipu(force: true) }
        }
    }

    private func persistZhipuAccounts() {
        guard let data = try? JSONEncoder().encode(zhipuAccounts),
              let json = String(data: data, encoding: .utf8) else { return }
        UserDefaults.standard.set(json, forKey: UserDefaultsKeys.zhipuAccounts)
    }

    private static func loadZhipuAccounts(defaults: UserDefaults) -> [ZhipuAccount] {
        guard let json = defaults.string(forKey: UserDefaultsKeys.zhipuAccounts),
              let data = json.data(using: .utf8),
              let accounts = try? JSONDecoder().decode([ZhipuAccount].self, from: data) else {
            return []
        }
        return accounts
    }

    /// 某账户下一标签("账户N",N = 现有数量+1)。
    public var zhipuNextAccountLabel: String { "账户\(zhipuAccounts.count + 1)" }

    /// 智谱账户的感官区分提示:Key 尾 4 位(每把 Key 唯一,一眼对上是哪把)。
    public func zhipuAccountHint(_ accountID: String) -> String? {
        guard let key = zhipuKey(accountID: accountID), key.count > 4 else { return nil }
        return "…\(key.suffix(4))"
    }

    /// 重命名账户(didSet 持久化)。
    public func renameZhipuAccount(id: String, label: String) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = zhipuAccounts.firstIndex(where: { $0.id == id }) else { return }
        zhipuAccounts[idx].label = trimmed
    }

    // MARK: - Kimi 多账户(2026-10-04;web JWT 按 id 分槽,main 复用旧槽+本机 coding 凭证)

    /// 登录成功后登记 Kimi 账户(登录窗已把 JWT 写进该 id 的 Keychain 槽)。
    public func addKimiAccount(_ account: KimiAccount) {
        guard !kimiAccounts.contains(where: { $0.id == account.id }) else { return }
        kimiAccounts.append(account)
        kimiAccountErrors[account.id] = nil
        Task { await refreshKimi(force: true) }
    }

    public func removeKimiAccount(id: String) {
        kimiAccounts.removeAll { $0.id == id }
        KimiUsageService.clearWebToken(accountID: id)
        kimiAccountQuotas.removeAll { $0.id == id }
        kimiAccountErrors[id] = nil
        notificationTracker.clear(provider: "kimi")
        if kimiAccounts.isEmpty {
            kimiQuota = nil
            kimiError = nil
        } else {
            Task { await refreshKimi(force: true) }
        }
    }

    private func persistKimiAccounts() {
        guard let data = try? JSONEncoder().encode(kimiAccounts),
              let json = String(data: data, encoding: .utf8) else { return }
        UserDefaults.standard.set(json, forKey: UserDefaultsKeys.kimiAccounts)
    }

    private static func loadKimiAccounts(defaults: UserDefaults) -> [KimiAccount] {
        guard let json = defaults.string(forKey: UserDefaultsKeys.kimiAccounts),
              let data = json.data(using: .utf8),
              let accounts = try? JSONDecoder().decode([KimiAccount].self, from: data) else {
            return []
        }
        return accounts
    }

    /// 某账户下一标签("账户N",N = 现有数量+1)。
    public var kimiNextAccountLabel: String { "账户\(kimiAccounts.count + 1)" }

    /// Kimi 账户的感官区分提示:登录态 JWT 里的用户标识尾 6 位
    /// (web JWT 的 sub;main 无网页登录时回退本机 coding token 的 user_id)。
    public func kimiAccountHint(_ accountID: String) -> String? {
        guard let sub = KimiUsageService.accountSubject(accountID: accountID), sub.count > 6 else { return nil }
        return "…\(sub.suffix(6))"
    }

    /// 重命名账户(didSet 持久化)。
    public func renameKimiAccount(id: String, label: String) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = kimiAccounts.firstIndex(where: { $0.id == id }) else { return }
        kimiAccounts[idx].label = trimmed
    }

    // MARK: - OpenCode Go 多 workspace(2026-10-17;一份登录 cookie,按 workspace 分流抓取)

    /// 登录成功后并入发现的 workspace(已存在的保留原 label=用户重命名)。
    /// 返回新加入的条目数(UI 提示用)。
    @discardableResult
    public func mergeOpenCodeWorkspaces(_ discovered: [OpenCodeUsageService.OpenCodeWorkspaceInfo]) -> Int {
        var added = 0
        for info in discovered where !openCodeWorkspaces.contains(where: { $0.id == info.id }) {
            openCodeWorkspaces.append(OpenCodeWorkspace(id: info.id, label: info.name))
            openCodeWorkspaceErrors[info.id] = nil
            added += 1
        }
        return added
    }

    /// 登录后拉取全部 workspace 列表并并入(console API;端点失效时返回 0,
    /// 用户可在卡片手动添加 wrk_xxx)。返回并入的条目数。
    @discardableResult
    public func discoverOpenCodeWorkspaces() async -> Int {
        ensureCredentialLoaded()
        guard !openCodeCookie.isEmpty else { return 0 }
        let infos = await OpenCodeUsageService.listWorkspaces(cookie: openCodeCookie)
        guard !infos.isEmpty else { return 0 }
        let added = mergeOpenCodeWorkspaces(infos)
        if !openCodeWorkspaces.isEmpty {
            await refreshOpenCode(force: true)
        }
        return added
    }

    /// 手动添加 workspace(列表端点失效时;用户从浏览器 URL 复制 wrk_xxx)。
    public func addOpenCodeWorkspace(id: String, label: String?) {
        let wsID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wsID.isEmpty, !openCodeWorkspaces.contains(where: { $0.id == wsID }) else { return }
        let trimmedLabel = (label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        openCodeWorkspaces.append(OpenCodeWorkspace(id: wsID,
                                                    label: trimmedLabel.isEmpty ? "Workspace \(openCodeWorkspaces.count + 1)" : trimmedLabel))
        openCodeWorkspaceErrors[wsID] = nil
        Task { await refreshOpenCode(force: true) }
    }

    public func removeOpenCodeWorkspace(id: String) {
        openCodeWorkspaces.removeAll { $0.id == id }
        openCodeWorkspaceQuotas.removeAll { $0.id == id }
        openCodeWorkspaceErrors[id] = nil
        notificationTracker.clear(provider: "opencode")
        if openCodeWorkspaces.isEmpty {
            openCodeQuota = nil
            openCodeError = nil
        } else {
            Task { await refreshOpenCode(force: true) }
        }
    }

    private func persistOpenCodeWorkspaces() {
        guard let data = try? JSONEncoder().encode(openCodeWorkspaces),
              let json = String(data: data, encoding: .utf8) else { return }
        UserDefaults.standard.set(json, forKey: UserDefaultsKeys.openCodeWorkspaces)
    }

    private static func loadOpenCodeWorkspaces(defaults: UserDefaults) -> [OpenCodeWorkspace] {
        guard let json = defaults.string(forKey: UserDefaultsKeys.openCodeWorkspaces),
              let data = json.data(using: .utf8),
              let workspaces = try? JSONDecoder().decode([OpenCodeWorkspace].self, from: data) else {
            return []
        }
        return workspaces
    }

    /// 重命名 workspace(didSet 持久化)。
    public func renameOpenCodeWorkspace(id: String, label: String) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = openCodeWorkspaces.firstIndex(where: { $0.id == id }) else { return }
        openCodeWorkspaces[idx].label = trimmed
    }

    /// jar 落盘:新键存 JSON;旧键同步 platform 段(回滚到旧版本时凭据仍可用)。
    /// ⚠️ 凭据加载完成前一律不落盘——init 里的清空赋值会经 didSet 走到这里,
    /// 若此时写盘就会把刚从 Keychain 读出的凭据抹掉。
    private func persistMiMoJar() {
        guard mimoCredentialsLoaded else { return }
        guard let jar = mimoJar else {
            credentialStore.delete(account: Self.mimoJarAccount)
            credentialStore.delete(account: Self.mimoCookieAccount)
            return
        }
        credentialStore.write(jar.jsonString() ?? "", account: Self.mimoJarAccount)
        credentialStore.write(jar.platformHeader, account: Self.mimoCookieAccount)
    }

    // MARK: - MiniMax Coding Plan

    /// MiniMax Coding Plan 用量(当前窗口 + 周);未配置/未拉取为 nil
    @Published public var minimaxQuota: MiniMaxQuota?
    /// MiniMax Coding Plan API Key(Keychain 存储,设置页粘贴)
    @Published public var minimaxAPIKey: String {
        didSet { credentialStore.write(minimaxAPIKey, account: Self.minimaxAPIKeyAccount) }
    }
    /// MiniMax 是否已配置 API Key。
    public var minimaxConfigured: Bool { !minimaxAPIKey.isEmpty }
    @Published public var minimaxError: String?
    /// CredentialStore 里 MiniMax API Key 的 account 名。
    public static let minimaxAPIKeyAccount = KeychainAccounts.minimaxAPIKey

    // MARK: - Ollama Cloud

    /// Ollama Cloud 用量(近 30 天消费 vs 套餐月额度);未配置/未拉取为 nil
    @Published public var ollamaQuota: OllamaQuota?
    /// Ollama Cloud API Key(Keychain 存储,设置页粘贴)
    @Published public var ollamaAPIKey: String {
        didSet { credentialStore.write(ollamaAPIKey, account: Self.ollamaAPIKeyAccount) }
    }
    /// Ollama 是否已配置 API Key。
    public var ollamaConfigured: Bool { !ollamaAPIKey.isEmpty }
    @Published public var ollamaError: String?
    /// CredentialStore 里 Ollama API Key 的 account 名。
    public static let ollamaAPIKeyAccount = KeychainAccounts.ollamaAPIKey

    // MARK: - 阶跃 StepFun Step Plan(多账户)

    /// 阶跃 Step Plan 用量(**全部账户聚合**;菜单栏/摘要/快照口径);未配置/未拉取为 nil
    @Published public var stepfunQuota: StepFunQuota?
    /// 按账户的用量快照(面板分段展示;本轮失败的账户保留 last-good 旧值并标 isStale)
    @Published public var stepfunAccountQuotas: [StepFunAccountSnapshot] = []
    /// 按账户的最后错误(面板分段展示;键=账户 id,值=错误文案)
    @Published public var stepfunAccountErrors: [String: String] = [:]
    /// 已登录账户列表(UserDefaults 持久化;id = 会话仓库标识,首账户 "main" 沿用默认仓库)
    @Published public var stepfunAccounts: [StepFunAccount] {
        didSet { persistStepFunAccounts() }
    }
    @Published public var stepfunError: String?
    @Published public var stepfunLoading = false
    /// 最近一次成功拉取时间(状态行展示;失败保留旧值)
    @Published public var stepfunLastUpdated: Date?
    /// 控制台登录态遗留粘贴通道(Keychain;主通道是常驻 WebView 会话,粘贴 token
    /// 会被平台滚动轮换作废,仅作 v1.0.60 前的兼容回退)。
    @Published public var stepfunConsoleToken: String {
        didSet {
            guard stepfunCredentialsLoaded else { return }
            credentialStore.write(stepfunConsoleToken, account: Self.stepfunConsoleTokenAccount)
            stepfunAuthFailures.removeAll()
            stepfunRetryNotBefore.removeAll()
        }
    }
    /// 阶跃是否已配置(任一账户已登录,或遗留 token 非空)。
    public var stepfunConfigured: Bool { !stepfunAccounts.isEmpty || !stepfunConsoleToken.isEmpty }
    /// 兼容标记:任一账户有会话即 true(仅作状态展示;真值在账户列表——
    /// 冷启动预热不再看它,防止一次全员失败把整个数据源冻住)。
    @Published public var stepfunSessionActive: Bool = false {
        didSet {
            guard stepfunSessionActive != oldValue else { return }
            UserDefaults.standard.set(stepfunSessionActive, forKey: UserDefaultsKeys.stepfunSessionActive)
        }
    }
    /// 阶跃额度拉取通道:App 层注入(参数=账户 id,返回该账户会话页的三态结果)。
    /// 无通道且有存量 token 时退回 URLSession 直连(遗留粘贴通道)。
    public var stepfunConsoleFetchSink: ((String) async -> StepFunUsageService.StepFunFetchOutcome)?
    /// 阶跃会话重载通道:App 层注入(参数=账户 id)。鉴权失败自愈用——
    /// 强制重载会话页,让 SPA 用 30 天 refresh token 换发新 access token
    /// (Oasis-Token 的 access 段只有 30 分钟 TTL,与 30 分钟刷新周期同频竞态)。
    public var stepfunSessionReload: ((String) async -> Void)?
    /// 阶跃账户身份通道:App 层注入(参数=账户 id,返回该账户会话的 oasis_id;
    /// nil=读不到)。仅对尚未识别身份的账户调用一次(去重/防重复登录用)。
    public var stepfunIdentitySink: ((String) async -> String?)?
    /// 阶跃账户手机号通道:App 层注入(参数=账户 id,返回该账户绑定的手机号尾4位;
    /// nil=读不到/未绑手机)。登录成功后抓一次 + 惰性补抓(见 refreshStepFun),
    /// 供面板身份展示(优先于 oasis_id 尾4位)。
    public var stepfunPhoneSink: ((String) async -> String?)?
    /// 平台 web_id(登录窗抓取;SPA 的 Oasis-Webid 请求头同源,非敏感)。
    @Published public var stepfunWebId: String {
        didSet { UserDefaults.standard.set(stepfunWebId, forKey: UserDefaultsKeys.stepfunWebId) }
    }
    /// CredentialStore 里阶跃控制台登录态的 account 名。
    public static let stepfunConsoleTokenAccount = KeychainAccounts.stepfunConsoleToken
    /// 每账户独立鉴权失败计数 + 冷却截止(键=账户 id;单账户过期不连坐其他账户)
    private var stepfunAuthFailures: [String: Int] = [:]
    private var stepfunRetryNotBefore: [String: Date] = [:]
    /// 每账户 last-good 快照(本轮失败时保留展示旧值,标 isStale;进程内有效)
    private var stepfunLastGood: [String: StepFunAccountSnapshot] = [:]
    /// 手机号尾号补抓次数(键=账户 id;**进程内**有效,不持久化):
    /// 每账户每次启动最多试 3 次——覆盖启动初期会话页未就绪的竞态,
    /// 又避免会话真死时每轮刷新都白打一次账户中心 RPC。
    private var stepfunPhoneAttempts: [String: Int] = [:]
    private var stepfunCredentialsLoaded = false

    /// 刷新间隔(分钟),用户可在设置改;默认 10。只影响 usage(高频)。
    @Published public var refreshIntervalMinutes: Int = 10 {
        didSet { UserDefaults.standard.set(refreshIntervalMinutes, forKey: UserDefaultsKeys.refreshIntervalMinutes); resetTimer() }
    }

    // MARK: - 阈值 / 通知 / 历史(P0-P1)

    /// 告警阈值(默认 warning 80 / critical 90),用户可在设置改。
    @Published public var thresholdConfig: ThresholdConfig = ThresholdConfig() {
        didSet { UserDefaults.standard.set(thresholdConfig.warning, forKey: UserDefaultsKeys.thresholdWarning)
                 UserDefaults.standard.set(thresholdConfig.critical, forKey: UserDefaultsKeys.thresholdCritical) }
    }
    /// 是否启用接近上限通知(默认开)。用户可在设置关。
    @Published public var notificationsEnabled: Bool = true {
        didSet { UserDefaults.standard.set(notificationsEnabled, forKey: UserDefaultsKeys.notificationsEnabled) }
    }
    /// 面板 sparkline 是否显示(默认开)。
    @Published public var sparklineEnabled: Bool = true {
        didSet { UserDefaults.standard.set(sparklineEnabled, forKey: UserDefaultsKeys.sparklineEnabled) }
    }
    /// 每日用量摘要通知(P2-B7,默认关)。开启后每天 20:00 汇总全部 Provider 用量。
    @Published public var dailyDigestEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(dailyDigestEnabled, forKey: UserDefaultsKeys.dailyDigestEnabled)
            scheduleDailyDigest()
        }
    }
    // MARK: - 数据源显示开关(全面停用语义)

    /// 已停用的数据源(ProviderKind.rawValue 集合)。停用 = 菜单栏不出列、
    /// 面板不出 tab、停止轮询刷新、不参与告警与每日摘要。
    @Published public private(set) var disabledProviders: Set<String> = []

    /// 某数据源是否启用(未停用)。
    public func isEnabled(_ kind: ProviderKind) -> Bool {
        !disabledProviders.contains(kind.rawValue)
    }

    /// 启停某数据源。写库后:本机采样联动 systemStatsEnabled 代理
    /// (AppDelegate 订阅它启停 SystemMetricsMonitor),并立即重渲染菜单栏图标。
    public func setEnabled(_ kind: ProviderKind, _ enabled: Bool) {
        if enabled {
            disabledProviders.remove(kind.rawValue)
        } else {
            disabledProviders.insert(kind.rawValue)
        }
        UserDefaults.standard.set(Array(disabledProviders).sorted(), forKey: UserDefaultsKeys.disabledProviders)
        if kind == .system {
            systemStatsEnabled = enabled   // didSet 同步兼容键,触发采样启停订阅
        }
        prerenderIcon()
        if enabled {
            // 重新启用立即拉一次数据(否则要等下一个 timer tick 才出列)
            Task { await refresh(provider: kind) }
        }
    }

    /// 某数据源是否已配置凭据(阿里云 = bl 登录态、本机 = 无凭据概念,均恒 true)。
    public func isConfigured(_ kind: ProviderKind) -> Bool {
        switch kind {
        case .aliyun, .system: return true
        case .openCode: return openCodeConfigured
        case .kimi: return kimiConfigured
        case .deepSeek: return deepSeekConfigured
        case .zhipu: return zhipuConfigured
        case .mimo: return mimoConfigured
        case .minimax: return minimaxConfigured
        case .ollama: return ollamaConfigured
        case .stepfun: return stepfunConfigured
        }
    }

    /// 菜单栏是否显示本机 CPU/内存(默认开)。
    /// 兼容代理:真值在 disabledProviders("system" 条目),didSet 同步写旧键,
    /// 保持 AppDelegate 的 `$systemStatsEnabled` 订阅链路不变。
    @Published public var systemStatsEnabled: Bool = true {
        didSet {
            guard systemStatsEnabled != oldValue else { return }
            UserDefaults.standard.set(systemStatsEnabled, forKey: UserDefaultsKeys.systemStatsEnabled)
            if systemStatsEnabled {
                disabledProviders.remove(ProviderKind.system.rawValue)
            } else {
                disabledProviders.insert(ProviderKind.system.rawValue)
            }
            UserDefaults.standard.set(Array(disabledProviders).sorted(), forKey: UserDefaultsKeys.disabledProviders)
        }
    }
    /// 重新登录轮询是否在跑(面板显示"等待浏览器登录完成…")。
    @Published public var isReloginWatching = false
    /// Keychain 中是否已保存阿里云 OpenAPI AK/SK。
    @Published public var aliyunAKSKConfigured = false
    /// 正在通过 AK/SK 自动配置 bl（面板显示 loading）。
    @Published public var aliyunAKSKConfiguring = false
    /// 当前进程使用的短期 bl 配置；释放时自动删除临时目录。
    private var aliyunEphemeralConfig: BlEphemeralConfig?
    /// 上次自动恢复失败时间；nil = 从未失败或已成功重置。
    @Published public var aliyunAutoRecoveryFailedAt: Date?
    /// 连续自动恢复失败次数(P1-C11:连续 ≥2 次后暂停弹浏览器,防骚扰)。
    private var aliyunAutoRecoveryFailures = 0
    /// 检查更新结果(P1-C1:GitHub Releases 最新版本;有新版时 UI 提示跳转下载)。
    @Published public var appUpdate: ReleaseInfo?
    /// 信息类通知 sink(标题,正文):非用量告警的温和提醒(自动恢复暂停等)。
    /// 由 executable 层注入 NotificationManager;默认 no-op。
    public var infoNotifySink: ((String, String) -> Void)?

    // MARK: - 自动化调度状态(P1:C2/C3/C4/C6/C7)
    private var wakeObserver: NSObjectProtocol?
    private var networkMonitor: NWPathMonitor?
    private var networkSatisfied = true
    /// 是否离线(UI 展示"离线"提示;UI/UX 打磨)
    @Published public var isOffline = false
    private var resetBoundaryTask: Task<Void, Never>?
    private var consecutiveFailures = 0
    private var currentIntervalMinutes = 0
    /// 上次自动刷新完成时刻 + 最小间隔(P1 热修复第二道防线:定时/唤醒/网络/重置边界
    /// 等自动路径 30s 内只放行一次,任何调度回环都无法把服务端打爆)。
    private var lastAutoRefreshAt: Date = .distantPast
    private let minAutoRefreshSpacing: TimeInterval = 30

    /// 冷却窗口：刷新间隔的 2 倍，确保至少跳过一个 timer tick（最小 10 分钟）。
    private var autoRecoveryCooldownMinutes: Int {
        max(refreshIntervalMinutes * 2, 10)
    }
    /// 多窗口通知状态机(纯值,内部维护)。
    public private(set) var notificationTracker = NotificationTracker()

    /// 历史仓库(默认文件落盘;测试/预览可注入内存实现)。
    public let historyStore: HistoryStore

    /// 通知触发闭包:逻辑层评估出应通知的窗口时回调,executable 层注入真正的 UNUserNotificationCenter。
    /// 默认 no-op(逻辑层零副作用),避免 Core 依赖 UserNotifications 框架。
    public var notifySink: ((WatchKey, UsageBand) -> Void)?

    /// 凭据存储(默认 Keychain;测试可注入内存实现)。
    public let credentialStore: CredentialStore

    /// CredentialStore 里 OpenCode cookie 的 account 名(兼容旧引用,实际值见 KeychainAccounts)。
    public static let openCodeCookieAccount = KeychainAccounts.openCodeCookie

    /// CredentialStore 里阿里云 OpenAPI AK/SK 的 account 名（JSON: {"accessKeyId":"...","accessKeySecret":"..."}）。
    public static let aliyunAKSKAccount = KeychainAccounts.aliyunAKSK

    /// 菜单栏图标预渲染缓存(数据更新时生成,label 只读)。
    @Published public var renderedIcon: NSImage?
    /// 最近一次预渲染的菜单栏 tooltip(与 renderedIcon 同批更新)。
    @Published public var menuBarTooltip: String?
    /// 渲染图标的闭包:由 executable 层注入(因 MenuBarTextRenderer 在 executable 层)。
    public var renderIconSink: ((TokenPlanModel) -> NSImage?)?
    /// 菜单栏 tooltip 渲染闭包(App 目标注入,与 renderIconSink 同批)。
    public var renderTooltipSink: ((TokenPlanModel) -> String?)?

    private var timer: AnyCancellable?

    /// 辅助数据(subscription/addon)上次拉取时间。这俩一天内基本不变,24h 拉一次即可,
    /// 避免每轮刷新都 spawn 3 个 node 进程(降 2/3 开销)。
    private var lastAuxFetch: Date?
    private let auxRefreshInterval: TimeInterval = 24 * 60 * 60  // 24 小时

    /// Keychain 是否已加载(延迟到首次访问,避免启动时序问题)
    private var credentialLoaded = false
    /// MiMo jar 是否已从 Keychain 载入(载入前禁止落盘,防 init 清空赋值误删凭据)
    private var mimoCredentialsLoaded = false

    private init() {
        let defaults = UserDefaults.standard
        refreshIntervalMinutes = defaults.object(forKey: UserDefaultsKeys.refreshIntervalMinutes) as? Int ?? 10

        // 阈值/通知/sparkline 配置
        let w = defaults.object(forKey: UserDefaultsKeys.thresholdWarning) as? Int ?? 80
        let c = defaults.object(forKey: UserDefaultsKeys.thresholdCritical) as? Int ?? 90
        thresholdConfig = ThresholdConfig(warning: w, critical: c)
        if defaults.object(forKey: UserDefaultsKeys.notificationsEnabled) != nil {
            notificationsEnabled = defaults.bool(forKey: UserDefaultsKeys.notificationsEnabled)
        }
        if defaults.object(forKey: UserDefaultsKeys.sparklineEnabled) != nil {
            sparklineEnabled = defaults.bool(forKey: UserDefaultsKeys.sparklineEnabled)
        }
        // 数据源停用集合 + 一次性迁移(旧 systemStatsEnabled=false → "system" 进停用集;纯函数见 ProviderVisibilityMigration)
        let disabled = ProviderVisibilityMigration.initialDisabledSet(
            existing: defaults.stringArray(forKey: UserDefaultsKeys.disabledProviders),
            legacySystemStatsEnabled: defaults.object(forKey: UserDefaultsKeys.systemStatsEnabled) != nil
                ? defaults.bool(forKey: UserDefaultsKeys.systemStatsEnabled) : nil)
        if defaults.object(forKey: UserDefaultsKeys.disabledProviders) == nil {
            defaults.set(Array(disabled).sorted(), forKey: UserDefaultsKeys.disabledProviders)
        }
        disabledProviders = disabled
        systemStatsEnabled = !disabled.contains(ProviderKind.system.rawValue)
        if defaults.object(forKey: UserDefaultsKeys.dailyDigestEnabled) != nil {
            dailyDigestEnabled = defaults.bool(forKey: UserDefaultsKeys.dailyDigestEnabled)
        }

        credentialStore = AppFileCredentialStore.shared
        openCodeCookie = ""   // 延迟到 ensureCredentialLoaded() 读取
        deepSeekAPIKey = ""   // 延迟到 ensureCredentialLoaded() 读取
        zhipuAPIKey = ""      // 延迟到 ensureCredentialLoaded() 读取
        // mimoJar 默认 nil,延迟到 ensureCredentialLoaded() 读取(不在此处赋值:
        // 计算属性 setter 需要 self 完全初始化,且会经 didSet 触发落盘)
        minimaxAPIKey = ""    // 延迟到 ensureCredentialLoaded() 读取
        ollamaAPIKey = ""     // 延迟到 ensureCredentialLoaded() 读取
        stepfunConsoleToken = ""   // 延迟到 ensureCredentialLoaded() 读取
        stepfunWebId = defaults.string(forKey: UserDefaultsKeys.stepfunWebId) ?? ""
        if defaults.object(forKey: UserDefaultsKeys.stepfunSessionActive) != nil {
            stepfunSessionActive = defaults.bool(forKey: UserDefaultsKeys.stepfunSessionActive)
        }
        // 账户列表(迁移在 init 末尾做——需要 self 完全初始化)
        stepfunAccounts = Self.loadStepFunAccounts(defaults: defaults)
        zhipuAccounts = Self.loadZhipuAccounts(defaults: defaults)
        kimiAccounts = Self.loadKimiAccounts(defaults: defaults)
        openCodeWorkspaces = Self.loadOpenCodeWorkspaces(defaults: defaults)
        historyStore = HistoryStore(backend: FileHistoryBackend(url: HistoryStore.defaultURL()))
        deepSeekDailyStore = DeepSeekDailyStore()

        // 一次性迁移:v1.0.60–63 的单会话(默认仓库)→ 首账户 "main"(沿用默认仓库,零 Cookie 迁移)
        if stepfunAccounts.isEmpty, stepfunSessionActive {
            stepfunAccounts = [StepFunAccount(id: "main", label: "账户1")]
            persistStepFunAccounts()
        }
        // 一次性迁移:v1.0.66 前的单 Key/单登录 → 首账户 "main"(各自复用旧槽,零迁移)
        // ⚠️ 智谱 Key 是延迟加载的,key-based 迁移放在 ensureCredentialLoaded() 末尾
        // ⚠️ 列表键存在(哪怕为空数组)即视为已迁移——否则用户移除全部账户后,
        // 下次启动会因本机凭据仍在把 main 复活。
        if kimiAccounts.isEmpty, defaults.object(forKey: UserDefaultsKeys.kimiAccounts) == nil,
           KimiUsageService.tokenExists() || KimiUsageService.loadWebToken() != nil {
            kimiAccounts = [KimiAccount(id: "main", label: "账户1")]
            persistKimiAccounts()
        }
    }

    /// 延迟加载 Keychain 中的 cookie(避免启动时序问题)。幂等。
    public func ensureCredentialLoaded() {
        guard !credentialLoaded else { return }
        credentialLoaded = true
        CredentialMigration.migrate(legacyKey: "openCodeCookie",
                                    account: Self.openCodeCookieAccount, to: credentialStore)
        openCodeCookie = credentialStore.read(account: Self.openCodeCookieAccount) ?? ""
        // 多 workspace 一次性迁移(2026-10-17):旧单 cookie + 旧 workspace ID 键
        // → 首个受监控 workspace(cookie 复用旧 Keychain 槽,零迁移)。
        // ⚠️ 列表键存在(哪怕空数组)即视为已迁移——否则用户移除全部 workspace 后,
        // 下次启动会因 cookie 仍在把旧 workspace 复活。
        if openCodeWorkspaces.isEmpty,
           UserDefaults.standard.object(forKey: UserDefaultsKeys.openCodeWorkspaces) == nil,
           !openCodeCookie.isEmpty {
            let legacyWS = UserDefaults.standard.string(forKey: UserDefaultsKeys.openCodeWorkspaceID) ?? ""
            if !legacyWS.isEmpty {
                openCodeWorkspaces = [OpenCodeWorkspace(id: legacyWS, label: "默认 workspace")]
                persistOpenCodeWorkspaces()
            }
        }
        deepSeekAPIKey = credentialStore.read(account: Self.deepSeekAPIKeyAccount) ?? ""
        zhipuAPIKey = credentialStore.read(account: Self.zhipuAPIKeyAccount) ?? ""
        // jar 优先(含 account 段 passToken);旧版单键作为兼容回退
        if let raw = credentialStore.read(account: Self.mimoJarAccount), let jar = MiMoCookieJar.decode(raw) {
            mimoJar = jar
        } else if let legacy = credentialStore.read(account: Self.mimoCookieAccount) {
            mimoJar = MiMoCookieJar.legacy(legacy)
        }
        mimoCredentialsLoaded = true
        minimaxAPIKey = credentialStore.read(account: Self.minimaxAPIKeyAccount) ?? ""
        ollamaAPIKey = credentialStore.read(account: Self.ollamaAPIKeyAccount) ?? ""
        stepfunConsoleToken = credentialStore.read(account: Self.stepfunConsoleTokenAccount) ?? ""
        stepfunCredentialsLoaded = true
        // 多账户一次性迁移(2026-10-04):智谱单 Key(手动或自动发现)→ 首账户 "main"。
        // ⚠️ 列表键存在(哪怕空数组)即视为已迁移,防止移除全部账户后被复活。
        if zhipuAccounts.isEmpty,
           UserDefaults.standard.object(forKey: UserDefaultsKeys.zhipuAccounts) == nil,
           zhipuEffectiveAPIKey != nil {
            zhipuAccounts = [ZhipuAccount(id: "main", label: "账户1")]
            persistZhipuAccounts()
        }
    }

    /// 启动定时刷新
    public func startTimer() {
        startSystemObservers()                                  // 唤醒/网络(P1-C2/C3)
        BlEphemeralConfig.sweepStaleTempDirectories()            // P1-C8 崩溃泄漏清扫
        scheduleDailyDigest()                                    // P2-B7
        resetTimer()
        ensureCredentialLoaded()
        Task { await checkAuthAndRefresh() }
        Task { await checkBlVersion() }
        Task { await checkAppUpdate() }                          // P1-C1
        Task { await recoverOpenCodeIfNeeded(); await refreshOpenCode() }
        Task { await refreshKimi() }
        Task { await refreshDeepSeek() }
        Task { await refreshZhipu() }
        Task { await refreshMiMo() }
        loadMiMoLocalSide()                                      // P2:跨重启快照
        Task { await collectMiMoLocal(force: true) }             // P2:本机口径账本
        Task { await refreshMiniMax() }
        Task { await refreshOllama() }
        Task { await refreshStepFun() }
        if loadAliyunAKSK() != nil {
            aliyunAKSKConfigured = true
        }
    }

    // MARK: - 自动化调度(P1:C2/C3/C4/C6/C7)

    /// 睡眠唤醒 + 网络恢复的即时刷新(事件驱动,不等下一个 tick)。
    private func startSystemObservers() {
        // C2:系统唤醒 → 立即刷新(合盖期间数据已陈旧)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            AppLog.info("系统唤醒,立即刷新", category: .general)
            Task { await self?.refreshAll() }
        }
        // C3:网络恢复 → 立即刷新;断网时跳过定时刷新(避免每 tick 空转报错)
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                guard satisfied != self.networkSatisfied else { return }
                self.networkSatisfied = satisfied
                self.isOffline = !satisfied
                if satisfied {
                    AppLog.info("网络恢复,立即刷新", category: .general)
                    self.consecutiveFailures = 0
                    await self.refreshAll()
                } else {
                    AppLog.warning("网络断开,暂停定时刷新", category: .general)
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.zww.aliyuntokenbar.network"))
        networkMonitor = monitor
    }

    /// C6:按下次用量重置时刻排一次精确刷新(重置后 10s 捕捉归零)。
    /// 每次成功刷新后重排;窗口不返回重置时间时不排。
    ///
    /// ⚠️ 热修复(2026-08-13 用户反馈"一直 loading/不断刷新"):睡眠被下一次调度
    /// cancel 后,`try? await Task.sleep` 吞掉 CancellationError 会**继续往下走**,
    /// 于是「取消→立即刷新→成功→重新调度→再取消」形成每秒一次的自我维持热循环,
    /// 把服务端打爆且 isLoading 恒真。修复:取消即退出,绝不因取消而触发刷新。
    private func scheduleResetBoundaryRefresh() {
        resetBoundaryTask?.cancel()
        guard let q = quota else { return }
        let now = Date()
        // 三窗口(5h/周/月)全量收集:存在的窗口才参与边界调度(月窗重置=订阅月起点)
        let candidates: [Int64] = q.usage.activeWindows.compactMap { $0.detail.resetTimeMs > 0 ? $0.detail.resetTimeMs : nil }
        let upcoming = candidates.compactMap { ms -> Int64? in
            guard ms > 0 else { return nil }
            let t = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
            return t > now ? ms : nil
        }
        guard let nextMs = upcoming.min() else { return }
        let fireAt = TimeInterval(nextMs) / 1000 + 10
        resetBoundaryTask = Task { [weak self] in
            let delay = fireAt - Date().timeIntervalSince1970
            guard delay > 0 else { return }
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return   // 被新调度取消:静默退出,绝不触发刷新(热循环根因)
            }
            guard !Task.isCancelled else { return }
            AppLog.info("到达用量重置边界,立即刷新", category: .aliyun)
            await self?.refreshAll()
        }
    }

    /// C4+C7:实际刷新间隔 = 基础间隔(低电量 ×2)× 2^连续失败次数,上限 120 分钟。
    private func effectiveIntervalMinutes() -> Int {
        var minutes = refreshIntervalMinutes
        if ProcessInfo.processInfo.isLowPowerModeEnabled { minutes *= 2 }
        let backoff = min(consecutiveFailures, 3)   // 最多 ×8
        return min(max(minutes << backoff, 1), 120)
    }

    /// 失败计数变化后,若有效间隔与当前定时器不一致则重排。
    private func rescheduleIfNeeded() {
        let effective = effectiveIntervalMinutes()
        guard effective != currentIntervalMinutes else { return }
        resetTimer()
    }

    /// 一次拉齐全部**已启用** Provider(定时器 tick / 唤醒 / 网络恢复共用)。
    /// registry 驱动:新增数据源只需在 refresh(provider:) 补一个 case,此处零改动。
    public func refreshAll() async {
        for kind in ProviderKind.allCases where isEnabled(kind) {
            await refresh(provider: kind)
        }
    }

    /// 单 provider 刷新调度表(system 无网络刷新,本机采样由开关启停)。
    /// Verify 断言此表覆盖全部 ProviderKind,防"漏数"。
    public func refresh(provider kind: ProviderKind) async {
        switch kind {
        case .aliyun: await refreshAliyun()
        case .openCode: await refreshOpenCode()
        case .kimi: await refreshKimi()
        case .deepSeek: await refreshDeepSeek()
        case .zhipu: await refreshZhipu()
        case .mimo: await refreshMiMo()
        case .minimax: await refreshMiniMax()
        case .ollama: await refreshOllama()
        case .stepfun: await refreshStepFun()
        case .system: break
        }
    }

    /// 阿里云自动路径刷新(走 refresh() 的 30s 节流);停用时空转。
    public func refreshAliyun() async {
        guard isEnabled(.aliyun) else { return }
        await refresh()
    }

    /// P1-C1:查 GitHub Releases 最新版本(启动一次 + 手动)。
    public func checkAppUpdate() async {
        guard let info = await SelfUpdater.fetchLatest() else { return }
        if SelfUpdater.isNewer(info.version, than: SelfUpdater.currentVersion()) {
            appUpdate = info
            AppLog.info("发现新版本 \(info.version)(当前 \(SelfUpdater.currentVersion()))", category: .general)
        }
    }

    /// 打开更新下载页(菜单栏/设置页按钮)。
    public func openUpdatePage() {
        let url = appUpdate?.url ?? SelfUpdater.releasesPageURL
        NSWorkspace.shared.open(url)
    }

    /// 自愈:已登录但没有受监控 workspace(旧版登录失败遗留/迁移时 workspace 缺失)
    /// → 拉取 workspace 列表并入(端点失效时回落到 /auth 发现的默认 workspace)。
    private func recoverOpenCodeIfNeeded() async {
        ensureCredentialLoaded()
        guard !openCodeCookie.isEmpty, openCodeWorkspaces.isEmpty else { return }
        await discoverOpenCodeWorkspaces()
    }

    /// 拉取 OpenCode Go 用量(2026-10-17 多 workspace:逐 workspace 用同一 cookie
    /// 抓取 → 聚合 → 面板/告警用聚合值)。单 workspace 时等价于旧路径。
    /// ⚠️ 不在这里补 workspace:cookie 仍在,补了会把用户刚移除的条目复活。
    public func refreshOpenCode(force: Bool = false) async {
        ensureCredentialLoaded()
        guard isEnabled(.openCode), !openCodeCookie.isEmpty, !openCodeWorkspaces.isEmpty else { return }

        var snapshots: [OpenCodeWorkspaceSnapshot] = []
        var errors: [String: String] = [:]
        var anySucceeded = false
        for ws in openCodeWorkspaces {
            let result = await OpenCodeUsageService.fetchQuota(cookie: openCodeCookie, workspaceID: ws.id)
            switch result {
            case .success(let q):
                anySucceeded = true
                snapshots.append(OpenCodeWorkspaceSnapshot(id: ws.id, label: ws.label, quota: q))
            case .failure(let e):
                errors[ws.id] = openCodeErrorMessage(e)
            }
        }

        if anySucceeded {
            openCodeQuota = OpenCodeQuota.aggregate(snapshots.map(\.quota))
            openCodeError = nil
            openCodeLastUpdated = Date()
            openCodeWorkspaceQuotas = snapshots
            AppLog.debug("OpenCode 用量刷新成功 \(snapshots.count) workspace rolling=\(openCodeQuota.map { "\($0.rolling.pct)%" } ?? "无") weekly=\(openCodeQuota.map { "\($0.weekly.pct)%" } ?? "无")", category: .opencode)
            recordAndNotify()
        } else {
            openCodeError = errors.values.first ?? "OpenCode 刷新失败"
        }
        openCodeWorkspaceErrors = errors
    }

    /// OpenCode 错误文案(与旧单账户口径一致的用户可读描述)。
    private func openCodeErrorMessage(_ e: UsageError) -> String {
        switch e {
        case .authExpired: return "OpenCode 登录已过期,请重新登录账户"
        case .network(let s): return "OpenCode 网络错误: \(s)"
        case .parse: return "无 Go 用量数据(未订阅或页面改版)"
        case .invalidResponse: return "OpenCode 响应异常"
        case .unknown(let s): return s
        }
    }

    // MARK: - Kimi Code

    /// 拉取 Kimi Code 套餐用量(读本机 KimiCodeBar/Kimi CLI 凭证 + web 控制台登录)。
    /// 凭证不存在时静默跳过(设置页有引导)。
    /// 刷新 Kimi 用量(2026-10-04 多账户:main=本机凭证/legacy web 槽,其余=各自 web JWT 槽)。
    public func refreshKimi(force: Bool = false) async {
        guard isEnabled(.kimi), kimiConfigured else { return }
        // 无账户(用户移除全部)→ 不拉取;卡片显示登录引导。
        // ⚠️ 不在这里补 main:本机凭证文件仍在,补了会把用户刚移除的账户复活。
        guard !kimiAccounts.isEmpty else { return }

        var snapshots: [KimiAccountSnapshot] = []
        var errors: [String: String] = [:]
        var anySucceeded = false
        for account in kimiAccounts {
            let result = await KimiUsageService.fetchQuota(accountID: account.id)
            switch result {
            case .success(let q):
                anySucceeded = true
                snapshots.append(KimiAccountSnapshot(id: account.id, label: account.label, quota: q))
            case .failure(let e):
                errors[account.id] = kimiErrorMessage(e)
            }
        }

        if anySucceeded {
            kimiQuota = KimiQuota.aggregate(snapshots.map(\.quota))
            kimiError = nil
            kimiLastUpdated = Date()
            kimiAccountQuotas = snapshots
            AppLog.debug("Kimi 用量刷新成功 \(snapshots.count) 账户 5h=\(kimiQuota.map { "\($0.fiveHour.pct)%" } ?? "无") weekly=\(kimiQuota.map { "\($0.weekly.pct)%" } ?? "无")", category: .kimi)
            recordAndNotify()
        } else {
            kimiError = errors.values.first ?? "Kimi 刷新失败"
        }
        kimiAccountErrors = errors
    }

    /// Kimi 错误文案(与旧单账户口径一致)。
    private func kimiErrorMessage(_ e: UsageError) -> String {
        switch e {
        case .authExpired: return "Kimi 登录已过期,请重新登录该账户"
        case .network(let s): return "Kimi 网络错误: \(s)"
        case .parse: return "Kimi 响应格式变化,解析失败"
        case .invalidResponse: return "Kimi 响应异常"
        case .unknown(let s): return s
        }
    }

    /// 清空 Kimi 状态(不删共享凭证文件;所有账户的 web token 一并清)。
    public func clearKimi() {
        for account in kimiAccounts {
            KimiUsageService.clearWebToken(accountID: account.id)
        }
        kimiAccounts = []
        kimiAccountQuotas = []
        kimiAccountErrors = [:]
        kimiQuota = nil
        kimiError = nil
        notificationTracker.clear(provider: "kimi")
    }

    // MARK: - 智谱 GLM Coding Plan

    /// 拉取智谱 Coding Plan 用量。未配置(无手动 key 且未发现 opencode 配置)时静默跳过。
    /// 刷新智谱用量(2026-10-04 多账户:逐账户拉取 → 聚合 → 面板/告警用聚合值)。
    /// 单账户时等价于旧路径(聚合返回原值);无任何账户但有 Key 时先补 main 迁移。
    public func refreshZhipu(force: Bool = false) async {
        ensureCredentialLoaded()
        guard isEnabled(.zhipu), zhipuConfigured else { return }
        // 无账户(用户移除全部)→ 不拉取;卡片显示添加引导。
        // ⚠️ 不在这里补 main:凭据(Key/自动发现)仍在,补了会把用户刚移除的账户复活。
        guard !zhipuAccounts.isEmpty else { return }

        var snapshots: [ZhipuAccountSnapshot] = []
        var errors: [String: String] = [:]
        var anySucceeded = false
        for account in zhipuAccounts {
            guard let key = zhipuKey(accountID: account.id), !key.isEmpty else {
                errors[account.id] = "未配置 API Key(设置 → 智谱 GLM 粘贴)"
                continue
            }
            let result = await ZhipuUsageService.fetchQuota(apiKey: key)
            switch result {
            case .success(let q):
                anySucceeded = true
                snapshots.append(ZhipuAccountSnapshot(id: account.id, label: account.label, quota: q))
            case .failure(let e):
                errors[account.id] = zhipuErrorMessage(e)
            }
        }

        if anySucceeded {
            zhipuQuota = ZhipuQuota.aggregate(snapshots.map(\.quota))
            zhipuError = nil
            zhipuLastUpdated = Date()
            zhipuAccountQuotas = snapshots
            AppLog.debug("智谱用量刷新成功 \(snapshots.count) 账户 5h=\(zhipuQuota?.fiveHour.map { "\($0.pctInt)%" } ?? "无") weekly=\(zhipuQuota?.weekly.map { "\($0.pctInt)%" } ?? "无") level=\(zhipuQuota?.level ?? "?")", category: .zhipu)
            recordAndNotify()
        } else {
            zhipuError = errors.values.first ?? "智谱刷新失败"
            AppLog.warning("智谱刷新失败: \(zhipuError ?? "")", category: .zhipu)
        }
        zhipuAccountErrors = errors
    }

    /// 智谱错误文案(与旧单账户口径一致的用户可读描述)。
    private func zhipuErrorMessage(_ e: ZhipuUsageService.ZhipuError) -> String {
        switch e {
        case .authExpired: return "智谱 API Key 无效或已失效,请在设置更新"
        case .network(let s): return "智谱 网络错误: \(s)"
        case .parse: return "智谱 响应格式变化,解析失败"
        case .invalidResponse(let s): return "智谱 响应异常: \(s)"
        case .unknown(let s): return s
        }
    }

    /// 移除手动配置的智谱 API Key + 清状态(自动发现的 opencode 配置不受影响)。
    /// 多账户:清全部账户与各自 Keychain 槽。
    public func clearZhipu() {
        for account in zhipuAccounts where account.id != "main" {
            credentialStore.delete(account: Self.zhipuKeySlot(accountID: account.id))
        }
        credentialStore.delete(account: Self.zhipuAPIKeyAccount)
        zhipuAPIKey = ""
        zhipuAccounts = []
        zhipuAccountQuotas = []
        zhipuAccountErrors = [:]
        zhipuQuota = nil
        zhipuError = nil
        notificationTracker.clear(provider: "zhipu")
    }

    // MARK: - DeepSeek API

    /// 拉取 DeepSeek 总余额,并更新当日费用账本(余额差快照法)。
    /// 未配置 API Key 时静默跳过(设置页/面板有引导)。
    public func refreshDeepSeek() async {
        ensureCredentialLoaded()
        guard isEnabled(.deepSeek), deepSeekConfigured else { return }
        guard !deepSeekLoading else { return }
        deepSeekLoading = true
        defer { deepSeekLoading = false }
        let result = await DeepSeekUsageService.fetchBalance(apiKey: deepSeekAPIKey)
        switch result {
        case .success(let b):
            deepSeekBalance = b
            deepSeekError = nil
            deepSeekLastUpdated = Date()
            deepSeekTodayCost = deepSeekDailyStore.record(balance: b.totalBalance, at: Date())
            AppLog.debug("DeepSeek 余额刷新成功 total=\(b.totalBalance) currency=\(b.currency) 今日=\(deepSeekTodayCost?.cost ?? 0)", category: .deepseek)
            recordAndNotify()
        case .failure(let e):
            switch e {
            case .authExpired: deepSeekError = "API Key 无效或已失效,请在设置更新"
            case .network(let s): deepSeekError = "DeepSeek 网络错误: \(s)"
            case .parse: deepSeekError = "DeepSeek 响应格式变化,解析失败"
            case .invalidResponse: deepSeekError = "DeepSeek 响应异常"
            case .unknown(let s): deepSeekError = s
            }
            AppLog.warning("DeepSeek 刷新失败: \(deepSeekError ?? "")", category: .deepseek)
        }
    }

    /// 移除 DeepSeek API Key + 清状态(账本保留,下次配置后同一天继续累计)。
    public func clearDeepSeek() {
        credentialStore.delete(account: Self.deepSeekAPIKeyAccount)
        deepSeekAPIKey = ""
        deepSeekBalance = nil
        deepSeekTodayCost = nil
        deepSeekError = nil
        deepSeekLastUpdated = nil
    }

    // MARK: - 小米 MiMo API

    /// 拉取 MiMo 余额 + Token 套餐用量(控制台 Cookie 认证)。
    /// 未配置 Cookie 时静默跳过;失败保留旧数据 + 状态行报错(DeepSeek 同语义)。
    /// - Parameter force: 手动刷新/保存新 Cookie 时传 true,跳过鉴权失败冷却。
    public func refreshMiMo(force: Bool = false) async {
        ensureCredentialLoaded()
        guard isEnabled(.mimo), mimoConfigured else { return }
        guard !mimoLoading else { return }
        // 鉴权失败冷却:会话过期属于"用户不处理不会自愈",按正常间隔轮询纯属无效请求
        if !force, let until = mimoRetryNotBefore, Date() < until { return }
        mimoLoading = true
        defer { mimoLoading = false }
        var result = await MiMoUsageService.fetchUsage(cookieHeader: mimoCookie)
        // 会话过期 → 先用 passToken 静默续期,成功则重试一次(用户无感,不再需要手工重抄 Cookie)
        if case .failure(let e) = result, isMiMoAuthFailure(e), let jar = mimoJar, jar.canRenew {
            AppLog.info("MiMo 会话过期,尝试用 passToken 自动续期", category: .mimo)
            if case .success(let renewed) = await MiMoSessionRenewal.renew(jar: jar) {
                mimoJar = renewed
                result = await MiMoUsageService.fetchUsage(cookieHeader: renewed.platformHeader)
                if case .success = result {
                    AppLog.info("MiMo 自动续期完成,重试成功", category: .mimo)
                } else {
                    AppLog.warning("MiMo 自动续期完成,但重试仍失败", category: .mimo)
                }
            } else {
                AppLog.warning("MiMo 自动续期失败,需人工重新登录", category: .mimo)
            }
        }
        switch result {
        case .success(let usage):
            mimoUsage = usage
            mimoError = nil
            mimoLastUpdated = Date()
            mimoAuthFailures = 0
            mimoRetryNotBefore = nil
            // 落一份跨重启快照,控制台不可用时仍能展示"上次已知口径 + 时间"
            let snapshot = MiMoLastUsage(schemaVersion: 1, capturedAt: Date(), usage: usage)
            mimoLastSnapshot = snapshot
            mimoLastStore.save(snapshot)
            AppLog.debug("MiMo 余额刷新成功 balance=\(usage.balance.balance)\(usage.balance.currency) plan=\(usage.plan.map { "\(Int($0.usedPct.rounded()))%" } ?? "无")", category: .mimo)
            recordAndNotify()
        case .failure(let e):
            switch e {
            case .invalidCookie: mimoError = "Cookie 缺少必需字段(serviceToken/userId),请重新复制"
            case .loginRequired: mimoError = "MiMo 登录已过期,请重新登录平台并复制新 Cookie"
            case .invalidCredentials: mimoError = "MiMo 账号无权访问(403),请检查账号"
            case .network(let s): mimoError = "MiMo 网络错误: \(s)"
            case .parse(let s): mimoError = "MiMo 响应格式变化,解析失败(\(s))"
            case .unknown(let s): mimoError = s
            }
            // 鉴权类失败才降频;网络抖动仍按正常间隔重试
            switch e {
            case .loginRequired, .invalidCredentials, .invalidCookie:
                mimoAuthFailures += 1
                let cooldown = MiMoUsageService.authRetryCooldownSeconds(consecutiveFailures: mimoAuthFailures)
                mimoRetryNotBefore = Date().addingTimeInterval(cooldown)
                AppLog.warning("MiMo 鉴权失败,\(Int(cooldown / 60)) 分钟内不再重试(第 \(mimoAuthFailures) 次)", category: .mimo)
            default:
                break
            }
            AppLog.warning("MiMo 刷新失败: \(mimoError ?? "")", category: .mimo)
        }
    }

    /// 是否属于"用户必须处理"的 MiMo 鉴权失败(只有这类才值得尝试静默续期)。
    private func isMiMoAuthFailure(_ e: MiMoUsageService.MiMoError) -> Bool {
        switch e {
        case .loginRequired, .invalidCredentials, .invalidCookie: return true
        case .network, .parse, .unknown: return false
        }
    }

    /// 载入 MiMo 本地侧数据:上次成功快照 + 本机 CLI 用量账本。
    /// 启动时调一次即可(快照立即读盘;账本走 `collectMiMoLocal` 节流采集)。
    public func loadMiMoLocalSide() {
        if let snapshot = mimoLastStore.load() {
            mimoLastSnapshot = snapshot
            if mimoLastUpdated == nil { mimoLastUpdated = snapshot.capturedAt }
        }
    }

    /// 采集本机 CLI 用量账本(零凭据、零网络)。节流 10 分钟;`force` 绕过。
    /// sqlite3 子进程放到后台线程,不阻塞主线程刷新。
    public func collectMiMoLocal(force: Bool = false) async {
        if !force, let last = mimoLocalCollectedAt, Date().timeIntervalSince(last) < 600 { return }
        mimoLocalCollectedAt = Date()
        let store = mimoLocalStore
        let collected = await Task.detached(priority: .utility) {
            MiMoLocalUsageCollector.collect(store: store)
        }.value
        if let collected { mimoLocalUsage = collected }
    }

    /// 移除 MiMo Cookie + 清状态。
    public func clearMiMo() {
        credentialStore.delete(account: Self.mimoCookieAccount)
        credentialStore.delete(account: Self.mimoJarAccount)
        mimoCookie = ""
        mimoUsage = nil
        mimoError = nil
        mimoLastUpdated = nil
        mimoAuthFailures = 0
        mimoRetryNotBefore = nil
    }

    // MARK: - MiniMax Coding Plan

    /// 拉取 MiniMax Coding Plan 用量(国内→国际→旧端点依次尝试)。
    public func refreshMiniMax() async {
        ensureCredentialLoaded()
        guard isEnabled(.minimax), minimaxConfigured else { return }
        let result = await MiniMaxUsageService.fetchQuota(apiKey: minimaxAPIKey)
        switch result {
        case .success(let q):
            minimaxQuota = q
            minimaxError = nil
            AppLog.debug("MiniMax 用量刷新成功 本窗=\(q.interval.map { "\($0.pctInt)%" } ?? "无") 周=\(q.weekly.map { "\($0.pctInt)%" } ?? "无") plan=\(q.planName ?? "?")", category: .minimax)
            recordAndNotify()
        case .failure(let e):
            switch e {
            case .authExpired: minimaxError = "MiniMax API Key 无效或已失效,请在设置更新"
            case .noSubscription: minimaxError = "Key 有效,但当前无生效中的 Coding Plan 订阅(订阅后自动恢复显示)"
            case .network(let s): minimaxError = "MiniMax 网络错误: \(s)"
            case .parse: minimaxError = "MiniMax 响应格式变化,解析失败"
            case .invalidResponse(let s): minimaxError = "MiniMax 响应异常: \(s)"
            case .unknown(let s): minimaxError = s
            }
            AppLog.warning("MiniMax 刷新失败: \(minimaxError ?? "")", category: .minimax)
        }
    }

    /// 移除 MiniMax API Key + 清状态。
    public func clearMiniMax() {
        credentialStore.delete(account: Self.minimaxAPIKeyAccount)
        minimaxAPIKey = ""
        minimaxQuota = nil
        minimaxError = nil
        notificationTracker.clear(provider: "minimax")
    }

    // MARK: - Ollama Cloud

    /// 拉取 Ollama Cloud 用量(ollama.com 私有端点 + 本机 daemon 探测档位)。
    /// 未配置 API Key 时静默跳过(设置页/面板有引导)。
    public func refreshOllama() async {
        ensureCredentialLoaded()
        guard isEnabled(.ollama), ollamaConfigured else { return }
        let result = await OllamaUsageService.fetchQuota(apiKey: ollamaAPIKey)
        switch result {
        case .success(let q):
            ollamaQuota = q
            ollamaError = nil
            // 诊断:记录近 30 天消费(美元)+ 请求数 + 档位/额度。2026-10-09 起
            // /api/usage 只回报绝对美元(totals.usage_usd),不再有 0-1 小数口径歧义。
            AppLog.debug("Ollama 用量刷新成功 近30天=$\(String(format: "%.2f", q.spentUSD30d))(\(q.requests30d) 次) 近7天=$\(String(format: "%.2f", q.spentUSD7d)) 额度=\(q.capUSD.map { "$\($0)" } ?? "未知") 占比=\(q.usagePct.map { "\(Int($0.rounded()))%" } ?? "无") plan=\(q.plan ?? "?")", category: .ollama)
            recordAndNotify()
        case .failure(let e):
            switch e {
            case .authExpired: ollamaError = "API Key 无效或已吊销,请在设置更新"
            case .rateLimited: ollamaError = "请求被限流(用量可能已耗尽),稍后自动重试"
            case .network(let s): ollamaError = "Ollama 网络错误: \(s)"
            case .parse(let s): ollamaError = "Ollama 响应格式变化,解析失败(\(s))"
            case .invalidResponse(let s): ollamaError = "Ollama 响应异常: \(s)"
            case .unknown(let s): ollamaError = s
            }
            AppLog.warning("Ollama 刷新失败: \(ollamaError ?? "")", category: .ollama)
        }
    }

    /// 移除 Ollama API Key + 清状态。
    public func clearOllama() {
        credentialStore.delete(account: Self.ollamaAPIKeyAccount)
        ollamaAPIKey = ""
        ollamaQuota = nil
        ollamaError = nil
        notificationTracker.clear(provider: "ollama")
    }

    // MARK: - 阶跃 StepFun Step Plan

    /// 拉取阶跃 Step Plan 用量(**逐账户**)并聚合。通道:
    /// ① 主:App 注入的 `stepfunConsoleFetchSink(accountID)`(每账户一个常驻
    ///    WebView,页面内同源 fetch,Cookie 自动轮换);
    /// ② 兜底:无账户仅存量 token 时走 URLSession 直连(遗留粘贴通道)。
    ///
    /// 稳定性语义(2026-10-09 重写):
    /// - 鉴权失败先**自愈**(重载会话页让 SPA 用 30 天 refresh token 换发新
    ///   access,再重试一次),仍失败才标记「需重登」——Oasis-Token 的 access 段
    ///   只有 30 分钟 TTL,与刷新周期同频,裸 fetch 常抢在 SPA 续期前打出 401,
    ///   不重载就直接逼用户重登属于误杀;
    /// - 冷却**按账户独立**,一个账户过期不连坐其他账户;
    /// - 「会话页加载中」是软错误(页面未就绪),不计鉴权失败、不进冷却;
    /// - 本轮失败的账户保留 last-good 快照(标 isStale),统计不跳动、行不消失。
    public func refreshStepFun(force: Bool = false) async {
        ensureCredentialLoaded()
        guard isEnabled(.stepfun), stepfunConfigured else { return }
        guard !stepfunLoading else { return }
        stepfunLoading = true
        defer { stepfunLoading = false }

        // 遗留单 token 通道(无账户列表时;v1.0.60 前用户)
        if stepfunAccounts.isEmpty {
            guard let token = StepFunUsageService.normalizedToken(from: stepfunConsoleToken) else {
                if stepfunConsoleToken.isEmpty { return }
                stepfunError = "Oasis-Token 无法识别,请重新登录"
                return
            }
            let result = await StepFunUsageService.fetchQuota(
                consoleToken: token, webId: stepfunWebId,
                onRotatedToken: { [weak self] rotated in
                    Task { @MainActor in self?.stepfunConsoleToken = rotated }
                })
            applyStepFunResult(snapshots: [], aggregateResult: result)
            return
        }

        var errors: [String: String] = [:]
        var fresh: [String: StepFunAccountSnapshot] = [:]
        var anyFresh = false
        for account in stepfunAccounts {
            // 每账户独立冷却(手动刷新 force 绕过)
            if !force, let until = stepfunRetryNotBefore[account.id], Date() < until {
                let mins = max(1, Int(until.timeIntervalSinceNow / 60))
                errors[account.id] = "刷新冷却中,约 \(mins) 分钟后重试"
                continue
            }
            // 身份懒识别(与拉取结果无关:cookie 在就有身份;失败账户也要能识别出重复)
            if account.oasisID == nil, let identity = stepfunIdentitySink,
               let oasis = await identity(account.id), !oasis.isEmpty {
                setStepFunAccountOasisID(account.id, oasis)
                AppLog.info("阶跃[\(account.id)]身份识别:oasis_id=\(oasis)", category: .stepfun)
            }
            // 手机号尾号惰性补抓(JWT 里没有手机号,走账户中心 GetAccountBinding):
            // 老账户(加功能前登录的)没有 phoneTail,启动后补抓;每账户最多 3 次。
            // 拿不到不阻塞用量展示——身份回落 oasis_id 尾4位。
            if account.phoneTail == nil, (stepfunPhoneAttempts[account.id] ?? 0) < 3,
               let phone = stepfunPhoneSink {
                stepfunPhoneAttempts[account.id, default: 0] += 1
                if let tail = await phone(account.id), !tail.isEmpty {
                    setStepFunAccountPhoneTail(account.id, tail)
                    AppLog.info("阶跃[\(account.id)]手机号识别:尾号 \(tail)", category: .stepfun)
                }
            }
            guard let sink = stepfunConsoleFetchSink else {
                errors[account.id] = "会话通道未接入(需重启应用)"
                continue
            }
            // 拉取(含一次重载自愈:401 包络/页面被踢到登录域都会先重载再判死刑)
            let outcome = await fetchStepFunAccount(accountID: account.id, sink: sink)
            var raw: String
            switch outcome {
            case .pageNotReady:
                // 页面/webView 未就绪:软错误,不消耗鉴权冷却
                errors[account.id] = "会话页面加载中,稍后自动重试"
                continue
            case .sessionExpired:
                // 重载后仍停在登录域:会话真的死了(区别于「加载中」,给重登入口)
                errors[account.id] = "登录态已过期,请重新登录该账户"
                noteStepFunAuthFailure(accountID: account.id)
                continue
            case .json(let text):
                raw = text
            }
            let data = Data(raw.utf8)
            if let envelope = StepFunUsageService.classifyEnvelope(data: data) {
                switch envelope {
                case .authExpired:
                    errors[account.id] = "登录态已过期,请重新登录该账户"
                    noteStepFunAuthFailure(accountID: account.id)
                case .tokenNotPermitted:
                    errors[account.id] = "凭证类型不对:API Key 查不了额度"
                    noteStepFunAuthFailure(accountID: account.id)
                default:
                    errors[account.id] = "平台返回异常(\(raw.prefix(50)))"
                }
                continue
            }
            guard let quota = StepFunUsageService.parseQuota(from: data) else {
                errors[account.id] = "响应格式变化,解析失败(\(raw.prefix(50)))"
                continue
            }
            anyFresh = true
            fresh[account.id] = StepFunAccountSnapshot(id: account.id, label: account.label,
                                                       quota: quota, fetchedAt: Date())
            stepfunLastGood[account.id] = fresh[account.id]
            // 成功即清该账户的失败计数/冷却
            stepfunAuthFailures[account.id] = 0
            stepfunRetryNotBefore[account.id] = nil
        }

        // 合并:成功用新值,失败保留 last-good(标旧);按账户顺序输出
        let merged = StepFunAccountSnapshot.merge(accounts: stepfunAccounts, fresh: fresh,
                                                  previous: stepfunLastGood, now: Date())
        stepfunAccountQuotas = merged
        stepfunAccountErrors = errors
        // 同一 oasis_id 的重复会话只计一次(登录时已防重复添加,这里是双重保险)
        let duplicates = stepfunDuplicateAccountIDs
        let counted = merged.filter { !duplicates.contains($0.id) }
        if anyFresh {
            stepfunQuota = counted.isEmpty ? nil : StepFunQuota.aggregate(counted.map(\.quota))
            stepfunError = nil
            stepfunLastUpdated = Date()
            stepfunSessionActive = true
            AppLog.debug("阶跃用量刷新成功 \(fresh.count)/\(stepfunAccounts.count) 账户(\(merged.count - fresh.count) 个旧数据) 月池=\(stepfunQuota?.subscription.map { "\($0.usedPctInt)%" } ?? "无") 加油包=\(stepfunQuota?.topup.map { "\($0.usedPctInt)%" } ?? "无")", category: .stepfun)
            recordAndNotify()
        } else if !merged.isEmpty {
            // 全员失败但有 last-good:展示旧数据 + 汇总错误(行内还有逐账户明细)
            stepfunQuota = StepFunQuota.aggregate(counted.map(\.quota))
            stepfunError = "全部账户刷新失败(展示旧数据,见各账户明细)"
            AppLog.warning("阶跃全部账户刷新失败:\(errors)", category: .stepfun)
        } else {
            stepfunQuota = nil
            stepfunError = errors.values.first ?? "阶跃用量暂不可用"
            AppLog.warning("阶跃刷新失败:\(stepfunError ?? "")", category: .stepfun)
        }
    }

    /// 记录一次(自愈后的)鉴权失败:该账户独立计数 + 冷却(15/30/60/120 分钟)。
    private func noteStepFunAuthFailure(accountID: String) {
        stepfunAuthFailures[accountID, default: 0] += 1
        let cooldown = StepFunUsageService.authRetryCooldownSeconds(
            consecutiveFailures: stepfunAuthFailures[accountID] ?? 1)
        stepfunRetryNotBefore[accountID] = Date().addingTimeInterval(cooldown)
        AppLog.warning("阶跃[\(accountID)]鉴权失败(第 \(stepfunAuthFailures[accountID] ?? 1) 次),\(Int(cooldown / 60)) 分钟内不再重试该账户", category: .stepfun)
    }

    /// 拉取单账户(含一次重载自愈)。两类信号触发自愈:
    /// ① 响应是 `unauthenticated` 包络(access token 抢跑过期);
    /// ② 页面被踢到登录域(account.stepfun.com,会话已死但 refresh 可能还有效)。
    /// 自愈 = 强制重载会话页(SPA 用 30 天 refresh token 换发新 access)后重试;
    /// 重载后回到平台域并拿到响应 → 正常继续;仍停在登录域 → `.sessionExpired`
    /// (调用方按真鉴权失败处理:重登入口 + 冷却);还在导航 → `.pageNotReady`(软)。
    private func fetchStepFunAccount(accountID: String,
                                     sink: @escaping (String) async -> StepFunUsageService.StepFunFetchOutcome)
    async -> StepFunUsageService.StepFunFetchOutcome {
        let first = await sink(accountID)
        let needsHeal: Bool
        if case .json(let raw) = first {
            needsHeal = StepFunUsageService.classifyEnvelope(data: Data(raw.utf8)) == .authExpired
        } else {
            needsHeal = first == .sessionExpired
        }
        guard needsHeal, let reload = stepfunSessionReload else { return first }
        AppLog.info("阶跃[\(accountID)]鉴权失败,重载会话页自愈", category: .stepfun)
        await reload(accountID)
        var last: StepFunUsageService.StepFunFetchOutcome = .pageNotReady
        for _ in 0..<4 {
            if Task.isCancelled { break }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            last = await sink(accountID)
            if case .json = last { return last }
        }
        return last
    }

    /// 应用一轮刷新结果(成功:快照+聚合+时间+告警评估;失败:错误文案)。
    /// 仅遗留单 token 通道仍走这里;多账户路径在 refreshStepFun 内联处理
    /// (每账户独立冷却 + last-good 合并)。
    private func applyStepFunResult(snapshots: [StepFunAccountSnapshot],
                                    aggregateResult: Result<StepFunQuota, StepFunUsageService.StepFunError>?) {
        switch aggregateResult {
        case .success(let q):
            stepfunQuota = q
            stepfunError = nil
            stepfunLastUpdated = Date()
            stepfunAuthFailures.removeAll()
            stepfunRetryNotBefore.removeAll()
            stepfunSessionActive = true
            if !snapshots.isEmpty { stepfunAccountQuotas = snapshots }
            AppLog.debug("阶跃用量刷新成功 \(snapshots.count) 账户 月池=\(q.subscription.map { "\($0.usedPctInt)%" } ?? "无") 加油包=\(q.topup.map { "\($0.usedPctInt)%" } ?? "无")", category: .stepfun)
            recordAndNotify()
        case .failure(let e):
            switch e {
            case .authExpired: stepfunError = "阶跃控制台登录态已过期,请重新登录 platform.stepfun.com"
            case .tokenNotPermitted: stepfunError = "阶跃凭证类型不对:API Key 查不了额度,需要网页登录态"
            case .network(let s): stepfunError = "阶跃网络错误: \(s)"
            case .parse(let s): stepfunError = "阶跃响应格式变化,解析失败(\(s))"
            case .invalidResponse(let s): stepfunError = "阶跃响应异常: \(s)"
            case .unknown(let s): stepfunError = s
            }
            AppLog.warning("阶跃刷新失败: \(stepfunError ?? "")", category: .stepfun)
        case .none:
            break
        }
    }

    /// 移除阶跃全部登录态 + 清状态(App 层同时调 StepFunSessionController.logoutAll())。
    public func clearStepFun() {
        credentialStore.delete(account: Self.stepfunConsoleTokenAccount)
        stepfunConsoleToken = ""
        stepfunAccounts = []
        persistStepFunAccounts()
        stepfunSessionActive = false
        stepfunQuota = nil
        stepfunAccountQuotas = []
        stepfunAccountErrors = [:]
        stepfunError = nil
        stepfunLastUpdated = nil
        stepfunAuthFailures.removeAll()
        stepfunRetryNotBefore.removeAll()
        stepfunLastGood.removeAll()
        notificationTracker.clear(provider: "stepfun")
    }

    // MARK: - 阿里云 OpenAPI AK/SK（console token 自动刷新）

    /// 保存 AK/SK 到 Keychain。
    @discardableResult
    public func saveAliyunAKSK(accessKeyID: String, accessKeySecret: String) -> Bool {
        guard let credential = AliyunOpenAPICredential(accessKeyID: accessKeyID,
                                                       accessKeySecret: accessKeySecret) else {
            return false
        }
        guard let payload = try? JSONEncoder().encode(credential),
              let str = String(data: payload, encoding: .utf8) else { return false }
        credentialStore.write(str, account: Self.aliyunAKSKAccount)
        aliyunAKSKConfigured = true
        return true
    }

    /// 从 Keychain 读取 AK/SK。
    public func loadAliyunAKSK() -> AliyunOpenAPICredential? {
        guard let raw = credentialStore.read(account: Self.aliyunAKSKAccount),
              let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AliyunOpenAPICredential.self, from: data)
    }

    /// 删除 Keychain 中的 AK/SK。临时 profile 由其生命周期自动清理。
    public func clearAliyunAKSK() {
        credentialStore.delete(account: Self.aliyunAKSKAccount)
        aliyunEphemeralConfig = nil
        aliyunAutoRecoveryFailedAt = nil
        aliyunAKSKConfigured = false
        aliyunAKSKConfiguring = false
    }

    /// 当前进程使用的 bl 环境；没有短期配置时使用用户默认环境。
    private var aliyunEnvironment: [String: String]? {
        aliyunEphemeralConfig?.environment
    }

    /// 交换短期 token、验证 usage RPC 并在成功后保存 AK/SK。
    /// 自动恢复和手动配置共用此入口，避免同时写入临时配置。
    public func configureAliyun(accessKeyID: String, accessKeySecret: String) async -> Result<Void, BlAuthError> {
        guard !aliyunAKSKConfiguring else {
            return .failure(.verification("已有配置操作正在进行"))
        }
        guard let credential = AliyunOpenAPICredential(accessKeyID: accessKeyID,
                                                       accessKeySecret: accessKeySecret) else {
            return .failure(.invalidResponse)
        }
        aliyunAKSKConfiguring = true
        defer { aliyunAKSKConfiguring = false }
        do {
            let ephemeral = try await BlAuthManager.makeEphemeralConfig(credential: credential)
            let data = try await BlUsageService.callRPC(BlUsageService.usageAPI,
                                                        environment: ephemeral.environment)
            let usage = try BlUsageService.parseUsage(data)
            aliyunEphemeralConfig = ephemeral
            aliyunAutoRecoveryFailedAt = nil   // 手动/自动配置成功 → 冷却清零
            aliyunAutoRecoveryFailures = 0
            guard saveAliyunAKSK(accessKeyID: credential.accessKeyID,
                                  accessKeySecret: credential.accessKeySecret) else {
                return .failure(.verification("凭据保存失败"))
            }
            quota = TokenPlanQuota(usage: usage,
                                   subscription: quota?.subscription,
                                   addon: quota?.addon)
            lastUpdated = Date()
            lastError = nil
            authState = .ok
            recordAndNotify()
            return .success(())
        } catch let error as BlAuthError {
            return .failure(error)
        } catch let error as UsageError {
            return .failure(.verification(String(describing: error)))
        } catch {
            return .failure(.verification(error.localizedDescription))
        }
    }

    /// 交换短期 token 后用临时 profile 验证 usage RPC；失败则回退浏览器登录。
    /// 失败后进入冷却窗口（刷新间隔 ×2，最小 10 分钟），避免每个 timer tick 重复
    /// 弹出浏览器标签。手动配置成功后冷却清零。
    public func autoConfigureAliyunIfNeeded() async {
        guard authState == .expired || authState == .notLoggedIn else { return }
        guard !aliyunAKSKConfiguring else { return }
        guard let credential = loadAliyunAKSK() else { return }
        guard !AliyunAuthRecovery.inCooldown(
            failedAt: aliyunAutoRecoveryFailedAt,
            now: Date(),
            cooldownMinutes: autoRecoveryCooldownMinutes
        ) else { return }
        let result = await configureAliyun(accessKeyID: credential.accessKeyID,
                                           accessKeySecret: credential.accessKeySecret)
        switch result {
        case .success:
            aliyunAutoRecoveryFailures = 0
            AppLog.info("阿里云 AK/SK 自动恢复成功", category: .aliyun)
        case .failure(let e):
            aliyunAutoRecoveryFailures += 1
            aliyunAutoRecoveryFailedAt = Date()
            aliyunEphemeralConfig = nil
            AppLog.warning("阿里云 AK/SK 自动恢复失败(第 \(aliyunAutoRecoveryFailures) 次): \(String(describing: e))", category: .aliyun)
            // P1-C11:连续 ≥2 次失败后暂停自动弹浏览器,改为温和通知 + 面板提示
            if aliyunAutoRecoveryFailures < 2 {
                lastError = "自动恢复失败,请重新登录"
                relogin()
            } else {
                lastError = "自动恢复连续失败,已暂停自动打开浏览器,请手动重新登录"
                infoNotifySink?("阿里云自动恢复已暂停",
                                 "连续多次自动恢复失败。已停止自动打开浏览器,请在面板手动重新登录或检查 AK/SK。")
            }
        }
    }

    // MARK: - 历史记录 + 通知评估(P0-P1)

    /// 把当前已知用量落盘一条快照,并对所有窗口跑一次通知评估。
    /// 在任一 Provider 刷新成功后调用(两个 Provider 任一更新都会聚合一条快照)。
    public func recordAndNotify() {
        let snap = UsageSnapshot(
            timestamp: Date(),
            aliyunFiveHour: quota?.usage.fiveHour?.percentageInt,
            aliyunOneWeek: quota?.usage.oneWeek?.percentageInt,
            aliyunOneMonth: quota?.usage.oneMonth?.percentageInt,
            opencodeRolling: openCodeQuota?.rolling.pct,
            opencodeWeekly: openCodeQuota?.weekly.pct,
            opencodeMonthly: openCodeQuota?.monthly.pct,
            kimiFiveHour: kimiQuota?.fiveHour.pctInt,
            kimiWeekly: kimiQuota?.weekly.pctInt,
            kimiMonthly: kimiQuota?.monthly?.pctInt,
            deepSeekBalance: deepSeekBalance?.totalBalance,
            deepSeekTodayCost: deepSeekTodayCost?.cost,
            zhipuFiveHour: zhipuQuota?.fiveHour?.pctInt,
            zhipuWeekly: zhipuQuota?.weekly?.pctInt,
            mimoBalance: mimoUsage?.balance.balance,
            mimoPlanPct: mimoUsage?.plan.map { Int($0.usedPct.rounded()) },
            minimaxInterval: minimaxQuota?.interval?.pctInt,
            minimaxWeekly: minimaxQuota?.weekly?.pctInt,
            ollamaMonthly: ollamaQuota?.monthly?.pctInt,
            ollamaSession: nil,
            ollamaWeekly: nil,
            stepfunMonthly: stepfunQuota?.subscription?.usedPctInt,
            stepfunTopup: stepfunQuota?.topup?.usedPctInt
        )
        historyStore.append(snap)

        // 预渲染菜单栏图标(数据更新后,主线程上下文稳定)
        prerenderIcon()
        checkSubscriptionExpiry()

        guard notificationsEnabled else { return }
        // 停用的数据源不参与阈值告警(全面停用语义)
        var entries: [(WatchKey, Int)] = []
        if isEnabled(.aliyun), let q = quota {
            if let f = q.usage.fiveHour {
                entries.append((WatchKey(provider: "aliyun", window: "5h"), f.percentageInt))
            }
            if let w = q.usage.oneWeek {
                entries.append((WatchKey(provider: "aliyun", window: "7d"), w.percentageInt))
            }
            if let m = q.usage.oneMonth {
                entries.append((WatchKey(provider: "aliyun", window: "monthly"), m.percentageInt))
            }
        }
        // OpenCode:按 workspace 参与告警(单 workspace=旧口径;多 workspace=每行独立流,避免合计稀释风险)
        if isEnabled(.openCode) {
            let perWorkspace = openCodeWorkspaceQuotas
            if perWorkspace.count <= 1, let oc = openCodeQuota {
                entries.append((WatchKey(provider: "opencode", window: "rolling"), oc.rolling.pct))
                entries.append((WatchKey(provider: "opencode", window: "weekly"), oc.weekly.pct))
            } else {
                for snap in perWorkspace {
                    entries.append((WatchKey(provider: "opencode", window: "滚动·\(snap.label)"), snap.quota.rolling.pct))
                    entries.append((WatchKey(provider: "opencode", window: "周·\(snap.label)"), snap.quota.weekly.pct))
                }
            }
        }
        // Kimi:按账户参与告警(单账户=旧口径;多账户=每账户独立流,避免合计稀释风险)
        if isEnabled(.kimi) {
            let perAccount = kimiAccountQuotas
            if perAccount.count <= 1, let k = kimiQuota {
                entries.append((WatchKey(provider: "kimi", window: "5h"), k.fiveHour.pctInt))
                entries.append((WatchKey(provider: "kimi", window: "weekly"), k.weekly.pctInt))
                if let m = k.monthly {
                    entries.append((WatchKey(provider: "kimi", window: "monthly"), m.pctInt))
                }
            } else {
                for snap in perAccount {
                    entries.append((WatchKey(provider: "kimi", window: "5h·\(snap.label)"), snap.quota.fiveHour.pctInt))
                    entries.append((WatchKey(provider: "kimi", window: "weekly·\(snap.label)"), snap.quota.weekly.pctInt))
                    if let m = snap.quota.monthly {
                        entries.append((WatchKey(provider: "kimi", window: "monthly·\(snap.label)"), m.pctInt))
                    }
                }
            }
        }
        // 智谱:按账户参与告警(单账户=旧口径;多账户=每账户独立流)
        if isEnabled(.zhipu) {
            let perAccount = zhipuAccountQuotas
            if perAccount.count <= 1, let z = zhipuQuota {
                if let f = z.fiveHour {
                    entries.append((WatchKey(provider: "zhipu", window: "5h"), f.pctInt))
                }
                if let w = z.weekly {
                    entries.append((WatchKey(provider: "zhipu", window: "weekly"), w.pctInt))
                }
            } else {
                for snap in perAccount {
                    if let f = snap.quota.fiveHour {
                        entries.append((WatchKey(provider: "zhipu", window: "5h·\(snap.label)"), f.pctInt))
                    }
                    if let w = snap.quota.weekly {
                        entries.append((WatchKey(provider: "zhipu", window: "weekly·\(snap.label)"), w.pctInt))
                    }
                }
            }
        }
        // MiMo 为余额型(同 DeepSeek),不参与阈值告警;MiniMax 双窗口参与。
        if isEnabled(.minimax), let mm = minimaxQuota {
            if let i = mm.interval {
                entries.append((WatchKey(provider: "minimax", window: "interval"), i.pctInt))
            }
            if let w = mm.weekly {
                entries.append((WatchKey(provider: "minimax", window: "weekly"), w.pctInt))
            }
        }
        if isEnabled(.ollama), let ol = ollamaQuota {
            // 2026-10-09 起只有滚动 30 天 vs 月额度一个口径(窗口名沿用 monthly,
            // 历史序列/预测都按这个名字采样);无档位(无占比)不参与告警。
            if let m = ol.monthly {
                entries.append((WatchKey(provider: "ollama", window: "monthly"), m.pctInt))
            }
        }
        // 阶跃:按账户参与告警(单账户=monthly 旧口径;多账户=月池·<标签> 区分流)。
        if isEnabled(.stepfun) {
            let perAccount = stepfunAccountQuotas
            if perAccount.count <= 1, let sf = stepfunQuota {
                if let m = sf.subscription {
                    entries.append((WatchKey(provider: "stepfun", window: "monthly"), m.usedPctInt))
                }
                if let t = sf.topup {
                    entries.append((WatchKey(provider: "stepfun", window: "topup"), t.usedPctInt))
                }
            } else {
                for snap in perAccount {
                    if let m = snap.quota.subscription {
                        entries.append((WatchKey(provider: "stepfun", window: "月池·\(snap.label)"), m.usedPctInt))
                    }
                }
            }
        }
        for (key, band) in notificationTracker.evaluate(entries, config: thresholdConfig) {
            notifySink?(key, band)
        }
    }

    /// P2-B7:每天 20:00 汇总全部 Provider 用量发一条摘要通知。
    /// 进程未运行到点即错过(温和功能,不强求);关开关取消。
    private var digestTask: Task<Void, Never>?

    private func scheduleDailyDigest() {
        digestTask?.cancel()
        guard dailyDigestEnabled else { return }
        digestTask = Task { [weak self] in
            guard let self else { return }
            let now = Date()
            guard let next = Calendar.current.nextDate(
                after: now, matching: DateComponents(hour: 20, minute: 0), matchingPolicy: .nextTime
            ) else { return }
            try? await Task.sleep(nanoseconds: UInt64(next.timeIntervalSince(now) * 1_000_000_000))
            guard self.dailyDigestEnabled, !Task.isCancelled else { return }
            self.sendDailyDigest()
        }
    }

    private func sendDailyDigest() {
        // 停用的数据源不进摘要(全面停用语义)
        var parts: [String] = []
        if isEnabled(.aliyun), let q = quota {
            var line = "阿里云"
            if let f = q.usage.fiveHour { line += " 5h \(f.percentageInt)%" }
            if let w = q.usage.oneWeek { line += " 7d \(w.percentageInt)%" }
            if let m = q.usage.oneMonth { line += " 月 \(m.percentageInt)%" }
            parts.append(line)
        }
        if isEnabled(.openCode), let o = openCodeQuota {
            parts.append("OpenCode 滚动 \(o.rolling.pct)% · 周 \(o.weekly.pct)% · 月 \(o.monthly.pct)%")
            // 多 workspace:附每 workspace 滚动/周
            if openCodeWorkspaceQuotas.count > 1 {
                let detail = openCodeWorkspaceQuotas.map { snap in
                    "\(snap.label) 滚动 \(snap.quota.rolling.pct)% · 周 \(snap.quota.weekly.pct)%"
                }.joined(separator: " · ")
                parts.append("OpenCode工作区: \(detail)")
            }
        }
        if isEnabled(.kimi), let k = kimiQuota {
            var line = "Kimi 5h \(k.fiveHour.pctInt)% · 周 \(k.weekly.pctInt)%"
            if let m = k.monthly { line += " · 月 \(m.pctInt)%" }
            parts.append(line)
            // 多账户:附每账户 5h
            if kimiAccountQuotas.count > 1 {
                let detail = kimiAccountQuotas.map { snap in
                    "\(snap.label) 5h \(snap.quota.fiveHour.pctInt)%"
                }.joined(separator: " · ")
                parts.append("Kimi账户: \(detail)")
            }
        }
        if isEnabled(.deepSeek), let b = deepSeekBalance {
            var line = "DeepSeek 余额 \(DeepSeekMoneyFormat.full(b.totalBalance))"
            if let c = deepSeekTodayCost { line += " · 今日 \(DeepSeekMoneyFormat.full(c.cost))" }
            parts.append(line)
        }
        if isEnabled(.zhipu), let z = zhipuQuota {
            var line = "智谱 GLM"
            if let f = z.fiveHour { line += " 5h \(f.pctInt)%" }
            if let w = z.weekly { line += " · 周 \(w.pctInt)%" }
            if let m = z.mcp { line += " · MCP \(Int(m.percentage.rounded()))%" }
            parts.append(line)
            // 多账户:附每账户 5h/周
            if zhipuAccountQuotas.count > 1 {
                let detail = zhipuAccountQuotas.map { snap in
                    var s = "\(snap.label)"
                    if let f = snap.quota.fiveHour { s += " 5h \(f.pctInt)%" }
                    if let w = snap.quota.weekly { s += " 周 \(w.pctInt)%" }
                    return s
                }.joined(separator: " · ")
                parts.append("智谱账户: \(detail)")
            }
        }
        if isEnabled(.mimo), let m = mimoUsage {
            var line = "MiMo 余额 \(MiMoMoneyFormat.full(m.balance.balance, currency: m.balance.currency))"
            if let p = m.plan { line += " · 套餐 \(Int(p.usedPct.rounded()))%" }
            parts.append(line)
        }
        if isEnabled(.minimax), let mm = minimaxQuota {
            var line = "MiniMax"
            if let i = mm.interval { line += " 本窗 \(i.pctInt)%" }
            if let w = mm.weekly { line += " · 周 \(w.pctInt)%" }
            parts.append(line)
        }
        if isEnabled(.ollama), let ol = ollamaQuota {
            // 新接口只有滚动 30 天口径:有档位显示占比,否则显示绝对消费
            if let m = ol.monthly {
                parts.append("Ollama 30天 \(m.pctInt)%")
            } else {
                parts.append("Ollama 近30天 \(OllamaMoney.full(ol.spentUSD30d))")
            }
        }
        if isEnabled(.stepfun), let sf = stepfunQuota {
            var line = "阶跃"
            if let m = sf.subscription { line += " 月池 \(m.usedPctInt)%" }
            if let t = sf.topup { line += " · 加油包 \(t.usedPctInt)%" }
            parts.append(line)
            // 多账户:附每账户月池
            if stepfunAccountQuotas.count > 1 {
                let detail = stepfunAccountQuotas.compactMap { snap -> String? in
                    guard let m = snap.quota.subscription else { return nil }
                    return "\(snap.label) \(m.usedPctInt)%"
                }.joined(separator: " · ")
                if !detail.isEmpty { parts.append("阶跃账户: \(detail)") }
            }
        }
        guard !parts.isEmpty else { return }
        AppLog.info("发送每日用量摘要", category: .general)
        infoNotifySink?("今日用量摘要", parts.joined(separator: "\n"))
    }

    /// 订阅到期预警(P1-B2):剩余 ≤7 天时每天最多温和提醒一次。
    /// 用独立 UserDefaults 键记"今日已提醒",避免每次刷新重复轰炸。
    private func checkSubscriptionExpiry() {
        guard isEnabled(.aliyun) else { return }
        guard let sub = quota?.subscription,
              (0...7).contains(sub.remainingDays) else { return }
        let key = UserDefaultsKeys.subscriptionExpiryWarnedDay
        let defaults = UserDefaults.standard
        let today = Calendar.current.startOfDay(for: Date())
        if let warned = defaults.object(forKey: key) as? Date, warned == today { return }
        defaults.set(today, forKey: key)
        AppLog.warning("阿里云套餐剩余 \(sub.remainingDays) 天,触发到期提醒", category: .aliyun)
        infoNotifySink?("阿里云套餐即将到期", "套餐剩余 \(sub.remainingDays) 天,请及时续费。")
    }

    /// 登出 OpenCode:清凭据 + 重置状态 + 清通知记忆(下次登录重新走首次通知)。
    public func clearOpenCode() {
        credentialStore.delete(account: Self.openCodeCookieAccount)
        openCodeCookie = ""
        openCodeWorkspaces = []
        openCodeWorkspaceQuotas = []
        openCodeWorkspaceErrors = [:]
        openCodeQuota = nil
        openCodeError = nil
        notificationTracker.clear(provider: "opencode")
    }

    /// 预渲染图标:数据更新后调用。若 renderIconSink 为 nil 则跳过。
    public func prerenderIcon() {
        menuBarTooltip = renderTooltipSink?(self)
        renderedIcon = renderIconSink?(self)
    }

    /// 查 bl 已装版本 + 最新版本(后台,不阻塞主流程)
    public func checkBlVersion() async {
        blInstalledVersion = await BlAuthManager.installedVersion()
        blLatestVersion = await BlAuthManager.latestVersion()
    }

    private func resetTimer() {
        timer?.cancel()
        let minutes = effectiveIntervalMinutes()
        currentIntervalMinutes = minutes
        timer = Timer.publish(every: TimeInterval(minutes * 60), on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, self.networkSatisfied else { return }   // 断网跳过 tick
                Task { await self.refreshAll() }
            }
    }

    /// 先查环境；默认 bl session 无效时，若已有 AK/SK 则走一次短期 token 恢复。
    /// 阿里云停用(全面停用语义)时整段跳过:不查登录态、不自动弹浏览器重登。
    public func checkAuthAndRefresh() async {
        guard isEnabled(.aliyun) else { return }
        authState = await BlAuthManager.currentAuthState()
        if authState == .ok {
            await refresh()
        } else if loadAliyunAKSK() != nil {
            aliyunAKSKConfigured = true
            await autoConfigureAliyunIfNeeded()
        }
    }

    /// 重新登录:拉起浏览器授权,并轮询 `bl auth status`(每 5s,最多 3 分钟)。
    /// 浏览器登录完成后自动回置 .ok 并立即刷数据,无需用户手动操作或等定时器。
    /// 已有轮询在跑时不重复起。
    public func relogin() {
        BlAuthManager.relogin()
        guard !isReloginWatching else { return }
        isReloginWatching = true
        Task {
            var done = false
            // P1-C9:监听延长到 5 分钟(60×5s),浏览器扫码慢也能赶上
            for _ in 0..<60 {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if await BlAuthManager.currentAuthState() == .ok {
                    authState = .ok
                    await refresh()
                    done = true
                    break
                }
            }
            if !done { lastError = "浏览器登录超时(5 分钟),可点击重新登录再试" }
            isReloginWatching = false
        }
    }

    /// 拉数据。usage 每次都拉(高频);subscription/addon 仅超过 24h 或首次才拉(低频),
    /// 否则沿用上次缓存。失败时:auth 错误 → 置 .expired;其他 → 保留旧数据 + 记录错误。
    public func refresh() async {
        guard !isLoading else { return }
        // 自动路径节流:30s 内只放行一次(热修复第二道防线;手动 refreshFull 不受限)
        guard Date().timeIntervalSince(lastAutoRefreshAt) >= minAutoRefreshSpacing else {
            AppLog.debug("自动刷新节流跳过(距上次 \(String(format: "%.0f", Date().timeIntervalSince(lastAutoRefreshAt)))s)", category: .aliyun)
            return
        }
        lastAutoRefreshAt = Date()
        isLoading = true
        let start = Date()
        defer { isLoading = false }

        // 是否需要刷新辅助数据(首次 或 超过 24h)
        let needAux = lastAuxFetch == nil || Date().timeIntervalSince(lastAuxFetch!) >= auxRefreshInterval

        if needAux {
            // 全量拉(3 RPC)。usage 失败则以 usage-only 重试仍走全量错误路径。
            let result = await BlUsageService.fetchQuota(environment: aliyunEnvironment)
            switch result {
            case .success(let q):
                quota = q
                lastAuxFetch = Date()
                lastUpdated = Date()
                lastError = nil
                authState = authState.afterRefresh(error: nil)
                if consecutiveFailures != 0 { consecutiveFailures = 0; rescheduleIfNeeded() }
                AppLog.info("阿里云全量刷新成功 \(logWindows(q.usage))耗时=\(String(format: "%.1f", Date().timeIntervalSince(start)))s", category: .aliyun)
                scheduleResetBoundaryRefresh()
                recordAndNotify()
            case .failure(let e):
                authState = authState.afterRefresh(error: e)
                lastError = errorMessage(e)
                consecutiveFailures += 1
                rescheduleIfNeeded()
                AppLog.warning("阿里云全量刷新失败: \(String(describing: e))", category: .aliyun)
                if e == .authExpired { Task { await autoConfigureAliyunIfNeeded() } }
            }
        } else {
            // 只拉 usage(1 RPC),辅助数据沿用缓存
            let result = await BlUsageService.fetchUsageOnly(environment: aliyunEnvironment)
            switch result {
            case .success(let usage):
                quota = TokenPlanQuota(usage: usage,
                                       subscription: quota?.subscription,
                                       addon: quota?.addon)
                lastUpdated = Date()
                lastError = nil
                authState = authState.afterRefresh(error: nil)
                if consecutiveFailures != 0 { consecutiveFailures = 0; rescheduleIfNeeded() }
                AppLog.debug("阿里云 usage 刷新成功 \(logWindows(usage))耗时=\(String(format: "%.1f", Date().timeIntervalSince(start)))s", category: .aliyun)
                scheduleResetBoundaryRefresh()
                recordAndNotify()
            case .failure(let e):
                authState = authState.afterRefresh(error: e)
                lastError = errorMessage(e)
                consecutiveFailures += 1
                rescheduleIfNeeded()
                AppLog.warning("阿里云 usage 刷新失败: \(String(describing: e))", category: .aliyun)
                if e == .authExpired { Task { await autoConfigureAliyunIfNeeded() } }
            }
        }
    }

    /// 手动刷新(用户点"刷新"按钮):强制全量拉一次,无视 24h 缓存。
    public func refreshFull() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let result = await BlUsageService.fetchQuota(environment: aliyunEnvironment)
        switch result {
        case .success(let q):
            quota = q
            lastAuxFetch = Date()
            lastUpdated = Date()
            lastError = nil
            authState = authState.afterRefresh(error: nil)
            if consecutiveFailures != 0 { consecutiveFailures = 0; rescheduleIfNeeded() }
            scheduleResetBoundaryRefresh()
            recordAndNotify()
        case .failure(let e):
            authState = authState.afterRefresh(error: e)
            lastError = errorMessage(e)
            consecutiveFailures += 1
            rescheduleIfNeeded()
        }
    }

    private func errorMessage(_ e: UsageError) -> String {
        switch e {
        case .authExpired: return "控制台登录已过期"
        case .network(let s): return "网络错误: \(s)"
        case .parse: return "数据解析失败"
        case .invalidResponse: return "响应异常"
        case .unknown(let s): return s
        }
    }

    /// 日志用窗口片段:存在的窗口逐个输出 "5h=X% 7d=Y% 30d=Z% "(尾随空格);全缺失时空串。
    private func logWindows(_ w: UsageWindows) -> String {
        w.activeWindows.map { "\($0.name)=\($0.detail.percentageInt)% " }.joined()
    }

    /// 语义化版本比较:返回 -1(a<b)/0(=)/1(a>b)。解析失败按字符串比。
    private func compareVersions(_ a: String, _ b: String) -> Int {
        let pa = a.split(separator: ".").compactMap { Int($0) }
        let pb = b.split(separator: ".").compactMap { Int($0) }
        if pa.isEmpty || pb.isEmpty { return a < b ? -1 : (a > b ? 1 : 0) }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }
}
