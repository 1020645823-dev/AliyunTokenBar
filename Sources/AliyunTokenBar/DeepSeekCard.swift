import SwiftUI
import AppKit
import AliyunTokenBarCore

// MARK: - DeepSeek API 余额卡

/// DeepSeek API:总余额 + 当日使用费用(0点→当前,余额差快照法)。
/// 未配置 API Key 时内联引导输入(Key 只进系统钥匙串);
/// 官方接口只有余额——当日费用由 DeepSeekDailyLedger 计算,刷新时更新。
struct DeepSeekCard: View {
    @StateObject private var model = TokenPlanModel.shared
    @State private var draftKey = ""
    @State private var saveError: String?
    private let platformURL = URL(string: "https://platform.deepseek.com/api_keys")!

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingM) {
            header
            if model.deepSeekConfigured {
                if let b = model.deepSeekBalance {
                    balanceCard(b)
                    if let c = model.deepSeekTodayCost { todayCostCard(c) }
                    statusRow
                } else if let err = model.deepSeekError, isAuthError(err) {
                    keyErrorCard(err)
                } else if model.deepSeekLoading {
                    loadingCard
                } else {
                    unavailableCards
                    statusRow
                }
            } else {
                setupCard
            }
        }
        .padding(DesignTokens.spacingL)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 品牌头部行:蓝色 DeepSeek 标识 + 刷新按钮。
    private var header: some View {
        HStack(spacing: DesignTokens.spacingS) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 13, weight: .bold)).foregroundStyle(.atbBlue)
            Text("DeepSeek API")
                .font(.system(size: 13, weight: .medium)).foregroundStyle(.atbTextPrimary)
            Spacer()
            if model.deepSeekConfigured {
                Button { Task { await model.refreshDeepSeek() } } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 12)).foregroundStyle(.atbTextTertiary)
                }
                .buttonStyle(.plain)
                .help("刷新余额与当日费用")
                .accessibilityLabel("刷新 DeepSeek 余额")
            }
        }
    }

    // MARK: 总余额

    private func balanceCard(_ b: DeepSeekUsageService.DeepSeekBalance) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingS) {
            HStack(alignment: .firstTextBaseline) {
                Text("总余额").font(.system(size: 12, weight: .medium)).foregroundStyle(.atbTextSecondary)
                Spacer()
                Text(DeepSeekMoneyFormat.full(b.totalBalance))
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.atbTextPrimary)
            }
            HStack(spacing: DesignTokens.spacingM) {
                Label {
                    Text("充值 \(DeepSeekMoneyFormat.full(b.toppedUpBalance))")
                } icon: {
                    Image(systemName: "creditcard").font(.system(size: 9))
                }
                .font(.system(size: 10)).foregroundStyle(.atbTextSecondary)
                Label {
                    Text("赠金 \(DeepSeekMoneyFormat.full(b.grantedBalance))")
                } icon: {
                    Image(systemName: "gift").font(.system(size: 9))
                }
                .font(.system(size: 10)).foregroundStyle(.atbTextSecondary)
                Spacer(minLength: 0)
                HStack(spacing: 3) {
                    Circle().fill(b.isAvailable ? Color.green : Color.atbCritical).frame(width: 6, height: 6)
                    Text(b.isAvailable ? "可用" : "官方标记不可用")
                        .font(.system(size: 9)).foregroundStyle(.atbTextTertiary)
                }
            }
        }
        .padding(.horizontal, DesignTokens.spacingM).padding(.vertical, DesignTokens.spacingS + 2)
        .background(Color.atbCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusM))
        .shadow(color: Color.black.opacity(0.04), radius: 2, y: 1)
    }

    // MARK: 当日费用

    private func todayCostCard(_ c: DeepSeekDailyCost) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingS) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("当日使用费用")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.atbTextSecondary)
                    Text("0 点 → 现在 · 点击刷新或按刷新间隔更新")
                        .font(.system(size: 9)).foregroundStyle(.atbTextTertiary)
                }
                Spacer()
                Text(DeepSeekMoneyFormat.full(c.cost))
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(c.cost > 0 ? .atbBlue : .atbTextPrimary)
            }
            HStack(spacing: DesignTokens.spacingS) {
                if c.estimated {
                    Text("估算")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.orange)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.orange.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusS - 2))
                }
                if let baseline = c.baselineAt {
                    Text("基线 \(Self.timeText(baseline))")
                        .font(.system(size: 9)).foregroundStyle(.atbTextTertiary)
                }
                Spacer(minLength: 0)
            }
            if c.estimated {
                Text("应用今天首次刷新晚于 0 点,费用按最近一次余额估算;此后 0 点刷新即恢复精确累计。")
                    .font(.system(size: 9)).foregroundStyle(.orange.opacity(0.9))
            }
        }
        .padding(.horizontal, DesignTokens.spacingM).padding(.vertical, DesignTokens.spacingS + 2)
        .background(Color.atbCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusM))
        .shadow(color: Color.black.opacity(0.04), radius: 2, y: 1)
    }

    // MARK: 状态行

    /// 数据时间戳/离线/错误行(与阿里云状态行同视觉规范)。
    private var statusRow: some View {
        HStack(alignment: .top, spacing: 6) {
            if model.isOffline {
                Image(systemName: "wifi.slash").font(.system(size: 9)).foregroundStyle(.orange)
                Text("离线:网络恢复后自动刷新").font(.system(size: 9)).foregroundStyle(.orange)
            } else if let err = model.deepSeekError {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)).foregroundStyle(.orange)
                Text("刷新失败:\(err)(显示 \(Self.timeText(model.deepSeekLastUpdated)) 的旧数据)")
                    .font(.system(size: 9)).foregroundStyle(.orange)
                    .lineLimit(2)
            } else {
                Text("最后查询 \(Self.timeText(model.deepSeekLastUpdated))")
                    .font(.system(size: 9)).foregroundStyle(.atbTextTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2)
    }

    private var loadingCard: some View {
        HStack { Spacer(); LoadingRing().frame(width: 18, height: 18); Spacer() }
            .padding(DesignTokens.spacingL)
            .frame(maxWidth: .infinity)
            .background(Color.atbCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusL))
            .shadow(color: Color.black.opacity(0.04), radius: 2, y: 1)
    }

    /// 网络/服务故障:两张卡片显示横杠(—),表示数值不可用。
    private var unavailableCards: some View {
        VStack(spacing: DesignTokens.spacingM) {
            dashCard(title: "总余额")
            dashCard(title: "当日使用费用")
        }
    }

    private func dashCard(title: String) -> some View {
        HStack {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.atbTextSecondary)
            Spacer()
            Text("—").font(.system(size: 20, weight: .bold)).foregroundStyle(.atbTextTertiary)
        }
        .padding(.horizontal, DesignTokens.spacingM).padding(.vertical, DesignTokens.spacingS + 2)
        .background(Color.atbCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusM))
        .shadow(color: Color.black.opacity(0.04), radius: 2, y: 1)
    }

    /// API Key 无效/吊销:引导去设置更新(不显示旧余额,避免误导)。
    private func keyErrorCard(_ err: String) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingS) {
            HStack(spacing: DesignTokens.spacingS) {
                Image(systemName: "key.slash").font(.system(size: 12)).foregroundStyle(.atbCritical)
                Text(err).font(.system(size: 11, weight: .medium)).foregroundStyle(.atbCritical)
            }
            Text("Key 可能已被删除或吊销,请在下方重新粘贴有效 Key(仅存系统钥匙串)。")
                .font(.system(size: 10)).foregroundStyle(.atbTextSecondary)
            keyInputRow
        }
        .padding(.horizontal, DesignTokens.spacingM).padding(.vertical, DesignTokens.spacingS + 2)
        .background(Color.atbCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusM))
        .shadow(color: Color.black.opacity(0.04), radius: 2, y: 1)
    }

    // MARK: 未配置引导

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingS) {
            HStack(spacing: DesignTokens.spacingS) {
                Image(systemName: "key").font(.system(size: 12)).foregroundStyle(.atbBlue)
                Text("未配置 API Key").font(.system(size: 12, weight: .medium)).foregroundStyle(.atbTextPrimary)
                Spacer()
                Button { NSWorkspace.shared.open(platformURL) } label: {
                    HStack(spacing: 2) {
                        Text("创建 Key").font(.system(size: 10, weight: .medium))
                        Image(systemName: "arrow.up.right.square").font(.system(size: 9))
                    }
                    .foregroundStyle(.atbBlue)
                }
                .buttonStyle(.plain)
                .help("打开 DeepSeek 开放平台 API Keys 页面")
            }
            Text("填入 DeepSeek 开放平台 API Key 后,将显示总余额与当日使用费用(0 点起累计)。")
                .font(.system(size: 10)).foregroundStyle(.atbTextSecondary)
            keyInputRow
            Text("Key 仅保存在系统钥匙串,本机其他应用不可读;随时可在设置 → 服务中移除。")
                .font(.system(size: 9)).foregroundStyle(.atbTextTertiary)
        }
        .padding(.horizontal, DesignTokens.spacingM).padding(.vertical, DesignTokens.spacingS + 2)
        .background(Color.atbCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusM))
        .shadow(color: Color.black.opacity(0.04), radius: 2, y: 1)
    }

    private var keyInputRow: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingS - 2) {
            HStack(spacing: DesignTokens.spacingS) {
                SecureField("sk-...", text: $draftKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                Button("保存并查询") { saveKey() }
                    .buttonStyle(ATBPrimaryButtonStyle())
                    .font(.system(size: 11, weight: .medium))
            }
            if let saveError {
                Text(saveError).font(.system(size: 10)).foregroundStyle(.atbCritical)
            }
        }
    }

    private func saveKey() {
        let k = draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else {
            saveError = "请输入 API Key"
            return
        }
        saveError = nil
        model.deepSeekAPIKey = k
        draftKey = ""
        Task { await model.refreshDeepSeek() }
    }

    private func isAuthError(_ err: String) -> Bool {
        err.contains("API Key 无效")
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private static func timeText(_ date: Date?) -> String {
        guard let date else { return "--" }
        return timeFormatter.string(from: date)
    }
}
