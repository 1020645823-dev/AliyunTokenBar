import SwiftUI
import WebKit
import AliyunTokenBarCore

// MARK: - 阶跃会话控制器(每账户一个常驻隐藏 WKWebView)
//
// 2026-10-02 实勘定论:Oasis-Token 是**滚动轮换**凭据——SPA 在浏览器里持续
// 换新 pair,任何静态复制出来的 token 几分钟内即被服务端判 `embezzled`
// (页面上下文内同源 fetch 实测同样作废,排除传输层差异)。因此阶跃额度
// 查询不能走「存 token + URLSession」:唯一可靠方案是 App 常驻承载
// platform.stepfun.com 的 WKWebView,把 RPC 作为**页面内同源 fetch**发出
// (Cookie 自动轮换、WAF/TLS 全与浏览器等价)。
//
// 多账户(2026-10-02 需求):每个账户一个独立会话仓库 ——
// - 首账户固定 id="main":沿用 `WKWebsiteDataStore.default()`(v1.0.60 起的
//   单会话仓库,零迁移);
// - 其余账户:UUID id + `WKWebsiteDataStore(forIdentifier:)` 命名仓库(持久化,
//   登录态跨启动保留,账户间完全隔离)。
//
// 生命周期:登录窗把对应账户的 webView 挂进视图树;验证成功后由控制器保留
// (脱离视图树仍可 evaluateJavaScript);冷启动按账户列表预热。
@MainActor
final class StepFunSessionController: NSObject, ObservableObject {
    static let shared = StepFunSessionController()

    /// 会话页(控制台 SPA 任一同源页面即可;订阅页登录态跳转最直接)。
    static let sessionURL = URL(string: "https://platform.stepfun.com/step-plan")!

    /// 账户 id → 会话 WebView。
    private(set) var webViews: [String: WKWebView] = [:]
    /// 最近一次 load 时刻(防重复加载;页面内 fetch 自带就绪轮询)。
    private var lastLoadAt: [String: Date] = [:]

    override private init() {
        super.init()
    }

    /// 账户 id → 会话仓库(main=固定 UUID 命名仓库,其余=各账户 UUID,各自持久化隔离)。
    ///
    /// ⚠️ 2026-10-18:main 从 `WKWebsiteDataStore.default()` 迁到固定 UUID 命名仓库。
    /// 实勘定论:默认仓库的 cookie 落盘文件(WebsiteData/Default/Cookies/)会整文件
    /// 丢失(本次 2026-10-17 20:45 复现),此后登录态只存活于一个僵尸 WebKit 网络
    /// 进程的内存里——app 重启能"续命"只因该进程还活着,进程一死(实测:僵尸退出
    /// 后默认仓库 cookie 从 21 条变 0 条)全部登录态灰飞烟灭。UUID 命名仓库的
    /// cookie 一直稳定落盘(账户2 的仓库文件跨月正常),故全部账户统一走命名仓库。
    static let mainStoreIdentifier = UUID(uuidString: "6C2E1A50-3D4B-4E5F-8A9B-0C1D2E3F4A5B")!

    static func dataStore(accountID: String) -> WKWebsiteDataStore {
        if accountID == "main" {
            return WKWebsiteDataStore(forIdentifier: mainStoreIdentifier)
        }
        guard let uuid = UUID(uuidString: accountID) else {
            AppLog.warning("阶跃账户 id 非法,退回 main 仓库: \(accountID)", category: .stepfun)
            return WKWebsiteDataStore(forIdentifier: mainStoreIdentifier)
        }
        return WKWebsiteDataStore(forIdentifier: uuid)
    }

    /// 取(或建)某账户的会话 webView。
    func ensureWebView(accountID: String) -> WKWebView {
        if let existing = webViews[accountID] { return existing }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = Self.dataStore(accountID: accountID)
        let webView = WKWebView(frame: .init(x: 0, y: 0, width: 1100, height: 760), configuration: config)
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"
        webViews[accountID] = webView
        loadSessionPage(accountID: accountID)
        return webView
    }

    /// 加载会话页(冷启动预热 / 重登后重建;30s 内不重复)。
    func loadSessionPage(accountID: String) {
        guard let webView = webViews[accountID],
              Date().timeIntervalSince(lastLoadAt[accountID] ?? .distantPast) > 30 else { return }
        lastLoadAt[accountID] = Date()
        webView.load(URLRequest(url: Self.sessionURL))
        AppLog.info("阶跃会话页加载[\(accountID)](保持登录态与 Cookie 轮换)", category: .stepfun)
    }

    /// 强制重载会话页(鉴权自愈,模型层 `stepfunSessionReload` 注入调用)。
    /// Oasis-Token 的 access 段 30 分钟 TTL,页面内裸 fetch 可能抢在 SPA 续期前
    /// 打出 401——重载让 SPA 用 30 天 refresh token 换发新 access,比逼用户重登
    /// 温和得多。绕过 30s 防抖:自愈是显式动作,不应被节流。
    func reloadSessionPage(accountID: String) {
        let webView = ensureWebView(accountID: accountID)
        lastLoadAt[accountID] = Date()
        webView.load(URLRequest(url: Self.sessionURL))
        AppLog.info("阶跃[\(accountID)]会话页重载(鉴权自愈:换取新 access token)", category: .stepfun)
    }

    /// 冷启动预热:已登记账户全部预载(数据源停用时跳过)。
    /// ⚠️ 不再看 `stepfunSessionActive`——一次全员鉴权失败会把该标记置 false,
    /// 门控预热会导致之后所有 fetch 拿不到页面(整个数据源冻死,2026-10-09 修)。
    func warmUpIfConfigured() {
        let model = TokenPlanModel.shared
        guard model.isEnabled(.stepfun) else { return }
        for account in model.stepfunAccounts {
            _ = ensureWebView(accountID: account.id)
        }
    }

    /// 页面内同源 fetch 额度 RPC,返回三态结果:
    /// - `.json`:平台域内拿到响应文本(可能含错误包络,由调用方分类);
    /// - `.sessionExpired`:页面被踢到登录域(account.stepfun.com)——会话已死,
    ///   区别于「加载中」(2026-10-09 修:此前混同导致永远「会话页面加载中」,
    ///   既不触发重载自愈也不给重登入口);
    /// - `.pageNotReady`:页面还在导航/加载(软状态)。
    ///
    /// ⚠️ 实现约束(2026-10-02 实勘):必须用 completion 回调版 evaluateJavaScript
    /// 包一层显式超时——async 版在 SPA 导航期间会**挂起不返回**;且仅当页面位于
    /// platform.stepfun.com 时才能发同源 fetch(登录流程会途经 account.stepfun.com,
    /// 跨域 fetch 不带 Cookie)。
    func fetchQuota(accountID: String) async -> StepFunUsageService.StepFunFetchOutcome {
        // 自愈:WebView 缺失(预热被跳过/进程重启后)即时创建并加载,不再让模型层
        // 拿到 nil 干等(2026-10-09 修:此前缺失即「会话页面加载中」死循环)。
        let webView = ensureWebView(accountID: accountID)
        guard webView.url?.host == "platform.stepfun.com" else {
            let host = webView.url?.host ?? "nil"
            AppLog.debug("阶跃[\(accountID)]会话页不在平台域(\(host)),本轮跳过", category: .stepfun)
            return host == "account.stepfun.com" ? .sessionExpired : .pageNotReady
        }
        let mark = "__atbRpc\(Int.random(in: 1000...9999))"
        let js = """
        (function(){
            var m = '\(mark)';
            window[m] = null;
            fetch('/api/step.openapi.devcenter.Dashboard/QueryStepPlanRateLimit', {
                method: 'POST',
                credentials: 'same-origin',
                headers: {'Content-Type': 'application/json',
                          'Oasis-appID': '10300',
                          'Oasis-Platform': 'web'},
                body: '{}'
            }).then(function(r){ return r.text(); })
              .then(function(t){ window[m] = t; })
              .catch(function(e){ window[m] = 'ERR:' + e; });
        })()
        """
        // fire-and-forget(completion 版保证回调;此处不关心结果)
        await Self.eval(webView, js)
        // 轮询结果窗口(0.4s × 50 ≈ 20s 上限;单次 eval 1.5s 超时防挂起)
        for _ in 0..<50 {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { return .pageNotReady }
            guard let value = await Self.evalWithTimeout(webView, "window.\(mark) ?? ''", seconds: 1.5),
                  let text = value as? String, !text.isEmpty else { continue }
            AppLog.debug("阶跃[\(accountID)]页面内 fetch 返回(len=\(text.count)): \(text.prefix(80))", category: .stepfun)
            return text.hasPrefix("ERR:") ? .pageNotReady : .json(text)
        }
        AppLog.warning("阶跃[\(accountID)]页面内 fetch 轮询超时(页面可能仍在导航)", category: .stepfun)
        return .pageNotReady
    }

    /// completion 版 evaluateJavaScript(WebKit 保证回调;async 版导航期会挂起)。
    @MainActor
    static func eval(_ webView: WKWebView, _ js: String) async -> Any? {
        await withCheckedContinuation { cont in
            webView.evaluateJavaScript(js) { result, _ in
                cont.resume(returning: result)
            }
        }
    }

    /// eval + 硬超时(超时返回 nil;与"JS 返回 null"同义处理)。
    @MainActor
    static func evalWithTimeout(_ webView: WKWebView, _ js: String, seconds: Double) async -> Any? {
        await withTaskGroup(of: Any?.self) { group in
            group.addTask { await Self.eval(webView, js) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// 读取该账户会话两域 Oasis-Token cookie 原值(platform=SPA 持续轮换的那对,
    /// account=登录时种下的旧对;身份识别/手机号查询分流使用)。
    /// 走原生 httpCookieStore(不受 HttpOnly 影响);某域没有对应值为 nil。
    private func oasisCookies(accountID: String) async -> (platform: String?, account: String?) {
        let store = ensureWebView(accountID: accountID).configuration.websiteDataStore
        let cookies = await withCheckedContinuation { cont in
            store.httpCookieStore.getAllCookies { cookies in
                cont.resume(returning: cookies)
            }
        }
        var platform: String?, account: String?
        for cookie in cookies where cookie.name.caseInsensitiveCompare("Oasis-Token") == .orderedSame {
            let value = cookie.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            if cookie.domain.contains("account.stepfun.com") {
                account = account ?? value
            } else {
                platform = platform ?? value
            }
        }
        return (platform, account)
    }

    /// 读取该账户会话的 Oasis-Token cookie,解析出 oasis_id(账户身份)。
    /// 多账户去重/防重复登录用:同一 oasis_id = 同一个阶跃账户。
    func currentOasisID(accountID: String) async -> String? {
        let (platform, account) = await oasisCookies(accountID: accountID)
        for token in [platform, account].compactMap({ $0 }) {
            if let oasis = StepFunUsageService.oasisID(fromCookieValue: token) { return oasis }
        }
        return nil
    }

    /// 查该账户绑定的手机号尾4位(账户中心 GetAccountBinding,2026-10-15)。
    /// **鉴权组合是实勘定的**(curl 矩阵,见 StepFunUsageService.accountBindingURL):
    /// `Oasis-Token` 与 `Oasis-Webid` 都取 **platform.stepfun.com 域**的同一对
    /// cookie——token 用 cookie 原值,Webid 用该 cookie 里 device JWT 的 device_id,
    /// 账户中心校验二者同设备(错配即 CODE_TOKEN_ILLEGAL "device is not matching")。
    /// platform 对由 SPA 持续轮换,请求前即时读取保证新鲜;从平台会话页**跨域**
    /// POST(CORS 放行 token/webid 头,无 CSP),不导航离开会话页、不带 Cookie——
    /// 额度拉取不受干扰。cookie 缺失/未绑手机 → nil(展示层回落 oasis_id 尾4位)。
    func currentPhoneTail(accountID: String) async -> String? {
        let (platformToken, _) = await oasisCookies(accountID: accountID)
        guard let platformToken,
              !platformToken.contains("'"), !platformToken.contains("\""), !platformToken.contains("\\") else {
            return nil
        }
        guard let webId = StepFunUsageService.deviceID(fromCookieValue: platformToken),
              !webId.contains("'"), !webId.contains("\""), !webId.contains("\\") else {
            return nil
        }
        let webView = ensureWebView(accountID: accountID)
        guard webView.url?.host == "platform.stepfun.com" else {
            AppLog.debug("阶跃[\(accountID)]手机号查询跳过:会话页不在平台域(\(webView.url?.host ?? "nil"))", category: .stepfun)
            return nil
        }
        let mark = "__atbPhone\(Int.random(in: 1000...9999))"
        let js = """
        (function(){
            var m = '\(mark)';
            window[m] = null;
            fetch('\(StepFunUsageService.accountBindingURL.absoluteString)', {
                method: 'POST',
                headers: {'Content-Type': 'application/json',
                          'Accept': 'application/json',
                          'Oasis-appID': '10300',
                          'Oasis-Platform': 'web',
                          'Oasis-Webid': '\(webId)',
                          'Oasis-Token': '\(platformToken)'},
                body: '{}'
            }).then(function(r){ return r.text(); })
              .then(function(t){ window[m] = t; })
              .catch(function(e){ window[m] = 'ERR:' + e; });
        })()
        """
        await Self.eval(webView, js)
        // 轮询结果窗口(0.4s × 25 ≈ 10s 上限;单次 eval 1.5s 超时防挂起,同额度拉取)
        for _ in 0..<25 {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { return nil }
            guard let value = await Self.evalWithTimeout(webView, "window.\(mark) ?? ''", seconds: 1.5),
                  let text = value as? String, !text.isEmpty else { continue }
            if text.hasPrefix("ERR:") {
                AppLog.warning("阶跃[\(accountID)]手机号查询 fetch 失败: \(text.prefix(80))", category: .stepfun)
                return nil
            }
            guard let tail = StepFunUsageService.phoneTail(fromBindingJSON: text) else {
                // 未绑手机/形状变化:记片段定位,不重试(调用方有次数上限)
                AppLog.warning("阶跃[\(accountID)]手机号解析为空: \(text.prefix(120))", category: .stepfun)
                return nil
            }
            AppLog.info("阶跃[\(accountID)]手机号查询成功(尾号 \(tail))", category: .stepfun)
            return tail
        }
        AppLog.warning("阶跃[\(accountID)]手机号查询轮询超时(页面可能仍在导航)", category: .stepfun)
        return nil
    }

    /// 登出单账户:清该账户仓库的平台站点数据 + 销毁其 WebView。
    /// ⚠️ 首账户(main)走默认仓库——只清 stepfun.com 站点数据,不动仓库本身。
    func logout(accountID: String) {
        let store = Self.dataStore(accountID: accountID)
        store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
            let targets = records.filter { $0.displayName.contains("stepfun.com") }
            guard !targets.isEmpty else { return }
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: targets) {
                AppLog.info("阶跃[\(accountID)]登录态已清除(\(targets.count) 条站点数据)", category: .stepfun)
            }
        }
        webViews[accountID] = nil
        lastLoadAt[accountID] = nil
    }

    /// 登出全部账户(设置页「移除登录态」)。
    func logoutAll() {
        for id in webViews.keys {
            logout(accountID: id)
        }
    }
}
