import SwiftUI
import AppKit
import AliyunTokenBarCore

// MARK: - 阿里云鉴权内联提示卡

/// 阿里云 tab 内的鉴权异常提示卡(未装 bl / 未登录 / token 失效)。
/// 内联而非全屏遮罩:其他 Provider 标签与面板按钮始终可用
/// (2026-08-03 用户反馈修复:全屏遮罩导致 token 失效时整面板不可用)。
struct AliyunAuthCard: View {
    @StateObject private var model = TokenPlanModel.shared
    @State private var copied = false
    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: DesignTokens.spacingS) {
                Image(systemName: iconName).font(.system(size: 28)).foregroundStyle(.orange)
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(.atbTextPrimary)
                if model.authState == .blNotInstalled {
                    blInstallGuide
                } else {
                    Text(hint).font(.system(size: 11)).foregroundStyle(.atbTextSecondary).multilineTextAlignment(.center)
                    if model.aliyunAKSKConfiguring {
                        HStack(spacing: DesignTokens.spacingS - 2) {
                            ProgressView().controlSize(.small)
                            Text("正在自动恢复登录状态…")
                                .font(.system(size: 10))
                                .foregroundStyle(.atbTextSecondary)
                        }
                    } else {
                        reloginButton
                    }
                    if let failedAt = model.aliyunAutoRecoveryFailedAt,
                       AliyunAuthRecovery.inCooldown(
                           failedAt: failedAt, now: Date(),
                           cooldownMinutes: max(model.refreshIntervalMinutes * 2, 10)) {
                        Text("自动恢复已暂停，稍后将重试。如需立即恢复请点击「使用 AK/SK 配置」。")
                            .font(.system(size: 10))
                            .foregroundStyle(.atbTextTertiary)
                            .multilineTextAlignment(.center)
                    }
                    if !model.aliyunAKSKConfigured && !model.aliyunAKSKConfiguring {
                        Button {
                            AliyunAKSKWindowManager.shared.show()
                        } label: {
                            Label("使用 AK/SK 配置（推荐，自动刷新）", systemImage: "key.fill")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(ATBTextButtonStyle())
                        .padding(.top, DesignTokens.spacingXS)
                        .help("配置一次后自动续期阿里云登录状态")
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(DesignTokens.spacingL)
            .background(Color.atbCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusL))
            .shadow(color: Color.black.opacity(0.04), radius: 2, y: 1)
        }
    }

    /// 重新登录按钮:点击后拉起浏览器并轮询,登录完成自动恢复数据(无需手动操作)。
    private var reloginButton: some View {
        VStack(spacing: DesignTokens.spacingS - 2) {
            Button {
                model.relogin()
            } label: {
                HStack(spacing: DesignTokens.spacingS - 2) {
                    if model.isReloginWatching { LoadingRing().frame(width: 12, height: 12) }
                    Text("重新登录")
                }
            }
            .buttonStyle(ATBPrimaryButtonStyle())
            if model.isReloginWatching {
                Text("已打开浏览器,登录完成后自动刷新…")
                    .font(.system(size: 10)).foregroundStyle(.atbTextTertiary)
            }
        }
    }

    /// 未装 bl 时的安装引导:安装命令(可复制)+ Node.js 要求链接
    private var blInstallGuide: some View {
        VStack(spacing: DesignTokens.spacingS + 2) {
            Text("CodingTokenBar 依赖百炼 CLI (bl) 获取套餐用量,但未检测到 bl。")
                .font(.system(size: 12)).foregroundStyle(.atbTextSecondary)
                .multilineTextAlignment(.center)
            // 安装命令框
            HStack(spacing: DesignTokens.spacingS) {
                Text("npm install -g bailian-cli")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.atbTextPrimary)
                    .padding(.horizontal, DesignTokens.spacingM).padding(.vertical, DesignTokens.spacingS - 2)
                    .background(Color.atbSeparator)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusS))
                    .textSelection(.enabled)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("npm install -g bailian-cli", forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12)).foregroundStyle(.atbTextSecondary)
                }.buttonStyle(.plain)
            }
            // Node.js 要求 + 官方文档链接
            VStack(spacing: DesignTokens.spacingXS) {
                Text("需要 Node.js 18+").font(.system(size: 10)).foregroundStyle(.atbTextTertiary)
                HStack(spacing: DesignTokens.spacingL - DesignTokens.spacingXS) {
                    Link("Node.js 下载", destination: URL(string: "https://nodejs.org/")!)
                        .font(.system(size: 11)).foregroundStyle(.atbBlue)
                    Link("百炼 CLI 文档", destination: URL(string: "https://bailian.console.aliyun.com/cli/install.md")!)
                        .font(.system(size: 11)).foregroundStyle(.atbBlue)
                }
            }
            Text("安装后重启 CodingTokenBar").font(.system(size: 10)).foregroundStyle(.atbTextTertiary)
        }
    }

    private var iconName: String { model.authState == .blNotInstalled ? "exclamationmark.triangle" : "lock.rotation" }
    private var title: String {
        switch model.authState {
        case .blNotInstalled: return "无法使用:未安装 bl CLI"
        case .notLoggedIn: return "请先登录百炼控制台"
        case .expired: return "控制台登录已过期"
        default: return ""
        }
    }
    private var hint: String {
        switch model.authState {
        case .notLoggedIn: return "点击下方登录(将打开浏览器授权)"
        case .expired: return "token 已失效,点击下方重新登录"
        default: return ""
        }
    }
}

