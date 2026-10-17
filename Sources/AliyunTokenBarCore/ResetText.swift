import Foundation

/// 重置倒计时紧凑文案(epoch 毫秒时间戳)。
///
/// 分支与各家 `timeUntilReset` 一致,唯一区别是小时分支去掉「钟」字:
/// "2小时10分后重置" 而非 "2小时10分钟后重置"。
///
/// 供 ATBThinMeterRow 细条行尾注使用:行内容只有 312pt
/// (面板 360 − 内容边距 24 − 卡片内边距 24),完整版在最长情况
/// ("4小时59分钟后重置" ≈ 83pt)下必被截断出省略号,紧凑版 ≈ 69pt 可完整显示。
/// 过去时间/缺失返回 nil(UI 隐藏倒计时)。
public enum ATBResetText {
    public static func compact(fromMs ms: Int64?) -> String? {
        guard let ms else { return nil }
        let delta = Date(timeIntervalSince1970: TimeInterval(ms) / 1000).timeIntervalSinceNow
        guard delta > 0 else { return nil }
        let mins = Int(delta) / 60
        let hrs = mins / 60
        let days = hrs / 24
        if days > 0 { return "\(days)天\(hrs % 24)小时后重置" }
        if hrs > 0 { return "\(hrs)小时\(mins % 60)分后重置" }
        if mins > 0 { return "\(mins)分钟后重置" }
        return "即将重置"
    }
}
