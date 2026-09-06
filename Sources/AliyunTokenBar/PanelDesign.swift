import SwiftUI
import AppKit
import AliyunTokenBarCore

// MARK: - Provider 品牌色(固定,不随系统明暗——身份识别用)
//
// 设计原则:
// - 品牌色只用于「标识 Provider 是谁」(左上竖纹 / 大数字 / 图标)
// - 阈值色(橙/红)只用于「表达风险」(进度条 / 大数字)——品牌色与风险正交,互不污染。

extension Color {
    /// 阿里云百炼(暖橙,云栖品牌基调)
    static var atbBrandAliyun: Color { Color(red: 0.95, green: 0.45, blue: 0.10) }
    /// OpenCode Go(电气紫,工具感)
    static var atbBrandOpenCode: Color { Color(red: 0.49, green: 0.23, blue: 0.93) }
    /// Kimi(青绿,温和安全)
    static var atbBrandKimi: Color { Color(red: 0.06, green: 0.72, blue: 0.51) }
    /// DeepSeek(钴蓝,严谨)
    static var atbBrandDeepSeek: Color { Color(red: 0.12, green: 0.45, blue: 0.90) }
    /// 智谱 GLM(bigmodel.cn 品牌电光蓝 #134CFF)
    static var atbBrandZhipu: Color { Color(red: 0.07, green: 0.30, blue: 1.00) }
    /// 小米 MiMo(小米品牌橙 #FF6900 基调)
    static var atbBrandMiMo: Color { Color(red: 1.00, green: 0.41, blue: 0.00) }
    /// MiniMax(品牌洋红/绛红基调)
    static var atbBrandMiniMax: Color { Color(red: 0.78, green: 0.10, blue: 0.38) }
    /// 本机/系统(中性银灰)
    static var atbBrandSystem: Color { Color(red: 0.42, green: 0.45, blue: 0.50) }
}

// MARK: - Provider → 品牌色映射
enum ProviderBrand {
    static func color(for tab: ProviderTab) -> Color {
        switch tab {
        case .aliyun: return .atbBrandAliyun
        case .opencode: return .atbBrandOpenCode
        case .kimi: return .atbBrandKimi
        case .deepSeek: return .atbBrandDeepSeek
        case .zhipu: return .atbBrandZhipu
        case .mimo: return .atbBrandMiMo
        case .minimax: return .atbBrandMiniMax
        case .system: return .atbBrandSystem
        }
    }
}

// MARK: - 阈值 band 与风险色
@MainActor
func thresholdBrand(_ pct: Int, config: ThresholdConfig, brand: Color) -> Color {
    switch config.band(for: pct) {
    case .safe: return brand
    case .warning: return Color(red: 0.95, green: 0.55, blue: 0.10)
    case .critical: return Color(red: 0.92, green: 0.23, blue: 0.21)
    }
}

// MARK: - 大数字辉光修饰符
extension View {
    func atbHeroGlow(_ brand: Color, radius: CGFloat = 14) -> some View {
        self.shadow(color: brand.opacity(0.15), radius: radius, x: 0, y: 0)
    }
}

// MARK: - 圆环(Canvas 精确绘制)
struct ATBFillRing: View {
    let percentage: Double
    let brand: Color
    var diameter: CGFloat = 30
    var lineWidth: CGFloat = 4
    var threshold: ThresholdConfig?

    var body: some View {
        Canvas { ctx, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = (min(size.width, size.height) - lineWidth) / 2
            let pctInt = Int(percentage.rounded())
            // nil threshold = 不做阈值变色(与 ATBHeroNumber 语义一致),恒用品牌色
            let color: Color = threshold.map { thresholdBrand(pctInt, config: $0, brand: brand) } ?? brand
            // 背景圆环
            let bgRect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            ctx.stroke(Path(ellipseIn: bgRect), with: .color(brand.opacity(0.15)), lineWidth: lineWidth)
            // 进度弧
            let pct = max(0, min(percentage, 100)) / 100
            if pct > 0 {
                var arcPath = Path()
                arcPath.addArc(center: center, radius: radius, startAngle: .degrees(-90),
                               endAngle: .degrees(-90 + 360 * pct), clockwise: false)
                ctx.stroke(arcPath, with: .color(color), lineWidth: lineWidth)
            }
        }
        .frame(width: diameter, height: diameter)
    }
}

// MARK: - 多窗口环组(三窗口共用一张卡:环 + 大数字 + 标签)
//
// v3 改进:每个 slot 显示大百分比数字,一眼可读
struct ATBMultiRingCard: View {
    struct Slot: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let percentage: Double
        let bandColor: Color
        let threshold: ThresholdConfig?
    }
    let slots: [Slot]
    var ringDiameter: CGFloat = 40
    var ringLine: CGFloat = 3.5

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(slots.enumerated()), id: \.element.id) { idx, slot in
                slotView(slot)
                if idx < slots.count - 1 {
                    Divider().opacity(0.3).frame(height: 50)
                }
            }
        }
    }

    private func slotView(_ slot: Slot) -> some View {
        VStack(spacing: 4) {
            // 环
            ATBFillRing(percentage: slot.percentage, brand: slot.bandColor,
                        diameter: ringDiameter, lineWidth: ringLine, threshold: slot.threshold)
            // 大百分比数字(核心信息)
            Text(String(format: "%.0f%%", slot.percentage))
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(slot.bandColor)
            // 标题
            Text(slot.title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.atbTextPrimary)
            // 副标题(倒计时)
            Text(slot.subtitle)
                .font(.system(size: 8.5))
                .foregroundStyle(Color.atbTextTertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }
}

// MARK: - 状态点
struct ATBStatusDot: View {
    let status: ATBStatusLevel
    @State private var pulse = false
    var diameter: CGFloat = 7

    enum ATBStatusLevel {
        case ok, warning, critical, idle
        var color: Color {
            switch self {
            case .ok: return Color.atbSuccess
            case .warning: return Color(red: 0.95, green: 0.55, blue: 0.10)
            case .critical: return Color.atbCritical
            case .idle: return Color.atbTextTertiary
            }
        }
    }

    var body: some View {
        ZStack {
            if status == .critical {
                Circle().stroke(status.color.opacity(0.45), lineWidth: 1)
                    .frame(width: diameter * 2.6, height: diameter * 2.6)
                    .scaleEffect(pulse ? 1.4 : 0.9)
                    .opacity(pulse ? 0 : 1)
                    .animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false), value: pulse)
            }
            Circle().fill(status.color).frame(width: diameter, height: diameter)
        }
        .onAppear { if status == .critical { pulse = true } }
        .onChange(of: status) { newValue in pulse = newValue == .critical }
    }
}

// MARK: - Provider 标识徽标
struct ATBProviderMark: View {
    let tab: ProviderTab
    var size: CGFloat = 32

    var body: some View {
        let brand = ProviderBrand.color(for: tab)
        ZStack {
            Circle().fill(brand.opacity(0.14)).frame(width: size, height: size)
            Circle().fill(brand).frame(width: size * 0.62, height: size * 0.62)
            Image(systemName: tab.icon)
                .font(.system(size: size * 0.32, weight: .heavy))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - 数字大显示
struct ATBHeroNumber: View {
    let percentage: Double
    let brand: Color
    let threshold: ThresholdConfig?
    var size: CGFloat = 28
    var suffix: String? = nil

    var body: some View {
        let pctInt = Int(percentage.rounded())
        let color: Color = {
            guard let threshold else { return brand }
            return thresholdBrand(pctInt, config: threshold, brand: brand)
        }()
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(displayString)
                .font(.system(size: size, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
            if let suffix {
                Text(suffix)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.atbTextTertiary)
                    .textCase(.uppercase)
                    .tracking(0.5)
            }
        }
    }

    private var displayString: String {
        let pct = max(0, min(percentage, 100))
        return String(format: "%.1f%%", pct)
    }
}

// MARK: - 倒计时小胶囊
struct ATBCountdownPill: View {
    let text: String
    let brand: Color

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 8, weight: .semibold))
            Text(text)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(0.2)
        }
        .foregroundStyle(brand)
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(brand.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

// MARK: - 标签式徽章
struct ATBTag: View {
    let text: String
    let brand: Color
    var symbol: String? = nil

    var body: some View {
        HStack(spacing: 3) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.3)
                .textCase(.uppercase)
        }
        .foregroundStyle(brand)
        .padding(.horizontal, 5.5)
        .padding(.vertical, 2)
        .background(brand.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
