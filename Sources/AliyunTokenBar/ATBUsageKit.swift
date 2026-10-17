import SwiftUI
import AppKit
import AliyunTokenBarCore

// MARK: - 订阅卡共享组件(StepFun 卡 v1.0.65 设计语言泛化)
//
// v1.0.65 阶跃卡跑通的设计范式,推广到全部内置订阅(各有特色,底座统一):
//   ① 品牌行副标题带**更新时间**(旧卡只写静态描述,看不出数据新旧);
//   ② **预测行**(UsageForecast 外推):月池类=清零时用到几成、窗口类=触顶还要多久、
//      余额类=还能撑几天;数据不足时诚实显示"积累中",不拍脑袋;
//   ③ mini-ring + 心理账户主口径(%)/¥/次数)替代装饰性大环;
//   ④ 细条行替代嵌套小卡(多窗口/多模型/多账户信息密度);
//   ⑤ 三态统一:未配置引导 / 鉴权重登 / 异常提示 / 数据不可用横杠。
//
// 本文件只收"所有卡都在重复"的零件;provider 特有结构仍留在各自卡文件。

// MARK: 品牌行零件

/// 刷新圆钮(所有卡同款)。
struct ATBRefreshButton: View {
    let action: () -> Void
    var help: String = "刷新用量"
    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.atbTextTertiary)
                .frame(width: 22, height: 22)
                .background(Color.primary.opacity(0.06))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// 品牌行副标题(9pt/三级色/微字距)。
struct ATBSubtitleText: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(Color.atbTextTertiary)
            .tracking(0.3)
    }
}

/// 品牌色徽章(套餐等级/plan 名)。
struct ATBBrandTag: View {
    let text: String
    let brand: Color
    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(brand)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(brand.opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

/// 品牌色小按钮(创建 Key / 添加账户 / 登录平台)。
struct ATBBrandActionButton: View {
    let title: String
    let symbol: String
    let brand: Color
    let action: () -> Void
    var help: String? = nil
    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(title).font(.system(size: 10, weight: .semibold))
                Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(brand)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(brand.opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help(help ?? title)
    }
}

// MARK: 卡片容器(品牌竖纹 + 卡片底 + 发丝描边,统一样式)

/// 品牌竖纹卡:左 3pt 品牌色条 + 卡片底 + 圆角 + 发丝描边。
/// 取代每个卡里重复一遍的 overlay/clipShape 组合(StepFun/Kimi/Ollama/MiMo 多处雷同)。
struct ATBStripeCard: ViewModifier {
    let brand: Color
    var paddingH: CGFloat = DesignTokens.spacingM
    var paddingV: CGFloat = DesignTokens.spacingS
    /// Hero 卡:品牌色 5% 铺底 + 品牌色描边(阿里云/DeepSeek hero 语义)。
    var hero: Bool = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, paddingH)
            .padding(.vertical, paddingV)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                ZStack {
                    Color.atbCardBackground
                    if hero { brand.opacity(0.05) }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.radiusM)
                    .strokeBorder(hero ? brand.opacity(0.18) : Color.atbSeparator.opacity(0.5),
                                  lineWidth: DesignTokens.strokeHairline)
            )
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusM))
            .overlay(alignment: .leading) {
                Rectangle().fill(brand)
                    .frame(width: DesignTokens.stripeWidth)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusM))
                    .padding(.vertical, 1)
            }
    }
}

extension View {
    func atbStripeCard(brand: Color, paddingH: CGFloat = DesignTokens.spacingM,
                       paddingV: CGFloat = DesignTokens.spacingS, hero: Bool = false) -> some View {
        modifier(ATBStripeCard(brand: brand, paddingH: paddingH, paddingV: paddingV, hero: hero))
    }
}

// MARK: mini 进度环(StepFun hero 同款:轻于大环卡,承担"一眼用量")

struct ATBMiniRing: View {
    let pct: Int
    let color: Color
    var diameter: CGFloat = 46
    var lineWidth: CGFloat = 4
    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.10), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(max(0, min(100, pct))) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(pct)%")
                .font(.system(size: diameter * 0.24, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
        }
        .frame(width: diameter, height: diameter)
    }
}

// MARK: 行级零件

/// 预测行(StepFun v1.0.65 同款):图标 + 文案;tint 着色图标。
struct ATBForecastRow: View {
    var icon: String = "chart.line.uptrend.xyaxis"
    var text: String
    var tint: Color = Color.atbTextTertiary
    var help: String? = nil

    var body: some View {
        HStack(spacing: DesignTokens.spacingS) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(Color.atbTextSecondary)
            Spacer(minLength: 0)
        }
        .atbCard(paddingV: DesignTokens.spacingS - 2)
        .help(help ?? text)
    }
}

/// 信息行(图标 + 单行明细):模型请求数、MCP 通道、积分余额等。
struct ATBInfoRow: View {
    var icon: String
    var text: String
    var tint: Color = Color.atbTextTertiary
    var help: String? = nil

    var body: some View {
        HStack(spacing: DesignTokens.spacingS) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.atbTextSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .atbCard(paddingV: DesignTokens.spacingS - 2)
        .help(help ?? text)
    }
}

/// 细条行(StepFun 多账户行泛化):标签 + 身份提示 + 已用% + 3pt 进度条 + 右侧数值 + 尾注。
struct ATBThinMeterRow: View {
    var label: String
    var pct: Int
    var color: Color
    /// 感官区分提示(Key/JWT 尾缀;nil 时不占位)
    var hint: String? = nil
    var valueText: String? = nil
    var trailing: String? = nil
    var help: String? = nil

    var body: some View {
        HStack(spacing: DesignTokens.spacingS) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.atbTextSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: DesignTokens.meterLabelWidth, alignment: .leading)
            if let hint {
                Text(hint)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Color.atbTextTertiary)
                    .frame(width: 46, alignment: .leading)
            }
            Text("\(pct)%")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
                .frame(width: 32, alignment: .trailing)
            // 固定宽度条:各行严格等长;曾用 GeometryReader 弹性宽度,
            // 被可变长尾注(重置倒计时有/无/长/短)挤成各行长短不齐
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(color)
                    .frame(width: DesignTokens.meterWidth * CGFloat(max(0, min(100, pct))) / 100)
            }
            .frame(width: DesignTokens.meterWidth, height: 3)
            if let valueText {
                Text(valueText)
                    .font(.system(size: 9, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.atbTextTertiary)
                    .frame(minWidth: 40, alignment: .trailing)
            }
            if let trailing {
                Text(trailing)
                    .font(.system(size: 9))
                    .foregroundStyle(Color.atbTextTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .atbCard(paddingV: DesignTokens.spacingS - 2)
        .help(help ?? "\(label) 已用 \(pct)%")
    }
}

/// 内联重命名编辑器(账户行就地改名:输入框 + 保存/取消)。
struct ATBRenameField: View {
    let initial: String
    let onSave: (String) -> Void
    let onCancel: () -> Void
    @State private var text: String
    @FocusState private var focused: Bool

    init(initial: String, onSave: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.initial = initial
        self.onSave = onSave
        self.onCancel = onCancel
        _text = State(initialValue: initial)
    }

    var body: some View {
        HStack(spacing: DesignTokens.spacingS) {
            TextField("账户名", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .focused($focused)
                .onSubmit { onSave(text) }
            Button("保存") { onSave(text) }
                .buttonStyle(ATBPrimaryButtonStyle())
                .font(.system(size: 10, weight: .medium))
            Button("取消") { onCancel() }
                .buttonStyle(ATBTextButtonStyle(color: .atbTextSecondary))
                .font(.system(size: 10))
        }
        .onAppear { focused = true }
    }
}

/// 账户操作菜单(重命名/移除等)的公共条目构造。
enum ATBAccountMenu {
    /// 账户行右键菜单(替代堆一排小按钮,保持细条行紧凑)。
    @ViewBuilder
    static func items(rename: @escaping () -> Void, remove: @escaping () -> Void,
                      relogin: (() -> Void)? = nil) -> some View {
        if let relogin {
            Button("重新登录", action: relogin)
        }
        Button("重命名", action: rename)
        Button("移除账户", action: remove)
    }
}

/// 数据不可用横杠卡(网络/服务故障时的占位)。
struct ATBUnavailableRow: View {
    var title: String
    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.atbTextSecondary)
            Spacer()
            Text("—")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.atbTextTertiary)
        }
        .atbCard(paddingV: DesignTokens.spacingS - 2)
    }
}

/// 异常提示卡(统一三态之一)。
struct ATBErrorHintCard: View {
    var title: String = "配置异常"
    var message: String
    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.spacingS) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.atbTextPrimary)
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.atbTextSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .atbCard(corner: DesignTokens.radiusL)
    }
}

/// 加载卡(转圈)。
struct ATBLoadingCard: View {
    var height: CGFloat = 64
    var body: some View {
        HStack { Spacer(); LoadingRing().frame(width: 18, height: 18); Spacer() }
            .frame(height: height)
            .atbCard(corner: DesignTokens.radiusL, paddingH: DesignTokens.spacingL,
                     paddingV: DesignTokens.spacingL, alignment: .center)
    }
}

// MARK: 时间文案

@MainActor
enum ATBTimeFormat {
    /// 最近一条历史快照时间(provider 无专属 lastUpdated 时用)。
    /// recordAndNotify 每次刷新都会落一条全量快照,时间戳即数据新鲜度。
    static func latestData(_ model: TokenPlanModel) -> Date? {
        model.historyStore.recent(1).first?.timestamp
    }

    /// "14:36 更新"(品牌行副标题用);nil → ""。
    static func updated(_ date: Date?) -> String {
        guard let date else { return "" }
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    /// "MM-dd HH:mm"(订阅到期等绝对时间)。
    static func short(_ ms: Int64?) -> String {
        guard let ms else { return "" }
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
    }
}

// MARK: 历史序列提取(卡内预测的统一取数入口)

/// 从 HistoryStore 取预测用序列。窗口命名与 HistoryStore.series 一致;
/// 金额序列(deepseek/mimo 余额)走 valueSamples。
@MainActor
enum ATBHistory {
    /// 百分比序列(定期窗口:5h/周/月…)。nil 点剔除,升序。
    static func pctSamples(_ model: TokenPlanModel, provider: String, window: String,
                           lastHours: Int = 96) -> [(t: Date, pct: Double)] {
        let snaps = model.historyStore.within(lastHours: lastHours)
        let series = HistoryStore.series(snaps, provider: provider, window: window)
        return zip(snaps, series).compactMap { snap, v in
            v.map { (snap.timestamp, Double($0)) }
        }
    }

    /// 金额/残量序列(余额类:deepseek/mimo)。nil 点剔除,升序。
    static func valueSamples(_ model: TokenPlanModel, provider: String,
                             lastHours: Int = 168) -> [(t: Date, v: Double)] {
        model.historyStore.within(lastHours: lastHours).compactMap { snap -> (t: Date, v: Double)? in
            switch provider {
            case "deepseek": return snap.deepSeekBalance.map { (snap.timestamp, $0) }
            case "mimo": return snap.mimoBalance.map { (snap.timestamp, $0) }
            default: return nil
            }
        }
    }

    /// 触顶预测文案:窗口还剩多久到 100%;速率非正/数据不足 → nil。
    /// - window: "5h"/"weekly"/"monthly"(或 provider 自定义窗口名)。
    static func minutesToLimitText(_ model: TokenPlanModel, provider: String, window: String) -> String? {
        let samples = pctSamples(model, provider: provider, window: window)
        guard let mins = UsageForecast.minutesToLimit(samples: samples) else { return nil }
        return UsageForecast.durationText(minutes: mins)
    }
}
