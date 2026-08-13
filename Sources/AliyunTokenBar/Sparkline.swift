import SwiftUI
import Charts
import AliyunTokenBarCore

// MARK: - 用量趋势 sparkline

/// 单窗口用量百分比 sparkline(最近 N 条)。
/// 从 HistoryStore 读取序列,nil 点跳过;末点高亮;满 100% 标红虚线。
/// 数据点 <2 时不渲染(避免单点噪声),返回细弱占位提示。
struct UsageSparkline: View {
    let provider: String
    let window: String
    let color: Color
    var maxPoints: Int = 40            // 最近 ~40 条(10 分钟间隔 ≈ 6.5 小时)
    var height: CGFloat = 28           // 默认 28pt(全尺寸卡);紧凑卡传 16
    var store: HistoryStore = TokenPlanModel.shared.historyStore

    var body: some View {
        let snaps = store.recent(maxPoints)
        let values: [Int] = HistoryStore.series(snaps, provider: provider, window: window)
            .compactMap { $0 }
        if values.count < 2 {
            // 数据不足:显示一条淡线占位,避免视觉空白
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: height)
                .overlay(alignment: .leading) {
                    Text("趋势积累中…").font(.system(size: 9)).foregroundStyle(.atbTextTertiary).padding(.leading, 4)
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            Chart {
                ForEach(Array(values.enumerated()), id: \.offset) { idx, v in
                    LineMark(
                        x: .value("Idx", Double(idx)),
                        y: .value("Pct", Double(v)),
                        series: .value("Series", provider + window)
                    )
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .interpolationMethod(.catmullRom)
                }
                // 末点圆点高亮
                if let lastIdx = values.indices.last {
                    PointMark(
                        x: .value("Idx", Double(lastIdx)),
                        y: .value("Pct", Double(values[lastIdx]))
                    )
                    .foregroundStyle(color)
                    .symbolSize(20)
                }
                if let last = values.last, last >= 100 {
                    RuleMark(y: .value("Limit", 100.0))
                        .foregroundStyle(.red.opacity(0.4))
                        .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                }
            }
            .chartYScale(domain: 0 ... max(100, (values.max() ?? 100)))
            .chartYAxis(.hidden)
            .chartXAxis(.hidden)
            .frame(height: height)
        }
    }
}

// MARK: - 耗尽预测标注

/// 基于近 7 天指定窗口序列线性外推「距达上限约 X 分钟」(P2-B6:支持任意 provider/window)。
/// 估算粗略(滚动窗口非固定周期),仅作提示。
struct LimitEstimateLabel: View {
    var provider: String = "aliyun"
    var window: String = "7d"
    var store: HistoryStore = TokenPlanModel.shared.historyStore
    var body: some View {
        let snaps = store.recent(100)
        if let mins = HistoryStore.estimateMinutesToLimit(snapshots: snaps, provider: provider, window: window) {
            let text = mins >= 60 ? "约 \(mins / 60) 小时后达上限(估算)" : "约 \(mins) 分钟后达上限(估算)"
            Text(text)
                .font(.system(size: 9))
                .foregroundStyle(.orange)
                .lineLimit(1)
                .help("按近 7 天该窗口用量增速线性外推,仅供参考")
        }
    }
}
