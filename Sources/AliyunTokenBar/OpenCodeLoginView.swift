import SwiftUI
import WebKit
import AliyunTokenBarCore

/// OpenCode Go 登录窗口:内嵌 WKWebView 让用户登录 opencode.ai,
/// 登录后打包该域全部 cookie(一个账户一份会话)并自动发现该账户下全部
/// workspace(每个 workspace 是独立订阅/独立配额,2026-10-17)。
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

    /// 登录成功(cookie 拿到)后:存 cookie → 拉取账户下全部 workspace 并入 →
    /// 逐 workspace 拉取用量 → 关闭窗口。
    private func handleLoginSuccess(cookie: String) async {
        loading = true
        message = "正在发现 workspace..."
        model.openCodeCookie = cookie
        let added = await model.discoverOpenCodeWorkspaces()
        if !model.openCodeWorkspaces.isEmpty {
            message = added > 0
                ? "登录成功!已发现 \(model.openCodeWorkspaces.count) 个 workspace(新增 \(added))"
                : "登录成功!\(model.openCodeWorkspaces.count) 个 workspace 已同步"
        } else {
            message = "登录成功,但未发现 workspace(可在卡片里手动添加 wrk_xxx)"
        }
        loading = false
        // 短暂展示后关闭
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        dismiss()
    }
}

/// 登出辅助(P1-D7):清 WKWebsiteDataStore 里 opencode.ai 的 cookies。
/// 登出只删 Keychain 会残留共享 WebView 的登录态(隐私 + 误判登录)。
enum OpenCodeWebCleanup {
    static func clearCookies() {
        WKWebsiteDataStore.default().fetchDataRecords(ofTypes: [WKWebsiteDataTypeCookies]) { records in
            let opencode = records.filter { $0.displayName.contains("opencode.ai") }
            WKWebsiteDataStore.default().removeData(ofTypes: [WKWebsiteDataTypeCookies], for: opencode) {}
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
            // 登录成功判定:落到 console 工作区页(未登录会停在 /console/login)。
            let url = webView.url?.absoluteString ?? ""
            let onConsole = url.contains("/console") && !url.contains("/console/login")
            guard onConsole || url.contains("/workspace/") else { return }
            captureCookies(webView)
        }

        /// 打包 opencode.ai 域全部 cookie 成 Cookie 头。
        /// ⚠️ 不假设会话 cookie 名叫 "auth"(console 会话名可能变化),
        /// 全部带上让服务端自己选(2026-10-17 加固)。
        private func captureCookies(_ webView: WKWebView) {
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                let header = cookies
                    .filter { $0.domain.contains("opencode.ai") }
                    .map { "\($0.name)=\($0.value)" }
                    .joined(separator: "; ")
                guard !header.isEmpty else { return }
                DispatchQueue.main.async {
                    self.parent.onLoginSuccess(header)
                }
            }
        }
    }
}
