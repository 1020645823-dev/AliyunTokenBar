import SwiftUI
import WebKit
import AliyunTokenBarCore

/// OpenCode Go 登录窗口:内嵌 WKWebView 让用户登录 opencode.ai,
/// 登录后自动从 cookieStore 抓 auth cookie + 发现 workspace ID。
@MainActor
struct OpenCodeLoginView: View {
    @StateObject private var model = TokenPlanModel.shared
    @State private var loading = false
    @State private var message = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // 顶栏
            HStack(spacing: DesignTokens.spacingS) {
                Image(systemName: "bolt.fill").foregroundStyle(.purple)
                Text("登录 OpenCode Go").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(ATBTextButtonStyle(color: .atbTextSecondary))
            }
            .padding(DesignTokens.spacingM)

            // WebView
            OpenCodeWebView(
                onLoginSuccess: { cookie in
                    Task { await handleLoginSuccess(cookie: cookie) }
                }
            )
            .frame(minWidth: 480, minHeight: 600)

            // 状态
            if loading {
                HStack(spacing: DesignTokens.spacingS) {
                    LoadingRing().frame(width: 14, height: 14)
                    Text(message.isEmpty ? "正在获取用量配置..." : message)
                        .font(.system(size: 12)).foregroundStyle(.atbTextSecondary)
                }
                .padding(DesignTokens.spacingM - 2)
            } else if !message.isEmpty {
                Text(message).font(.system(size: 12)).foregroundStyle(.atbTextSecondary).padding(DesignTokens.spacingM - 2)
            }
        }
        .background(Color.atbPanelBackground)
    }

    /// 登录成功(cookie 拿到)后:发现 workspace ID,存配置,关闭窗口。
    private func handleLoginSuccess(cookie: String) async {
        loading = true
        message = "正在获取 workspace..."
        // 用 cookie 发现 workspace ID
        if let wsID = await OpenCodeUsageService.discoverWorkspaceID(cookie: cookie) {
            model.openCodeCookie = cookie
            model.openCodeWorkspaceID = wsID
            message = "登录成功!workspace: \(wsID)"
            await model.refreshOpenCode()
            loading = false
            // 短暂展示后关闭
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            dismiss()
        } else {
            loading = false
            message = "登录成功但未找到 workspace,请在设置手动填 workspace ID(wrk_xxx)"
            // cookie 还是存上
            model.openCodeCookie = cookie
        }
    }
}

/// WKWebView 包装:加载 opencode.ai/auth,监听 cookie + URL 变化。
struct OpenCodeWebView: NSViewRepresentable {
    let onLoginSuccess: (String) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()  // 用默认 store 保留登录态
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"
        if let url = URL(string: "https://opencode.ai/auth") {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: OpenCodeWebView
        init(_ parent: OpenCodeWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // 每次页面加载完,检查 cookie 里有没有 auth
            checkAuthCookie(webView)
        }

        private func checkAuthCookie(_ webView: WKWebView) {
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                for c in cookies {
                    // 找 opencode.ai 域的 auth cookie
                    if c.name == "auth" && (c.domain.contains("opencode.ai")) {
                        let cookieValue = "auth=\(c.value)"
                        DispatchQueue.main.async {
                            self.parent.onLoginSuccess(cookieValue)
                        }
                        return
                    }
                }
            }
        }
    }
}
