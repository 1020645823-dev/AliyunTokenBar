import SwiftUI
import WebKit
import AliyunTokenBarCore

/// 小米 MiMo 平台登录窗口:内嵌 WKWebView 让用户在窗内完成平台登录,
/// 登录后从 `WKWebsiteDataStore` 的 Cookie 仓库抓**两域** Cookie:
///   - platform.xiaomimimo.com → 控制台 API 认证
///   - account.xiaomi.com / .xiaomi.com → `passToken`,用于会话静默续期
///
/// 这样用户永远不需要手工复制 Cookie 请求头,且会话过期后 App 能自行续期。
@MainActor
struct MiMoLoginView: View {
    @StateObject private var model = TokenPlanModel.shared
    @State private var loading = false
    @State private var message = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DesignTokens.spacingS) {
                Image(systemName: "waveform").foregroundStyle(Color.atbBrandMiMo)
                Text("登录小米 MiMo 开放平台").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(ATBTextButtonStyle(color: .atbTextSecondary))
            }
            .padding(DesignTokens.spacingM)

            Text("登录后会自动保存平台与小米账号两域 Cookie。"
                 + "小米账号的 passToken 让 App 在登录态过期时自动续期,无需再手工复制 Cookie。")
                .font(.system(size: 10))
                .foregroundStyle(Color.atbTextSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DesignTokens.spacingM)
                .padding(.bottom, DesignTokens.spacingS)

            MiMoWebView(onJarReady: { jar in
                Task { await handleLoginSuccess(jar: jar) }
            })
            .frame(minWidth: 520, minHeight: 620)

            if loading {
                HStack(spacing: DesignTokens.spacingS) {
                    LoadingRing().frame(width: 14, height: 14)
                    Text(message.isEmpty ? "正在保存凭据..." : message)
                        .font(.system(size: 12)).foregroundStyle(.atbTextSecondary)
                }
                .padding(DesignTokens.spacingM - 2)
            } else if !message.isEmpty {
                Text(message).font(.system(size: 12)).foregroundStyle(.atbTextSecondary)
                    .padding(DesignTokens.spacingM - 2)
            }
        }
        .background(Color.atbPanelBackground)
    }

    private func handleLoginSuccess(jar: MiMoCookieJar) async {
        loading = true
        message = "正在校验控制台凭据..."
        model.mimoJar = jar
        await model.refreshMiMo(force: true)
        if model.mimoUsage != nil {
            message = jar.canRenew ? "登录成功,已启用自动续期" : "登录成功(未取到 passToken,过期后需重新登录)"
        } else {
            message = "已保存凭据,但用量拉取失败:\(model.mimoError ?? "未知原因")"
        }
        loading = false
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        dismiss()
    }
}

/// WKWebView 包装:加载平台余额页,轮询 `WKWebsiteDataStore` 里的 Cookie 组 jar。
struct MiMoWebView: NSViewRepresentable {
    let onJarReady: (MiMoCookieJar) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()   // 默认 store 保留登录态
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"
        if let url = URL(string: "https://platform.xiaomimimo.com/#/console/balance") {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: MiMoWebView
        private var done = false
        init(_ parent: MiMoWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            pollCookies(webView)
        }

        /// 轮询 Cookie 仓库:platform 段出现 serviceToken + userId 即视为登录完成。
        private func pollCookies(_ webView: WKWebView) {
            guard !done else { return }
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self, !self.done else { return }
                if let jar = Self.makeJar(from: cookies) {
                    self.done = true
                    DispatchQueue.main.async { self.parent.onJarReady(jar) }
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    guard let self, !self.done else { return }
                    self.pollCookies(webView)
                }
            }
        }

        /// Cookie 列表 → 两域 jar。platform 段缺必需 cookie 返回 nil(继续等登录)。
        static func makeJar(from cookies: [HTTPCookie]) -> MiMoCookieJar? {
            let platform = cookies.filter { $0.domain.contains("xiaomimimo.com") }
            // account 段要的是小米账号域;排除 xiaomimimo 自己(它也含 "xiaomi" 子串)
            let account = cookies.filter {
                $0.domain.contains("xiaomi.com") && !$0.domain.contains("xiaomimimo.com")
            }
            let platformHeader = MiMoCookieJar.header(from: Dictionary(
                platform.map { ($0.name, $0.value) }, uniquingKeysWith: { _, new in new }))
            let accountHeader = MiMoCookieJar.header(from: Dictionary(
                account.map { ($0.name, $0.value) }, uniquingKeysWith: { _, new in new }))
            guard MiMoUsageService.normalizedCookie(from: platformHeader) != nil else { return nil }
            return MiMoCookieJar(platformHeader: platformHeader, accountHeader: accountHeader)
        }
    }
}
