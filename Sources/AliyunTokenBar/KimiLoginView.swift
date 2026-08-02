import SwiftUI
import WebKit
import AliyunTokenBarCore

/// Kimi Code 网页控制台登录窗口:内嵌 WKWebView 让用户登录 www.kimi.com,
/// 登录后从 localStorage 抓 web JWT(access_token + refresh_token),用于月度总额度。
@MainActor
struct KimiLoginView: View {
    @StateObject private var model = TokenPlanModel.shared
    @State private var loading = false
    @State private var message = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // 顶栏
            HStack {
                Image(systemName: "sparkles").foregroundStyle(.teal)
                Text("登录 Kimi 网页控制台").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("取消") { dismiss() }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(12)

            // WebView
            KimiWebView(
                onLoginSuccess: { accessToken, refreshToken in
                    Task { await handleLoginSuccess(accessToken: accessToken, refreshToken: refreshToken) }
                }
            )
            .frame(minWidth: 480, minHeight: 600)

            // 状态
            if loading {
                HStack(spacing: 8) {
                    LoadingRing().frame(width: 14, height: 14)
                    Text(message.isEmpty ? "正在获取用量配置..." : message)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .padding(10)
            } else if !message.isEmpty {
                Text(message).font(.system(size: 12)).foregroundStyle(.secondary).padding(10)
            }
        }
        .background(Color.atbPanelBackground)
    }

    /// 登录成功(web JWT 拿到)后:存 Keychain,刷新数据,关闭窗口。
    private func handleLoginSuccess(accessToken: String, refreshToken: String) async {
        loading = true
        message = "正在获取用量配置..."
        let token = KimiUsageService.KimiWebToken(accessToken: accessToken, refreshToken: refreshToken, expiresAt: Date().timeIntervalSince1970 + 900)
        KimiUsageService.saveWebToken(token)
        await model.refreshKimi()
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
        config.websiteDataStore = WKWebsiteDataStore.default()  // 用默认 store 保留登录态
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