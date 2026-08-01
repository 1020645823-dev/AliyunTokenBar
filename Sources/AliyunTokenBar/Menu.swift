import SwiftUI
import AppKit
import AliyunTokenBarCore

// MARK: - 主面板

struct TokenPlanMenu: View {
    @StateObject private var model = TokenPlanModel.shared
    @StateObject private var sparkle = SparkleUpdater.shared
    private let consoleURL = URL(string: "https://bailian.console.aliyun.com/cn-beijing?tab=plan#/efm/subscription/token-plan/personal")!

    var body: some View {
        VStack(spacing: 14) {
            header
            if model.authState == .ok || model.authState == .unknown {
                usageSection
            }
            actionButtons
            if let sub = model.quota?.subscription { subscriptionRow(sub) }
            updateRow
        }
        .padding(16)
        .frame(width: 340)
        .background(Color.atbPanelBackground)
        .overlay { if needsAuthOverlay { AuthOverlay() } }
        .task {
            await model.checkAuthAndRefresh()
            sparkle.checkForUpdateInformation()
        }
    }

    /// 更新状态行:有新版本可点击安装,否则点击手动检查
    private var updateRow: some View {
        HStack(spacing: 6) {
            Image(systemName: sparkle.isUpdateReadyToRestart ? "arrow.triangle.2.circlepath" : "sparkles")
                .font(.system(size: 11)).foregroundStyle(.atbTextTertiary)
            if sparkle.isUpdateReadyToRestart {
                Text("新版本已就绪,点击重启安装").font(.system(size: 11)).foregroundStyle(.orange)
                Spacer()
                Text("重启").font(.system(size: 11, weight: .medium)).foregroundStyle(.atbBlue)
                    .onTapGesture { sparkle.restartToInstallUpdate() }
            } else if sparkle.isUpdateAvailable {
                Text("发现新版本").font(.system(size: 11)).foregroundStyle(.orange)
                Spacer()
                Text("更新").font(.system(size: 11, weight: .medium)).foregroundStyle(.atbBlue)
                    .onTapGesture { sparkle.showStandardUpdateUI() }
            } else if sparkle.didDownloadFail {
                Text("更新下载失败").font(.system(size: 11)).foregroundStyle(.red)
                Spacer()
                Text("重试").font(.system(size: 11, weight: .medium)).foregroundStyle(.atbBlue)
                    .onTapGesture { sparkle.showStandardUpdateUI() }
            } else {
                Text("检查更新").font(.system(size: 11)).foregroundStyle(.atbTextTertiary)
                Spacer()
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.atbCardBackground))
        .contentShape(Rectangle())
        .onTapGesture {
            if !sparkle.isUpdateAvailable && !sparkle.isUpdateReadyToRestart {
                sparkle.showStandardUpdateUI()
            }
        }
    }

    private var needsAuthOverlay: Bool {
        model.authState == .blNotInstalled || model.authState == .notLoggedIn || model.authState == .expired
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "speedometer")
                .font(.system(size: 24))
                .foregroundStyle(.atbBlue)
            Text("AliyunTokenBar").font(.system(size: 18, weight: .bold)).foregroundStyle(.atbTextPrimary)
            Spacer()
            Button { NSWorkspace.shared.open(consoleURL) } label: {
                Image(systemName: "arrow.up.right.square").foregroundStyle(.atbTextTertiary)
            }.buttonStyle(.plain)
        }
    }

    private var usageSection: some View {
        HStack(spacing: 12) {
            if let q = model.quota {
                UsageCard(title: "5小时限额", detail: q.usage.fiveHour, color: .atbBlue, isLoading: model.isLoading)
                UsageCard(title: "7天限额", detail: q.usage.oneWeek, color: .orange, isLoading: model.isLoading)
            } else if model.isLoading {
                Spacer(); LoadingRing(); Spacer()
            } else {
                Text(model.lastError ?? "加载中…").foregroundStyle(.atbTextSecondary)
            }
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            ActionButton(title: "刷新", icon: "arrow.clockwise") { Task { await model.refreshFull() } }
            ActionButton(title: "控制台", icon: "globe") { NSWorkspace.shared.open(consoleURL) }
            ActionButton(title: "设置", icon: "gearshape") { SettingsWindowManager.shared.show() }
            ActionButton(title: "退出", icon: "power") { NSApplication.shared.terminate(nil) }
        }
    }

    private func subscriptionRow(_ sub: SubscriptionDetail) -> some View {
        HStack(spacing: 8) {
            Text("\(sub.specDisplay) 套餐").font(.system(size: 13, weight: .medium)).foregroundStyle(.atbTextPrimary)
            tagPill(sub.statusDisplay, color: .green)
            Spacer()
            Text("剩余 \(sub.remainingDays) 天").font(.system(size: 12)).foregroundStyle(.atbTextSecondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.atbCardBackground))
    }

    private func tagPill(_ text: String, color: Color) -> some View {
        Text(text).font(.system(size: 9, weight: .medium)).foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - 用量卡片(复刻 KimiCodeBar UsageCard)

struct UsageCard: View {
    let title: String
    let detail: UsageDetail
    let color: Color
    let isLoading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(.atbTextPrimary)
            ZStack(alignment: .leading) {
                if !isLoading {
                    Text("\(detail.percentage)%").font(.system(size: 32, weight: .bold, design: .rounded))
                        .monospacedDigit().foregroundStyle(.atbTextPrimary)
                } else { LoadingRing().frame(width: 24, height: 24) }
            }.frame(height: 38)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().frame(height: 4).foregroundStyle(Color.atbTextPrimary.opacity(0.10))
                    Capsule().frame(width: proxy.size.width * CGFloat(min(detail.percentage, 100)) / 100, height: 4)
                        .foregroundStyle(color)
                }
            }.frame(height: 4)
            Text(detail.timeUntilReset).font(.system(size: 11)).foregroundStyle(.atbTextSecondary)
        }
        .padding(14).frame(maxWidth: .infinity)
        .background(Color.atbCardBackground).clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - 鉴权遮罩

struct AuthOverlay: View {
    @StateObject private var model = TokenPlanModel.shared
    var body: some View {
        ZStack {
            Color.atbPanelBackground.opacity(0.94)
            VStack(spacing: 14) {
                Image(systemName: iconName).font(.system(size: 40)).foregroundStyle(.orange)
                Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(.atbTextPrimary)
                Text(hint).font(.system(size: 12)).foregroundStyle(.atbTextSecondary).multilineTextAlignment(.center)
                if model.authState != .blNotInstalled {
                    Button("重新登录") { BlAuthManager.relogin() }
                        .buttonStyle(.plain).foregroundStyle(.white)
                        .padding(.horizontal, 20).padding(.vertical, 8)
                        .background(Color.atbBlue).clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }.padding(24)
        }
    }
    private var iconName: String { model.authState == .blNotInstalled ? "exclamationmark.triangle" : "lock.rotation" }
    private var title: String {
        switch model.authState {
        case .blNotInstalled: return "未检测到 bl CLI"
        case .notLoggedIn: return "请先登录百炼控制台"
        case .expired: return "控制台登录已过期"
        default: return ""
        }
    }
    private var hint: String {
        switch model.authState {
        case .blNotInstalled: return "请在终端安装:npm install -g bailian-cli"
        case .notLoggedIn: return "点击下方登录(将打开浏览器授权)"
        case .expired: return "token 已失效,点击下方重新登录"
        default: return ""
        }
    }
}

// MARK: - 复用小组件

struct ActionButton: View {
    let title: String; let icon: String; let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 16))
                Text(title).font(.system(size: 11))
            }.frame(maxWidth: .infinity).padding(.vertical, 8).foregroundStyle(.atbTextSecondary)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.atbCardBackground))
        }.buttonStyle(.plain)
    }
}

struct LoadingRing: View {
    @State private var rotate = false
    var body: some View {
        Image(systemName: "circle.dashed")
            .rotationEffect(.degrees(rotate ? 360 : 0))
            .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: rotate)
            .onAppear { rotate = true }
    }
}
