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
check("usage 5h pct 35.0", u?.fiveHour?.percentage == 35.0)
check("usage 5h reset", u?.fiveHour?.resetTimeMs == 1785560220000)
check("usage 7d pct 61.43", u?.oneWeek.percentage == 61.43)
check("usage 7d reset", u?.oneWeek.resetTimeMs == 1785687360000)

// 空窗形态(2026-08-03 事故根因回归):5h 字段缺失/null → fiveHour == nil(无窗口),
// 不再整次抛错,也不冒充 0%(0% 与「窗口存在零用量」混淆;无窗口应隐藏统计)
let usageEmptyFixture = #"{"code":"200","data":{"DataV2":{"ret":["SUCCESS::接口调用成功"],"data":{"msg":"Success.","code":"SUCCESS","data":{"per5HourPercentage":null,"per1WeekResetTime":1785687360000,"per1WeekPercentage":0.61428294255},"requestId":"x","success":true}},"success":true,"httpStatus":200,"errorCode":"","api":"x","errorMsg":""},"httpStatusCode":"200","requestId":"x","successResponse":true}"#
let ue = try? BlUsageService.parseUsage(Data(usageEmptyFixture.utf8))
check("usage empty-window parses", ue != nil)
check("usage empty-window 5h nil(无窗口)", ue?.fiveHour == nil)
check("usage empty-window 7d kept", ue?.oneWeek.percentage == 61.43)
// 无 5h 窗口实测形态(2026-08-15 官方限时取消 5h 限额后服务端只返回周窗口)
let usageNo5hFixture = #"{"code":"200","data":{"DataV2":{"ret":["SUCCESS::接口调用成功"],"data":{"msg":"Success.","code":"SUCCESS","data":{"per1WeekResetTime":1787149800000,"per1WeekPercentage":0.1107448506},"requestId":"x","success":true}},"success":true,"httpStatus":200,"errorCode":"","api":"x","errorMsg":""},"httpStatusCode":"200","requestId":"x","successResponse":true}"#
let un = try? BlUsageService.parseUsage(Data(usageNo5hFixture.utf8))
check("usage 无5h窗口 fiveHour nil", un?.fiveHour == nil)
check("usage 无5h窗口 7d 11.07", un?.oneWeek.percentage == 11.07)
check("usage 无5h窗口 7d reset", un?.oneWeek.resetTimeMs == 1787149800000)
// 整数 0(JSON 可能返回 Int 形态)也应解析;字段存在(哪怕 0)≠ 无窗口
let usageIntFixture = #"{"code":"200","data":{"DataV2":{"data":{"data":{"per5HourPercentage":0,"per1WeekResetTime":1785687360000,"per5HourResetTime":1785560220000,"per1WeekPercentage":0}}}}}"#
check("usage int-zero parses", (try? BlUsageService.parseUsage(Data(usageIntFixture.utf8)))?.fiveHour?.percentage == 0.0)
check("usage int-zero 窗口存在", (try? BlUsageService.parseUsage(Data(usageIntFixture.utf8)))?.fiveHour != nil)
// resetTimeDisplay 可选语义:无重置时间 → nil(调用方隐藏重置行)
check("usage resetText nil when 0", UsageDetail(percentageRaw: 0, resetTimeMs: 0).resetTimeDisplay == nil)
check("usage resetText some when >0", u?.fiveHour?.resetTimeDisplay != nil)

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
        check("live usage parses", w.oneWeek.percentage >= 0 && (w.fiveHour?.percentage ?? 0) >= 0)
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

// --- AuthState.afterRefresh 状态机(2026-08-03 死循环修复回归)---
// RPC 成功 → 恒回置 .ok(重新登录后定时器/手动刷新成功必须解除鉴权提示)
check("auth next: expired + success -> ok", AuthState.expired.afterRefresh(error: nil) == .ok)
check("auth next: notLoggedIn + success -> ok", AuthState.notLoggedIn.afterRefresh(error: nil) == .ok)
check("auth next: unknown + success -> ok", AuthState.unknown.afterRefresh(error: nil) == .ok)
// authExpired:仅 .ok/.unknown 降级为 .expired(未登录不误标"已过期")
check("auth next: ok + authExpired -> expired", AuthState.ok.afterRefresh(error: .authExpired) == .expired)
check("auth next: unknown + authExpired -> expired", AuthState.unknown.afterRefresh(error: .authExpired) == .expired)
check("auth next: expired stays expired", AuthState.expired.afterRefresh(error: .authExpired) == .expired)
check("auth next: notLoggedIn not mislabeled", AuthState.notLoggedIn.afterRefresh(error: .authExpired) == .notLoggedIn)
// 网络故障 ≠ 登录失效:状态保持
check("auth next: ok + network stays ok", AuthState.ok.afterRefresh(error: .network("x")) == .ok)
check("auth next: expired + network stays", AuthState.expired.afterRefresh(error: .network("x")) == .expired)

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

// P1-D6:键序无关 + 空格容忍 + status 校验(页面改版不整体失效)
let ocReordered = "<script>weeklyUsage:$R[2]={usagePercent:43, resetInSec:777, status:\"ok\"}, rollingUsage:$R[1]={resetInSec:12345,status:\"ok\",usagePercent:22}, monthlyUsage:$R[3]={usagePercent:98,status:\"ok\",resetInSec:888}</script>"
let ocR = OpenCodeUsageService.parse(ocReordered)
check("opencode reordered keys parses", ocR?.rolling.pct == 22 && ocR?.rolling.resetInSec == 12345)
check("opencode reordered weekly", ocR?.weekly.pct == 43)
check("opencode reordered monthly", ocR?.monthly.pct == 98)
let ocBadStatus = "<script>weeklyUsage:$R[2]={status:\"error\",resetInSec:777,usagePercent:43}, rollingUsage:$R[1]={status:\"ok\",resetInSec:12345,usagePercent:22}, monthlyUsage:$R[3]={status:\"ok\",resetInSec:888,usagePercent:98}</script>"
check("opencode bad status -> nil", OpenCodeUsageService.parse(ocBadStatus) == nil)

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

let kimiStringWindowFixture = #"{"usage":{"limit":"100","used":"10","remaining":"90"},"limits":[{"window":{"duration":"300","timeUnit":"MINUTE"},"detail":{"limit":"100","used":"20","remaining":"80"}}]}"#
let kqStringWindow = KimiUsageService.parse(Data(kimiStringWindowFixture.utf8))
check("kimi string duration 5h parses", kqStringWindow?.fiveHour.used == 20)

// KimiWindow.pct 边界
let kw = KimiWindow(used: 5, limit: 1000, resetTimeMs: nil)
check("kimi window pct 0.5", kw.pct == 0.5)
check("kimi window pctInt 1", kw.pctInt == 1)
check("kimi window remaining 995", kw.remaining == 995)
check("kimi window zero limit pct 0", KimiWindow(used: 5, limit: 0, resetTimeMs: nil).pct == 0)

// 订阅共享池:Work/Kimi 与 Code 共用同一总额度,不能把两套 limit 相加。
let shared = KimiSubscriptionBalance(totalUsedRatio: 0.4173,
                                     codeUsedRatio: 0.2173,
                                     expireTimeMs: nil)
check("kimi shared total 41.73%", shared.totalUsedPercent == 41.73)
check("kimi shared code 21.73%", shared.codeUsedPercent == 21.73)
check("kimi shared work 20.00%", shared.workUsedPercent == 20.0)
check("kimi shared remaining 58.27%", shared.remainingPercent == 58.27)

let codeOverTotal = KimiSubscriptionBalance(totalUsedRatio: 0.30,
                                            codeUsedRatio: 0.80,
                                            expireTimeMs: nil)
check("kimi shared code clamps to total", codeOverTotal.codeUsedPercent == 30.0)
check("kimi shared work clamps to zero", codeOverTotal.workUsedPercent == 0.0)

let noCodeBreakdown = KimiSubscriptionBalance(totalUsedRatio: 0.30,
                                              codeUsedRatio: nil,
                                              expireTimeMs: nil)
check("kimi shared missing code stays nil", noCodeBreakdown.codeUsedPercent == nil)
check("kimi shared missing code work stays nil", noCodeBreakdown.workUsedPercent == nil)

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

// GetSubscriptionStats:账户共享池总量 + Code 子量,Work 为差值而非第二份额度。
let kimiStatsFixture = """
{
  "ratelimitCode5h":{"ratio":0.10,"enabled":true,"resetTime":"2026-08-03T14:36:22.762591Z"},
  "ratelimitCode7d":{"ratio":0.20,"enabled":true,"resetTime":"2026-08-04T14:36:22.762591Z"},
  "subscriptionBalance":{
    "feature":"FEATURE_OMNI",
    "type":"SUBSCRIPTION",
    "amountUsedRatio":0.4173,
    "kimiCodeUsedRatio":0.2173,
    "expireTime":"2026-08-20T00:00:00.000Z"
  }
}
"""
let stats = KimiUsageService.parseSubscriptionStats(Data(kimiStatsFixture.utf8))
check("kimi stats total ratio", stats?.totalUsedPercent == 41.73)
check("kimi stats code ratio", stats?.codeUsedPercent == 21.73)
check("kimi stats work ratio", stats?.workUsedPercent == 20.0)
check("kimi stats expire parsed", stats?.expireTimeMs != nil)

let statsWithoutCode = #"{"subscriptionBalance":{"amountUsedRatio":"0.3","expireTime":"2026-08-20T00:00:00Z"}}"#
let noCodeStats = KimiUsageService.parseSubscriptionStats(Data(statsWithoutCode.utf8))
check("kimi stats missing code accepted", noCodeStats?.totalUsedPercent == 30.0)
check("kimi stats missing code breakdown", noCodeStats?.codeUsedPercent == nil && noCodeStats?.workUsedPercent == nil)

let kimiWebMultiScopeFixture = #"""
{
  "usages":[
    {"scope":"FEATURE_OMNI","detail":{"limit":"100","used":"99","remaining":"1"}},
    {"scope":"FEATURE_CODING","detail":{"limit":"100","used":"58","remaining":"42"},"limits":[]}
  ],
  "totalQuota":{}
}
"""#
let multiScope = KimiUsageService.parseWebUsages(Data(kimiWebMultiScopeFixture.utf8))
check("web parser selects coding scope", multiScope?.weekly.used == 58)


// KimiQuota.monthlyResetDisplay 用订阅到期时间
let kq3 = KimiQuota(fiveHour: KimiWindow(used: 0, limit: 100, resetTimeMs: nil),
                    weekly: KimiWindow(used: 58, limit: 100, resetTimeMs: nil),
                    monthly: KimiWindow(used: 41, limit: 100, resetTimeMs: nil),
                    booster: nil, membershipLevel: nil,
                    subscriptionExpireMs: 1784678400000)
check("kimi monthlyReset uses expire", kq3.monthlyResetDisplay == "2026-07-22 08:00:00")

// --- Kimi 共享额度端到端(仅 KIMI_E2E=1;走本机 Keychain web token,不打印凭据)---
// 与 App 定时刷新同一调用路径(fetchQuota → GetUsages + GetSubscriptionStats)。
if ProcessInfo.processInfo.environment["KIMI_E2E"] == "1" {
    check("e2e web token in keychain", KimiUsageService.loadWebToken() != nil)
    let r = await KimiUsageService.fetchQuota()
    switch r {
    case .success(let q):
        check("e2e fetch success", true)
        check("e2e 5h parses", q.fiveHour.limit > 0)
        check("e2e weekly parses", q.weekly.limit > 0)
        if let b = q.subscriptionBalance {
            check("e2e shared total in 0...100", (0.0...100.0).contains(b.totalUsedPercent))
            if let code = b.codeUsedPercent, let work = b.workUsedPercent {
                check("e2e code <= total", code <= b.totalUsedPercent + 0.01)
                check("e2e segments sum to total", abs(code + work - b.totalUsedPercent) < 0.01)
                print("E2E summary: total=\(b.totalUsedPercent)% code=\(code)% work=\(work)% remaining=\(b.remainingPercent)% expire=\(b.expireTimeMs.map(String.init) ?? "nil")")
            } else {
                print("E2E summary: total=\(b.totalUsedPercent)% (Code 分项未返回,只显示总量)")
            }
        } else {
            check("e2e shared balance present", false)
            print("E2E: subscriptionBalance 为 nil(订阅统计未返回或已回退 coding API)")
        }
    case .failure(let e):
        check("e2e fetch success", false)
        print("E2E error: \(e)")
    }
} else {
    print("SKIP kimi e2e (set KIMI_E2E=1;uses local Keychain web token, no env credentials)")
}

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
// 首刷静默种子(P0-D3):第一轮 evaluate 只记录 band 不弹通知(防 8 条风暴)
let seedResult = tracker.evaluate([(k5h, 30), (k7d, 30)], config: tc)
check("tracker first eval silent seeds", seedResult.isEmpty)
check("tracker seeded states recorded", tracker.states[k5h] != nil && tracker.states[k7d] != nil)
// 种子后第二轮:5h 跨入 warning 触发,7d 仍在 safe 不触发
let fired1 = tracker.evaluate([(k5h, 85), (k7d, 50)], config: tc)
check("tracker fires only crossing window", fired1.count == 1 && fired1[0].0 == k5h && fired1[0].1 == .warning)
// 第三轮:5h 同级不触发,7d 跨入 critical 触发
let fired2 = tracker.evaluate([(k5h, 88), (k7d, 92)], config: tc)
check("tracker second eval: only 7d", fired2.count == 1 && fired2[0].0 == k7d && fired2[0].1 == .critical)
// 首刷即使已在 critical 也不弹(静默),下一轮维持 critical 仍不弹(迟滞)
var tracker2 = NotificationTracker()
check("tracker first-seen critical silent", tracker2.evaluate([(k5h, 95)], config: tc).isEmpty)
check("tracker critical->critical no fire", tracker2.evaluate([(k5h, 97)], config: tc).isEmpty)
// reset 后重新进入静默种子期
tracker2.reset()
check("tracker reset re-primes silent", tracker2.evaluate([(k5h, 95)], config: tc).isEmpty)
// clear(provider:) 只清该 Provider
tracker.clear(provider: "aliyun")
check("tracker clear aliyun empties aliyun", tracker.states[k5h] == nil && tracker.states[k7d] == nil)
check("tracker clear keeps others", tracker.states.isEmpty)

// --- ProcessRunner(P0-D1):echo/超时/失败语义 ---
func runEcho() -> ProcessRunner.Result {
    ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sh"),
                      arguments: ["-c", "echo hello; echo oops 1>&2"],
                      timeout: 5)
}
let echoR = runEcho()
check("pr echo exit 0", echoR.exitCode == 0 && !echoR.timedOut)
check("pr echo stdout", echoR.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
check("pr echo stderr", echoR.stderr.trimmingCharacters(in: .whitespacesAndNewlines) == "oops")
check("pr echo combined", echoR.combinedOutput.contains("hello") && echoR.combinedOutput.contains("oops"))
let slowR = ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sh"),
                              arguments: ["-c", "sleep 5"], timeout: 0.5)
check("pr slow times out", slowR.timedOut && slowR.exitCode == -1)
let badR = ProcessRunner.run(executable: URL(fileURLWithPath: "/nonexistent/xyz"),
                             arguments: [], timeout: 2)
check("pr launch failure nonzero", badR.exitCode == -1 && !badR.stderr.isEmpty)
// 热修复回归:孙进程继承管道(sh 退出后 sleep 仍持有 stdout)——
// 旧实现 readDataToEndOfFile + group.wait 会阻塞到孙进程结束;新实现必须数秒内返回
let grandchildStart = Date()
let gcR = ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sh"),
                            arguments: ["-c", "echo hello; sleep 30 &"],
                            timeout: 5)
let gcElapsed = Date().timeIntervalSince(grandchildStart)
check("pr grandchild returns fast (<4s)", gcElapsed < 4)
check("pr grandchild exit 0", gcR.exitCode == 0 && !gcR.timedOut)
check("pr grandchild stdout kept", gcR.stdout.contains("hello"))


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
// P2-B6:泛化预测——任意 provider/window 序列
let ocSnaps = [
    UsageSnapshot(timestamp: baseT, aliyunFiveHour: nil, aliyunOneWeek: nil,
                  opencodeRolling: nil, opencodeWeekly: nil, opencodeMonthly: 20),
    UsageSnapshot(timestamp: baseT.addingTimeInterval(3600), aliyunFiveHour: nil, aliyunOneWeek: nil,
                  opencodeRolling: nil, opencodeWeekly: nil, opencodeMonthly: 40),
]
check("history estimate generalized opencode monthly ~180min",
      HistoryStore.estimateMinutesToLimit(snapshots: ocSnaps, provider: "opencode", window: "monthly") == 180)
check("history estimate wrong window nil",
      HistoryStore.estimateMinutesToLimit(snapshots: ocSnaps, provider: "opencode", window: "weekly") == nil)

// P2-B5:CSV 输出(表头 + 行数 + 空值留空 + DeepSeek 金额列)
let csvOut = HistoryStore.csv(ocSnaps)
check("csv header", csvOut.hasPrefix("timestamp,aliyun5h,aliyun7d,opencodeRolling,opencodeWeekly,opencodeMonthly,kimi5h,kimiWeekly,kimiMonthly,deepseekBalance,deepseekTodayCost,zhipu5h,zhipuWeekly,mimoBalance,mimoPlanPct,minimaxInterval,minimaxWeekly"))
check("csv row count", csvOut.split(separator: "\n").count == 3)
check("csv empty cells", csvOut.split(separator: "\n")[1].components(separatedBy: ",").count == 17)
let dsCsvSnaps = [UsageSnapshot(timestamp: baseT, aliyunFiveHour: nil, aliyunOneWeek: nil,
                                opencodeRolling: nil, opencodeWeekly: nil, opencodeMonthly: nil,
                                deepSeekBalance: 110.0, deepSeekTodayCost: 1.5)]
let dsCsv = HistoryStore.csv(dsCsvSnaps)
let dsCells = dsCsv.split(separator: "\n")[1].components(separatedBy: ",")
check("csv deepseek 金额单元格", dsCells.count == 17 && dsCells[9] == "110.00" && dsCells[10] == "1.50")
check("csv 新增列空值留空", dsCells.suffix(7).dropFirst(2).allSatisfy { $0.isEmpty })

// FileHistoryBackend 往返(Codable)
let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent("atb-test-\(Int.random(in: 0..<1_000_000)).json")
let fb = FileHistoryBackend(url: tmpURL)
let sampleSnap = UsageSnapshot(timestamp: Date(timeIntervalSince1970: 1_700_000_000), aliyunFiveHour: 11, aliyunOneWeek: 22, opencodeRolling: 33, opencodeWeekly: 44, opencodeMonthly: 55)
fb.write([sampleSnap])
check("file backend roundtrip", fb.read() == [sampleSnap])
// 带 DeepSeek 字段的快照往返(新字段参与持久化)
let sampleSnapDs = UsageSnapshot(timestamp: Date(timeIntervalSince1970: 1_700_000_000), aliyunFiveHour: 11, aliyunOneWeek: 22, opencodeRolling: 33, opencodeWeekly: 44, opencodeMonthly: 55, deepSeekBalance: 110.0, deepSeekTodayCost: 1.5)
fb.write([sampleSnapDs])
check("file backend roundtrip with deepseek", fb.read() == [sampleSnapDs])
// 旧格式快照(无 DeepSeek 字段)解码后新字段为 nil → 向后兼容
let encOld = JSONEncoder()
encOld.dateEncodingStrategy = .iso8601
if let oldData = try? encOld.encode(sampleSnap) {
    let oldDecoded = FileHistoryBackend.decode(oldData).first
    check("v0 decode deepseek nil", oldDecoded?.deepSeekBalance == nil && oldDecoded?.deepSeekTodayCost == nil)
}
// v0 旧格式(JSON 数组)透明迁移读取
let encV0 = JSONEncoder()
encV0.dateEncodingStrategy = .iso8601
if let v0Data = try? encV0.encode([sampleSnap]) {
    check("history v0 array decodes", FileHistoryBackend.decode(v0Data) == [sampleSnap])
}
// v1 JSONL 容忍损坏行(单行坏不影响整体)
let encLine = JSONEncoder()
encLine.dateEncodingStrategy = .iso8601
let goodLine = (try? encLine.encode(sampleSnap)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
let v1WithBad = "// CodingTokenBar history v1 (JSONL: one snapshot per line)\nnot-json-garbage\n\(goodLine)\n"
check("history v1 skips bad line",
      FileHistoryBackend.decode(Data(v1WithBad.utf8)) == [sampleSnap])
check("history v1 empty header",
      FileHistoryBackend.decode(Data("// header only\n".utf8)).isEmpty)
try? FileManager.default.removeItem(at: tmpURL)

// --- 菜单栏状态项恢复阶梯(运行期图标被系统隐藏/停放的自愈) ---
var recovery = StatusItemRecoveryMonitor(requiredHiddenSamples: 3)
check("recovery transient hidden no action", recovery.sample(isEffectivelyVisible: false) == .none)
check("recovery visible resets samples", recovery.sample(isEffectivelyVisible: true) == .none)
check("recovery hidden sample 1", recovery.sample(isEffectivelyVisible: false) == .none)
check("recovery hidden sample 2", recovery.sample(isEffectivelyVisible: false) == .none)
check("recovery sustained hidden resurrects", recovery.sample(isEffectivelyVisible: false) == .resurrect)
// 触发动作后计数清零:重建前需再攒满 3 个异常样本
check("recovery action window sample 1", recovery.sample(isEffectivelyVisible: false) == .none)
check("recovery action window sample 2", recovery.sample(isEffectivelyVisible: false) == .none)
check("recovery still hidden recreates", recovery.sample(isEffectivelyVisible: false) == .recreate)
check("recovery recreate window sample 1", recovery.sample(isEffectivelyVisible: false) == .none)
check("recovery recreate window sample 2", recovery.sample(isEffectivelyVisible: false) == .none)
check("recovery final fallback docks", recovery.sample(isEffectivelyVisible: false) == .dockFallback)
check("recovery dock fallback fires once", recovery.sample(isEffectivelyVisible: false) == .none)
check("recovery dock fallback visible then hidden stays none", {
    _ = recovery.sample(isEffectivelyVisible: true)
    _ = recovery.sample(isEffectivelyVisible: false)
    _ = recovery.sample(isEffectivelyVisible: false)
    return recovery.sample(isEffectivelyVisible: false) == .none
}())
check("recovery dock fallback flag", recovery.hasIssuedDockFallback == true)
// 恢复可见后阶梯回零:下一次故障从最轻动作(resurrect)重新开始
var recovery2 = StatusItemRecoveryMonitor(requiredHiddenSamples: 3)
_ = recovery2.sample(isEffectivelyVisible: false)
_ = recovery2.sample(isEffectivelyVisible: false)
check("recovery2 first trouble resurrects", recovery2.sample(isEffectivelyVisible: false) == .resurrect)
_ = recovery2.sample(isEffectivelyVisible: true)
_ = recovery2.sample(isEffectivelyVisible: false)
_ = recovery2.sample(isEffectivelyVisible: false)
check("recovery2 ladder resets after recovery", recovery2.sample(isEffectivelyVisible: false) == .resurrect)

// --- 有效可见性判定(isVisible + 按钮帧在屏幕内;停放=帧在屏幕外) ---
let screens = [CGRect(x: 0, y: 0, width: 1728, height: 1117)]
check("effective hidden when not visible",
      StatusItemRecoveryMonitor.isEffectivelyVisible(isVisible: false, buttonFrame: CGRect(x: 1500, y: 5, width: 30, height: 24), screenFrames: screens) == false)
check("effective visible on screen",
      StatusItemRecoveryMonitor.isEffectivelyVisible(isVisible: true, buttonFrame: CGRect(x: 1500, y: 5, width: 30, height: 24), screenFrames: screens) == true)
// AX 观察到的停放位 (-1,1113)(左上原点)换算到 AppKit 左下原点坐标 ≈ (-1,-20):
// 帧大部分在屏幕外,只有边缘几像素蹭在屏幕内——按面积占比判定为不可见
check("parked frame mostly offscreen detected",
      StatusItemRecoveryMonitor.isEffectivelyVisible(isVisible: true, buttonFrame: CGRect(x: -1, y: -20, width: 30, height: 24), screenFrames: screens) == false)
check("parked frame grossly offscreen detected",
      StatusItemRecoveryMonitor.isEffectivelyVisible(isVisible: true, buttonFrame: CGRect(x: -200, y: -200, width: 30, height: 24), screenFrames: screens) == false)
check("missing frame trusts isVisible",
      StatusItemRecoveryMonitor.isEffectivelyVisible(isVisible: true, buttonFrame: nil, screenFrames: screens) == true)
check("no screens trusts isVisible",
      StatusItemRecoveryMonitor.isEffectivelyVisible(isVisible: true, buttonFrame: CGRect(x: 1500, y: 5, width: 30, height: 24), screenFrames: []) == true)
check("edge frame mostly onscreen still visible",
      StatusItemRecoveryMonitor.isEffectivelyVisible(isVisible: true, buttonFrame: CGRect(x: -10, y: 5, width: 30, height: 24), screenFrames: screens) == true)

// --- CredentialStore (InMemory + 迁移) ---
let cs = InMemoryCredentialStore()
cs.write("secret123", account: "opencode")
check("credstore read", cs.read(account: "opencode") == "secret123")
cs.delete(account: "opencode")
check("credstore delete", cs.read(account: "opencode") == nil)

// AK/SK Codable roundtrip + empty input rejection
let credential = AliyunOpenAPICredential(accessKeyID: " LTAI-test ", accessKeySecret: " secret-test ")
check("aliyun credential trims", credential?.accessKeyID == "LTAI-test" && credential?.accessKeySecret == "secret-test")
check("aliyun credential rejects empty", AliyunOpenAPICredential(accessKeyID: " ", accessKeySecret: "x") == nil)
if let credential,
   let encoded = try? JSONEncoder().encode(credential),
   let decoded = try? JSONDecoder().decode(AliyunOpenAPICredential.self, from: encoded) {
    check("aliyun credential Codable roundtrip", decoded == credential)
}
let configWithAKSK = #"{"token-plan":{"access_key_id":"LTAI-test","access_key_secret":"secret-test"}}"#
let configWithoutAKSK = #"{"token-plan":{"access_key_id":"LTAI-test"}}"#
let directConfig = #"{"access_key_id":"LTAI-test","access_key_secret":"secret-test"}"#
let routingFixture = #"{"console_region":"cn-beijing","console_site":"domestic","console_switch_agent":10079304}"#
check("bl config AK/SK fixture", BlAuthManager.parseOpenAPIConfig(Data(configWithAKSK.utf8)))
check("bl direct config fixture", BlAuthManager.parseOpenAPIConfig(Data(directConfig.utf8)))
check("bl config incomplete rejected", !BlAuthManager.parseOpenAPIConfig(Data(configWithoutAKSK.utf8)))
check("bl routing fixture", BlAuthManager.parseConsoleRouting(Data(routingFixture.utf8))?.switchAgent == 10079304)

// auth error classification must remain reachable from non-zero bl output
let expiredText = Data("Console session is not logged in or has expired.".utf8)
check("classify text auth expired", BlUsageService.classifyError(expiredText) == .authExpired)
check("classify NotLogined auth expired", BlUsageService.classifyError(Data("NotLogined".utf8)) == .authExpired)
check("classify ordinary error as network", BlUsageService.classifyError(Data("connection reset".utf8)) == .network("connection reset"))

// ACS3 request contract: fixed inputs produce signed Authorization without logging secret
if let credential {
    let request = AliyunOpenAPIService.makeTokenRequest(credential: credential,
                                                         timestamp: "2026-08-08T00:00:00Z",
                                                         nonce: "verify-nonce")
    let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
    check("ACS3 endpoint", request.url?.absoluteString == "https://modelstudio.cn-beijing.aliyuncs.com/modelstudio/cli/generateAccessToken")
    check("ACS3 method", request.httpMethod == "POST")
    check("ACS3 auth scheme", auth.hasPrefix("ACS3-HMAC-SHA256 Credential=LTAI-test"))
    check("ACS3 auth omits secret", !auth.contains("secret-test"))
    // 确定性:同 timestamp+nonce 重复构造,签名完全一致(纯函数,无随机)
    let request2 = AliyunOpenAPIService.makeTokenRequest(credential: credential,
                                                         timestamp: "2026-08-08T00:00:00Z",
                                                         nonce: "verify-nonce")
    check("ACS3 deterministic signature",
          request.value(forHTTPHeaderField: "Authorization") == request2.value(forHTTPHeaderField: "Authorization"))
    // SignedHeaders 必须按字典序排列(ACS3 规范),signature 为 64 位 hex
    let signed = request.value(forHTTPHeaderField: "Authorization")?
        .split(separator: ",").dropFirst()
        .first(where: { $0.hasPrefix("SignedHeaders=") })
        .map { $0.split(separator: "=").last.map(String.init) ?? "" } ?? ""
    let sig = request.value(forHTTPHeaderField: "Authorization")?
        .split(separator: ",")
        .first(where: { $0.hasPrefix("Signature=") })
        .map { $0.split(separator: "=").last.map(String.init) ?? "" } ?? ""
    check("ACS3 signedHeaders sorted", signed == signed.split(separator: ";").sorted().joined(separator: ";"))
    check("ACS3 signature 64hex", sig.count == 64 && sig.allSatisfy { $0.isHexDigit })
    // 空 body 的 sha256 必须为 SHA256("") 常量
    check("ACS3 empty body hash",
          request.value(forHTTPHeaderField: "x-acs-content-sha256")
            == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    // 不同 nonce → 不同签名(防固定签名)
    let request3 = AliyunOpenAPIService.makeTokenRequest(credential: credential,
                                                         timestamp: "2026-08-08T00:00:00Z",
                                                         nonce: "verify-nonce-2")
    check("ACS3 nonce changes signature",
          request.value(forHTTPHeaderField: "Authorization") != request3.value(forHTTPHeaderField: "Authorization"))
    // token 解析:嵌套 cliAccessToken / 平铺 access_token / accessToken / 垃圾
    check("ACS3 token nested cliAccessToken",
          AliyunOpenAPIService.parseAccessToken(Data(#"{"data":{"cliAccessToken":"tok-1"}}"#.utf8)) == "tok-1")
    check("ACS3 token flat access_token",
          AliyunOpenAPIService.parseAccessToken(Data(#"{"access_token":"tok-2"}"#.utf8)) == "tok-2")
    check("ACS3 token flat accessToken",
          AliyunOpenAPIService.parseAccessToken(Data(#"{"accessToken":"tok-3"}"#.utf8)) == "tok-3")
    check("ACS3 token empty string rejected",
          AliyunOpenAPIService.parseAccessToken(Data(#"{"cliAccessToken":""}"#.utf8)) == nil)
    check("ACS3 token garbage nil",
          AliyunOpenAPIService.parseAccessToken(Data("not json".utf8)) == nil)
}

// 自动恢复冷却纯函数(测 AliyunAuthRecovery,不引用 TokenPlanModel——
// 后者含 @Published,在 Verify 的 async 顶层触发 Combine metadata 崩溃)
let failBase = Date(timeIntervalSince1970: 1_700_000_000)
check("cooldown nil failedAt -> not cooling",
      !AliyunAuthRecovery.inCooldown(failedAt: nil, now: failBase, cooldownMinutes: 10))
check("cooldown within window -> cooling",
      AliyunAuthRecovery.inCooldown(failedAt: failBase, now: failBase.addingTimeInterval(9 * 60), cooldownMinutes: 10))
check("cooldown at boundary -> not cooling",
      !AliyunAuthRecovery.inCooldown(failedAt: failBase, now: failBase.addingTimeInterval(10 * 60), cooldownMinutes: 10))
check("cooldown past window -> not cooling",
      !AliyunAuthRecovery.inCooldown(failedAt: failBase, now: failBase.addingTimeInterval(30 * 60), cooldownMinutes: 10))
// cooldownMinutes 钳制到最小 1，避免 0 导致秒级冷却失效
check("cooldown zero minutes clamps to 1min",
      AliyunAuthRecovery.inCooldown(failedAt: failBase, now: failBase.addingTimeInterval(30), cooldownMinutes: 0))

// --- SelfUpdater 版本比较(P1-C1 纯函数)---
check("ver 1.0.28 newer than 1.0.27", SelfUpdater.isNewer("1.0.28", than: "1.0.27"))
check("ver 1.0.10 newer than 1.0.9", SelfUpdater.isNewer("1.0.10", than: "1.0.9"))
check("ver equal not newer", !SelfUpdater.isNewer("1.0.27", than: "1.0.27"))
check("ver older not newer", !SelfUpdater.isNewer("1.0.26", than: "1.0.27"))
check("ver 2.0.0 newer than 1.9.9", SelfUpdater.isNewer("2.0.0", than: "1.9.9"))
check("ver garbage differs by string", SelfUpdater.isNewer("abc", than: "def"))

// --- 临时目录清扫(P1-C8)---
let sweepDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("CodingTokenBar-bl-verify-sweep-\(UUID().uuidString)", isDirectory: true)
try? FileManager.default.createDirectory(at: sweepDir, withIntermediateDirectories: true)
// 置为 48h 前(清扫阈值 24h)
try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-48 * 3600)],
                                       ofItemAtPath: sweepDir.path)
BlEphemeralConfig.sweepStaleTempDirectories()
check("sweep removes stale temp dir", !FileManager.default.fileExists(atPath: sweepDir.path))
// 新目录(刚创建)必须保留
let freshDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("CodingTokenBar-bl-verify-fresh-\(UUID().uuidString)", isDirectory: true)
try? FileManager.default.createDirectory(at: freshDir, withIntermediateDirectories: true)
BlEphemeralConfig.sweepStaleTempDirectories()
check("sweep keeps fresh temp dir", FileManager.default.fileExists(atPath: freshDir.path))
try? FileManager.default.removeItem(at: freshDir)

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
// pageSize=0 → nil(纯函数契约)
check("mem zero pageSize -> nil",
      SystemMetricsMonitor.memoryUsedPercent(active: 1, wired: 1, compressed: 1,
                                             pageSize: 0, totalBytes: 16 * 1024 * 1024) == nil)
// 冒烟:本机真实采样必然非 nil
check("smoke sampleCPUTicks", SystemMetricsMonitor.sampleCPUTicks() != nil)
check("smoke sampleMemoryPercent", SystemMetricsMonitor.sampleMemoryPercent() != nil)

// --- ProcessListMonitor:纯函数 ---
func snap(_ pid: Int32, _ name: String, cpu: Double?, mem: UInt64) -> ProcessSnapshot {
    ProcessSnapshot(pid: pid, name: name, appName: name, appPath: nil,
                    cpuPercent: cpu, memoryBytes: mem, isRoot: false)
}
let plist = [snap(1, "a", cpu: 10, mem: 500), snap(2, "b", cpu: 90, mem: 100),
             snap(3, "c", cpu: nil, mem: 900), snap(4, "d", cpu: 50, mem: 700)]
check("topByCPU desc + nil last", ProcessListMonitor.topByCPU(plist).map(\.pid) == [2, 4, 1, 3])
check("topByCPU truncates", ProcessListMonitor.topByCPU(plist, limit: 2).map(\.pid) == [2, 4])
check("topByCPU empty safe", ProcessListMonitor.topByCPU([]).isEmpty)
check("topByMemory desc", ProcessListMonitor.topByMemory(plist).map(\.pid) == [3, 4, 1, 2])

check("bytesToHuman zero", ProcessListMonitor.bytesToHuman(0) == "0 B")
check("bytesToHuman 900", ProcessListMonitor.bytesToHuman(900) == "900 B")
check("bytesToHuman 1024", ProcessListMonitor.bytesToHuman(1024) == "1.0 KB")
check("bytesToHuman MB", ProcessListMonitor.bytesToHuman(350 * 1024 * 1024) == "350.0 MB")
check("bytesToHuman GB", ProcessListMonitor.bytesToHuman(UInt64(1.2 * 1024 * 1024 * 1024)) == "1.2 GB")

check("appBundlePath chrome",
      ProcessListMonitor.appBundlePath(fromExecutablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
      == "/Applications/Google Chrome.app")
check("appBundlePath nested",
      ProcessListMonitor.appBundlePath(fromExecutablePath: "/Users/x/Library/Application Support/Foo.app/Contents/MacOS/helper")
      == "/Users/x/Library/Application Support/Foo.app")
check("appBundlePath non-app nil",
      ProcessListMonitor.appBundlePath(fromExecutablePath: "/usr/sbin/mDNSResponder") == nil)
check("appBundlePath weird safe", ProcessListMonitor.appBundlePath(fromExecutablePath: "no-slash") == nil)

// CPU%:elapsed<=0 → nil
check("cpuPercent zero elapsed nil",
      ProcessListMonitor.cpuPercent(previousTicks: 100, currentTicks: 200, elapsedSeconds: 0) == nil)
// pid 复用/回绕:current < previous → nil(不产生天文数字假值)
check("cpuPercent wrap -> nil",
      ProcessListMonitor.cpuPercent(previousTicks: 1000, currentTicks: 5, elapsedSeconds: 3) == nil)
// 冒烟:全量采样非空且含本进程
let smokeAll = ProcessListMonitor.sampleAll(previousTicks: [:]).list
check("smoke sampleAll non-empty", !smokeAll.isEmpty)
check("smoke sampleAll contains self", smokeAll.contains { $0.pid == getpid() })

// --- DeepSeek API:余额解析 + 错误分类 ---
let dsFixture = Data(#"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"110.00","granted_balance":"10.00","topped_up_balance":"100.00"}]}"#.utf8)
check("ds parseBalance 官方样例",
      DeepSeekUsageService.parseBalance(dsFixture)
      == DeepSeekUsageService.DeepSeekBalance(isAvailable: true, currency: "CNY",
                                              totalBalance: 110.0, grantedBalance: 10.0, toppedUpBalance: 100.0))
// 金额为数字(非字符串)也宽容;is_available=false 仍解析
let dsNumeric = Data(#"{"is_available":false,"balance_infos":[{"currency":"USD","total_balance":5.5,"granted_balance":1,"topped_up_balance":4.5}]}"#.utf8)
check("ds parseBalance 数字金额 + is_available=false",
      DeepSeekUsageService.parseBalance(dsNumeric)
      == DeepSeekUsageService.DeepSeekBalance(isAvailable: false, currency: "USD",
                                              totalBalance: 5.5, grantedBalance: 1.0, toppedUpBalance: 4.5))
// 多币种优先 CNY
let dsMulti = Data(#"{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"5.00","granted_balance":"0","topped_up_balance":"5.00"},{"currency":"CNY","total_balance":"220.00","granted_balance":"20.00","topped_up_balance":"200.00"}]}"#.utf8)
check("ds parseBalance 多币种优先CNY",
      DeepSeekUsageService.parseBalance(dsMulti)?.currency == "CNY"
      && DeepSeekUsageService.parseBalance(dsMulti)?.totalBalance == 220.0)
// 空数组 / 损坏 JSON → nil
check("ds parseBalance 空数组 nil",
      DeepSeekUsageService.parseBalance(Data(#"{"is_available":true,"balance_infos":[]}"#.utf8)) == nil)
check("ds parseBalance 损坏 nil", DeepSeekUsageService.parseBalance(Data("not json".utf8)) == nil)
// 错误分类
check("ds classify 200 nil", DeepSeekUsageService.classifyBalanceError(statusCode: 200) == nil)
check("ds classify 401 authExpired", DeepSeekUsageService.classifyBalanceError(statusCode: 401) == .authExpired)
check("ds classify 403 authExpired", DeepSeekUsageService.classifyBalanceError(statusCode: 403) == .authExpired)
check("ds classify 500 network", DeepSeekUsageService.classifyBalanceError(statusCode: 500) == .network("HTTP 500"))

// --- DeepSeek 金额格式化 ---
check("ds money full 110", DeepSeekMoneyFormat.full(110) == "¥110.00")
check("ds money full 0", DeepSeekMoneyFormat.full(0) == "¥0.00")
check("ds money compact <100", DeepSeekMoneyFormat.compact(1.5) == "¥1.50")
check("ds money compact 0", DeepSeekMoneyFormat.compact(0) == "¥0.00")
check("ds money compact 100-1万", DeepSeekMoneyFormat.compact(110) == "¥110")
check("ds money compact 1万-1亿", DeepSeekMoneyFormat.compact(12345.6) == "¥1.2万")
check("ds money compact ≥1亿", DeepSeekMoneyFormat.compact(123_000_000) == "¥1.2亿")
check("ds money compact 负钳0", DeepSeekMoneyFormat.compact(-5) == "¥0.00")
// 契约:任何金额 ≤7 字符(渲染层值域宽依据)
check("ds money compact ≤7字符",
      [0.001, 9.99, 99.99, 9999.9, 12345.6, 123_000_000, 9_999_999_999]
          .allSatisfy { DeepSeekMoneyFormat.compact($0).count <= 7 })

// --- DeepSeek 当日费用账本(固定 GMT+8,纯函数)---
var dsCal = Calendar(identifier: .gregorian)
dsCal.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
func dsDate(_ h: Int, _ m: Int = 0, day: Int = 13) -> Date {
    var comps = DateComponents()
    comps.year = 2026; comps.month = 8; comps.day = day; comps.hour = h; comps.minute = m
    comps.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
    return dsCal.date(from: comps)!
}
check("ds ledger dateKey", DeepSeekDailyLedger.dateKey(dsDate(8), calendar: dsCal) == "2026-08-13")
// 首拉:建今日 entry,cost 0,estimated false(基线=今日首拉)
var dsEntries: [DeepSeekDailyEntry] = []
dsEntries = DeepSeekDailyLedger.record(entries: dsEntries, balance: 110.0, at: dsDate(8), calendar: dsCal)
var dsCost = DeepSeekDailyLedger.computeCost(entries: dsEntries, currentBalance: 110.0, at: dsDate(9), calendar: dsCal)
check("ds ledger 首拉 cost 0", dsCost.cost == 0 && dsCost.estimated == false)
// 同天消费 2.5 → cost 2.5
dsEntries = DeepSeekDailyLedger.record(entries: dsEntries, balance: 107.5, at: dsDate(10), calendar: dsCal)
dsCost = DeepSeekDailyLedger.computeCost(entries: dsEntries, currentBalance: 107.5, at: dsDate(11), calendar: dsCal)
check("ds ledger 当日费用 2.5", dsCost.cost == 2.5 && dsCost.estimated == false)
// 充值:余额涨到 200 → 基线重设,cost 归零
dsEntries = DeepSeekDailyLedger.record(entries: dsEntries, balance: 200.0, at: dsDate(12), calendar: dsCal)
dsCost = DeepSeekDailyLedger.computeCost(entries: dsEntries, currentBalance: 200.0, at: dsDate(13), calendar: dsCal)
check("ds ledger 充值重设基线", dsCost.cost == 0 && dsEntries.last?.firstBalance == 200.0)
// 充值后再消费 1 → cost 1
dsEntries = DeepSeekDailyLedger.record(entries: dsEntries, balance: 199.0, at: dsDate(14), calendar: dsCal)
dsCost = DeepSeekDailyLedger.computeCost(entries: dsEntries, currentBalance: 199.0, at: dsDate(15), calendar: dsCal)
check("ds ledger 充值后重新累计 1", dsCost.cost == 1.0)
// 微涨不超 0.001 → 浮点抖动不算充值
dsEntries = DeepSeekDailyLedger.record(entries: dsEntries, balance: 199.0005, at: dsDate(16), calendar: dsCal)
check("ds ledger 微涨不算充值", dsEntries.last?.firstBalance == 200.0)
// 次日:今天还没拉到快照 → 用昨日余额估算(199.0005 − 197.2 = 1.8005)
let dsCostNextDay = DeepSeekDailyLedger.computeCost(entries: dsEntries, currentBalance: 197.2,
                                                    at: dsDate(8, day: 14), calendar: dsCal)
check("ds ledger 次日估算", abs(dsCostNextDay.cost - 1.8005) < 0.0001 && dsCostNextDay.estimated == true)
// 次日首拉:新 entry,基线 = 首拉余额,费用从此刻精确累计
dsEntries = DeepSeekDailyLedger.record(entries: dsEntries, balance: 197.2, at: dsDate(8, day: 14), calendar: dsCal)
check("ds ledger 次日新 entry", dsEntries.count == 2 && dsEntries.last?.date == "2026-08-14")
let dsCostDay2 = DeepSeekDailyLedger.computeCost(entries: dsEntries, currentBalance: 196.7,
                                                 at: dsDate(12, day: 14), calendar: dsCal)
check("ds ledger 次日精确累计 0.5", abs(dsCostDay2.cost - 0.5) < 0.0001 && dsCostDay2.estimated == false)
// 无历史:cost 0 + estimated true(首拉即基线)
check("ds ledger 无历史", DeepSeekDailyLedger.computeCost(entries: [], currentBalance: 5,
                                                          at: dsDate(9), calendar: dsCal)
      == DeepSeekDailyCost(cost: 0, estimated: true, baselineAt: nil))
// 淘汰:超过 32 天只留最近 32 条
var manyEntries: [DeepSeekDailyEntry] = []
for d in 1...40 {
    manyEntries = DeepSeekDailyLedger.record(entries: manyEntries, balance: 100,
                                             at: dsDate(8, day: d), calendar: dsCal)
}
check("ds ledger 淘汰至32天", manyEntries.count == 32 && manyEntries.first?.date == "2026-08-09")

// --- MenuBarTable:迷你表格列模型 ---
func mtCols(
    a5: Int? = 40, a7: Int? = 18,
    kConf: Bool = true, kErr: Bool = false, k5: Int? = 0, kW: Int? = 58,
    oConf: Bool = true, oErr: Bool = false, oR: Int? = 3, oW: Int? = 2,
    dConf: Bool = true, dErr: Bool = false, dCost: Double? = 1.5, dBal: Double? = 110.0,
    mmConf: Bool = true, mmErr: Bool = false, mmI: Int? = 1, mmW: Int? = 1,
    sysOn: Bool = true, cpu: Int? = 12, mem: Int? = 25,
    dis: Set<String> = []
) -> [MenuBarTableColumn] {
    MenuBarTable.columns(aliyunFiveHour: a5, aliyunOneWeek: a7,
        kimiConfigured: kConf, kimiHasError: kErr, kimiFiveHour: k5, kimiWeekly: kW,
        openCodeConfigured: oConf, openCodeHasError: oErr, openCodeRolling: oR, openCodeWeekly: oW,
        deepSeekConfigured: dConf, deepSeekHasError: dErr, deepSeekTodayCost: dCost, deepSeekBalance: dBal,
        minimaxConfigured: mmConf, minimaxHasError: mmErr, minimaxInterval: mmI, minimaxWeekly: mmW,
        systemEnabled: sysOn, cpu: cpu, memory: mem,
        disabled: dis)
}

let mtAll = mtCols()
check("mt 6列全显示且固定顺序(本机恒最后)", mtAll.map(\.kind) == [.aliyun, .kimi, .openCode, .deepSeek, .minimax, .system])
check("mt 阿里云主次值", mtAll[0].primary.text == "40%" && mtAll[0].secondary.text == "18%")
check("mt 0% 不省略", mtAll[1].primary.text == "0%" && mtAll[1].primary.pct == 0)
check("mt DeepSeek 金额主次值", mtAll[3].primary.text == "¥1.50" && mtAll[3].secondary.text == "¥110"
      && mtAll[3].primary.pct == nil && mtAll[3].secondary.pct == nil)
check("mt MiniMax 主次值", mtAll[4].primary.text == "1%" && mtAll[4].secondary.text == "1%"
      && mtAll[4].primaryLabel == "本窗" && mtAll[4].secondaryLabel == "周")
check("mt 未配置Kimi→隐藏", mtCols(kConf: false).map(\.kind) == [.aliyun, .openCode, .deepSeek, .minimax, .system])
check("mt 未配置OpenCode→隐藏", mtCols(oConf: false).map(\.kind) == [.aliyun, .kimi, .deepSeek, .minimax, .system])
check("mt 未配置DeepSeek→隐藏", mtCols(dConf: false).map(\.kind) == [.aliyun, .kimi, .openCode, .minimax, .system])
check("mt 未配置MiniMax→隐藏", mtCols(mmConf: false).map(\.kind) == [.aliyun, .kimi, .openCode, .deepSeek, .system])
check("mt 本机关闭→隐藏(仍恒最后)", mtCols(sysOn: false).map(\.kind) == [.aliyun, .kimi, .openCode, .deepSeek, .minimax])
let mtErr = mtCols(kErr: true, k5: nil, kW: nil)
check("mt 已配置+出错→横杠列", mtErr.map(\.kind).contains(.kimi)
      && mtErr[1].primary.text == "—" && mtErr[1].primary.pct == nil
      && mtErr[1].secondary.text == "—")
check("mt 已配置无数据无错→隐藏", !mtCols(k5: nil, kW: nil).map(\.kind).contains(.kimi))
let mtDsErr = mtCols(dErr: true, dCost: nil, dBal: nil)
check("mt DeepSeek 出错→横杠", mtDsErr[3].primary.text == "—" && mtDsErr[3].secondary.text == "—"
      && mtDsErr[3].primary.pct == nil)
let mmErrCols = mtCols(mmErr: true, mmI: nil, mmW: nil)
check("mt MiniMax 出错→横杠列", mmErrCols[4].primary.text == "—" && mmErrCols[4].secondary.text == "—"
      && mmErrCols[4].primary.pct == nil)
check("mt MiniMax 已配置无数据无错→隐藏", !mtCols(mmI: nil, mmW: nil).map(\.kind).contains(.minimax))
check("mt 本机未采样→横杠(仍在末位)", mtCols(cpu: nil, mem: nil)[5].primary.text == "—")
check("mt 阿里云启用+无数据→横杠列", mtCols(a5: nil, a7: nil)[0].primary.text == "—")
// 5h 窗口取消形态:单值列(主行 7d,次行横杠对齐网格,tooltip 省略次段)
let mtNo5h = mtCols(a5: nil, a7: 11)
check("mt 5h无窗口→主行显7d", mtNo5h[0].primary.text == "11%" && mtNo5h[0].primary.pct == 11)
check("mt 5h无窗口→单值列标签", mtNo5h[0].primaryLabel == "7天" && mtNo5h[0].secondaryLabel == nil)
check("mt 5h无窗口→次行横杠", mtNo5h[0].secondary.text == "—" && mtNo5h[0].secondary.pct == nil)
check("mt 5h无窗口 tooltip", MenuBarTable.tooltip(columns: mtNo5h).hasPrefix("阿里云 7天 11% |"))
let mtTip = MenuBarTable.tooltip(columns: mtAll)
check("mt tooltip 全文", mtTip == "阿里云 5小时 40% · 7天 18% | Kimi 5小时 0% · 周 58% | OpenCode 滚动 3% · 周 2% | DeepSeek 今日 ¥1.50 · 余额 ¥110 | MiniMax 本窗 1% · 周 1% | 本机 CPU 12% · 内存 25%")
check("mt tooltip 横杠形态", MenuBarTable.tooltip(columns: mtErr).contains("Kimi 5小时 — · 周 —"))

// 渲染契约:百分比列值文本最长 4 字符("100%");DeepSeek 金额列最长 7 字符
check("mt 百分比列≤4字符", mtCols(a5: 100, a7: 100, k5: 100, kW: 100, oR: 100, oW: 100, mmI: 100, mmW: 100, cpu: 100, mem: 100)
    .filter { $0.kind != .deepSeek }
    .allSatisfy { $0.primary.text.count <= 4 && $0.secondary.text.count <= 4 })
check("mt DeepSeek 金额列≤7字符", mtCols(dCost: 0.01, dBal: 123456.78)[3].primary.text.count <= 7
      && mtCols(dCost: 0.01, dBal: 123456.78)[3].secondary.text.count <= 7
      && mtCols(dCost: 9999.9, dBal: 100_000_000)[3].primary.text.count <= 7
      && mtCols(dCost: 9999.9, dBal: 100_000_000)[3].secondary.text.count <= 7)

// --- 数据源停用开关(disabledProviders,全面停用语义的菜单栏列过滤) ---
check("mt 停用阿里云→列隐藏(不再恒显示)", mtCols(dis: ["aliyun"]).map(\.kind) == [.kimi, .openCode, .deepSeek, .minimax, .system])
check("mt 停用Kimi→已配置有数据也隐藏", !mtCols(dis: ["kimi"]).map(\.kind).contains(.kimi))
check("mt 停用DeepSeek→列隐藏", mtCols(dis: ["deepSeek"]).map(\.kind) == [.aliyun, .kimi, .openCode, .minimax, .system])
check("mt 停用本机→列隐藏(同 systemEnabled=false)", mtCols(dis: ["system"]).map(\.kind) == [.aliyun, .kimi, .openCode, .deepSeek, .minimax])
check("mt 停用不影响其余列顺序", mtCols(dis: ["openCode", "minimax"]).map(\.kind) == [.aliyun, .kimi, .deepSeek, .system])
check("mt 停用集含未知rawValue→忽略", mtCols(dis: ["bogus"]).map(\.kind) == mtCols().map(\.kind))
check("mt 全部停用→空列(渲染层降级仅图标)", mtCols(dis: Set(ProviderKind.allCases.map(\.rawValue))).isEmpty)
check("mt 停用列不进 tooltip", !MenuBarTable.tooltip(columns: mtCols(dis: ["kimi"])).contains("Kimi"))

// --- ProviderKind 统一 registry ---
check("registry 8 个数据源(7 订阅商+本机)", ProviderKind.allCases.count == 8
      && ProviderKind.allCases.map(\.rawValue) == ["aliyun", "openCode", "kimi", "deepSeek", "zhipu", "mimo", "minimax", "system"])
check("registry 面板 tab 顺序=旧 ProviderTab 顺序", ProviderKind.allCases.map(\.displayName)
      == ["阿里云", "OpenCode", "Kimi", "DeepSeek", "智谱 GLM", "MiMo", "MiniMax", "本机"])
check("registry 菜单栏列映射(智谱/MiMo 暂无列)", ProviderKind.allCases.compactMap(\.menuBarColumnKind)
      == [.aliyun, .openCode, .kimi, .deepSeek, .minimax, .system])
check("registry 列→provider 反向映射全覆盖", MenuBarColumnKind.allCases.allSatisfy {
    ProviderKind.from(menuBarColumnKind: $0).menuBarColumnKind == $0
})
check("registry 面板恒在项=阿里云/DeepSeek/本机", ProviderKind.allCases.filter(\.panelTabAlwaysListed)
      == [.aliyun, .deepSeek, .system])

// --- 停用集一次性迁移(纯函数) ---
check("迁移 新键缺失+旧键false→system停用", ProviderVisibilityMigration.initialDisabledSet(
    existing: nil, legacySystemStatsEnabled: false) == ["system"])
check("迁移 新键缺失+旧键true→空集", ProviderVisibilityMigration.initialDisabledSet(
    existing: nil, legacySystemStatsEnabled: true).isEmpty)
check("迁移 新键缺失+旧键缺失→空集", ProviderVisibilityMigration.initialDisabledSet(
    existing: nil, legacySystemStatsEnabled: nil).isEmpty)
check("迁移 新键存在→旧键不参与", ProviderVisibilityMigration.initialDisabledSet(
    existing: ["kimi"], legacySystemStatsEnabled: false) == ["kimi"])

// --- ZhipuUsageService:智谱 GLM Coding Plan 解析 ---
// fixture = 2026-08-14 真实响应(双 TOKENS_LIMIT + TIME_LIMIT + level max)
let zhipuLive = #"{"code":200,"msg":"操作成功","data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":11,"nextResetTime":1786703321390},{"type":"TOKENS_LIMIT","unit":6,"number":1,"percentage":2,"nextResetTime":1786888215998},{"type":"TIME_LIMIT","unit":5,"number":1,"usage":4000,"currentValue":5,"remaining":3995,"percentage":1,"nextResetTime":1787925015983,"usageDetails":[{"modelCode":"search-prime","usage":2},{"modelCode":"web-reader","usage":0},{"modelCode":"zread","usage":3}]}],"level":"max"},"success":true}"#
let zq = ZhipuUsageService.parseQuota(from: Data(zhipuLive.utf8))
check("zhipu live parse ok", zq != nil)
check("zhipu 5h=11", zq?.fiveHour?.pct == 11)
check("zhipu 5h reset ms", zq?.fiveHour?.resetTimeMs == 1786703321390)
check("zhipu weekly=2", zq?.weekly?.pct == 2)
check("zhipu level=max", zq?.level == "max")
check("zhipu mcp pct=1", zq?.mcp?.percentage == 1)
check("zhipu mcp usageText", zq?.mcp?.usageText == "5/4000 次")
check("zhipu mcp details=3", zq?.mcp?.details.count == 3)
check("zhipu mcp detail values", zq?.mcp?.details.first?.modelCode == "search-prime"
      && zq?.mcp?.details.first?.usage == 2)
check("zhipu mcp reset", zq?.mcp?.resetTimeMs == 1787925015983)
// 倒序乱序 limits:排序按窗口时长,不依赖返回顺序
let zhipuShuffled = #"{"code":200,"success":true,"data":{"limits":[{"type":"TOKENS_LIMIT","unit":6,"number":1,"percentage":2},{"type":"TIME_LIMIT","unit":5,"number":1,"percentage":1},{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":11}],"level":"pro"}}"#
let zq2 = ZhipuUsageService.parseQuota(from: Data(zhipuShuffled.utf8))
check("zhipu shuffled 5h=11", zq2?.fiveHour?.pct == 11)
check("zhipu shuffled weekly=2", zq2?.weekly?.pct == 2)
check("zhipu shuffled level=pro", zq2?.level == "pro")
// 单条 TOKENS_LIMIT:窗口 ≥24h 归周,<24h 归 5h
let zhipuWeeklyOnly = #"{"code":200,"success":true,"data":{"limits":[{"type":"TOKENS_LIMIT","unit":6,"number":1,"percentage":7}]}}"#
let zq3 = ZhipuUsageService.parseQuota(from: Data(zhipuWeeklyOnly.utf8))
check("zhipu weekly-only归类", zq3?.fiveHour == nil && zq3?.weekly?.pct == 7)
let zhipu5hOnly = #"{"code":200,"success":true,"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":9}]}}"#
let zq4 = ZhipuUsageService.parseQuota(from: Data(zhipu5hOnly.utf8))
check("zhipu 5h-only归类", zq4?.weekly == nil && zq4?.fiveHour?.pct == 9)
// 空 limits / 缺 data
check("zhipu empty limits -> 无窗口", ZhipuUsageService.parseQuota(
    from: Data(#"{"code":200,"success":true,"data":{"limits":[]}}"#.utf8))?.fiveHour == nil)
check("zhipu missing data -> nil", ZhipuUsageService.parseQuota(
    from: Data(#"{"code":200,"success":true}"#.utf8)) == nil)
// 业务错误包络:code 1001 → authExpired;其它 code → invalidResponse;success 包 → nil
check("zhipu 1001 -> authExpired", ZhipuUsageService.envelopeError(
    in: Data(#"{"code":1001,"msg":"Header中未收到Authorization参数，无法进行身份验证。","success":false}"#.utf8)) == .authExpired)
check("zhipu other code -> invalidResponse", {
    if case .invalidResponse = ZhipuUsageService.envelopeError(
        in: Data(#"{"code":500,"msg":"server busy","success":false}"#.utf8)) { return true }
    return false
}())
check("zhipu success envelope -> nil", ZhipuUsageService.envelopeError(
    in: Data(zhipuLive.utf8)) == nil)
check("zhipu error envelope not parsed", ZhipuUsageService.parseQuota(
    from: Data(#"{"code":1001,"msg":"Header中未收到Authorization参数","success":false}"#.utf8)) == nil)
// windowMinutes 枚举(1=天 3=小时 5=分钟 6=周)
check("zhipu unit 3h×5=300min", ZhipuUsageService.windowMinutes(unit: 3, number: 5) == 300)
check("zhipu unit 6w×1=10080min", ZhipuUsageService.windowMinutes(unit: 6, number: 1) == 10080)
check("zhipu unit 1d×2=2880min", ZhipuUsageService.windowMinutes(unit: 1, number: 2) == 2880)
check("zhipu unit 5m×30=30min", ZhipuUsageService.windowMinutes(unit: 5, number: 30) == 30)
check("zhipu unit unknown -> nil", ZhipuUsageService.windowMinutes(unit: 9, number: 1) == nil)
check("zhipu number 0 -> nil", ZhipuUsageService.windowMinutes(unit: 3, number: 0) == nil)
// 重置倒计时文案(共享 resetText)
let zReset90 = Int64((Date().addingTimeInterval(90 * 60).timeIntervalSince1970) * 1000)
let zt = ZhipuWindow.resetText(fromMs: zReset90)
check("zhipu 90min contains 1小时", zt?.contains("1小时") == true && zt?.contains("分钟") == true)
check("zhipu past reset -> nil", ZhipuWindow.resetText(
    fromMs: Int64((Date().timeIntervalSince1970 - 60) * 1000)) == nil)
check("zhipu nil reset -> nil", ZhipuWindow.resetText(fromMs: nil) == nil)
let zMCPNoUsage = ZhipuMCPQuota(usage: nil, currentValue: nil, remaining: nil,
                                percentage: 3, resetTimeMs: nil, details: [])
check("zhipu mcp usageText nil 兜底", zMCPNoUsage.usageText == nil)
// UsageSnapshot:旧 JSON(无 zhipu 字段)解码兼容 + 新字段往返
let zOldSnapJson = #"{"timestamp":700000000,"aliyunFiveHour":10,"aliyunOneWeek":5}"#
let zOldSnap = try? JSONDecoder().decode(UsageSnapshot.self, from: Data(zOldSnapJson.utf8))
check("zhipu snapshot 旧JSON兼容", zOldSnap?.zhipuFiveHour == nil && zOldSnap?.zhipuWeekly == nil)
let zNewSnap = UsageSnapshot(timestamp: Date(), aliyunFiveHour: nil, aliyunOneWeek: nil,
                             opencodeRolling: nil, opencodeWeekly: nil, opencodeMonthly: nil,
                             zhipuFiveHour: 11, zhipuWeekly: 2)
let zEnc = try? JSONEncoder().encode(zNewSnap)
let zDec = zEnc.flatMap { try? JSONDecoder().decode(UsageSnapshot.self, from: $0) }
check("zhipu snapshot 新字段往返", zDec?.zhipuFiveHour == 11 && zDec?.zhipuWeekly == 2)
check("zhipu series 映射", HistoryStore.series([zNewSnap], provider: "zhipu", window: "5h") == [11]
      && HistoryStore.series([zNewSnap], provider: "zhipu", window: "weekly") == [2])

// --- 小米 MiMo 开放平台(余额 + Token 套餐)---
let mimoBal = MiMoUsageService.parseBalance(from: Data(
    #"{"code":0,"message":"success","data":{"balance":"110.50","currency":"CNY","cashBalance":"100.50","giftBalance":"10.00"}}"#.utf8))
check("mimo balance ok", mimoBal != nil)
check("mimo balance=110.5", mimoBal?.balance == 110.5)
check("mimo currency CNY", mimoBal?.currency == "CNY")
check("mimo cash=100.5", mimoBal?.cashBalance == 100.5)
check("mimo gift=10", mimoBal?.giftBalance == 10.0)
check("mimo 数字金额容忍", MiMoUsageService.parseBalance(from: Data(
    #"{"code":0,"data":{"balance":88,"currency":"CNY"}}"#.utf8))?.balance == 88)
check("mimo code≠0 拒绝", MiMoUsageService.parseBalance(from: Data(
    #"{"code":401,"message":"unauthorized"}"#.utf8)) == nil)
check("mimo 缺 data 拒绝", MiMoUsageService.parseBalance(from: Data(#"{"code":0}"#.utf8)) == nil)

let mimoDetail = MiMoUsageService.parsePlanDetail(from: Data(
    #"{"code":0,"data":{"planCode":"standard","currentPeriodEnd":"2026-09-01 00:00:00","expired":false}}"#.utf8))
check("mimo detail planCode", mimoDetail?.planCode == "standard")
check("mimo detail 未过期", mimoDetail?.expired == false)
check("mimo detail periodEnd 2026", Calendar.current.dateComponents([.year], from: mimoDetail?.periodEnd ?? Date()).year == 2026)
check("mimo detail code≠0 → nil", MiMoUsageService.parsePlanDetail(from: Data(
    #"{"code":500,"message":"boom"}"#.utf8)) == nil)

let mimoPlanUsage = MiMoUsageService.parsePlanUsage(from: Data(
    #"{"code":0,"data":{"monthUsage":{"percent":0.1633,"items":[{"name":"default","used":163326,"limit":1000000,"percent":0.1633}]}}}"#.utf8))
check("mimo plan used", mimoPlanUsage?.used == 163326)
check("mimo plan limit", mimoPlanUsage?.limit == 1_000_000)
check("mimo plan pct≈16.33", abs((mimoPlanUsage?.usedPct ?? 0) - 16.33) < 0.01)
check("mimo plan 无percent→计数计算", MiMoUsageService.parsePlanUsage(from: Data(
    #"{"code":0,"data":{"monthUsage":{"items":[{"used":50,"limit":200}]}}}"#.utf8))?.usedPct == 25)

check("mimo cookie 合法(带前缀)", MiMoUsageService.normalizedCookie(
    from: "Cookie: api-platform_serviceToken=abc; userId=123") != nil)
check("mimo cookie 去前缀", MiMoUsageService.normalizedCookie(
    from: "Cookie: api-platform_serviceToken=abc; userId=123") == "api-platform_serviceToken=abc; userId=123")
check("mimo cookie 缺 serviceToken → nil", MiMoUsageService.normalizedCookie(from: "userId=123") == nil)
check("mimo cookie 缺 userId → nil", MiMoUsageService.normalizedCookie(from: "api-platform_serviceToken=abc") == nil)
check("mimo cookie 大小写不敏感", MiMoUsageService.normalizedCookie(
    from: "api-platform_ServiceToken=x; UserID=1") != nil)

check("mimo 200→nil", MiMoUsageService.classifyHTTP(200) == nil)
check("mimo 302→loginRequired", MiMoUsageService.classifyHTTP(302) == .loginRequired)
check("mimo 401→loginRequired", MiMoUsageService.classifyHTTP(401) == .loginRequired)
check("mimo 403→invalidCredentials", MiMoUsageService.classifyHTTP(403) == .invalidCredentials)
check("mimo 500→unknown", {
    if case .unknown = MiMoUsageService.classifyHTTP(500)! { return true }
    return false
}())
check("mimo envelope 0→nil", MiMoUsageService.classifyEnvelope(code: 0, message: nil) == nil)
check("mimo envelope 401→loginRequired", MiMoUsageService.classifyEnvelope(code: 401, message: nil) == .loginRequired)
check("mimo envelope 403→invalidCredentials", MiMoUsageService.classifyEnvelope(code: 403, message: nil) == .invalidCredentials)
check("mimo envelope 1000→parse", {
    if case .parse = MiMoUsageService.classifyEnvelope(code: 1000, message: "boom")! { return true }
    return false
}())

check("mimo money full CNY", MiMoMoneyFormat.full(110.5, currency: "CNY") == "¥110.50")
check("mimo money full USD", MiMoMoneyFormat.full(9.5, currency: "USD") == "$9.50")
check("mimo money compact 万", MiMoMoneyFormat.compact(12345.6, currency: "CNY") == "¥1.2万")
check("mimo money compact 小额", MiMoMoneyFormat.compact(9.996, currency: "CNY") == "¥10.00")

// --- MiniMax Coding Plan(token_plan/remains)---
// 2026-08-18 真实订阅 payload(CN 端点原样):general 纯百分比窗口(total=0)
// + video 专项日/周次数;base_resp 成功。
let mmLive = #"{"model_remains":[{"start_time":1786982400000,"end_time":1787000400000,"remains_time":17656587,"current_interval_total_count":0,"current_interval_usage_count":0,"model_name":"general","current_weekly_total_count":0,"current_weekly_usage_count":0,"weekly_start_time":1786896000000,"weekly_end_time":1787500800000,"weekly_remains_time":518056587,"current_interval_status":1,"current_interval_remaining_percent":100,"current_weekly_status":1,"current_weekly_remaining_percent":100},{"start_time":1786982400000,"end_time":1787068800000,"remains_time":86056587,"current_interval_total_count":3,"current_interval_usage_count":0,"model_name":"video","current_weekly_total_count":21,"current_weekly_usage_count":0,"weekly_start_time":1786896000000,"weekly_end_time":1787500800000,"weekly_remains_time":518056587,"current_interval_status":1,"current_interval_remaining_percent":100,"current_weekly_status":1,"current_weekly_remaining_percent":100}],"base_resp":{"status_code":0,"status_msg":"success"}}"#
let mmq = MiniMaxUsageService.parseQuota(from: Data(mmLive.utf8))
check("minimax 真实 payload 解析 ok", mmq != nil)
check("minimax 主条目=general", mmq?.modelName == "general")
check("minimax general 纯百分比窗口 pct=0", mmq?.interval?.pct == 0)
check("minimax general total=0 → usageText nil", mmq?.interval?.usageText == nil)
check("minimax general interval reset=endTime", mmq?.interval?.resetTimeMs == 1_787_000_400_000)
check("minimax general 周窗口 pct=0", mmq?.weekly?.pct == 0)
check("minimax general 周窗口 reset", mmq?.weekly?.resetTimeMs == 1_787_500_800_000)
check("minimax 其他模型条目=video", mmq?.models.count == 1 && mmq?.models.first?.name == "video")
check("minimax video 日次数(percent反推)", mmq?.models.first?.interval?.usageText == "0/3 次")
check("minimax video 周次数", mmq?.models.first?.weekly?.usageText == "0/21 次")

// percent 反推计数(rp=83 → 剩 498/600,已用 102,pct 17;usage_count 故意填错值验证被忽略)
let mmRp = #"{"data":{"model_remains":[{"model_name":"general","current_interval_total_count":600,"current_interval_usage_count":999,"end_time":1787000400000,"current_interval_remaining_percent":83}]}}"#
let mmqRp = MiniMaxUsageService.parseQuota(from: Data(mmRp.utf8))
check("minimax rp=83 → pct=17", mmqRp?.interval?.pct == 17)
check("minimax rp 反推计数 used=102 remaining=498", mmqRp?.interval?.used == 102 && mmqRp?.interval?.remaining == 498)

// percent 缺失 → 字面语义 usage_count=已用(2026-08-18 实测修正;旧社区口径相反,见模型头注释)
let mmNoPct = #"{"data":{"model_remains":[{"model_name":"general","current_interval_total_count":200,"current_interval_usage_count":50,"remains_time":600000,"current_weekly_total_count":0,"current_weekly_usage_count":0}]}}"#
let mmq2 = MiniMaxUsageService.parseQuota(from: Data(mmNoPct.utf8))
check("minimax 无percent→字面语义 used=50 pct=25%", mmq2?.interval?.pct == 25 && mmq2?.interval?.used == 50)
check("minimax 周额度0且无percent→nil", mmq2?.weekly == nil)
check("minimax 无 general→首条为主条目", MiniMaxUsageService.parseQuota(from: Data(
    #"{"data":{"model_remains":[{"model_name":"MiniMax-M2.5","current_interval_total_count":10,"current_interval_usage_count":2,"current_interval_remaining_percent":80}]}}"#.utf8))?.modelName == "MiniMax-M2.5")
check("minimax total0且无percent→窗口nil", MiniMaxUsageService.parseQuota(from: Data(
    #"{"data":{"model_remains":[{"model_name":"M","current_interval_total_count":0,"current_interval_usage_count":0}]}}"#.utf8))?.interval == nil)
check("minimax 空 model_remains→nil", MiniMaxUsageService.parseQuota(from: Data(
    #"{"data":{"model_remains":[]}}"#.utf8)) == nil)

check("minimax envelope 1004→authExpired", MiniMaxUsageService.envelopeError(in: Data(
    #"{"base_resp":{"status_code":1004,"status_msg":"not login"}}"#.utf8)) == .authExpired)
check("minimax envelope 2062→noSubscription(实测)", MiniMaxUsageService.envelopeError(in: Data(
    #"{"base_resp":{"status_code":2062,"status_msg":"no active token plan subscription"}}"#.utf8)) == .noSubscription)
check("minimax envelope 2062 空消息→noSubscription", MiniMaxUsageService.envelopeError(in: Data(
    #"{"base_resp":{"status_code":2062}}"#.utf8)) == .noSubscription)
check("minimax envelope 1024→invalidResponse", {
    if case .invalidResponse = MiniMaxUsageService.envelopeError(in: Data(
        #"{"base_resp":{"status_code":1024,"status_msg":"insufficient"}}"#.utf8))! { return true }
    return false
}())
check("minimax envelope 内嵌 data→authExpired", MiniMaxUsageService.envelopeError(in: Data(
    #"{"data":{"base_resp":{"status_code":1004}}}"#.utf8)) == .authExpired)
check("minimax envelope 0→nil", MiniMaxUsageService.envelopeError(in: Data(mmLive.utf8)) == nil)

check("minimax epochMs 秒→毫秒", MiniMaxUsageService.epochMs(1_755_400_000) == 1_755_400_000_000)
check("minimax epochMs 毫秒原样", MiniMaxUsageService.epochMs(1_755_400_000_000) == 1_755_400_000_000)
check("minimax epochMs 非法→nil", MiniMaxUsageService.epochMs(1000) == nil && MiniMaxUsageService.epochMs(nil) == nil)
check("minimax remains→now+1h", MiniMaxUsageService.resetTimeMs(
    endTime: nil, remainsTime: 3_600_000, now: Date(timeIntervalSince1970: 1_000_000)) == 1_003_600_000)
check("minimax endTime 优先", MiniMaxUsageService.resetTimeMs(
    endTime: 1_755_400_000, remainsTime: 999, now: Date()) == 1_755_400_000_000)
check("minimax 倒计时 90min 含1小时", MiniMaxWindow.resetText(
    fromMs: Int64((Date().timeIntervalSince1970 + 90 * 60) * 1000))?.contains("1小时") == true)
check("minimax 过去重置→nil", MiniMaxWindow.resetText(
    fromMs: Int64((Date().timeIntervalSince1970 - 60) * 1000)) == nil)

// UsageSnapshot:mimo/minimax 新字段旧 JSON 兼容 + 往返 + 序列/CSV
let mmOldSnap = try? JSONDecoder().decode(UsageSnapshot.self, from: Data(
    #"{"timestamp":700000000,"aliyunFiveHour":10}"#.utf8))
check("minimax snapshot 旧JSON兼容", mmOldSnap?.minimaxInterval == nil && mmOldSnap?.mimoBalance == nil)
let mmNewSnap = UsageSnapshot(timestamp: Date(), aliyunFiveHour: nil, aliyunOneWeek: nil,
                              opencodeRolling: nil, opencodeWeekly: nil, opencodeMonthly: nil,
                              mimoBalance: 110.5, mimoPlanPct: 16,
                              minimaxInterval: 17, minimaxWeekly: 7)
let mmEnc = try? JSONEncoder().encode(mmNewSnap)
let mmDec = mmEnc.flatMap { try? JSONDecoder().decode(UsageSnapshot.self, from: $0) }
check("minimax snapshot 往返", mmDec?.minimaxInterval == 17 && mmDec?.minimaxWeekly == 7
      && mmDec?.mimoBalance == 110.5 && mmDec?.mimoPlanPct == 16)
check("minimax series 映射", HistoryStore.series([mmNewSnap], provider: "minimax", window: "interval") == [17]
      && HistoryStore.series([mmNewSnap], provider: "minimax", window: "weekly") == [7]
      && HistoryStore.series([mmNewSnap], provider: "mimo", window: "plan") == [16])
check("minimax CSV 前缀兼容+新列", {
    let csv = HistoryStore.csv([mmNewSnap])
    return csv.hasPrefix("timestamp,aliyun5h") && csv.contains("minimaxInterval")
      && csv.contains("mimoBalance")
}())

print(fails == 0 ? "ALL PASS" : "\(fails) FAILED")
exit(fails == 0 ? 0 : 1)
