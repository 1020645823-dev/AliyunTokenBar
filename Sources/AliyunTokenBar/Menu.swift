import SwiftUI
import AppKit
import AliyunTokenBarCore

// MARK: - 阿里云风格云朵 logo

/// 风格化阿里云云朵 logo(橙色,Canvas 绘制)。
/// 视觉:底部平直、顶部三个圆弧隆起的抽象云朵,呼应阿里云标志性视觉。
struct AliyunCloudLogo: View {
    var size: CGFloat = 28
    var body: some View {
        Canvas { ctx, sz in
            // 云朵路径:用多个圆弧拼出底部平、顶部三隆起的云形
            let w = sz.width, h = sz.height
            var path = Path()
            // 从左下起,顺时针:左弧 → 左上凸起 → 中间大凸起 → 右上凸起 → 右弧 → 底部直线回起点
            path.move(to: CGPoint(x: w*0.10, y: h*0.70))
            // 左侧弧(上行)
            path.addQuadCurve(to: CGPoint(x: w*0.22, y: h*0.42),
                              control: CGPoint(x: w*0.04, y: h*0.45))
            // 左上小凸起
            path.addQuadCurve(to: CGPoint(x: w*0.38, y: h*0.28),
                              control: CGPoint(x: w*0.24, y: h*0.22))
            // 中间大凸起(最高点)
            path.addQuadCurve(to: CGPoint(x: w*0.55, y: h*0.18),
                              control: CGPoint(x: w*0.44, y: h*0.12))
            path.addQuadCurve(to: CGPoint(x: w*0.70, y: h*0.28),
                              control: CGPoint(x: w*0.66, y: h*0.14))
            // 右上凸起
            path.addQuadCurve(to: CGPoint(x: w*0.85, y: h*0.40),
                              control: CGPoint(x: w*0.86, y: h*0.22))
            // 右侧弧(下行)
            path.addQuadCurve(to: CGPoint(x: w*0.90, y: h*0.70),
                              control: CGPoint(x: w*1.00, y: h*0.50))
            // 底部直线回起点
            path.addLine(to: CGPoint(x: w*0.10, y: h*0.70))
            path.closeSubpath()
            // 填充阿里云橙
            ctx.fill(path, with: .color(Color(red: 1.0, green: 0.42, blue: 0.0)))
        }
        .frame(width: size, height: size * 0.78)
    }
}

// MARK: - 主面板

/// 面板 Provider 标签页(节省空间:三个 Provider 上下堆叠会超出屏幕)。
enum ProviderTab: String, CaseIterable, Identifiable {
    case aliyun
    case opencode
    case kimi
    var id: String { rawValue }
    var title: String {
        switch self {
        case .aliyun: return "阿里云"
        case .opencode: return "OpenCode"
        case .kimi: return "Kimi"
        }
    }
    var icon: String {
        switch self {
        case .aliyun: return "cloud.fill"
        case .opencode: return "bolt.fill"
        case .kimi: return "sparkles"
        }
    }
}

struct TokenPlanMenu: View {
    @StateObject private var model = TokenPlanModel.shared
    @State private var selectedTab: ProviderTab = .aliyun
    private let consoleURL = URL(string: "https://bailian.console.aliyun.com/cn-beijing?tab=plan#/efm/subscription/token-plan/personal")!

    /// 当前可用的标签页(阿里云恒有;OpenCode/Kimi 配置了才显示)。
    private var availableTabs: [ProviderTab] {
        var tabs: [ProviderTab] = [.aliyun]
        if model.openCodeConfigured { tabs.append(.opencode) }
        if model.kimiConfigured { tabs.append(.kimi) }
        return tabs
    }

    /// 实际生效的标签(选中项不可用时回退阿里云)。
    private var effectiveTab: ProviderTab {
        availableTabs.contains(selectedTab) ? selectedTab : .aliyun
    }

    var body: some View {
        VStack(spacing: 12) {
            header
            if model.authState == .ok || model.authState == .unknown {
                providerTabs
                selectedContent
            }
            actionButtons
            if model.authState == .ok { BlVersionRow() }
        }
        .padding(16)
        .frame(width: 340)
        .background(Color.atbPanelBackground)
        .overlay { if needsAuthOverlay { AuthOverlay() } }
        .task {
            // 数据刷新由 AppDelegate 在启动时触发(不等面板打开)。
            // 这里仅确保通知授权(面板可能是应用启动后很久才打开的场景)。
            NotificationManager.shared.requestAuthorization()
        }
    }

    private var needsAuthOverlay: Bool {
        model.authState == .blNotInstalled || model.authState == .notLoggedIn || model.authState == .expired
    }

    private var header: some View {
        HStack(spacing: 12) {
            AliyunCloudLogo(size: 28)
            Text("AliyunTokenBar").font(.system(size: 18, weight: .bold)).foregroundStyle(.atbTextPrimary)
            Spacer()
            Button { NSWorkspace.shared.open(consoleURL) } label: {
                Image(systemName: "arrow.up.right.square").foregroundStyle(.atbTextTertiary)
            }.buttonStyle(.plain)
        }
    }

    // MARK: 标签页切换

    /// 分段式标签栏:三个 Provider 平铺,选中项高亮。
    private var providerTabs: some View {
        HStack(spacing: 4) {
            ForEach(availableTabs) { tab in
                tabButton(tab)
            }
        }
        .padding(3)
        .background(Color.atbCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func tabButton(_ tab: ProviderTab) -> some View {
        let isSelected = effectiveTab == tab
        return Button {
            selectedTab = tab
        } label: {
            HStack(spacing: 4) {
                Image(systemName: tab.icon).font(.system(size: 10))
                Text(tab.title).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(isSelected ? .white : .atbTextSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(isSelected ? Color.atbBlue : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    /// 当前标签页内容。
    @ViewBuilder
    private var selectedContent: some View {
        switch effectiveTab {
        case .aliyun: aliyunContent
        case .opencode: OpenCodeCard()
        case .kimi: KimiCodeCard()
        }
    }

    /// 阿里云内容:5h/7d 用量卡 + 趋势估算 + 套餐信息。
    private var aliyunContent: some View {
        VStack(spacing: 12) {
            usageSection
            if model.sparklineEnabled {
                LimitEstimateLabel()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 2)
            }
            if let sub = model.quota?.subscription { subscriptionRow(sub) }
        }
    }

    private var usageSection: some View {
        // 上下结构(与 OpenCode 三窗口同向),小空间内信息密度更高
        VStack(spacing: 12) {
            if let q = model.quota {
                UsageCard(title: "5小时限额",
                          percentage: q.usage.fiveHour.percentage, resetText: q.usage.fiveHour.resetTimeDisplay,
                          color: .atbBlue, isLoading: model.isLoading, thresholdConfig: model.thresholdConfig,
                          showSparkline: model.sparklineEnabled, sparklineWindow: "5h")
                UsageCard(title: "7天限额",
                          percentage: q.usage.oneWeek.percentage, resetText: q.usage.oneWeek.resetTimeDisplay,
                          color: .orange, isLoading: model.isLoading, thresholdConfig: model.thresholdConfig,
                          showSparkline: model.sparklineEnabled, sparklineWindow: "7d")
            } else if model.isLoading {
                HStack { Spacer(); LoadingRing().frame(width: 18, height: 18); Spacer() }
                    .padding(14)
                    .background(Color.atbCardBackground)
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.black.opacity(0.08)))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            } else if model.lastError != nil {
                // 网络/服务故障:卡片显示横杠(—),表示数值不可用
                UsageCard(title: "5小时限额", percentage: nil, resetText: nil,
                          color: .atbBlue, isLoading: false, thresholdConfig: model.thresholdConfig,
                          dataUnavailable: true)
                UsageCard(title: "7天限额", percentage: nil, resetText: nil,
                          color: .orange, isLoading: false, thresholdConfig: model.thresholdConfig,
                          dataUnavailable: true)
            } else {
                Text("加载中…").foregroundStyle(.atbTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Color.atbCardBackground)
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.black.opacity(0.08)))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            ActionButton(title: "刷新", icon: "arrow.clockwise") {
                Task {
                    await model.refreshFull()
                    await model.refreshOpenCode()
                    await model.refreshKimi()
                }
            }
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
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.black.opacity(0.08)))
    }

    private func tagPill(_ text: String, color: Color) -> some View {
        Text(text).font(.system(size: 9, weight: .medium)).foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - 用量卡片(统一视觉 token:阿里云 5h/7d + OpenCode 三窗口共用)

/// 用量卡片。**所有用量窗口共用此组件**,保证设计 token 完全一致。
/// 数据源与视觉解耦:`percentage`/`resetText` 由调用方从
/// UsageDetail(阿里云)或 OpenCodeWindow(OpenCode)提取。
/// 对齐官方控制台:2 位小数精度 + 带刻度进度条(0/50/90/100) + 完整重置时间。
/// 当 `dataUnavailable` 为 true 时,数值显示为横杠(—),表示服务/网络不可用。
struct UsageCard: View {
    let title: String
    /// 百分比值(0–100 浮点,2 位小数精度)。nil = 加载中。
    let percentage: Double?
    let resetText: String?
    let color: Color
    let isLoading: Bool
    /// 阈值配置:进度条按风险变色(safe→color / warning→橙 / critical→红)。
    var thresholdConfig: ThresholdConfig = ThresholdConfig()
    /// 是否显示 sparkline(由面板按全局开关传入)。
    var showSparkline: Bool = false
    /// sparkline 数据序列标识(aliyun 5h/7d、opencode rolling/weekly/monthly)。
    var sparklineProvider: String = "aliyun"
    var sparklineWindow: String = "7d"
    /// 紧凑模式:true 单行高密度(推荐,默认);false 全尺寸展开(大字号)。
    var compact: Bool = true
    /// 数据不可用(服务/网络故障):显示横杠而非数值。
    var dataUnavailable: Bool = false

    var body: some View {
        if compact { compactBody } else { fullBody }
    }

    /// 百分比显示文本:2 位小数,对齐官方。
    private var pctDisplayText: String {
        guard let pct = percentage else { return "—" }
        return String(format: "%.2f%%", pct)
    }

    /// 阈值色(用整数部分判定 band,避免 0.26% 误触 warning)。
    private var thresholdPctInt: Int { Int((percentage ?? 0).rounded()) }

    /// 紧凑卡:对齐官方控制台布局——标题+重置时间 / 百分比已用 / 带刻度进度条。
    private var compactBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 上层:标题 + 重置时间
            HStack {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.atbTextPrimary)
                Spacer()
                if dataUnavailable {
                    Text("—").font(.system(size: 10)).foregroundStyle(.atbTextTertiary)
                } else if let reset = resetText {
                    Text("将于 \(reset) 重置刷新")
                        .font(.system(size: 9)).foregroundStyle(.atbTextTertiary)
                        .lineLimit(1)
                }
            }
            // 中层:百分比数值 + "已用" 标签
            HStack(spacing: 4) {
                if isLoading {
                    LoadingRing().frame(width: 14, height: 14)
                } else if dataUnavailable {
                    Text("—").font(.system(size: 15, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.atbTextTertiary)
                } else {
                    Text(pctDisplayText)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(thresholdColor(thresholdPctInt, config: thresholdConfig, base: .atbTextPrimary))
                    Text("已用").font(.system(size: 10)).foregroundStyle(.atbTextTertiary)
                }
            }
            // 下层:带刻度进度条(0% / 50% / 90% / 100%)
            scaledProgressBar
            if showSparkline && !dataUnavailable {
                UsageSparkline(provider: sparklineProvider, window: sparklineWindow, color: color, height: 16)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Color.atbCardBackground)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.black.opacity(0.08)))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// 全尺寸卡:大数字 + 带刻度进度条 + 重置时间 + sparkline。
    private var fullBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(.atbTextPrimary)
            // 百分比数值
            ZStack(alignment: .leading) {
                if isLoading {
                    LoadingRing().frame(width: 24, height: 24)
                } else if dataUnavailable {
                    Text("—").font(.system(size: 32, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.atbTextTertiary)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(pctDisplayText)
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(thresholdColor(thresholdPctInt, config: thresholdConfig, base: .atbTextPrimary))
                        Text("已用").font(.system(size: 12)).foregroundStyle(.atbTextTertiary)
                    }
                }
            }.frame(height: 38)
            // 带刻度进度条
            scaledProgressBar
            // 重置时间
            if dataUnavailable {
                Text("—").font(.system(size: 11)).foregroundStyle(.atbTextTertiary)
            } else if let reset = resetText {
                Text("将于 \(reset) 重置刷新").font(.system(size: 10)).foregroundStyle(.atbTextTertiary)
            }
            if showSparkline && !dataUnavailable {
                UsageSparkline(provider: sparklineProvider, window: sparklineWindow, color: color)
            }
        }
        .padding(14).frame(maxWidth: .infinity)
        .background(Color.atbCardBackground)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.black.opacity(0.08)))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    /// 带刻度标记的进度条:对齐官方 0% / 50% / 90% / 100% 四档刻度线。
    private var scaledProgressBar: some View {
        VStack(spacing: 2) {
            GeometryReader { proxy in
                let w = proxy.size.width
                ZStack(alignment: .leading) {
                    // 底轨
                    Capsule().frame(height: 6).foregroundStyle(Color.black.opacity(0.08))
                    // 填充
                    if !dataUnavailable, let pct = percentage {
                        Capsule()
                            .frame(width: w * CGFloat(min(pct, 100)) / 100, height: 6)
                            .foregroundStyle(thresholdColor(thresholdPctInt, config: thresholdConfig, base: color))
                    }
                    // 刻度线:50% / 90%(0% 和 100% 在两端不需要额外标记)
                    ForEach([50, 90], id: \.self) { tick in
                        Rectangle()
                            .frame(width: 1, height: 10)
                            .foregroundStyle(Color.black.opacity(0.20))
                            .offset(x: w * CGFloat(tick) / 100 - 0.5)
                    }
                }
            }.frame(height: 10)
            // 刻度标签
            HStack(spacing: 0) {
                Text("0%").font(.system(size: 8)).foregroundStyle(.atbTextTertiary)
                Spacer()
                Text("50%").font(.system(size: 8)).foregroundStyle(.atbTextTertiary)
                Spacer()
                Text("90%").font(.system(size: 8)).foregroundStyle(.atbTextTertiary)
                Spacer()
                Text("100%").font(.system(size: 8)).foregroundStyle(.atbTextTertiary)
            }
        }
    }
}

// MARK: - 鉴权遮罩

struct AuthOverlay: View {
    @StateObject private var model = TokenPlanModel.shared
    @State private var copied = false
    var body: some View {
        ZStack {
            Color.atbPanelBackground.opacity(0.94)
            VStack(spacing: 14) {
                Image(systemName: iconName).font(.system(size: 40)).foregroundStyle(.orange)
                Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(.atbTextPrimary)
                if model.authState == .blNotInstalled {
                    blInstallGuide
                } else {
                    Text(hint).font(.system(size: 12)).foregroundStyle(.atbTextSecondary).multilineTextAlignment(.center)
                    Button("重新登录") { BlAuthManager.relogin() }
                        .buttonStyle(.plain).foregroundStyle(.white)
                        .padding(.horizontal, 20).padding(.vertical, 8)
                        .background(Color.atbBlue).clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }.padding(24)
        }
    }

    /// 未装 bl 时的安装引导:安装命令(可复制)+ Node.js 要求链接
    private var blInstallGuide: some View {
        VStack(spacing: 10) {
            Text("AliyunTokenBar 依赖百炼 CLI (bl) 获取套餐用量,但未检测到 bl。")
                .font(.system(size: 12)).foregroundStyle(.atbTextSecondary)
                .multilineTextAlignment(.center)
            // 安装命令框
            HStack(spacing: 8) {
                Text("npm install -g bailian-cli")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.atbTextPrimary)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.atbTextPrimary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
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
            VStack(spacing: 4) {
                Text("需要 Node.js 18+").font(.system(size: 10)).foregroundStyle(.atbTextTertiary)
                HStack(spacing: 12) {
                    Link("Node.js 下载", destination: URL(string: "https://nodejs.org/")!)
                        .font(.system(size: 11)).foregroundStyle(.atbBlue)
                    Link("百炼 CLI 文档", destination: URL(string: "https://bailian.console.aliyun.com/cli/install.md")!)
                        .font(.system(size: 11)).foregroundStyle(.atbBlue)
                }
            }
            Text("安装后重启 AliyunTokenBar").font(.system(size: 10)).foregroundStyle(.atbTextTertiary)
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

/// bl 版本检查行:已装版本 + 有新版本时一键更新(可忽略)。
/// 仅当 bl 已装时显示。
struct BlVersionRow: View {
    @StateObject private var model = TokenPlanModel.shared
    @State private var updating = false
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal").font(.system(size: 11)).foregroundStyle(.atbTextTertiary)
            if let v = model.blInstalledVersion {
                Text("bl \(v)").font(.system(size: 11)).foregroundStyle(.atbTextTertiary)
            } else {
                Text("bl 版本未知").font(.system(size: 11)).foregroundStyle(.atbTextTertiary)
            }
            Spacer()
            if model.blUpdateAvailable, let latest = model.blLatestVersion {
                Text("可更新至 \(latest)").font(.system(size: 10)).foregroundStyle(.orange)
                if updating {
                    LoadingRing().frame(width: 10, height: 10)
                } else {
                    Button("更新") {
                        updating = true
                        BlAuthManager.updateBl()
                        // 开了 Terminal 后,标记一下(实际完成需用户在终端看)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { updating = false }
                    }
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.atbBlue).buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.atbCardBackground))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.black.opacity(0.08)))
    }
}

// MARK: - OpenCode Go 用量卡

/// OpenCode Go 套餐用量(rolling/weekly/monthly 三窗口)。
/// 与阿里云区域共用 UsageCard——同一套设计 token(紧凑卡/进度条/sparkline)。
/// 仅在用户配置了 cookie+workspace 后显示。
struct OpenCodeCard: View {
    @StateObject private var model = TokenPlanModel.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 品牌头部行:紫色闪电 + 刷新(OpenCode 专属)
            HStack(spacing: 8) {
                Image(systemName: "bolt.fill").font(.system(size: 13, weight: .bold)).foregroundStyle(.purple)
                Text("OpenCode Go").font(.system(size: 13, weight: .medium)).foregroundStyle(.atbTextPrimary)
                Spacer()
                Button { Task { await model.refreshOpenCode() } } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 12)).foregroundStyle(.atbTextTertiary)
                }.buttonStyle(.plain)
            }
            if let q = model.openCodeQuota {
                // 三窗口各一张卡片,视觉 token 与阿里云 5h/7d 完全一致
                UsageCard(title: "滚动限额",
                          percentage: Double(q.rolling.pct), resetText: q.rolling.timeUntilReset,
                          color: .purple, isLoading: model.isLoading, thresholdConfig: model.thresholdConfig,
                          showSparkline: model.sparklineEnabled,
                          sparklineProvider: "opencode", sparklineWindow: "rolling")
                UsageCard(title: "每周限额",
                          percentage: Double(q.weekly.pct), resetText: q.weekly.timeUntilReset,
                          color: .atbBlue, isLoading: model.isLoading, thresholdConfig: model.thresholdConfig,
                          showSparkline: model.sparklineEnabled,
                          sparklineProvider: "opencode", sparklineWindow: "weekly")
                UsageCard(title: "每月限额",
                          percentage: Double(q.monthly.pct), resetText: q.monthly.timeUntilReset,
                          color: .orange, isLoading: model.isLoading, thresholdConfig: model.thresholdConfig,
                          showSparkline: model.sparklineEnabled,
                          sparklineProvider: "opencode", sparklineWindow: "monthly")
            } else if let err = model.openCodeError {
                // 网络/服务故障:卡片显示横杠(—),表示数值不可用
                let isNetworkError = err.contains("网络") || err.contains("响应") || err.contains("解析")
                if isNetworkError {
                    UsageCard(title: "滚动限额", percentage: nil, resetText: nil,
                              color: .purple, isLoading: false, thresholdConfig: model.thresholdConfig,
                              dataUnavailable: true)
                    UsageCard(title: "每周限额", percentage: nil, resetText: nil,
                              color: .atbBlue, isLoading: false, thresholdConfig: model.thresholdConfig,
                              dataUnavailable: true)
                    UsageCard(title: "每月限额", percentage: nil, resetText: nil,
                              color: .orange, isLoading: false, thresholdConfig: model.thresholdConfig,
                              dataUnavailable: true)
                } else {
                    // 非网络错误(cookie 过期等):保留文本提示
                    Text(err).font(.system(size: 11)).foregroundStyle(.atbTextTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(Color.atbCardBackground)
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.black.opacity(0.08)))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
            } else {
                // 加载态:与阿里云一致的加载环
                HStack { Spacer(); LoadingRing().frame(width: 18, height: 18); Spacer() }
                    .padding(14)
                    .frame(maxWidth: .infinity)
                    .background(Color.atbCardBackground)
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.black.opacity(0.08)))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.atbPanelBackground)
    }
}

// MARK: - Kimi Code 用量卡

/// Kimi Code 套餐用量(5h/周/月度总额 + 加油包)。
/// 与阿里云/OpenCode 共用 UsageCard——同一套设计 token(2 位小数/带刻度进度条)。
/// 仅在检测到本机 KimiCodeBar / Kimi CLI 凭证后显示。
struct KimiCodeCard: View {
    @StateObject private var model = TokenPlanModel.shared
    @State private var showKimiLogin = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 品牌头部行:青色闪电 + 刷新(Kimi 专属)
            HStack(spacing: 8) {
                Image(systemName: "sparkles").font(.system(size: 13, weight: .bold)).foregroundStyle(.teal)
                Text("Kimi Code").font(.system(size: 13, weight: .medium)).foregroundStyle(.atbTextPrimary)
                if let level = model.kimiQuota?.membershipLevel {
                    Text(levelDisplay(level)).font(.system(size: 9, weight: .medium)).foregroundStyle(.teal)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.teal.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 4))
                }
                Spacer()
                Button { Task { await model.refreshKimi() } } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 12)).foregroundStyle(.atbTextTertiary)
                }.buttonStyle(.plain)
            }
            if let q = model.kimiQuota {
                // 三窗口各一张卡片,视觉 token 与阿里云 5h/7d 完全一致
                UsageCard(title: "5小时限额",
                          percentage: q.fiveHour.pct, resetText: q.fiveHour.resetTimeDisplay,
                          color: .teal, isLoading: model.isLoading, thresholdConfig: model.thresholdConfig,
                          showSparkline: model.sparklineEnabled,
                          sparklineProvider: "kimi", sparklineWindow: "5h")
                UsageCard(title: "每周限额",
                          percentage: q.weekly.pct, resetText: q.weekly.resetTimeDisplay,
                          color: .indigo, isLoading: model.isLoading, thresholdConfig: model.thresholdConfig,
                          showSparkline: model.sparklineEnabled,
                          sparklineProvider: "kimi", sparklineWindow: "weekly")
                if let m = q.monthly {
                    UsageCard(title: "订阅总额度",
                              percentage: m.pct, resetText: q.monthlyResetDisplay,
                              color: .orange, isLoading: model.isLoading, thresholdConfig: model.thresholdConfig,
                              showSparkline: model.sparklineEnabled,
                              sparklineProvider: "kimi", sparklineWindow: "monthly")
                } else if model.kimiWebLoggedIn {
                    UsageCard(title: "订阅总额度", percentage: nil, resetText: nil,
                              color: .orange, isLoading: false, thresholdConfig: model.thresholdConfig,
                              dataUnavailable: true)
                }
                if let booster = q.booster, booster.enabled {
                    KimiBoosterRow(booster: booster)
                }
                if !model.kimiWebLoggedIn {
                    kimiWebLoginHint
                }
            } else if let err = model.kimiError {
                // 网络/服务故障:卡片显示横杠(—),表示数值不可用
                let isNetworkError = err.contains("网络") || err.contains("响应") || err.contains("解析")
                if isNetworkError {
                    UsageCard(title: "5小时限额", percentage: nil, resetText: nil,
                              color: .teal, isLoading: false, thresholdConfig: model.thresholdConfig,
                              dataUnavailable: true)
                    UsageCard(title: "每周限额", percentage: nil, resetText: nil,
                              color: .indigo, isLoading: false, thresholdConfig: model.thresholdConfig,
                              dataUnavailable: true)
                    UsageCard(title: "月度总额度", percentage: nil, resetText: nil,
                              color: .orange, isLoading: false, thresholdConfig: model.thresholdConfig,
                              dataUnavailable: true)
                } else {
                    Text(err).font(.system(size: 11)).foregroundStyle(.atbTextTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(Color.atbCardBackground)
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.black.opacity(0.08)))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
            } else {
                // 加载态:与阿里云一致的加载环
                HStack { Spacer(); LoadingRing().frame(width: 18, height: 18); Spacer() }
                    .padding(14)
                    .frame(maxWidth: .infinity)
                    .background(Color.atbCardBackground)
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.black.opacity(0.08)))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.atbPanelBackground)
    }

    /// 登录网页控制台引导行(未登录时显示,用于获取订阅总额度)。
    private var kimiWebLoginHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.open").font(.system(size: 11)).foregroundStyle(.atbTextTertiary)
            Text("登录 Kimi 网页控制台查看订阅总额度").font(.system(size: 10)).foregroundStyle(.atbTextTertiary)
            Spacer()
            Button("登录") { showKimiLogin = true }
                .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(.teal)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.atbCardBackground))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.black.opacity(0.08)))
        .sheet(isPresented: $showKimiLogin) { KimiLoginView() }
    }

    /// 会员等级映射:LEVEL_* → 官方名称(未知等级去前缀美化)。
    private func levelDisplay(_ level: String) -> String {
        switch level.uppercased() {
        case "LEVEL_FREE": return "Free"
        case "LEVEL_TRIAL", "TRIAL": return "Trial"
        case "LEVEL_BASIC": return "Adagio"
        case "LEVEL_STANDARD": return "Moderato"
        case "LEVEL_INTERMEDIATE": return "Allegretto"
        case "LEVEL_ADVANCED": return "Allegro"
        case "LEVEL_PREMIUM": return "Vivace"
        default:
            let trimmed = level.replacingOccurrences(of: "LEVEL_", with: "", options: .caseInsensitive)
            return trimmed.replacingOccurrences(of: "_", with: " ").lowercased().capitalized
        }
    }
}

/// 加油包余额行:余额 + 本月消费/上限。
struct KimiBoosterRow: View {
    let booster: KimiBooster
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wallet.pass.fill").font(.system(size: 12)).foregroundStyle(.orange)
            Text("加油包余额").font(.system(size: 11, weight: .medium)).foregroundStyle(.atbTextPrimary)
            Text(String(format: "¥%.2f", booster.balanceYuan))
                .font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(.atbTextPrimary)
            Spacer()
            Text(String(format: "本月消费 ¥%.2f", booster.monthlyUsedYuan))
                .font(.system(size: 10)).foregroundStyle(.atbTextTertiary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.atbCardBackground))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.black.opacity(0.08)))
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
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.black.opacity(0.08)))
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
