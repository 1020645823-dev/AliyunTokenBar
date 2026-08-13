import SwiftUI
import AppKit
import AliyunTokenBarCore

@MainActor
final class AliyunAKSKWindowManager {
    static let shared = AliyunAKSKWindowManager()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: AliyunAKSKInputView(onDismiss: { [weak self] in
                self?.window?.close()
            }))
            let w = NSWindow(contentViewController: hosting)
            w.title = "CodingTokenBar · 阿里云登录"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 420, height: 390))
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - 阿里云 OpenAPI AK/SK 输入视图

struct AliyunAKSKInputView: View {
    let onDismiss: () -> Void
    @StateObject private var model = TokenPlanModel.shared
    @State private var accessKeyID = ""
    @State private var accessKeySecret = ""
    @State private var showSecret = false
    @State private var errorMessage: String?
    @State private var isConfiguring = false
    @State private var didSucceed = false

    private let accessKeyURL = URL(string: "https://ram.console.aliyun.com/manage/ak")!

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingXL - DesignTokens.spacingXS) {
            header
            intro
            credentialFields
            if let errorMessage {
                statusRow(icon: "exclamationmark.triangle.fill", color: .atbCritical,
                          text: errorMessage)
            }
            if didSucceed {
                statusRow(icon: "checkmark.circle.fill", color: .atbSuccess,
                          text: "已连接，正在刷新百炼用量…")
            }
            actions
        }
        .padding(DesignTokens.spacingXL)
        .frame(width: 420, height: 390)
        .background(Color.atbPanelBackground)
    }

    private var header: some View {
        HStack(spacing: DesignTokens.spacingM - 2) {
            Image(systemName: "key.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.atbBlue)
            VStack(alignment: .leading, spacing: 2) {
                Text("连接阿里云百炼")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.atbTextPrimary)
                Text("用 OpenAPI 凭据自动续期登录状态")
                    .font(.system(size: 11))
                    .foregroundStyle(.atbTextSecondary)
            }
            Spacer()
            Button("关闭") { onDismiss() }
                .buttonStyle(ATBTextButtonStyle(color: .atbTextSecondary))
                .accessibilityLabel("关闭阿里云登录窗口")
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingS) {
            Text("只需配置一次。凭据保存在系统钥匙串，CodingTokenBar 不会把 Secret 写入命令行参数或日志。")
                .font(.system(size: 11))
                .foregroundStyle(.atbTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DesignTokens.spacingXS) {
                Text("所需权限：")
                    .font(.system(size: 11))
                    .foregroundStyle(.atbTextSecondary)
                Text("AliyunBailianReadOnlyAccess")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.atbTextPrimary)
                Spacer()
                Link("打开 AccessKey 管理", destination: accessKeyURL)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.atbBlue)
                    .accessibilityLabel("打开阿里云 AccessKey 管理")
            }
        }
    }

    private var credentialFields: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingS + 2) {
            Text("AccessKey")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.atbTextPrimary)
            TextField("LTAI...", text: $accessKeyID)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .disabled(isConfiguring)
                .accessibilityLabel("AccessKey ID")
            HStack(spacing: DesignTokens.spacingS) {
                Group {
                    if showSecret {
                        TextField("AccessKey Secret", text: $accessKeySecret)
                    } else {
                        SecureField("AccessKey Secret", text: $accessKeySecret)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .disabled(isConfiguring)
                Button {
                    showSecret.toggle()
                } label: {
                    Image(systemName: showSecret ? "eye.slash" : "eye")
                        .foregroundStyle(.atbTextSecondary)
                }
                .buttonStyle(.plain)
                .help(showSecret ? "隐藏 Secret" : "显示 Secret")
                .accessibilityLabel(showSecret ? "隐藏 AccessKey Secret" : "显示 AccessKey Secret")
            }
            Text("AccessKey ID 通常以 LTAI 开头；Secret 仅用于本机加密签名。")
                .font(.system(size: 10))
                .foregroundStyle(.atbTextTertiary)
        }
    }

    private var actions: some View {
        HStack {
            Spacer()
            Button("取消") { onDismiss() }
                .buttonStyle(ATBTextButtonStyle(color: .atbTextSecondary))
                .disabled(isConfiguring)
            Button {
                Task { await configure() }
            } label: {
                HStack(spacing: DesignTokens.spacingS - 2) {
                    if isConfiguring { ProgressView().controlSize(.small) }
                    Text(isConfiguring ? "正在验证…" : "保存并验证")
                }
            }
            .buttonStyle(ATBPrimaryButtonStyle())
            .disabled(isConfiguring || accessKeyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || accessKeySecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .keyboardShortcut(.defaultAction)
        }
    }

    private func statusRow(icon: String, color: Color, text: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).font(.system(size: 11)).foregroundStyle(color)
        }
        .accessibilityElement(children: .combine)
    }

    private func configure() async {
        isConfiguring = true
        errorMessage = nil
        didSucceed = false
        defer { isConfiguring = false }

        let id = accessKeyID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = accessKeySecret.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = await model.configureAliyun(accessKeyID: id, accessKeySecret: secret)
        switch result {
        case .success:
            didSucceed = true
            try? await Task.sleep(nanoseconds: 700_000_000)
            onDismiss()
        case .failure(let error):
            errorMessage = message(for: error)
        }
    }

    private func message(for error: BlAuthError) -> String {
        switch error {
        case .unauthorized:
            return "AK/SK 无效或缺少百炼权限。请检查权限后重试。"
        case .invalidResponse:
            return "凭据格式无效，请检查输入内容。"
        case .network:
            return "网络连接失败，请稍后重试。"
        case .verification:
            return "验证失败，请检查 AK/SK 和百炼权限。"
        case .missingCredential:
            return "请填写完整的 AK/SK。"
        }
    }
}
