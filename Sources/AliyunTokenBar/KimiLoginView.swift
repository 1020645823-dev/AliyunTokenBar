import SwiftUI
import WebKit
import AliyunTokenBarCore

/// Kimi Code 网页控制台登录窗口:内嵌 WKWebView 让用户登录 www.kimi.com,
/// 登录后从 localStorage 抓 web JWT(access_token + refresh_token),用于月度总额度。
/// 2026-10-04 多账户:`accountID` 决定 JWT 写入哪个 Keychain 槽;
/// 新账户(nonMain)登录成功后由调用方负责登记账户列表。
/// 2026-10-24 身份判定:抓到 JWT 先解 sub 与既有账户槽比对——同户直存、
/// 换户落已有槽须确认(防 main 被静默覆盖)、他槽已登记该户则拒绝(防重复)。
@MainActor
struct KimiLoginView: View {
    @StateObject private var model = TokenPlanModel.shared
    /// 目标账户槽:"main"=旧单账户槽;UUID=新账户专属槽
    var accountID: String = "main"
    /// 新账户的展示名(仅 accountID != "main" 时用于登记账户列表)
    var newAccountLabel: String? = nil
    @State private var loading = false
    @State private var message = ""
    /// 上一次处理过的 access token:登录成功后页面跳转会重复触发轮询,同 token 只处理一次;
    /// 用户在窗内登出换号会拿到新 token,能再次进入判定。
    @State private var lastHandledToken = ""
    /// 待用户确认的换户替换(oldSub ≠ newSub 落已有槽)
    @State private var pendingReplace: PendingReplace?
    @Environment(\.dismiss) private var dismiss

    /// 换户替换确认弹窗载荷。
    struct PendingReplace: Identifiable {
        let id = UUID()
        let token: KimiUsageService.KimiWebToken
        let oldSub: String?
        let newSub: String?
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶栏
            HStack(spacing: DesignTokens.spacingS) {
                Image(systemName: "sparkles").foregroundStyle(.teal)
                Text(accountID == "main" ? "登录 Kimi 网页控制台" : "登录 Kimi 新账户")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(ATBTextButtonStyle(color: .atbTextSecondary))
            }
            .padding(DesignTokens.spacingM)

            // WebView
            KimiWebView(
                onLoginSuccess: { accessToken, refreshToken in
                    Task { await handleLoginSuccess(accessToken: accessToken, refreshToken: refreshToken) }
                }
            )
            .frame(minWidth: 480, minHeight: 600)

            // 状态
            if loading {
                HStack(spacing: DesignTokens.spacingS) {
                    LoadingRing().frame(width: 14, height: 14)
                    Text(message.isEmpty ? "正在获取用量配置..." : message)
                        .font(.system(size: 12)).foregroundStyle(Color.atbTextSecondary)
                }
                .padding(DesignTokens.spacingM - 2)
            } else if !message.isEmpty {
                Text(message).font(.system(size: 12)).foregroundStyle(Color.atbTextSecondary)
                    .padding(DesignTokens.spacingM - 2)
                    .frame(maxWidth: .infinity)
            }
        }
        .background(Color.atbPanelBackground)
        .alert(
            "替换该账户的登录态?",
            isPresented: Binding(
                get: { pendingReplace != nil },
                set: { if !$0 { pendingReplace = nil } }
            ),
            presenting: pendingReplace
        ) { pending in
            Button("替换", role: .destructive) {
                let token = pending.token
                pendingReplace = nil
                Task { await finishLogin(token: token) }
            }
            Button("取消", role: .cancel) {
                message = "未保存本次登录。如需换账户,请先在设置里「登录新账户」"
            }
        } message: { pending in
            Text("本次登录的是 \(Self.hint(pending.newSub)),该槽当前是 \(Self.hint(pending.oldSub))。" +
                 "替换后原账户登录态将被覆盖(之后可用「登录新账户」把它加回来)。")
        }
    }

    /// 身份尾缀(与卡片副标题口径一致,取 sub 后 6 位)。
    private static func hint(_ sub: String?) -> String {
        guard let sub, sub.count > 6 else { return "未知身份" }
        return "…\(sub.suffix(6))"
    }

    /// 轮询抓到 web JWT:先做身份判定,再决定直接落槽 / 请求确认 / 拒绝。
    private func handleLoginSuccess(accessToken: String, refreshToken: String) async {
        guard accessToken != lastHandledToken, !loading, pendingReplace == nil else { return }
        lastHandledToken = accessToken
        let token = KimiUsageService.KimiWebToken(
            accessToken: accessToken, refreshToken: refreshToken,
            expiresAt: Date().timeIntervalSince1970 + 900
        )
        let newSub = KimiUsageService.jwtSubject(accessToken)
        let slotSub = KimiUsageService.loadWebToken(accountID: accountID)
            .flatMap { KimiUsageService.jwtSubject($0.accessToken) }
        let others = model.kimiAccounts
            .filter { $0.id != accountID }
            .map { account in
                KimiUsageService.KimiSlotSubject(
                    id: account.id,
                    sub: KimiUsageService.loadWebToken(accountID: account.id)
                        .flatMap { KimiUsageService.jwtSubject($0.accessToken) }
                )
            }
        switch KimiUsageService.judgeLoginIdentity(newSub: newSub, slotSub: slotSub, otherSlots: others) {
        case .proceed:
            await finishLogin(token: token)
        case .replaceConfirmation(let oldSub, let newSub):
            pendingReplace = PendingReplace(token: token, oldSub: oldSub, newSub: newSub)
        case .duplicateOf(let otherID):
            let label = model.kimiAccounts.first(where: { $0.id == otherID })?.label ?? otherID
            message = "该账户已在列表中(\(label)),本次未保存。请在下方网页退出当前账号,登录另一个账户"
        }
    }

    /// 身份放行后:写该账户的槽,刷新数据,关闭窗口。
    private func finishLogin(token: KimiUsageService.KimiWebToken) async {
        loading = true
        message = "正在获取用量配置..."
        KimiUsageService.saveWebToken(token, accountID: accountID)
        if accountID != "main", let label = newAccountLabel {
            model.addKimiAccount(KimiAccount(id: accountID, label: label))
        } else if !model.kimiAccounts.contains(where: { $0.id == "main" }) {
            // main 曾被移除 → 本次登录重新登记(addKimiAccount 自带刷新)
            model.addKimiAccount(KimiAccount(id: "main", label: "账户1"))
        } else {
            await model.refreshKimi(force: true)
        }
        if model.kimiQuota != nil {
            message = "登录成功!月度额度已同步"
        } else {
            message = "登录成功,但用量拉取失败(可稍后刷新)"
        }
        loading = false
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        dismiss()
    }
}

/// WKWebView 包装:加载 www.kimi.com/code/console,轮询 localStorage 抓 web JWT。
struct KimiWebView: NSViewRepresentable {
    let onLoginSuccess: (String, String) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // 多账户安全(2026-10-24):非持久 store——登录窗不携带上一个账户的网页登录态。
        // 若共享 default store,「添加账户」窗口一打开就会抓到旧账户 token 秒成功,
        // 把旧账户伪装成新账户登记。代价是每次登录都要完整输入(登录窗的本职)。
        config.websiteDataStore = WKWebsiteDataStore.nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"
        if let url = URL(string: "https://www.kimi.com/code/console") {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: KimiWebView
        init(_ parent: KimiWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            pollLocalStorage(webView)
        }

        /// 轮询 localStorage 的 access_token / refresh_token(登录后写入)。
        private func pollLocalStorage(_ webView: WKWebView) {
            let js = """
            (function() {
                var at = localStorage.getItem('access_token');
                var rt = localStorage.getItem('refresh_token');
                if (at && rt && at.length > 50 && rt.length > 50) {
                    return JSON.stringify({at: at, rt: rt});
                }
                return null;
            })();
            """
            webView.evaluateJavaScript(js) { [weak self] result, _ in
                guard let self else { return }
                if let str = result as? String, let data = str.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let at = obj["at"] as? String, let rt = obj["rt"] as? String {
                    DispatchQueue.main.async {
                        self.parent.onLoginSuccess(at, rt)
                    }
                    return
                }
                // 未登录,3 秒后再查
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    self.pollLocalStorage(webView)
                }
            }
        }
    }
}
