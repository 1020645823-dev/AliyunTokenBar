import Foundation
import Darwin
import AliyunTokenBarCore

var fails = 0
func check(_ name: String, _ cond: Bool) {
    if cond { print("PASS \(name)") } else { print("FAIL \(name)"); fails += 1 }
}

// --- Task 2: Models ---
let d1 = UsageDetail(percentageRaw: 0.349956963, resetTimeMs: 1785560220000)
check("pct 0.3499->35.0", d1.percentage == 35.0)
check("pctInt 0.3499->35", d1.percentageInt == 35)
check("resetTimeMs stored", d1.resetTimeMs == 1785560220000)

check("pct clamp at 100", UsageDetail(percentageRaw: 1.5, resetTimeMs: 0).percentage == 100.0)
check("pct negative -> 0", UsageDetail(percentageRaw: -0.1, resetTimeMs: 0).percentage == 0.0)

// 2 位小数精度:小数值不再截断为 0
let dSmall = UsageDetail(percentageRaw: 0.0025827426666666666, resetTimeMs: 0)
check("pct small 0.26", dSmall.percentage == 0.26)
check("pctInt small -> 0", dSmall.percentageInt == 0)

// 90 min from now → "1小时N分钟后重置" (N may be 28-30 due to sub-second truncation; assert hour only)
let reset90 = Int64((Date().addingTimeInterval(90 * 60).timeIntervalSince1970) * 1000)
let t = UsageDetail(percentageRaw: 0.3, resetTimeMs: reset90).timeUntilReset
check("90min contains 1小时", t.contains("1小时"))
check("90min contains 分钟", t.contains("分钟"))

let sub = SubscriptionDetail(specCode: "pro", status: "VALID", remainingDays: 291,
                              startTimeMs: 1784451307000, endTimeMs: 1810742400000,
                              autoRenewFlag: false)
check("specDisplay Pro", sub.specDisplay == "Pro")
check("statusDisplay 生效中", sub.statusDisplay == "生效中")

// --- Task 3: BlUsageService JSON parsing ---
// ⚠️ 数据契约:以下 fixture 必须与 BlUsageService.swift 的解析函数保持同步。
// 修改 BlUsageService 的 JSON 键名/结构时,同步更新对应 fixture 字段:
//   usageFixture       ↔ BlUsageService.parseUsage()
//   subscriptionFixture ↔ BlUsageService.parseSubscription()
//   addonFixture        ↔ BlUsageService.parseAddon()
//   expiredFixture      ↔ BlUsageService.classifyError()
let usageFixture = #"{"code":"200","data":{"DataV2":{"ret":["SUCCESS::接口调用成功"],"data":{"msg":"Success.","code":"SUCCESS","data":{"per5HourPercentage":0.349956963,"per1WeekResetTime":1785687360000,"per5HourResetTime":1785560220000,"per1WeekPercentage":0.61428294255},"requestId":"x","success":true}},"success":true,"httpStatus":200,"errorCode":"","api":"x","errorMsg":""},"httpStatusCode":"200","requestId":"x","successResponse":true}"#
let subscriptionFixture = #"{"code":"200","data":{"DataV2":{"ret":["SUCCESS::接口调用成功"],"data":{"msg":"Success.","code":"SUCCESS","data":{"instanceCode":"sfm_x","specCode":"pro","remainingDays":291,"startTime":1784451307000,"endTime":1810742400000,"autoRenewFlag":false,"status":"VALID"},"requestId":"x","success":true}},"success":true,"httpStatus":200,"errorCode":"","api":"x","errorMsg":""},"httpStatusCode":"200","requestId":"x","successResponse":true}"#
let addonFixture = #"{"code":"200","data":{"DataV2":{"ret":["SUCCESS::接口调用成功"],"data":{"msg":"Success.","code":"SUCCESS","data":{"remainingCredits":0.0,"activeCount":0,"totalCredits":0.0},"requestId":"x","success":true}},"success":true,"httpStatus":200,"errorCode":"","api":"x","errorMsg":""},"httpStatusCode":"200","requestId":"x","successResponse":true}"#
let expiredFixture = #"{"error":{"code":3,"message":"Console session is not logged in or has expired.","hint":"Run `bl auth login --console` to sign in or refresh your console session."}}"#

let u = try? BlUsageService.parseUsage(Data(usageFixture.utf8))
check("usage 5h pct 35.0", u?.fiveHour.percentage == 35.0)
check("usage 5h reset", u?.fiveHour.resetTimeMs == 1785560220000)
check("usage 7d pct 61.43", u?.oneWeek.percentage == 61.43)
check("usage 7d reset", u?.oneWeek.resetTimeMs == 1785687360000)

// 空窗形态(2026-08-03 事故根因回归):字段 null/缺失 → 宽容解析为 0,不再整次抛错
let usageEmptyFixture = #"{"code":"200","data":{"DataV2":{"ret":["SUCCESS::接口调用成功"],"data":{"msg":"Success.","code":"SUCCESS","data":{"per5HourPercentage":null,"per1WeekResetTime":1785687360000,"per1WeekPercentage":0.61428294255},"requestId":"x","success":true}},"success":true,"httpStatus":200,"errorCode":"","api":"x","errorMsg":""},"httpStatusCode":"200","requestId":"x","successResponse":true}"#
let ue = try? BlUsageService.parseUsage(Data(usageEmptyFixture.utf8))
check("usage empty-window parses", ue != nil)
check("usage empty-window 5h pct 0", ue?.fiveHour.percentage == 0.0)
check("usage empty-window 5h reset 0", ue?.fiveHour.resetTimeMs == 0)
check("usage empty-window 7d kept", ue?.oneWeek.percentage == 61.43)
// 整数 0(JSON 可能返回 Int 形态)也应解析
let usageIntFixture = #"{"code":"200","data":{"DataV2":{"data":{"data":{"per5HourPercentage":0,"per1WeekResetTime":1785687360000,"per5HourResetTime":1785560220000,"per1WeekPercentage":0}}}}}"#
check("usage int-zero parses", (try? BlUsageService.parseUsage(Data(usageIntFixture.utf8)))?.fiveHour.percentage == 0.0)
// resetTimeDisplay 可选语义:无重置时间 → nil(调用方隐藏重置行)
check("usage resetText nil when 0", UsageDetail(percentageRaw: 0, resetTimeMs: 0).resetTimeDisplay == nil)
check("usage resetText some when >0", u?.fiveHour.resetTimeDisplay != nil)

let s = try? BlUsageService.parseSubscription(Data(subscriptionFixture.utf8))
check("sub specCode pro", s?.specCode == "pro")
check("sub remainingDays 291", s?.remainingDays == 291)
check("sub status VALID", s?.status == "VALID")
check("sub autoRenew false", s?.autoRenewFlag == false)

let a = try? BlUsageService.parseAddon(Data(addonFixture.utf8))
check("addon activeCount 0", a?.activeCount == 0)
check("addon totalCredits 0", a?.totalCredits == 0.0)

check("classify expired", BlUsageService.classifyError(Data(expiredFixture.utf8), httpOk: true) == .authExpired)

var threwOnGarbage = false
do { _ = try BlUsageService.parseUsage(Data("not json".utf8)) } catch { threwOnGarbage = true }
check("parseUsage throws on garbage", threwOnGarbage)

// --- Task 4: live bl call (only runs if BL_LIVE=1) ---
if ProcessInfo.processInfo.environment["BL_LIVE"] == "1" {
    do {
        let data = try await BlUsageService.callRPC(BlUsageService.usageAPI)
        let w = try BlUsageService.parseUsage(data)
        check("live usage parses", w.fiveHour.percentage >= 0)
    } catch {
        check("live usage parses", false)  // counts as a fail if bl not logged in
        print("live error: \(error)")
    }
} else {
    print("SKIP live bl call (set BL_LIVE=1 to run)")
}

// --- Task 6: BlAuthManager.parseAuthStatus ---
let loggedInJson = #"{"authenticated":true,"config":"token-plan","console":{"source":"config","masked":"b2cb...24ef","region":"cn-beijing","site":"domestic"}}"#
check("auth logged in -> .ok", BlAuthManager.parseAuthStatus(Data(loggedInJson.utf8)) == .ok)

let envSrcJson = #"{"authenticated":true,"console":{"source":"env","masked":""}}"#
check("auth env source -> .notLoggedIn", BlAuthManager.parseAuthStatus(Data(envSrcJson.utf8)) == .notLoggedIn)

let noConsoleJson = #"{"authenticated":true}"#
check("auth no console field -> .notLoggedIn", BlAuthManager.parseAuthStatus(Data(noConsoleJson.utf8)) == .notLoggedIn)

let emptyMaskedJson = #"{"console":{"source":"config","masked":""}}"#
check("auth empty masked -> .notLoggedIn", BlAuthManager.parseAuthStatus(Data(emptyMaskedJson.utf8)) == .notLoggedIn)

// --- OpenCode Go 用量解析(模拟 SolidJS SSR 注入的 HTML)---
let ocFixture = """
<html><script>rollingUsage:$R[38]={status:"ok",resetInSec:12345,usagePercent:22}
weeklyUsage:$R[39]={status:"ok",resetInSec:504671,usagePercent:43}
monthlyUsage:$R[40]={status:"ok",resetInSec:2504671,usagePercent:98}</script></html>
"""
let oc = OpenCodeUsageService.parse(ocFixture)
check("opencode rolling 22%", oc?.rolling.pct == 22)
check("opencode rolling reset", oc?.rolling.resetInSec == 12345)
check("opencode weekly 43%", oc?.weekly.pct == 43)
check("opencode monthly 98%", oc?.monthly.pct == 98)
check("opencode rolling 含 3小时", oc?.rolling.timeUntilReset.contains("3小时") == true)
// 缺少某窗口应返回 nil
let ocPartial = "<script>rollingUsage:$R[1]={status:\"ok\",resetInSec:1,usagePercent:5}</script>"
check("opencode partial -> nil", OpenCodeUsageService.parse(ocPartial) == nil)

// rolling 空窗:服务端恒返完整 5h 时长(18000)→ 隐藏倒计时(2026-08-03 用户反馈回归)
check("opencode rolling empty hides reset", OpenCodeWindow(pct: 0, resetInSec: 18000).rollingResetText == nil)
check("opencode rolling active shows reset", OpenCodeWindow(pct: 3, resetInSec: 3600).rollingResetText?.contains("1小时") == true)

// --- Kimi Code:官方 usages API 解析 ---
let kimiFixture = """
{"user":{"userId":"cp5vaei34pe4b64f8rfg","membership":{"level":"LEVEL_ADVANCED"}},
"usage":{"limit":"100","used":"58","remaining":"42","resetTime":"2026-08-04T06:36:22.762591Z"},
"limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":"100","remaining":"100","resetTime":"2026-08-02T18:36:22.762591Z"}}],
"totalQuota":{},
"boosterWallet":{"status":"STATUS_ACTIVE","balance":{"unit":"UNIT_CURRENCY"},"monthlyChargeLimit":{"currency":"CNY","priceInCents":"10000"},"monthlyUsed":{"currency":"CNY","priceInCents":"0"}}}
"""
let kq = KimiUsageService.parse(Data(kimiFixture.utf8))
check("kimi weekly 58%", kq?.weekly.pct == 58.0)
check("kimi weekly used 58", kq?.weekly.used == 58)
check("kimi weekly limit 100", kq?.weekly.limit == 100)
check("kimi 5h used 0", kq?.fiveHour.used == 0)
check("kimi 5h limit 100", kq?.fiveHour.limit == 100)
check("kimi monthly nil (empty totalQuota)", kq?.monthly == nil)
check("kimi booster enabled", kq?.booster?.enabled == true)
check("kimi booster monthlyUsed 0", kq?.booster?.monthlyUsedYuan == 0.0)
check("kimi booster monthlyLimit 100", kq?.booster?.monthlyLimitYuan == 100.0)
check("kimi membership LEVEL_ADVANCED", kq?.membershipLevel == "LEVEL_ADVANCED")
check("kimi weekly resetTimeDisplay", kq?.weekly.resetTimeDisplay == "2026-08-04 14:36:22")

// 5h 窗口 used 缺失时用 limit - remaining 推算
let kimiFixtureFiveHourUsed = """
{"usage":{"limit":"100","used":"58","remaining":"42","resetTime":"2026-08-04T06:36:22.762591Z"},
"limits":[{"window":{"duration":300},"detail":{"limit":"200","used":"40","remaining":"160","resetTime":"2026-08-02T18:36:22.762591Z"}}],
"totalQuota":{"limit":"1000000","used":"300000","remaining":"700000"}}
"""
let kq2 = KimiUsageService.parse(Data(kimiFixtureFiveHourUsed.utf8))
check("kimi 5h used 40", kq2?.fiveHour.used == 40)
check("kimi 5h pct 20", kq2?.fiveHour.pct == 20.0)
check("kimi monthly present", kq2?.monthly != nil)
check("kimi monthly pct 30", kq2?.monthly?.pct == 30.0)
check("kimi monthly used 300000", kq2?.monthly?.used == 300000)
check("kimi parse garbage -> nil", KimiUsageService.parse(Data("not json".utf8)) == nil)

// KimiWindow.pct 边界
let kw = KimiWindow(used: 5, limit: 1000, resetTimeMs: nil)
check("kimi window pct 0.5", kw.pct == 0.5)
check("kimi window pctInt 1", kw.pctInt == 1)
check("kimi window remaining 995", kw.remaining == 995)
check("kimi window zero limit pct 0", KimiWindow(used: 5, limit: 0, resetTimeMs: nil).pct == 0)

// 5h 空窗:API 返上一窗口的过去时间戳 → 隐藏倒计时(2026-08-03 活体验证回归)
let kimiPastMs = Int64((Date().addingTimeInterval(-3600).timeIntervalSince1970) * 1000)
check("kimi 5h past reset hides", KimiWindow(used: 0, limit: 100, resetTimeMs: kimiPastMs).slidingResetText == nil)
// 用 2h+余量:避免两次 Date() 之间的毫秒级竞态把"2小时0分"变成"1小时59分"
let kimiFutureMs = Int64((Date().addingTimeInterval(2 * 3600 + 60).timeIntervalSince1970) * 1000)
check("kimi 5h future reset shows", KimiWindow(used: 5, limit: 100, resetTimeMs: kimiFutureMs).slidingResetText?.contains("2小时") == true)

// --- Kimi Web 控制台:GetUsages 响应解析(月度总额度数据源)---
let kimiWebFixture = """
{"usages":[{"scope":"FEATURE_CODING","detail":{"limit":"100","used":"58","remaining":"42","resetTime":"2026-08-04T06:36:22.762591Z"},"limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":"100","remaining":"100","resetTime":"2026-08-02T18:36:22.762591Z"}}]}],
"totalQuota":{"limit":"100","used":"41","remaining":"59"}}
"""
// 用 parseWebUsages 纯函数验证(需在 KimiUsageService 暴露)
// 通过 fetchWebQuota 的解析逻辑直接验证:构造一个可测的解析函数
let webParsed = KimiUsageService.parseWebUsages(Data(kimiWebFixture.utf8))
check("web weekly 58%", webParsed?.weekly.pct == 58.0)
check("web 5h limit 100", webParsed?.fiveHour.limit == 100)
check("web monthly 41%", webParsed?.monthly?.pct == 41.0)
check("web monthly used 41", webParsed?.monthly?.used == 41)
check("web monthly limit 100", webParsed?.monthly?.limit == 100)
check("web monthly nil when empty", KimiUsageService.parseWebUsages(Data(#"{"usages":[],"totalQuota":{}}"#.utf8))?.monthly == nil) 
check("web parse garbage -> nil", KimiUsageService.parseWebUsages(Data("bad".utf8)) == nil)

// KimiQuota.monthlyResetDisplay 用订阅到期时间
let kq3 = KimiQuota(fiveHour: KimiWindow(used: 0, limit: 100, resetTimeMs: nil),
                    weekly: KimiWindow(used: 58, limit: 100, resetTimeMs: nil),
                    monthly: KimiWindow(used: 41, limit: 100, resetTimeMs: nil),
                    booster: nil, membershipLevel: nil,
                    subscriptionExpireMs: 1784678400000)
check("kimi monthlyReset uses expire", kq3.monthlyResetDisplay == "2026-07-22 08:00:00")

// --- Kimi Code:live API(仅 KIMI_LIVE=1 时跑)---
if ProcessInfo.processInfo.environment["KIMI_LIVE"] == "1" {
    let r = await KimiUsageService.fetchQuota()
    switch r {
    case .success(let q):
        check("kimi live weekly pct >= 0", q.weekly.pct >= 0)
        check("kimi live 5h limit > 0", q.fiveHour.limit > 0)
    case .failure(let e):
        check("kimi live fetch", false)
        print("kimi live error: \(e)")
    }
} else {
    print("SKIP kimi live call (set KIMI_LIVE=1 to run)")
}

// --- Kimi Web 控制台:live(仅 KIMI_WEB_LIVE=1 时跑;env 传 KIMI_WEB_AT/KIMI_WEB_RT)---
if ProcessInfo.processInfo.environment["KIMI_WEB_LIVE"] == "1" {
    let env = ProcessInfo.processInfo.environment
    if let at = env["KIMI_WEB_AT"], let rt = env["KIMI_WEB_RT"], !at.isEmpty, !rt.isEmpty {
        let token = KimiUsageService.KimiWebToken(accessToken: at, refreshToken: rt, expiresAt: Date().timeIntervalSince1970 + 900)
        KimiUsageService.saveWebToken(token)
        let r = await KimiUsageService.fetchQuota()
        switch r {
        case .success(let q):
            check("kimi web live weekly >= 0", q.weekly.pct >= 0)
            check("kimi web live monthly present", q.monthly != nil)
            check("kimi web live monthly pct > 0", (q.monthly?.pct ?? 0) > 0)
        case .failure(let e):
            check("kimi web live fetch", false)
            print("kimi web live error: \(e)")
        }
        KimiUsageService.clearWebToken()
    } else {
        check("kimi web live token env", false)
        print("need KIMI_WEB_AT / KIMI_WEB_RT env")
    }
} else {
    print("SKIP kimi web live call (set KIMI_WEB_LIVE=1 + KIMI_WEB_AT/KIMI_WEB_RT)")
}

// --- 阈值逻辑 (ThresholdConfig.band / UsageBand) ---
let tc = ThresholdConfig(warning: 80, critical: 90)
check("band 30 -> safe", tc.band(for: 30) == .safe)
check("band 79 -> safe", tc.band(for: 79) == .safe)
check("band 80 -> warning", tc.band(for: 80) == .warning)
check("band 89 -> warning", tc.band(for: 89) == .warning)
check("band 90 -> critical", tc.band(for: 90) == .critical)
check("band 100 -> critical", tc.band(for: 100) == .critical)
check("band 0 -> safe", tc.band(for: 0) == .safe)

// ThresholdConfig 钳制:warning 必须 < critical
let tcClamp = ThresholdConfig(warning: 95, critical: 50)  // 非法输入
check("threshold clamp: warning < critical", tcClamp.warning < tcClamp.critical)
check("threshold clamp: warning >= 1", tcClamp.warning >= 1)
check("threshold clamp: critical <= 100", tcClamp.critical <= 100)

// band 排序 Comparable
check("band safe < warning", UsageBand.safe < UsageBand.warning)
check("band warning < critical", UsageBand.warning < UsageBand.critical)

// --- NotificationState 状态机(迟滞) ---
var ns = NotificationState()
// 首次(任意值)→ 通知
check("notify first-seen fires", ns.update(percentage: 30, config: tc) != nil)
// 同级 safe 区间内爬升 → 不通知(30→60 都在 safe)
check("notify safe->safe no fire", ns.update(percentage: 60, config: tc) == nil)
// 上行跨入 warning → 通知
check("notify safe->warning fires", ns.update(percentage: 82, config: tc) == .warning)
// warning 内继续爬升 → 不通知
check("notify warning->warning no fire", ns.update(percentage: 85, config: tc) == nil)
// 上行跨入 critical → 通知
check("notify warning->critical fires", ns.update(percentage: 95, config: tc) == .critical)
// 从 critical 回落到 safe → 不通知(回落不打扰)
check("notify critical->safe no fire", ns.update(percentage: 50, config: tc) == nil)
// 再次上行跨入 warning → 通知(新一轮)
check("notify safe->warning fires again", ns.update(percentage: 81, config: tc) == .warning)

// --- NotificationTracker 多窗口 ---
var tracker = NotificationTracker()
let k5h = WatchKey(provider: "aliyun", window: "5h")
let k7d = WatchKey(provider: "aliyun", window: "7d")
// 先 seed 两个窗口在 safe 区(首次都会触发,这是预期——首见告知)
_ = tracker.evaluate([(k5h, 30), (k7d, 30)], config: tc)
// 第二轮:5h 跨入 warning 触发,7d 仍在 safe 不触发
let fired1 = tracker.evaluate([(k5h, 85), (k7d, 50)], config: tc)
check("tracker fires only crossing window", fired1.count == 1 && fired1[0].0 == k5h && fired1[0].1 == .warning)
// 第三轮:5h 同级不触发,7d 跨入 critical 触发
let fired2 = tracker.evaluate([(k5h, 88), (k7d, 92)], config: tc)
check("tracker second eval: only 7d", fired2.count == 1 && fired2[0].0 == k7d && fired2[0].1 == .critical)
// clear(provider:) 只清该 Provider
tracker.clear(provider: "aliyun")
check("tracker clear aliyun empties aliyun", tracker.states[k5h] == nil && tracker.states[k7d] == nil)
check("tracker clear keeps others", tracker.states.isEmpty)

// --- HistoryStore(内存后端 + 固定时钟)---
// 用 class 让时钟可变:HistoryStore 持引用,测试推进时间后 store.now() 同步更新。
final class FixedClock: HistoryClock {
    var t: Date
    init(_ t: Date) { self.t = t }
    func now() -> Date { t }
}
let mem = InMemoryHistoryBackend()
let clock = FixedClock(Date(timeIntervalSince1970: 1_700_000_000))
let hs = HistoryStore(backend: mem, clock: clock, maxAgeDays: 7, maxPerSeries: 5)

// append + recent
hs.append(UsageSnapshot(timestamp: clock.now(), aliyunFiveHour: 30, aliyunOneWeek: 40,
                         opencodeRolling: nil, opencodeWeekly: nil, opencodeMonthly: nil))
hs.append(UsageSnapshot(timestamp: clock.now(), aliyunFiveHour: 50, aliyunOneWeek: 60,
                         opencodeRolling: 22, opencodeWeekly: 43, opencodeMonthly: 98))
check("history recent count 2", hs.recent(10).count == 2)
check("history recent max 1", hs.recent(1).count == 1)
// series 提取
let snaps2 = hs.recent(10)
check("series aliyun 5h", HistoryStore.series(snaps2, provider: "aliyun", window: "5h") == [30, 50])
check("series opencode rolling", HistoryStore.series(snaps2, provider: "opencode", window: "rolling") == [nil, 22])
check("series unknown -> all nil", HistoryStore.series(snaps2, provider: "x", window: "y") == [nil, nil])
// kimi 字段(缺省 nil,由 append 时显式传入)
let kimiSnaps = [
    UsageSnapshot(timestamp: clock.now(), aliyunFiveHour: nil, aliyunOneWeek: nil,
                  opencodeRolling: nil, opencodeWeekly: nil, opencodeMonthly: nil,
                  kimiFiveHour: 58, kimiWeekly: 30, kimiMonthly: 10),
    UsageSnapshot(timestamp: clock.now(), aliyunFiveHour: nil, aliyunOneWeek: nil,
                  opencodeRolling: nil, opencodeWeekly: nil, opencodeMonthly: nil,
                  kimiFiveHour: 0, kimiWeekly: 35, kimiMonthly: nil),
]
check("series kimi 5h", HistoryStore.series(kimiSnaps, provider: "kimi", window: "5h") == [58, 0])
check("series kimi weekly", HistoryStore.series(kimiSnaps, provider: "kimi", window: "weekly") == [30, 35])
check("series kimi monthly", HistoryStore.series(kimiSnaps, provider: "kimi", window: "monthly") == [10, nil])

// 淘汰:超过 maxPerSeries 截断最旧
for i in 0..<8 {
    hs.append(UsageSnapshot(timestamp: clock.now(), aliyunFiveHour: i, aliyunOneWeek: nil,
                             opencodeRolling: nil, opencodeWeekly: nil, opencodeMonthly: nil))
}
check("history evicts to maxPerSeries", hs.recent(100).count == 5)

// 过期淘汰:8 天前的快照应被 append 时清掉
let clock2 = FixedClock(Date(timeIntervalSince1970: 1_700_000_000))
let mem2 = InMemoryHistoryBackend()
let hs2 = HistoryStore(backend: mem2, clock: clock2, maxAgeDays: 7, maxPerSeries: 100)
hs2.append(UsageSnapshot(timestamp: clock2.now(), aliyunFiveHour: 1, aliyunOneWeek: nil,
                          opencodeRolling: nil, opencodeWeekly: nil, opencodeMonthly: nil))
// 推进时钟 8 天(class 引用,store 内 now() 同步变化)
clock2.t = clock2.now().addingTimeInterval(8 * 86_400)
hs2.append(UsageSnapshot(timestamp: clock2.now(), aliyunFiveHour: 2, aliyunOneWeek: nil,
                          opencodeRolling: nil, opencodeWeekly: nil, opencodeMonthly: nil))
check("history evicts expired (>7d)", hs2.recent(100).count == 1)
check("history expired keeps only new", hs2.recent(100).first?.aliyunFiveHour == 2)

// 预测:线性外推(每 1 小时涨 10%,从 50→60→70,距 100% 还需 3 小时 = 180 分)
let clock3 = FixedClock(Date(timeIntervalSince1970: 1_700_000_000))
let mem3 = InMemoryHistoryBackend()
let hs3 = HistoryStore(backend: mem3, clock: clock3, maxAgeDays: 7, maxPerSeries: 100)
let baseT = clock3.now()
for (i, pct) in [50, 60, 70].enumerated() {
    hs3.append(UsageSnapshot(timestamp: baseT.addingTimeInterval(Double(i) * 3600),
                              aliyunFiveHour: nil, aliyunOneWeek: pct,
                              opencodeRolling: nil, opencodeWeekly: nil, opencodeMonthly: nil))
}
let est = HistoryStore.estimateMinutesToLimit(snapshots: hs3.recent(100))
check("history estimate ~180min to limit", est != nil && abs(est! - 180) <= 2)
// 数据不足 → nil
check("history estimate nil when <2 pts",
      HistoryStore.estimateMinutesToLimit(snapshots: [UsageSnapshot(timestamp: baseT, aliyunFiveHour: nil, aliyunOneWeek: 50, opencodeRolling: nil, opencodeWeekly: nil, opencodeMonthly: nil)]) == nil)
// 速率非正 → nil
let mem4 = InMemoryHistoryBackend()
let hs4 = HistoryStore(backend: mem4, clock: FixedClock(baseT), maxAgeDays: 7, maxPerSeries: 100)
hs4.append(UsageSnapshot(timestamp: baseT, aliyunFiveHour: nil, aliyunOneWeek: 80, opencodeRolling: nil, opencodeWeekly: nil, opencodeMonthly: nil))
hs4.append(UsageSnapshot(timestamp: baseT.addingTimeInterval(3600), aliyunFiveHour: nil, aliyunOneWeek: 70, opencodeRolling: nil, opencodeWeekly: nil, opencodeMonthly: nil))
check("history estimate nil when non-increasing",
      HistoryStore.estimateMinutesToLimit(snapshots: hs4.recent(100)) == nil)

// FileHistoryBackend 往返(Codable)
let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent("atb-test-\(Int.random(in: 0..<1_000_000)).json")
let fb = FileHistoryBackend(url: tmpURL)
let sampleSnap = UsageSnapshot(timestamp: Date(timeIntervalSince1970: 1_700_000_000), aliyunFiveHour: 11, aliyunOneWeek: 22, opencodeRolling: 33, opencodeWeekly: 44, opencodeMonthly: 55)
fb.write([sampleSnap])
check("file backend roundtrip", fb.read() == [sampleSnap])
try? FileManager.default.removeItem(at: tmpURL)

// --- 菜单栏状态项可见性去抖 ---
var visibility = StatusItemVisibilityMonitor(requiredHiddenSamples: 3)
check("visibility transient hidden does not notify", visibility.record(isVisible: false) == false)
check("visibility recovery resets hidden samples", visibility.record(isVisible: true) == false)
check("visibility hidden sample 1", visibility.record(isVisible: false) == false)
check("visibility hidden sample 2", visibility.record(isVisible: false) == false)
check("visibility sustained hidden notifies", visibility.record(isVisible: false) == true)
check("visibility notifies only once", visibility.record(isVisible: false) == false)

// --- CredentialStore (InMemory + 迁移) ---
let cs = InMemoryCredentialStore()
cs.write("secret123", account: "opencode")
check("credstore read", cs.read(account: "opencode") == "secret123")
cs.delete(account: "opencode")
check("credstore delete", cs.read(account: "opencode") == nil)

// 迁移:UserDefaults 明文 → CredentialStore
let testDefaults = UserDefaults(suiteName: "atb-migration-test-\(Int.random(in: 0..<1_000_000))")!
testDefaults.set("legacy-cookie-value", forKey: "openCodeCookie")
let migrated = CredentialMigration.migrate(legacyKey: "openCodeCookie", account: "opencode",
                                            from: testDefaults, to: cs)
check("migration returns true", migrated == true)
check("migration moved value", cs.read(account: "opencode") == "legacy-cookie-value")
check("migration cleared defaults", testDefaults.string(forKey: "openCodeCookie") == nil)
// 幂等:再迁移 no-op,不覆盖
let migratedAgain = CredentialMigration.migrate(legacyKey: "openCodeCookie", account: "opencode",
                                                  from: testDefaults, to: cs)
check("migration idempotent no-op", migratedAgain == false)

// --- SystemMetricsMonitor:CPU/内存纯函数 ---
// CPU 差值:busy +100, total +1000 → 20%
check("cpu delta 20%",
      SystemMetricsMonitor.cpuPercent(previous: CPUTicks(user: 100, system: 100, nice: 0, idle: 800),
                                      current: CPUTicks(user: 200, system: 200, nice: 0, idle: 1600)) == 20)
// 全 idle → 0%
check("cpu all idle -> 0",
      SystemMetricsMonitor.cpuPercent(previous: CPUTicks(user: 100, system: 100, nice: 0, idle: 100),
                                      current: CPUTicks(user: 100, system: 100, nice: 0, idle: 200)) == 0)
// 两次采样相同(total=0)→ 0,不除零
check("cpu same ticks -> 0",
      SystemMetricsMonitor.cpuPercent(previous: CPUTicks(user: 1, system: 1, nice: 1, idle: 1),
                                      current: CPUTicks(user: 1, system: 1, nice: 1, idle: 1)) == 0)
// 计数器回绕(&- 减法):idle 从 UInt64.max 回绕到 0,user 增 1 → busy=1, total=2 → 50%
check("cpu wrap-around safe",
      SystemMetricsMonitor.cpuPercent(previous: CPUTicks(user: 0, system: 0, nice: 0, idle: UInt64.max),
                                      current: CPUTicks(user: 1, system: 0, nice: 0, idle: 0)) == 50)
// 内存:2048 页 × 4096 = 8MB / 16MB → 50%
check("mem 50%",
      SystemMetricsMonitor.memoryUsedPercent(active: 1024, wired: 512, compressed: 512,
                                             pageSize: 4096, totalBytes: 16 * 1024 * 1024) == 50)
// 小占用 → Int 四舍五入为 0%
check("mem small -> 0",
      SystemMetricsMonitor.memoryUsedPercent(active: 1, wired: 1, compressed: 1,
                                             pageSize: 4096, totalBytes: 16 * 1024 * 1024) == 0)
// 钳制:5000 页 × 4096 = 20MB vs 8MB → 244% → 100
check("mem clamp 100",
      SystemMetricsMonitor.memoryUsedPercent(active: 3000, wired: 1000, compressed: 1000,
                                             pageSize: 4096, totalBytes: 8 * 1024 * 1024) == 100)
// total=0 → nil
check("mem zero total -> nil",
      SystemMetricsMonitor.memoryUsedPercent(active: 1, wired: 1, compressed: 1,
                                             pageSize: 4096, totalBytes: 0) == nil)
// 冒烟:本机真实采样必然非 nil
check("smoke sampleCPUTicks", SystemMetricsMonitor.sampleCPUTicks() != nil)
check("smoke sampleMemoryPercent", SystemMetricsMonitor.sampleMemoryPercent() != nil)

print(fails == 0 ? "ALL PASS" : "\(fails) FAILED")
exit(fails == 0 ? 0 : 1)
