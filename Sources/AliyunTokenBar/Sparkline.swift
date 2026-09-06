import SwiftUI
import AliyunTokenBarCore

// MARK: - 用量趋势 sparkline(Canvas 精确绘制)
//
// v2 视觉语言:
// - 用 Canvas 替代 Charts:可控制每一像素 + 极致轻量
// - 线条 1.5pt 细圆角 + 下方品牌色 18% 透明填充(品牌色辉光)
// - 关键点(警告线 50% / 临界线 90%)以浅灰虚线绘制,提示"何时变红"
// - 右侧"现在"用 2pt 宽品牌色竖条终结(无 ending dot——v1 的 dot 显得图形软件)

struct UsageSparkline: View {
    let provider: String
    let window: String
    let brand: Color
    var maxPoints: Int = 40
    var height: CGFloat = 28
    var store: HistoryStore = TokenPlanModel.shared.historyStore
    var threshold: ThresholdConfig? = nil

    var body: some View {
        let snaps = store.recent(maxPoints)
        let rawSeries: [Int?] = HistoryStore.series(snaps, provider: provider, window: window)
        let values: [Double] = rawSeries.compactMap { $0.map(Double.init) }
        if values.count < 2 {
            emptyPlaceholder.frame(height: height)
        } else {
            SparklineChart(values: values, brand: brand, threshold: threshold)
                .frame(height: height)
        }
    }

    /// 数据不足占位
    private var emptyPlaceholder: some View {
        Canvas { ctx, size in
            let path = Path { p in
                p.move(to: CGPoint(x: 0, y: size.height / 2))
                p.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            }
            ctx.stroke(path, with: .color(Color.primary.opacity(0.12)),
                       style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
        .overlay(alignment: .leading) {
            Text("趋势积累中…")
                .font(.system(size: 9))
                .foregroundStyle(Color.atbTextTertiary)
                .padding(.leading, 4)
        }
    }
}

// MARK: - 实际趋势图(单独组件,避免 Sparkline.body 推断超复杂度)
struct SparklineChart: View {
    let values: [Double]
    let brand: Color
    let threshold: ThresholdConfig?

    var body: some View {
        Canvas { ctx, size in
            draw(ctx: ctx, size: size)
        }
    }

    private func draw(ctx: GraphicsContext, size: CGSize) {
        let w = size.width, h = size.height
        let maxV = max(values.max() ?? 100, 100)
        // 1. 关键阈值虚线(50%/90%)——给用户"何时变红"的视觉锚点
        if let t = threshold {
            let dashLines: [(Double, CGFloat)] = [
                (Double(t.warning), 0.55),
                (Double(t.critical), 0.8)
            ]
            for (v, _) in dashLines where v <= maxV {
                let y = h - CGFloat(v / maxV) * h
                var p = Path()
                p.move(to: CGPoint(x: 0, y: y))
                p.addLine(to: CGPoint(x: w, y: y))
                ctx.stroke(p, with: .color(Color.primary.opacity(0.10)),
                           style: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
            }
        }
        // 2. 折线点
        let points: [CGPoint] = values.enumerated().map { idx, v in
            let x = w * CGFloat(idx) / CGFloat(max(values.count - 1, 1))
            let y = h - CGFloat(min(v, maxV) / maxV) * h
            return CGPoint(x: x, y: y)
        }
        // 3. 线下填充(品牌色柔光)
        if points.count >= 2, let lastPt = points.last {
            var fillPath = Path()
            fillPath.move(to: CGPoint(x: points[0].x, y: h))
            for p in points { fillPath.addLine(to: p) }
            fillPath.addLine(to: CGPoint(x: lastPt.x, y: h))
            fillPath.closeSubpath()
            ctx.fill(fillPath, with: .color(brand.opacity(0.18)))
        }
        // 4. 主线
        if points.count >= 2 {
            var linePath = Path()
            linePath.move(to: points[0])
            for p in points.dropFirst() { linePath.addLine(to: p) }
            ctx.stroke(linePath,
                       with: .color(brand),
                       style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        // 5. "现在"终端:2pt 宽品牌色竖条
        if let last = points.last {
            let barWidth: CGFloat = 2
            let barHeight: CGFloat = min(14, h * 0.55)
            let barRect = CGRect(x: last.x - barWidth / 2,
                                 y: last.y - barHeight / 2,
                                 width: barWidth, height: barHeight)
            ctx.fill(Path(roundedRect: barRect, cornerRadius: 1),
                     with: .color(brand))
        }
    }
}

// MARK: - 耗尽预测标注
struct LimitEstimateLabel: View {
    var provider: String = "aliyun"
    var window: String = "7d"
    var store: HistoryStore = TokenPlanModel.shared.historyStore

    var body: some View {
        let snaps = store.recent(100)
        if let mins = HistoryStore.estimateMinutesToLimit(snapshots: snaps, provider: provider, window: window) {
            let text = mins >= 60 ? "约 \(mins / 60) 小时后达上限(估算)" : "约 \(mins) 分钟后达上限(估算)"
            Text(text)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color(red: 0.95, green: 0.55, blue: 0.10))
                .lineLimit(1)
                .help("按近 7 天该窗口用量增速线性外推,仅供参考")
        }
    }
}
