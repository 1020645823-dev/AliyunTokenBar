import Foundation

// MARK: - 通用用量预测(纯函数,Verify 断言覆盖)
//
// v1.0.65 StepFun 卡首次引入「月末预测」——Credit 月池计费真正的问题不是
// "已用百分之几",而是"按当前速度能不能撑到清零"。随后把同一套外推泛化,
// 各类订阅卡按各自数据形态取用:
// - 月池类(StepFun / Ollama / MiMo 套餐 / 阿里云月度):外推到重置时刻的百分比;
// - 窗口类(5h / 周):按速率外推到 100% 的时间(触顶预测,回答"这波会不会被限流");
// - 余额类(DeepSeek / MiMo):按日均消耗外推还能撑几天(runway)。
//
// 诚实性原则:有效点 <2 或跨度 <6h 一律返回 nil,UI 显示"趋势积累中"而不是
// 拍脑袋数字;速率非正(窗口重置归零、余额回升)同样 nil。
// 线性外推只是粗估:费用型计费受请求强度波动影响大,UI 一律标注"约/预计"。

public enum UsageForecast {
    // MARK: 百分比序列

    /// 线性外推到重置时刻的已用百分比(0-100 钳制)。
    /// - Parameters:
    ///   - samples: (时间, 已用%)序列;可含 0(新周期刚重置)。
    ///   - now: 当前时刻。
    ///   - resetMs: 池子清零时刻(epoch ms);缺失或已过 → nil。
    public static func monthEndPct(samples: [(t: Date, pct: Double)], now: Date, resetMs: Int64?) -> Double? {
        guard let resetMs else { return nil }
        let resetDate = Date(timeIntervalSince1970: Double(resetMs) / 1000)
        guard resetDate > now else { return nil }
        let valid = samples.sorted { $0.t < $1.t }
        guard valid.count >= 2 else { return nil }
        let first = valid.first!
        let last = valid.last!
        let span = last.t.timeIntervalSince(first.t)
        guard span >= 6 * 3600 else { return nil }
        let slopePerDay = (last.pct - first.pct) * 24 * 3600 / span
        let daysLeft = resetDate.timeIntervalSince(now) / 86_400
        guard daysLeft.isFinite else { return nil }
        return max(0, min(100, last.pct + slopePerDay * daysLeft))
    }

    /// 日均变化(百分点/天);数据不足 → nil。用于"日均 +X%"展示。
    public static func pctPerDay(samples: [(t: Date, pct: Double)]) -> Double? {
        slope(samples: samples, unitSeconds: 86_400)
    }

    /// 小时速率(百分点/小时);数据不足 → nil。
    public static func pctPerHour(samples: [(t: Date, pct: Double)]) -> Double? {
        slope(samples: samples, unitSeconds: 3600)
    }

    /// 触顶预测:按最近样本速率,到 100% 还需多少分钟。
    /// 已达/超 100% → 0;速率非正(用量在回落)或数据不足 → nil。
    public static func minutesToLimit(samples: [(t: Date, pct: Double)]) -> Int? {
        let sorted = samples.sorted { $0.t < $1.t }
        guard let last = sorted.last, let rate = pctPerHour(samples: sorted), rate > 0 else { return nil }
        let remaining = 100 - last.pct
        guard remaining > 0 else { return 0 }
        return max(0, Int((remaining / rate * 60).rounded()))
    }

    // MARK: 金额/残量序列(余额类)

    /// 残量序列的日均消耗(下降为正):余额类 provider 的烧钱/烧量速度。
    /// 余额回升(净消耗为负)时返回负值,由调用方判 >0;数据不足 → nil。
    public static func burnPerDay(samples: [(t: Date, v: Double)]) -> Double? {
        let sorted = samples.sorted { $0.t < $1.t }
        guard sorted.count >= 2 else { return nil }
        let first = sorted.first!, last = sorted.last!
        let span = last.t.timeIntervalSince(first.t)
        guard span >= 6 * 3600 else { return nil }
        let burn = (first.v - last.v) * 86_400 / span
        return burn.isFinite ? burn : nil
    }

    /// 余额 runway:剩余 ÷ 日均消耗,还能撑几天;消耗非正/不有限 → nil。
    public static func runwayDays(remaining: Double, burnPerDay: Double) -> Double? {
        guard burnPerDay.isFinite, burnPerDay > 0, remaining.isFinite else { return nil }
        return max(0, remaining / burnPerDay)
    }

    // MARK: 文案

    /// 分钟数 → 中文时长:"3 小时 20 分钟" / "2 天 5 小时" / "45 分钟" / "即将"。
    public static func durationText(minutes: Int) -> String {
        let m = max(0, minutes)
        let days = m / (60 * 24)
        let hours = (m % (60 * 24)) / 60
        let mins = m % 60
        if days > 0 { return "\(days) 天 \(hours) 小时" }
        if hours > 0 { return "\(hours) 小时 \(mins) 分" }
        if mins > 0 { return "\(mins) 分钟" }
        return "即将"
    }

    // MARK: 内部

    /// 首末两点线性斜率(每 unitSeconds 多少个百分点)。
    /// 数据不足(<2 点或跨度 <6h)→ nil;斜率非有限 → nil。
    static func slope(samples: [(t: Date, pct: Double)], unitSeconds: Double) -> Double? {
        let sorted = samples.sorted { $0.t < $1.t }
        guard sorted.count >= 2 else { return nil }
        let first = sorted.first!, last = sorted.last!
        let span = last.t.timeIntervalSince(first.t)
        guard span >= 6 * 3600 else { return nil }
        let value = (last.pct - first.pct) * unitSeconds / span
        return value.isFinite ? value : nil
    }
}

/// 旧名兼容:v1.0.65 StepFun 卡的首版预测(现已泛化为 UsageForecast)。
/// typealias 保留,老调用点(Verify 断言)无需改动。
public typealias StepFunForecast = UsageForecast
