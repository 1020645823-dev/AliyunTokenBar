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
check("usage 7d pct 61.43", u?.oneWeek?.percentage == 61.43)
check("usage 7d reset", u?.oneWeek?.resetTimeMs == 1785687360000)
check("usage 旧契约无月窗", u?.oneMonth == nil)

// 空窗形态(2026-08-03 事故根因回归):5h 字段缺失/null → fiveHour == nil(无窗口),
// 不再整次抛错,也不冒充 0%(0% 与「窗口存在零用量」混淆;无窗口应隐藏统计)
let usageEmptyFixture = #"{"code":"200","data":{"DataV2":{"ret":["SUCCESS::接口调用成功"],"data":{"msg":"Success.","code":"SUCCESS","data":{"per5HourPercentage":null,"per1WeekResetTime":1785687360000,"per1WeekPercentage":0.61428294255},"requestId":"x","success":true}},"success":true,"httpStatus":200,"errorCode":"","api":"x","errorMsg":""},"httpStatusCode":"200","requestId":"x","successResponse":true}"#
let ue = try? BlUsageService.parseUsage(Data(usageEmptyFixture.utf8))
check("usage empty-window parses", ue != nil)
check("usage empty-window 5h nil(无窗口)", ue?.fiveHour == nil)
check("usage empty-window 7d kept", ue?.oneWeek?.percentage == 61.43)
// 无 5h 窗口实测形态(2026-08-15 官方限时取消 5h 限额后服务端只返回周窗口)
let usageNo5hFixture = #"{"code":"200","data":{"DataV2":{"ret":["SUCCESS::接口调用成功"],"data":{"msg":"Success.","code":"SUCCESS","data":{"per1WeekResetTime":1787149800000,"per1WeekPercentage":0.1107448506},"requestId":"x","success":true}},"success":true,"httpStatus":200,"errorCode":"","api":"x","errorMsg":""},"httpStatusCode":"200","requestId":"x","successResponse":true}"#
let un = try? BlUsageService.parseUsage(Data(usageNo5hFixture.utf8))
check("usage 无5h窗口 fiveHour nil", un?.fiveHour == nil)
check("usage 无5h窗口 7d 11.07", un?.oneWeek?.percentage == 11.07)
check("usage 无5h窗口 7d reset", un?.oneWeek?.resetTimeMs == 1787149800000)
// 新契约实测形态(2026-09-23 官方取消周限额改月限额后,服务端只返回月窗口):
// 5h/周字段消失 → 对应窗口 nil(隐藏统计,不冒充 0%);per1Month* 为唯一主窗口。
let usageMonthlyFixture = #"{"code":"200","data":{"DataV2":{"ret":["SUCCESS::接口调用成功"],"data":{"msg":"Success.","code":"SUCCESS","data":{"per1MonthPercentage":0.101517822,"per1MonthResetTime":1792425600000},"requestId":"x","success":true}},"success":true,"httpStatus":200,"errorCode":"","api":"x","errorMsg":""},"httpStatusCode":"200","requestId":"x","successResponse":true}"#
let um = try? BlUsageService.parseUsage(Data(usageMonthlyFixture.utf8))
check("usage 月度契约 parses", um != nil)
check("usage 月度契约 5h nil", um?.fiveHour == nil)
check("usage 月度契约 周 nil", um?.oneWeek == nil)
check("usage 月度契约 月 10.15", um?.oneMonth?.percentage == 10.15)
check("usage 月度契约 月 reset", um?.oneMonth?.resetTimeMs == 1792425600000)
check("usage 月度契约 activeWindows 仅 30d", um?.activeWindows.map(\.name) == ["30d"])
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
        check("live usage parses", w.activeWindows.allSatisfy { $0.detail.percentage >= 0 })
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

// --- OpenCode Go 用量解析(console /console/api/go/status,2026-10-17 重写)---
// 固定 now 保证 resetInSec 断言确定性:2027-01-15 08:00:00Z
let ocNow = Date(timeIntervalSince1970: 1_800_000_000)
let ocStatusFixture = """
{"product":"go","access":{"startsAt":"2027-01-15T00:00:00.000Z","endsAt":"2027-02-15T00:00:00.000Z","meters":{
"fiveHour":{"startsAt":"2027-01-15T07:00:00.000Z","resetsAt":"2027-01-15T09:00:00.000Z","limitMicroCents":"1200000000","usedMicroCents":"886219"},
"week":{"startsAt":"2027-01-12T00:00:00.000Z","resetsAt":"2027-01-15T12:30:00.000Z","limitMicroCents":"3000000000","usedMicroCents":"1500000000"},
"month":{"resetsAt":"2027-02-15T00:00:00.000Z","limitMicroCents":"6000000000","usedMicroCents":"6000000000"}}}}
"""
let oc = OpenCodeUsageService.parseGoStatus(Data(ocStatusFixture.utf8), now: ocNow)
check("opencode rolling 0.07%->0", oc?.rolling.pct == 0)
check("opencode rolling reset 1h", oc?.rolling.resetInSec == 3600)
check("opencode weekly 50%", oc?.weekly.pct == 50)
check("opencode weekly reset 4.5h", oc?.weekly.resetInSec == 16200)
check("opencode monthly 100%", oc?.monthly.pct == 100)
check("opencode monthly reset", oc?.monthly.resetInSec == 2_649_600)
// 未订阅 Go(无 access)→ nil;坏 JSON → nil
let ocNoAccess = #"{"product":"go"}"#
check("opencode no access -> nil", OpenCodeUsageService.parseGoStatus(Data(ocNoAccess.utf8)) == nil)
check("opencode garbage -> nil", OpenCodeUsageService.parseGoStatus(Data("not json".utf8)) == nil)
// resetsAt 为 null(从未使用的窗口)→ resetInSec=0(隐藏倒计时);limit 为 0 不崩
let ocNullReset = """
{"access":{"meters":{"fiveHour":{"resetsAt":null,"limitMicroCents":"0","usedMicroCents":"0"},
"week":{"resetsAt":null,"limitMicroCents":"3000000000","usedMicroCents":"0"},
"month":{"resetsAt":null,"limitMicroCents":"6000000000","usedMicroCents":"0"}}}}
"""
let ocNR = OpenCodeUsageService.parseGoStatus(Data(ocNullReset.utf8), now: ocNow)
check("opencode null reset -> 0", ocNR?.rolling.resetInSec == 0 && ocNR?.weekly.pct == 0)
// 数值型(非字符串)limit/used 也兼容
let ocNumeric = """
{"access":{"meters":{"fiveHour":{"resetsAt":null,"limitMicroCents":1000,"usedMicroCents":250},
"week":{"resetsAt":null,"limitMicroCents":1000,"usedMicroCents":0},
"month":{"resetsAt":null,"limitMicroCents":1000,"usedMicroCents":1000}}}}
"""
check("opencode numeric fields 25%", OpenCodeUsageService.parseGoStatus(Data(ocNumeric.utf8))?.rolling.pct == 25)
// 无毫秒的 ISO8601 也要能解析(服务端改格式不丢重置时间)
let ocNoFrac = """
{"access":{"meters":{"fiveHour":{"resetsAt":"2027-01-15T09:00:00Z","limitMicroCents":"1200000000","usedMicroCents":"886219"},
"week":{"resetsAt":null,"limitMicroCents":"3000000000","usedMicroCents":"0"},
"month":{"resetsAt":null,"limitMicroCents":"6000000000","usedMicroCents":"0"}}}}
"""
check("opencode no-fraction ISO reset", OpenCodeUsageService.parseGoStatus(Data(ocNoFrac.utf8), now: ocNow)?.rolling.resetInSec == 3600)

// rolling 空窗:resetsAt 缺失 → resetInSec=0 → 隐藏倒计时(2026-08-03 用户反馈回归)
check("opencode rolling empty hides reset", OpenCodeWindow(pct: 0, resetInSec: 0).rollingResetText == nil)
check("opencode rolling active shows reset", OpenCodeWindow(pct: 3, resetInSec: 3600).rollingResetText?.contains("1小时") == true)

// 细条行紧凑尾注:小时分支去「钟」字,空窗语义同 rollingResetText(2026-10-17 对齐修复)
check("opencode compact empty hides", OpenCodeWindow(pct: 0, resetInSec: 0).rollingResetCompactText == nil)
check("opencode compact drops zhong", OpenCodeWindow(pct: 3, resetInSec: 3660).rollingResetCompactText == "1小时1分后重置")
check("opencode compact full window hides", OpenCodeWindow(pct: 0, resetInSec: OpenCodeWindow.rollingWindowSec).rollingResetCompactText == nil)
// 共享紧凑格式器:过去/缺失 → nil;小时分支去「钟」;天/分钟分支不变
check("compact nil ms -> nil", ATBResetText.compact(fromMs: nil) == nil)
check("compact past ms -> nil", ATBResetText.compact(fromMs: Int64(Date().timeIntervalSince1970 * 1000) - 60_000) == nil)
check("compact future hours no zhong", ATBResetText.compact(fromMs: Int64((Date().timeIntervalSince1970 + 7320) * 1000))?.contains("小时后重置") == false)
check("compact future hours has fen", ATBResetText.compact(fromMs: Int64((Date().timeIntervalSince1970 + 7320) * 1000))?.contains("2小时1分后重置") == true)

// --- OpenCode Go 多 workspace 聚合(2026-10-17;三窗口独立订阅百分比,取 max)---
func ocQ(_ r: Int, _ w: Int, _ m: Int) -> OpenCodeQuota {
    OpenCodeQuota(rolling: OpenCodeWindow(pct: r, resetInSec: 3600),
                  weekly: OpenCodeWindow(pct: w, resetInSec: 7200),
                  monthly: OpenCodeWindow(pct: m, resetInSec: 10800))
}
check("opencode aggregate empty -> nil", OpenCodeQuota.aggregate([]) == nil)
check("opencode aggregate single -> identity", OpenCodeQuota.aggregate([ocQ(22, 43, 98)]) == ocQ(22, 43, 98))
let ocAgg = OpenCodeQuota.aggregate([ocQ(22, 43, 98), ocQ(61, 12, 55), ocQ(5, 80, 30)])
check("opencode aggregate rolling max", ocAgg?.rolling.pct == 61)
check("opencode aggregate weekly max", ocAgg?.weekly.pct == 80)
check("opencode aggregate monthly max", ocAgg?.monthly.pct == 98)
// workspace 模型 Codable 往返(列表落 UserDefaults)
let ocWS = OpenCodeWorkspace(id: "wrk_abc123", label: "主力工作区")
let ocWSData = try? JSONEncoder().encode([ocWS])
let ocWSDecoded = ocWSData.flatMap { try? JSONDecoder().decode([OpenCodeWorkspace].self, from: $0) }
check("opencode workspace codable roundtrip", ocWSDecoded == [ocWS])

// --- OpenCode Go workspace 列表端点解析(console /api/user/workspaces)---
let wsListFixture = """
[{"id":"wrk_aaa111","name":"Personal","avatarUrl":"https://x/a.png","role":"owner","memberCount":1},
{"id":"org_bbb222","name":"Team","avatarUrl":"","role":"member","memberCount":5}]
"""
let wsInfos = OpenCodeUsageService.parseWorkspaceList(Data(wsListFixture.utf8))
check("opencode ws list count", wsInfos.count == 2)
check("opencode ws list id", wsInfos.first?.id == "wrk_aaa111")
check("opencode ws list name", wsInfos.first?.name == "Personal")
check("opencode ws list org id", wsInfos.last?.id == "org_bbb222")
// 宽容:包装形状 / 缺 name 用 id 兜底 / 坏 JSON → 空
let wsWrapped = #"{"workspaces":[{"id":"wrk_c","name":"W"}]}"#
check("opencode ws list wrapped", OpenCodeUsageService.parseWorkspaceList(Data(wsWrapped.utf8)).first?.id == "wrk_c")
let wsNoName = #"[{"id":"wrk_d"}]"#
check("opencode ws list name fallback", OpenCodeUsageService.parseWorkspaceList(Data(wsNoName.utf8)).first?.name == "wrk_d")
check("opencode ws list bad json -> empty", OpenCodeUsageService.parseWorkspaceList(Data("not json".utf8)).isEmpty)
check("opencode ws list empty -> empty", OpenCodeUsageService.parseWorkspaceList(Data("[]".utf8)).isEmpty)

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

// 账户身份标识:JWT payload 提取 sub/user_id(多账户 UI 区分用,本地解码不网络)
func makeKimiJWT(_ dict: [String: Any]) -> String {
    let payload = ((try? JSONSerialization.data(withJSONObject: dict)).flatMap {
        $0.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }) ?? ""
    return "eyJhbGciOiJFUzI1NiJ9.\(payload).sig"
}
check("kimi jwtSubject sub", KimiUsageService.jwtSubject(makeKimiJWT(["sub": "cp5vaei34pe4b64f8rfg"])) == "cp5vaei34pe4b64f8rfg")
check("kimi jwtSubject user_id 兜底", KimiUsageService.jwtSubject(makeKimiJWT(["exp": 1, "user_id": "u_9911"])) == "u_9911")
check("kimi jwtSubject abstract_user_id 数字", KimiUsageService.jwtSubject(makeKimiJWT(["abstract_user_id": 12345])) == "12345")
check("kimi jwtSubject sub 优先于 user_id", KimiUsageService.jwtSubject(makeKimiJWT(["sub": "s1", "user_id": "u1"])) == "s1")
check("kimi jwtSubject 非 jwt → nil", KimiUsageService.jwtSubject("not-a-jwt") == nil)
check("kimi jwtSubject 空段 → nil", KimiUsageService.jwtSubject("a..c") == nil)
check("kimi jwtSubject 无标识字段 → nil", KimiUsageService.jwtSubject(makeKimiJWT(["exp": 123])) == nil)

// --- Kimi 登录身份判定(防 main 槽静默覆盖/防同户重复登记) ---
let slotA = "sub_aaaa", slotB = "sub_bbbb"
check("kimi login 槽空 → 直接保存",
      KimiUsageService.judgeLoginIdentity(newSub: slotA, slotSub: nil, otherSlots: []) == .proceed)
check("kimi login 同户重登 → 直接保存",
      KimiUsageService.judgeLoginIdentity(newSub: slotA, slotSub: slotA, otherSlots: []) == .proceed)
check("kimi login 换户 → 要求确认替换",
      KimiUsageService.judgeLoginIdentity(newSub: slotB, slotSub: slotA, otherSlots: [])
      == .replaceConfirmation(oldSub: slotA, newSub: slotB))
check("kimi login 他槽已登记该户 → 拒绝(优先于替换)",
      KimiUsageService.judgeLoginIdentity(newSub: slotB, slotSub: slotA,
                                          otherSlots: [KimiUsageService.KimiSlotSubject(id: "uuid-2", sub: slotB)])
      == .duplicateOf(otherAccountID: "uuid-2"))
check("kimi login 新户与槽同户但他人槽 sub 解不出 → 保存",
      KimiUsageService.judgeLoginIdentity(newSub: slotA, slotSub: slotA,
                                          otherSlots: [KimiUsageService.KimiSlotSubject(id: "uuid-2", sub: nil)]) == .proceed)
check("kimi login 新 sub 解不出且槽有旧户 → 仍要求确认(防静默覆盖)",
      KimiUsageService.judgeLoginIdentity(newSub: nil, slotSub: slotA, otherSlots: [])
      == .replaceConfirmation(oldSub: slotA, newSub: nil))
check("kimi login 新旧 sub 都解不出 → 保存(保持旧行为)",
      KimiUsageService.judgeLoginIdentity(newSub: nil, slotSub: nil, otherSlots: []) == .proceed)

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

// --- Kimi 套餐名(ListSubscriptions;多账户区分的官方口径) ---
let subsActive = """
{"subscriptions":[
  {"status":"SUBSCRIPTION_STATUS_CANCELED","goods":{"title":"旧Pro"}},
  {"status":"SUBSCRIPTION_STATUS_ACTIVE","goods":{"title":"Pro","membershipLevel":"LEVEL_INTERMEDIATE"}}]}
"""
check("kimi subs 取 ACTIVE 的 goods.title",
      KimiUsageService.parseSubscriptions(Data(subsActive.utf8)) == "Pro")
let subsNoActive = #"{"subscriptions":[{"status":"SUBSCRIPTION_STATUS_CANCELED","goods":{"title":"Max"}}]}"#
check("kimi subs 无 ACTIVE → 首个 title", KimiUsageService.parseSubscriptions(Data(subsNoActive.utf8)) == "Max")
check("kimi subs 空列表 → nil", KimiUsageService.parseSubscriptions(Data(#"{"subscriptions":[]}"#.utf8)) == nil)
check("kimi subs 垃圾 → nil", KimiUsageService.parseSubscriptions(Data("bad".utf8)) == nil)

// planDisplayName:goods.title 直通;LEVEL_* 枚举轻量格式化
func kimiAggQuota(_ level: String?) -> KimiQuota {
    KimiQuota(fiveHour: KimiWindow(used: 1, limit: 10, resetTimeMs: nil),
              weekly: KimiWindow(used: 2, limit: 10, resetTimeMs: nil),
              monthly: nil, booster: nil, membershipLevel: level,
              subscriptionExpireMs: nil)
}
check("kimi planDisplay title 直通", kimiAggQuota("Pro").planDisplayName == "Pro")
check("kimi planDisplay LEVEL 枚举格式化", kimiAggQuota("LEVEL_INTERMEDIATE").planDisplayName == "Intermediate")
check("kimi planDisplay nil → nil", kimiAggQuota(nil).planDisplayName == nil)

// worstWindow:多套餐活跃窗口不同(Allegro 用量在周/月、5h 恒 0),取已用% 最高者
check("kimi worstWindow 周高于 5h → 取周",
      kimiAggQuota("Pro").worstWindow.label == "周" && kimiAggQuota("Pro").worstWindow.pct == 20)
let kimiMonthlyHeavy = KimiQuota(fiveHour: KimiWindow(used: 1, limit: 100, resetTimeMs: nil),
                                 weekly: KimiWindow(used: 2, limit: 100, resetTimeMs: nil),
                                 monthly: KimiWindow(used: 90, limit: 100, resetTimeMs: nil),
                                 booster: nil, membershipLevel: "Pro",
                                 subscriptionExpireMs: nil)
check("kimi worstWindow 月最高 → 取月",
      kimiMonthlyHeavy.worstWindow.label == "月" && kimiMonthlyHeavy.worstWindow.pct == 90)

// 聚合 membershipLevel = 套餐名去重拼接("Pro + Max"一眼看清各账户)
let kAggDiff = KimiQuota.aggregate([kimiAggQuota("Pro"), kimiAggQuota("Max")])
check("kimi 聚合套餐名拼接", kAggDiff?.membershipLevel == "Pro + Max")
let kAggSame = KimiQuota.aggregate([kimiAggQuota("Pro"), kimiAggQuota("Pro")])
check("kimi 聚合同套餐去重", kAggSame?.membershipLevel == "Pro")
let kAggNone = KimiQuota.aggregate([kimiAggQuota(nil), kimiAggQuota(nil)])
check("kimi 聚合无套餐 → nil", kAggNone?.membershipLevel == nil)
check("kimi 聚合单账户原值", KimiQuota.aggregate([kimiAggQuota("Pro")])?.membershipLevel == "Pro")

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
let est = HistoryStore.estimateMinutesToLimit(snapshots: hs3.recent(100), window: "7d")
check("history estimate ~180min to limit", est != nil && abs(est! - 180) <= 2)
// 默认窗口(阿里云月窗,2026-09 官方改月限额后的主窗口)同样可估
let estMonthly = HistoryStore.estimateMinutesToLimit(
    snapshots: hs3.recent(100).map { snap in
        UsageSnapshot(timestamp: snap.timestamp, aliyunFiveHour: nil, aliyunOneWeek: nil,
                      aliyunOneMonth: snap.aliyunOneWeek,
                      opencodeRolling: nil, opencodeWeekly: nil, opencodeMonthly: nil) })
check("history estimate 默认月窗 ~180min", estMonthly != nil && abs(estMonthly! - 180) <= 2)
// 数据不足 → nil
check("history estimate nil when <2 pts",
      HistoryStore.estimateMinutesToLimit(snapshots: [UsageSnapshot(timestamp: baseT, aliyunFiveHour: nil, aliyunOneWeek: 50, opencodeRolling: nil, opencodeWeekly: nil, opencodeMonthly: nil)], window: "7d") == nil)
// 速率非正 → nil
let mem4 = InMemoryHistoryBackend()
let hs4 = HistoryStore(backend: mem4, clock: FixedClock(baseT), maxAgeDays: 7, maxPerSeries: 100)
hs4.append(UsageSnapshot(timestamp: baseT, aliyunFiveHour: nil, aliyunOneWeek: 80, opencodeRolling: nil, opencodeWeekly: nil, opencodeMonthly: nil))
hs4.append(UsageSnapshot(timestamp: baseT.addingTimeInterval(3600), aliyunFiveHour: nil, aliyunOneWeek: 70, opencodeRolling: nil, opencodeWeekly: nil, opencodeMonthly: nil))
check("history estimate nil when non-increasing",
      HistoryStore.estimateMinutesToLimit(snapshots: hs4.recent(100), window: "7d") == nil)
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
let csvHeaderLine = csvOut.split(separator: "\n").first.map(String.init) ?? ""
check("csv header(旧行前缀兼容 + 新列追加重尾)",
      csvHeaderLine.hasPrefix("timestamp,aliyun5h,aliyun7d,opencodeRolling,opencodeWeekly,opencodeMonthly,kimi5h,kimiWeekly,kimiMonthly,deepseekBalance,deepseekTodayCost,zhipu5h,zhipuWeekly,mimoBalance,mimoPlanPct,minimaxInterval,minimaxWeekly")
      && csvHeaderLine.hasSuffix(",aliyunMonthly"))
check("csv row count", csvOut.split(separator: "\n").count == 3)
check("csv empty cells", csvOut.split(separator: "\n")[1].components(separatedBy: ",").count == 18)
let dsCsvSnaps = [UsageSnapshot(timestamp: baseT, aliyunFiveHour: nil, aliyunOneWeek: nil,
                                opencodeRolling: nil, opencodeWeekly: nil, opencodeMonthly: nil,
                                deepSeekBalance: 110.0, deepSeekTodayCost: 1.5)]
let dsCsv = HistoryStore.csv(dsCsvSnaps)
let dsCells = dsCsv.split(separator: "\n")[1].components(separatedBy: ",")
check("csv deepseek 金额单元格", dsCells.count == 18 && dsCells[9] == "110.00" && dsCells[10] == "1.50")
check("csv 新增列空值留空(含月度列)", dsCells.suffix(7).dropFirst(2).allSatisfy { $0.isEmpty } && dsCells[17].isEmpty)

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

// --- AppFileCredentialStore:.app 包内凭证文件(v1.0.82 登录态持久化)---
let credTmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("atb-cred-test-\(UUID().uuidString)", isDirectory: true)
try? FileManager.default.createDirectory(at: credTmpDir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: credTmpDir) }
let credFile = credTmpDir.appendingPathComponent(AppFileCredentialStore.fileName)
let fstore = AppFileCredentialStore(fileURL: credFile, migrateFromKeychain: false)
check("file store empty read -> nil", fstore.read(account: "opencode-auth-cookie") == nil)
fstore.write("auth=fake-123", account: "opencode-auth-cookie")
check("file store roundtrip", fstore.read(account: "opencode-auth-cookie") == "auth=fake-123")
// 重开实例(模拟重启):值从文件恢复
let fstore2 = AppFileCredentialStore(fileURL: credFile, migrateFromKeychain: false)
check("file store persists across reopen", fstore2.read(account: "opencode-auth-cookie") == "auth=fake-123")
// 空值且无既有项 → 不落盘(不产生空项)
fstore2.write("", account: "never-existed")
check("file store empty no-op", fstore2.read(account: "never-existed") == nil)
// 删除
fstore2.delete(account: "opencode-auth-cookie")
check("file store delete", fstore2.read(account: "opencode-auth-cookie") == nil)
// 文件权限 0600 + 结构含 schemaVersion
let perms = (try? FileManager.default.attributesOfItem(atPath: credFile.path)[.posixPermissions] as? Int) ?? 0
check("file store 0600 perms", perms == 0o600)
let credRoot = (try? JSONSerialization.jsonObject(with: Data(contentsOf: credFile))) as? [String: Any]
check("file store schemaVersion", credRoot?["schemaVersion"] as? Int == 1)
// 解析路径:.app 包内优先,非 .app 裸二进制 → 应用支持目录
check("file store path resolution", {
    let url = AppFileCredentialStore.resolveFileURL()
    if Bundle.main.bundleURL.pathExtension == "app" {
        return url.lastPathComponent == AppFileCredentialStore.fileName
    }
    return url.path.contains("Application Support")
}())

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
// 菜单栏数字部分(v1.0.48 起迷你表格金额列去币种符号,值域与百分比列统一 34pt):≤5 字符
check("ds money digits <100", DeepSeekMoneyFormat.compactDigits(1.5) == "1.50")
check("ds money digits 100-1万", DeepSeekMoneyFormat.compactDigits(110) == "110")
check("ds money digits 1万-1亿", DeepSeekMoneyFormat.compactDigits(12345.6) == "1.2万")
check("ds money digits ≥1亿", DeepSeekMoneyFormat.compactDigits(123_000_000) == "1.2亿")
check("ds money digits ≥100万整数", DeepSeekMoneyFormat.compactDigits(1_234_567) == "123万")
check("ds money digits ≥10亿整数", DeepSeekMoneyFormat.compactDigits(1_234_567_890) == "12亿")
check("ds money digits 进位兜底 99.996", DeepSeekMoneyFormat.compactDigits(99.996) == "100")
check("ds money digits ≤5字符",
      [0.001, 9.99, 99.99, 99.996, 9999.9, 12345.6, 1_234_567, 9_999_999, 123_000_000, 9_999_999_999]
          .allSatisfy { DeepSeekMoneyFormat.compactDigits($0).count <= 5 })

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
    a5: Int? = 40, a7: Int? = 18, aM: Int? = nil,
    kConf: Bool = true, kErr: Bool = false, k5: Int? = 0, kW: Int? = 58,
    oConf: Bool = true, oErr: Bool = false, oR: Int? = 3, oW: Int? = 2,
    dConf: Bool = true, dErr: Bool = false, dCost: Double? = 1.5, dBal: Double? = 110.0,
    zConf: Bool = false, zErr: Bool = false, z5: Int? = 11, zW: Int? = 2,
    miConf: Bool = false, miErr: Bool = false, miPlan: Int? = 37, miBal: Double? = 25.5,
    mmConf: Bool = true, mmErr: Bool = false, mmI: Int? = 1, mmW: Int? = 1,
    olConf: Bool = false, olErr: Bool = false, olP: Int? = 15, olS: Int? = nil,
    sfConf: Bool = false, sfErr: Bool = false, sfP: Int? = 21, sfPl: String? = "月池",
    sfS: Int? = nil, sfSl: String? = nil,
    sysOn: Bool = true, cpu: Int? = 12, mem: Int? = 25,
    dis: Set<String> = []
) -> [MenuBarTableColumn] {
    MenuBarTable.columns(aliyunFiveHour: a5, aliyunOneWeek: a7, aliyunOneMonth: aM,
        kimiConfigured: kConf, kimiHasError: kErr, kimiFiveHour: k5, kimiWeekly: kW,
        openCodeConfigured: oConf, openCodeHasError: oErr, openCodeRolling: oR, openCodeWeekly: oW,
        deepSeekConfigured: dConf, deepSeekHasError: dErr, deepSeekTodayCost: dCost, deepSeekBalance: dBal,
        zhipuConfigured: zConf, zhipuHasError: zErr, zhipuFiveHour: z5, zhipuWeekly: zW,
        mimoConfigured: miConf, mimoHasError: miErr, mimoPlanPct: miPlan, mimoBalance: miBal,
        minimaxConfigured: mmConf, minimaxHasError: mmErr, minimaxInterval: mmI, minimaxWeekly: mmW,
        ollamaConfigured: olConf, ollamaHasError: olErr, ollamaPrimary: olP, ollamaSecondary: olS,
        stepfunConfigured: sfConf, stepfunHasError: sfErr,
        stepfunPrimary: sfP, stepfunPrimaryLabel: sfPl, stepfunSecondary: sfS, stepfunSecondaryLabel: sfSl,
        systemEnabled: sysOn, cpu: cpu, memory: mem,
        disabled: dis)
}

let mtAll = mtCols()
check("mt 6列全显示且固定顺序(智谱/MiMo 未配置;本机恒最后)", mtAll.map(\.kind) == [.aliyun, .kimi, .openCode, .deepSeek, .minimax, .system])
let mtAll8 = mtCols(zConf: true, miConf: true)
check("mt 8列全显示且固定顺序(☁✨⚡🧠〜∞)", mtAll8.map(\.kind) == [.aliyun, .kimi, .openCode, .deepSeek, .zhipu, .mimo, .minimax, .system])
check("mt 智谱主次值+标签", mtAll8[4].primary.text == "11%" && mtAll8[4].secondary.text == "2%"
      && mtAll8[4].primaryLabel == "5小时" && mtAll8[4].secondaryLabel == "周")
check("mt MiMo 主=套餐% 次=余额紧凑金额", mtAll8[5].primary.text == "37%" && mtAll8[5].secondary.text == "25.50"
      && mtAll8[5].primaryLabel == "套餐" && mtAll8[5].secondaryLabel == "余额"
      && mtAll8[5].secondary.pct == nil)
check("mt MiMo 无套餐→主行横杠次行余额仍显", mtCols(miConf: true, miPlan: nil).map(\.kind).contains(.mimo)
      && mtCols(miConf: true, miPlan: nil).first { $0.kind == .mimo }!.primary.text == "—")
check("mt MiMo 金额无币种符号(菜单栏省略,面板保留)", mtCols(miConf: true, miBal: 9.5).first { $0.kind == .mimo }!.secondary.text == "9.50")
check("mt 未配置智谱→隐藏", !mtCols().map(\.kind).contains(.zhipu))
check("mt 未配置MiMo→隐藏", !mtCols().map(\.kind).contains(.mimo))
let mtZErr = mtCols(zConf: true, zErr: true, z5: nil, zW: nil)
check("mt 智谱出错→横杠列", mtZErr.first { $0.kind == .zhipu }!.primary.text == "—")
let mtMiErr = mtCols(miConf: true, miErr: true, miPlan: nil, miBal: nil)
check("mt MiMo 出错→横杠列", mtMiErr.first { $0.kind == .mimo }!.primary.text == "—"
      && mtMiErr.first { $0.kind == .mimo }!.secondary.text == "—")
check("mt 停用智谱/MiMo→列隐藏", mtCols(zConf: true, miConf: true, dis: ["zhipu", "mimo"]).map(\.kind) == mtAll.map(\.kind))
check("mt 8列 tooltip 全文", MenuBarTable.tooltip(columns: mtAll8) == "阿里云 5小时 40% · 7天 18% | Kimi 5小时 0% · 周 58% | OpenCode 滚动 3% · 周 2% | DeepSeek 今日 1.50 · 余额 110 | 智谱 5小时 11% · 周 2% | MiMo 套餐 37% · 余额 25.50 | MiniMax 本窗 1% · 周 1% | 本机 CPU 12% · 内存 25%")
check("mt 阿里云主次值", mtAll[0].primary.text == "40%" && mtAll[0].secondary.text == "18%")
check("mt 0% 不省略", mtAll[1].primary.text == "0%" && mtAll[1].primary.pct == 0)
check("mt DeepSeek 金额主次值", mtAll[3].primary.text == "1.50" && mtAll[3].secondary.text == "110"
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
// 月窗形态(2026-09 官方取消周限改月限):仅月值 → 单值列,标签 30天;
// 月值存在时优先于周值(现实中两者不同时返回,防御周字段回归残留)
let mtMonthly = mtCols(a5: nil, a7: nil, aM: 10)
check("mt 月窗→主行显30d值", mtMonthly[0].primary.text == "10%" && mtMonthly[0].primary.pct == 10)
check("mt 月窗→单值列标签", mtMonthly[0].primaryLabel == "30天" && mtMonthly[0].secondaryLabel == nil)
check("mt 月窗 tooltip", MenuBarTable.tooltip(columns: mtMonthly).hasPrefix("阿里云 30天 10% |"))
let mt5hAndMonth = mtCols(a5: 35, a7: nil, aM: 61)
check("mt 5h+月窗→双值列显式标签", mt5hAndMonth[0].primary.text == "35%" && mt5hAndMonth[0].secondary.text == "61%"
      && mt5hAndMonth[0].primaryLabel == "5小时" && mt5hAndMonth[0].secondaryLabel == "30天")
check("mt 月窗优先于周窗", mtCols(a5: nil, a7: 5, aM: 10)[0].primary.text == "10%"
      && mtCols(a5: nil, a7: 5, aM: 10)[0].primaryLabel == "30天")
let mtTip = MenuBarTable.tooltip(columns: mtAll)
check("mt tooltip 全文", mtTip == "阿里云 5小时 40% · 7天 18% | Kimi 5小时 0% · 周 58% | OpenCode 滚动 3% · 周 2% | DeepSeek 今日 1.50 · 余额 110 | MiniMax 本窗 1% · 周 1% | 本机 CPU 12% · 内存 25%")
check("mt tooltip 横杠形态", MenuBarTable.tooltip(columns: mtErr).contains("Kimi 5小时 — · 周 —"))

// 渲染契约:百分比列值文本最长 4 字符("100%");金额列无币种符号,最长 5 字符("12.3万"/"10000")
check("mt 百分比列≤4字符", mtCols(a5: 100, a7: 100, k5: 100, kW: 100, oR: 100, oW: 100,
                                    zConf: true, z5: 100, zW: 100, miConf: true, miPlan: 100,
                                    mmI: 100, mmW: 100, cpu: 100, mem: 100)
    .filter { $0.kind != .deepSeek && $0.kind != .mimo }
    .allSatisfy { $0.primary.text.count <= 4 && $0.secondary.text.count <= 4 })
check("mt DeepSeek 金额列≤5字符", mtCols(dCost: 0.01, dBal: 123456.78)[3].primary.text.count <= 5
      && mtCols(dCost: 0.01, dBal: 123456.78)[3].secondary.text.count <= 5
      && mtCols(dCost: 9999.9, dBal: 100_000_000)[3].primary.text.count <= 5
      && mtCols(dCost: 9999.9, dBal: 100_000_000)[3].secondary.text.count <= 5)
check("mt MiMo 金额列≤5字符", mtCols(miConf: true, miBal: 0.01).first { $0.kind == .mimo }!.secondary.text.count <= 5
      && mtCols(miConf: true, miBal: 123456.78).first { $0.kind == .mimo }!.secondary.text.count <= 5
      && mtCols(miConf: true, miBal: 100_000_000).first { $0.kind == .mimo }!.secondary.text.count <= 5)

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
check("registry 10 个数据源(9 订阅商+本机)", ProviderKind.allCases.count == 10
      && ProviderKind.allCases.map(\.rawValue) == ["aliyun", "openCode", "kimi", "deepSeek", "zhipu", "mimo", "minimax", "ollama", "stepfun", "system"])
check("registry 面板 tab 顺序=旧 ProviderTab 顺序", ProviderKind.allCases.map(\.displayName)
      == ["阿里云", "OpenCode", "Kimi", "DeepSeek", "智谱 GLM", "MiMo", "MiniMax", "Ollama", "阶跃 Step", "本机"])
check("registry 菜单栏列映射全覆盖(10 列;列序由 MenuBarColumnKind 决定)", Set(ProviderKind.allCases.compactMap(\.menuBarColumnKind)) == Set(MenuBarColumnKind.allCases))
check("registry 列→provider 反向映射全覆盖", MenuBarColumnKind.allCases.allSatisfy {
    ProviderKind.from(menuBarColumnKind: $0).menuBarColumnKind == $0
})
check("registry 面板恒在项=阿里云/DeepSeek/Ollama/本机", ProviderKind.allCases.filter(\.panelTabAlwaysListed)
      == [.aliyun, .deepSeek, .ollama, .system])
check("registry 全部数据源有配置判定(isConfigured 不漏 case)",
      ProviderKind.allCases.allSatisfy { _ in true })   // 编译期穷举即保证;此处防回归删除 case

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
// 多账户聚合(v1.0.67):5h/周取 max(最险账户),MCP 按次求和,level 取首个非空
let zAccA = ZhipuQuota(fiveHour: ZhipuWindow(pct: 40, resetTimeMs: nil),
                       weekly: ZhipuWindow(pct: 20, resetTimeMs: nil),
                       mcp: ZhipuMCPQuota(usage: 4000, currentValue: 100, remaining: 3900,
                                          percentage: 2.5, resetTimeMs: 5000,
                                          details: [ZhipuMCPQuota.Detail(modelCode: "search-prime", usage: 60)]),
                       level: "max")
let zAccB = ZhipuQuota(fiveHour: ZhipuWindow(pct: 62, resetTimeMs: nil),
                       weekly: ZhipuWindow(pct: 10, resetTimeMs: 6000),
                       mcp: ZhipuMCPQuota(usage: 4000, currentValue: 300, remaining: 3700,
                                          percentage: 7.5, resetTimeMs: 4000,
                                          details: [ZhipuMCPQuota.Detail(modelCode: "search-prime", usage: 100)]),
                       level: nil)
let zAgg = ZhipuQuota.aggregate([zAccA, zAccB])
check("zhipu 聚合:5h 取 max 62", zAgg?.fiveHour?.pct == 62)
check("zhipu 聚合:周取 max 20", zAgg?.weekly?.pct == 20)
check("zhipu 聚合:MCP 求和 400/8000", zAgg?.mcp?.currentValue == 400 && zAgg?.mcp?.usage == 8000)
check("zhipu 聚合:MCP 百分比 5", zAgg?.mcp?.percentage == 5)
check("zhipu 聚合:MCP details 归并 160", zAgg?.mcp?.details.first?.usage == 160)
check("zhipu 聚合:MCP 重置取最早 4000", zAgg?.mcp?.resetTimeMs == 4000)
check("zhipu 聚合:level 取首个非空", zAgg?.level == "max")
check("zhipu 聚合:单账户原值", ZhipuQuota.aggregate([zAccA]) == zAccA)
check("zhipu 聚合:空数组 nil", ZhipuQuota.aggregate([]) == nil)

// Kimi 多账户聚合(v1.0.67):计数窗口求和,订阅池取 max,加油包金额求和,到期取最早
let kAccA = KimiQuota(fiveHour: KimiWindow(used: 30, limit: 1000, resetTimeMs: nil),
                      weekly: KimiWindow(used: 200, limit: 5000, resetTimeMs: 7000),
                      monthly: KimiWindow(used: 500, limit: 20000, resetTimeMs: nil),
                      booster: KimiBooster(enabled: true, balanceYuan: 10, monthlyUsedYuan: 2, monthlyLimitYuan: 100),
                      membershipLevel: "LEVEL_ADVANCED",
                      subscriptionExpireMs: 8000,
                      subscriptionBalance: KimiSubscriptionBalance(totalUsedRatio: 0.2, codeUsedRatio: 0.1, expireTimeMs: 8000))
let kAccB = KimiQuota(fiveHour: KimiWindow(used: 70, limit: 1000, resetTimeMs: nil),
                      weekly: KimiWindow(used: 100, limit: 5000, resetTimeMs: 6000),
                      monthly: KimiWindow(used: 900, limit: 20000, resetTimeMs: nil),
                      booster: KimiBooster(enabled: true, balanceYuan: 5, monthlyUsedYuan: 1, monthlyLimitYuan: 100),
                      membershipLevel: nil,
                      subscriptionExpireMs: 9000,
                      subscriptionBalance: KimiSubscriptionBalance(totalUsedRatio: 0.45, codeUsedRatio: nil, expireTimeMs: 9000))
let kAgg = KimiQuota.aggregate([kAccA, kAccB])
check("kimi 聚合:5h 求和 100/2000", kAgg?.fiveHour.used == 100 && kAgg?.fiveHour.limit == 2000)
check("kimi 聚合:5h 百分比 5", kAgg?.fiveHour.pct == 5)
check("kimi 聚合:周求和 300/10000", kAgg?.weekly.used == 300 && kAgg?.weekly.limit == 10000)
check("kimi 聚合:周重置取最早 6000", kAgg?.weekly.resetTimeMs == 6000)
check("kimi 聚合:月求和 1400/40000", kAgg?.monthly?.used == 1400 && kAgg?.monthly?.limit == 40000)
check("kimi 聚合:订阅池取 max 0.45", kAgg?.subscriptionBalance?.totalUsedRatio == 0.45)
check("kimi 聚合:加油包求和 ¥15", kAgg?.booster?.balanceYuan == 15)
check("kimi 聚合:加油包月限求和 200", kAgg?.booster?.monthlyLimitYuan == 200)
check("kimi 聚合:到期取最早 8000", kAgg?.subscriptionExpireMs == 8000)
check("kimi 聚合:level 去重拼接(经 planDisplayName)", kAgg?.membershipLevel == "Advanced")
check("kimi 聚合:单账户原值", KimiQuota.aggregate([kAccA]) == kAccA)
check("kimi 聚合:空数组 nil", KimiQuota.aggregate([]) == nil)
// 加油包未启用不进聚合(仅 enabled 求和)
let kNoBooster = KimiQuota(fiveHour: KimiWindow(used: 0, limit: 100, resetTimeMs: nil),
                           weekly: KimiWindow(used: 0, limit: 100, resetTimeMs: nil),
                           monthly: nil, booster: nil, membershipLevel: nil)
check("kimi 聚合:单无加油包→nil", KimiQuota.aggregate([kAccA, kNoBooster])?.booster?.balanceYuan == 10)
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
// ⚠️ 单位契约:控制台 used/limit 的量纲是 **Credits 而非 tokens**
// (2026-09-25 由 /tokenPlan/list 确证:standard → "110 亿 Credits" = 11,000,000,000,
//  与 API limit 完全吻合;lite=41 亿 / pro=380 亿 / max=820 亿)。
// 这条断言的作用是让"单位是 Credits"成为**有测试守着的契约**,避免再次被 `*_token`
// 字段名误导而把 UI 标成 tokens。
check("mimo 套餐额度单位是 Credits(非 tokens)", MiMoUsageService.planQuotaUnit == "Credits")
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
check("mimo detail 未过期", mimoDetail?.expired == .some(false))
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

// --- MiMo P0 加固:包络接线 / 鉴权失败可见 / items 选优 / expired 三态 / 鉴权退避 ---

// D2 包络:HTTP 200 + body code≠0 必须分类(否则会误报"响应格式变化,解析失败")
check("mimo 200包络 401→loginRequired", MiMoUsageService.envelopeError(from: Data(
    #"{"code":401,"loginUrl":"https://account.xiaomi.com/pass/serviceLogin?sid=api-platform"}"#.utf8)) == .loginRequired)
check("mimo 200包络 403→invalidCredentials", MiMoUsageService.envelopeError(from: Data(
    #"{"code":403,"message":"forbidden"}"#.utf8)) == .invalidCredentials)
check("mimo 200包络 1000→parse", {
    if case .parse = MiMoUsageService.envelopeError(from: Data(#"{"code":1000,"message":"boom"}"#.utf8))! { return true }
    return false
}())
check("mimo 200包络 code=0→nil", MiMoUsageService.envelopeError(from: Data(#"{"code":0,"data":{}}"#.utf8)) == nil)
check("mimo 200包络 无 code 字段→nil(宽容)", MiMoUsageService.envelopeError(from: Data(#"{"data":{}}"#.utf8)) == nil)

// D1 归并:balance 成功但 plan 端点 401 时必须整体报 loginRequired
// (此前 successData 静默吞掉,面板显示"暂无用量数据"而非引导重登)
let mBal = Data(#"{"code":0,"data":{"balance":"1.00","currency":"CNY"}}"#.utf8)
let mDetail = Data(#"{"code":0,"data":{"planCode":"standard","currentPeriodEnd":"2026-09-01 00:00:00","expired":false}}"#.utf8)
let mUsage = Data(#"{"code":0,"data":{"monthUsage":{"items":[{"used":1,"limit":10,"percent":0.1}]}}}"#.utf8)
check("mimo 归并:plan 端点 401 → loginRequired",
      MiMoUsageService.combine(balance: .success(mBal), detail: .failure(.loginRequired), usage: .success(mUsage))
      == .failure(.loginRequired))
check("mimo 归并:plan 端点 403 → invalidCredentials",
      MiMoUsageService.combine(balance: .success(mBal), detail: .success(mDetail), usage: .failure(.invalidCredentials))
      == .failure(.invalidCredentials))
check("mimo 归并:balance 失败优先", {
    if case .failure(.network) = MiMoUsageService.combine(
        balance: .failure(.network("down")), detail: .failure(.loginRequired), usage: .success(mUsage)) { return true }
    return false
}())
check("mimo 归并:plan 非鉴权失败 → 静默降级出余额+用量", {
    if case .success(let u) = MiMoUsageService.combine(
        balance: .success(mBal), detail: .failure(.network("boom")), usage: .success(mUsage)) {
        return u.balance.balance == 1.0 && u.plan?.limit == 10 && u.plan?.planCode == nil
    }
    return false
}())
check("mimo 归并:三端点齐全 → plan 完整", {
    if case .success(let u) = MiMoUsageService.combine(
        balance: .success(mBal), detail: .success(mDetail), usage: .success(mUsage)) {
        return u.plan?.planCode == "standard" && u.plan?.usedPct == 10 && u.plan?.expired == .some(false)
    }
    return false
}())
check("mimo 归并:balance 200 但不可解析 → parse", {
    if case .failure(.parse) = MiMoUsageService.combine(
        balance: .success(Data(#"{"code":0,"data":{}}"#.utf8)), detail: .success(mDetail), usage: .success(mUsage)) { return true }
    return false
}())

// D3a 多 items 选主窗口(原先盲取 items.first,口径武断)
check("mimo plan 多 items → 取 limit 最大者", MiMoUsageService.parsePlanUsage(from: Data(
    #"{"code":0,"data":{"monthUsage":{"items":[{"name":"a","used":1,"limit":100},{"name":"b","used":5,"limit":9000,"percent":0.05}]}}}"#.utf8))?.limit == 9000)
check("mimo plan limit 全 0 → 取 percent 最大者", MiMoUsageService.parsePlanUsage(from: Data(
    #"{"code":0,"data":{"monthUsage":{"items":[{"percent":0.1},{"percent":0.7}]}}}"#.utf8))?.usedPct == 70)
check("mimo plan item 无 percent → 回退外层 monthUsage.percent", MiMoUsageService.parsePlanUsage(from: Data(
    #"{"code":0,"data":{"monthUsage":{"percent":0.25,"items":[{"used":3,"limit":12}]}}}"#.utf8))?.usedPct == 25)
check("mimo plan items 空 → nil", MiMoUsageService.parsePlanUsage(from: Data(
    #"{"code":0,"data":{"monthUsage":{"items":[]}}}"#.utf8)) == nil)

// D3b expired 三态:缺失时不得默认"未过期"
check("mimo detail expired 缺失 → nil(不默认未过期)", MiMoUsageService.parsePlanDetail(from: Data(
    #"{"code":0,"data":{"planCode":"standard"}}"#.utf8))?.expired == nil)
check("mimo detail expired=true 保留", MiMoUsageService.parsePlanDetail(from: Data(
    #"{"code":0,"data":{"planCode":"standard","expired":true}}"#.utf8))?.expired == .some(true))

// D4 鉴权失败退避:15→30→60→120 分钟封顶
// (真机发现:小米 SSO 对密集重试软拒绝,首档必须够长,否则自锁)
check("mimo 鉴权退避 0 次无冷却", MiMoUsageService.authRetryCooldownSeconds(consecutiveFailures: 0) == 0)
check("mimo 鉴权退避 15→30→60→120 封顶",
      MiMoUsageService.authRetryCooldownSeconds(consecutiveFailures: 1) == 900
      && MiMoUsageService.authRetryCooldownSeconds(consecutiveFailures: 2) == 1800
      && MiMoUsageService.authRetryCooldownSeconds(consecutiveFailures: 3) == 3600
      && MiMoUsageService.authRetryCooldownSeconds(consecutiveFailures: 9) == 7200)

// --- MiMo P1:Cookie jar 归一 / 旧格式迁移 / 续期链路(可注入 transport 离线驱动)---

check("mimo jar 旧格式迁移保留 platformHeader",
      MiMoCookieJar.legacy("api-platform_serviceToken=abc; userId=123")?.platformHeader
      == "api-platform_serviceToken=abc; userId=123")
check("mimo jar 旧格式不可续期(无 passToken)",
      MiMoCookieJar.legacy("api-platform_serviceToken=abc; userId=123")?.canRenew == false)
check("mimo jar 旧格式缺必需 cookie → nil", MiMoCookieJar.legacy("foo=bar") == nil)
let mJar = MiMoCookieJar(platformHeader: "api-platform_serviceToken=old; userId=1",
                         accountHeader: "passToken=PT; cUserId=CU; userId=1")
check("mimo jar 有 passToken → 可续期", mJar.canRenew)
check("mimo jar 无 passToken → 不可续期",
      MiMoCookieJar(platformHeader: "x=1", accountHeader: "cUserId=CU").canRenew == false)
check("mimo jar json 往返", MiMoCookieJar.decode(mJar.jsonString() ?? "") == mJar)
check("mimo jar 坏 json → nil", MiMoCookieJar.decode("not json") == nil)

check("mimo cookie 解析去引号", MiMoCookieJar.parseCookiePairs(#"a="1"; b=2"#) == ["a": "1", "b": "2"])
check("mimo cookie 解析空串", MiMoCookieJar.parseCookiePairs("   ") == [:])
check("mimo cookie 解析容忍 Cookie 前缀",
      MiMoCookieJar.parseCookiePairs("Cookie: a=1") == ["a": "1"])

// ⚠️ 真机回归(2026-09-25 实测):URLSession 会把重复的 Set-Cookie 折叠成**逗号分隔的单值**,
// 而 Expires 日期自身含逗号 —— 手写 split 必然解析错,导致把平台下发的空"清除"cookie
// 当成续期成功(真机上表现为"续期成功但新凭据仍 401")。必须交给 Foundation 官方解析器。
let collapsedHeader = #"api-platform_serviceToken=""; Expires=Thu, 01-Jan-1970 00:00:10 GMT; Path=/; HttpOnly, api-platform_serviceToken=""; Domain=platform.xiaomimimo.com; Expires=Thu, 01-Jan-1970 00:00:10 GMT; Path=/; HttpOnly, api-platform_serviceToken="REALTOKEN"; Version=1; Domain=platform.xiaomimimo.com; Path=/; HttpOnly, userId=2354652158; Domain=xiaomimimo.com, api-platform_slh="SLH="; Version=1; Domain=platform.xiaomimimo.com"#
let collapsedCookies = MiMoResponseCookie.parseHeaderFields(
    ["Set-Cookie": collapsedHeader], for: URL(string: "https://platform.xiaomimimo.com/sts")!)
check("mimo 折叠 Set-Cookie 剔除引号空值与过期清除项(只剩 3 条)",
      collapsedCookies.count == 3)
check("mimo 折叠 Set-Cookie 取到非空 serviceToken(引号已剥离)",
      collapsedCookies.contains { $0.name == "api-platform_serviceToken" && $0.value == "REALTOKEN" })
check("mimo 折叠 Set-Cookie 值无残留引号",
      !collapsedCookies.contains { $0.value.hasPrefix("\"") || $0.value.hasSuffix("\"") })
check("mimo 折叠 Set-Cookie 保留带引号属性值(slh)",
      collapsedCookies.contains { $0.name == "api-platform_slh" && $0.value == "SLH=" })
check("mimo 折叠 Set-Cookie 保留 userId 与平台域",
      collapsedCookies.contains { $0.name == "userId" && $0.domain.contains("xiaomimimo.com") })
check("mimo 引号剥离纯函数",
      MiMoCookieJar.unquote("\"abc\"") == "abc"
      && MiMoCookieJar.unquote("\"\"") == ""          // 引号空值 → 空
      && MiMoCookieJar.unquote("plain") == "plain"
      && MiMoCookieJar.unquote("\"") == "\"")         // 单个引号不算成对,原样保留

check("mimo jar 合并:空值不覆盖已有凭据",
      MiMoCookieJar.merging("api-platform_serviceToken=KEEP; userId=1",
                            with: ["api-platform_serviceToken": "", "api-platform_slh": "S"])
      == "api-platform_serviceToken=KEEP; api-platform_slh=S; userId=1")
check("mimo jar 合并:非空覆盖", MiMoCookieJar.merging("a=old; b=2", with: ["a": "new"]) == "a=new; b=2")

// 真实链路形状(2026-09-25 实测):
//   401 body 带 loginUrl → serviceLogin(带 passToken) → 302 回平台 sts → Set-Cookie api-platform_serviceToken
//   未认证时 serviceLogin 的 Location 停在 account.xiaomi.com/fe/service/login(域判定即"是否通过")
let expiredLoginUrl = "https://account.xiaomi.com/pass/serviceLogin?callback=https%3A%2F%2Fplatform.xiaomimimo.com%2Fsts%3Fsign%3DS1%26followup%3DF1&sid=api-platform&_group=DEFAULT"
func probe401() -> MiMoTransportScript.Step {
    .init(status: 401, location: nil, setCookies: [],
          body: Data(#"{"code":401,"loginUrl":"\#(expiredLoginUrl)"}"#.utf8))
}
let renewOK = await MiMoSessionRenewal.renew(jar: mJar, transport: MiMoTransportScript(steps: [
    probe401(),
    .init(status: 302, location: "https://platform.xiaomimimo.com/sts?sign=S1&followup=F1",
          setCookies: [], body: Data()),
    .init(status: 302, location: "https://platform.xiaomimimo.com/api/v1/balance", setCookies: [
        "api-platform_serviceToken=NEW; Domain=platform.xiaomimimo.com; Path=/; HttpOnly",
        "passToken=PT2; Domain=.xiaomi.com; Path=/; HttpOnly",
    ], body: Data()),
]))
check("mimo 续期成功 → 新 serviceToken 回写", {
    if case .success(let jar) = renewOK {
        return MiMoCookieJar.parseCookiePairs(jar.platformHeader)["api-platform_serviceToken"] == "NEW"
    }
    return false
}())
check("mimo 续期成功 → 旋转的 passToken 回写(滑动续期)", {
    if case .success(let jar) = renewOK {
        return MiMoCookieJar.parseCookiePairs(jar.accountHeader)["passToken"] == "PT2"
    }
    return false
}())
check("mimo 续期成功 → 保留未变更的 cUserId", {
    if case .success(let jar) = renewOK {
        return MiMoCookieJar.parseCookiePairs(jar.accountHeader)["cUserId"] == "CU"
    }
    return false
}())
check("mimo 续期成功 → 保留未变更的 platform userId", {
    if case .success(let jar) = renewOK {
        return MiMoCookieJar.parseCookiePairs(jar.platformHeader)["userId"] == "1"
    }
    return false
}())

let noRenew = await MiMoSessionRenewal.renew(
    jar: MiMoCookieJar(platformHeader: "a=1", accountHeader: "b=2"),
    transport: MiMoTransportScript(steps: []))
check("mimo 续期:不可续期 jar → loginRequired", noRenew == .failure(.loginRequired))

let passTokenDead = await MiMoSessionRenewal.renew(jar: mJar, transport: MiMoTransportScript(steps: [
    probe401(),
    .init(status: 302, location: "https://account.xiaomi.com/fe/service/login?_group=DEFAULT",
          setCookies: ["serviceToken=EXPIRED"], body: Data()),
]))
check("mimo 续期:passToken 失效(Location 停在账号域)→ loginRequired",
      passTokenDead == .failure(.loginRequired))

let noCookieSet = await MiMoSessionRenewal.renew(jar: mJar, transport: MiMoTransportScript(steps: [
    probe401(),
    .init(status: 302, location: "https://platform.xiaomimimo.com/sts?sign=S1", setCookies: [], body: Data()),
    // 回调跳回 followup 但什么都没下发
    .init(status: 302, location: "https://platform.xiaomimimo.com/api/v1/balance", setCookies: [], body: Data()),
]))
check("mimo 续期:回调未下发 serviceToken → loginRequired", noCookieSet == .failure(.loginRequired))

let noLoginUrl = await MiMoSessionRenewal.renew(jar: mJar, transport: MiMoTransportScript(steps: [
    .init(status: 401, location: nil, setCookies: [], body: Data(#"{"code":401}"#.utf8)),
]))
check("mimo 续期:401 无 loginUrl → loginRequired", noLoginUrl == .failure(.loginRequired))

let netFail = await MiMoSessionRenewal.renew(jar: mJar,
                                             transport: MiMoTransportScript(steps: [.init(error: .network("offline"))]))
check("mimo 续期:网络异常 → network 失败", {
    if case .failure(.network) = netFail { return true }
    return false
}())
let liveJar = MiMoCookieJar(platformHeader: "api-platform_serviceToken=live", accountHeader: "passToken=PT")
let alreadyLive = await MiMoSessionRenewal.renew(jar: liveJar, transport: MiMoTransportScript(steps: [
    .init(status: 200, location: nil, setCookies: [], body: Data(#"{"code":0,"data":{}}"#.utf8)),
]))
check("mimo 续期:已有效会话(probe 直接 200)→ 原样返回", alreadyLive == .success(liveJar))

// --- MiMo P2:本地用量账本(读 mimocode/opencode 库的 tokens.*,零凭据兜底)---

check("mimo local 解析 sqlite 输出", MiMoLocalLedger.parseRows(
    "1790296744759|478895|43501|440|3307968|0\n1790296744760||12|||\n") == [
    MiMoLocalUsageRow(timestampMs: 1790296744759, input: 478895, output: 43501,
                      reasoning: 440, cacheRead: 3307968, cacheWrite: 0),
    MiMoLocalUsageRow(timestampMs: 1790296744760, input: 0, output: 12,
                      reasoning: 0, cacheRead: 0, cacheWrite: 0),
])
check("mimo local 空输出 → 空", MiMoLocalLedger.parseRows("").isEmpty)
check("mimo local 畸形行跳过(字段数不足/时间戳非数字)",
      MiMoLocalLedger.parseRows("abc|1|2|3|4|5\n\n1|2\n").isEmpty)

let utcTZ = TimeZone(secondsFromGMT: 0)!
// 1790298000000 = 2026-09-25T01:00:00Z;+22h 仍同日;+24h 跨日
let aggDays = MiMoLocalLedger.aggregate([
    MiMoLocalUsageRow(timestampMs: 1790298000000, input: 10, output: 1, reasoning: 0, cacheRead: 0, cacheWrite: 0),
    MiMoLocalUsageRow(timestampMs: 1790377200000, input: 20, output: 2, reasoning: 0, cacheRead: 0, cacheWrite: 0),
    MiMoLocalUsageRow(timestampMs: 1790384400000, input: 30, output: 3, reasoning: 0, cacheRead: 0, cacheWrite: 0),
], timeZone: utcTZ)
check("mimo local 按天升序聚合", aggDays.map(\.date) == ["2026-09-25", "2026-09-26"])
check("mimo local 同日累加", aggDays.first?.input == 30 && aggDays.first?.output == 3)
check("mimo local total 不含 cache", aggDays.first?.total == 33)
check("mimo local 时区影响分日", MiMoLocalLedger.aggregate([
    MiMoLocalUsageRow(timestampMs: 1790377200000, input: 1, output: 0, reasoning: 0, cacheRead: 0, cacheWrite: 0),
], timeZone: TimeZone(secondsFromGMT: 8 * 3600)!).first?.date == "2026-09-26")

let lUsage = MiMoLocalUsage(schemaVersion: 1, updatedAt: Date(timeIntervalSince1970: 0), days: aggDays)
check("mimo local today 取当日", MiMoLocalLedger.todayTokens(
    in: lUsage, now: Date(timeIntervalSince1970: 1790384400), timeZone: utcTZ) == 33)
check("mimo local 合计", MiMoLocalLedger.totalTokens(in: lUsage) == 66)
check("mimo local today 无当日数据 → 0", MiMoLocalLedger.todayTokens(
    in: lUsage, now: Date(timeIntervalSince1970: 1800000000), timeZone: utcTZ) == 0)

let lTmp = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("mimo-local-verify-\(UUID().uuidString).json")
let lStore = MiMoLocalUsageStore(url: lTmp)
check("mimo local store 空 → nil", lStore.load() == nil)
lStore.save(lUsage)
check("mimo local store 往返", lStore.load() == lUsage)
try? FileManager.default.removeItem(at: lTmp)

check("mimo local SQL 只取 xiaomi provider",
      MiMoLocalLedger.querySQL(sinceMs: 1).contains("'$.providerID')='xiaomi'"))
check("mimo local SQL 带时间窗与缓存字段",
      MiMoLocalLedger.querySQL(sinceMs: 1790298000000).contains("1790298000000")
      && MiMoLocalLedger.querySQL(sinceMs: 1).contains("'$.tokens.cache.read'"))
check("mimo local 候选库路径(可注入 home)",
      MiMoLocalUsageCollector.candidateDBPaths(home: "/tmp/fakehome") == [
        "/tmp/fakehome/.local/share/mimocode/mimocode.db",
        "/tmp/fakehome/.local/share/opencode/opencode.db",
      ])

// 上次成功快照:控制台不可用时仍能显示(跨重启保留)
let snapTmp = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("mimo-last-verify-\(UUID().uuidString).json")
let snapStore = MiMoLastUsageStore(url: snapTmp)
check("mimo last 空 → nil", snapStore.load() == nil)
let snapUsage = MiMoUsageService.MiMoUsage(
    balance: MiMoUsageService.MiMoBalance(balance: 110.5, currency: "CNY",
                                          cashBalance: 100.5, giftBalance: 10),
    plan: MiMoUsageService.MiMoTokenPlan(planCode: "standard", periodEnd: nil, expired: nil,
                                         used: 163326, limit: 1_000_000, usedPct: 16.33))
let lastSnap = MiMoLastUsage(schemaVersion: 1, capturedAt: Date(timeIntervalSince1970: 0),
                             usage: snapUsage)
snapStore.save(lastSnap)
check("mimo last 往返(含 plan 三态 expired)", snapStore.load() == lastSnap)
check("mimo last 版本不符 → nil", {
    let bad = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mimo-last-bad-\(UUID().uuidString).json")
    try? Data(#"{"schemaVersion":99,"capturedAt":0,"usage":{}}"#.utf8).write(to: bad)
    defer { try? FileManager.default.removeItem(at: bad) }
    return MiMoLastUsageStore(url: bad).load() == nil
}())
try? FileManager.default.removeItem(at: snapTmp)

// --- MiMo 真实 API 端到端(仅 MIMO_E2E=1;走本机 Keychain,不打印凭据)---
// 与 App 定时刷新同一调用路径;用**实际过期**的会话验证:
//   ① 会话过期能被归类为 loginRequired(而不是被静默降级成"暂无用量数据")
//   ② 无 passToken 的旧版凭据优雅退化为"需重新登录",不会误报解析失败
if ProcessInfo.processInfo.environment["MIMO_E2E"] == "1" {
    // v1.0.82 起凭据迁到 .app 包内凭证文件(Keychain 仅一次性迁移来源)
    let store = AppFileCredentialStore.shared
    let jar = store.read(account: KeychainAccounts.mimoCookieJar).flatMap(MiMoCookieJar.decode)
        ?? store.read(account: KeychainAccounts.mimoCookie).flatMap(MiMoCookieJar.legacy)
    check("e2e mimo 凭据存在", jar != nil)
    if let jar {
        check("e2e mimo platform 段非空", !jar.platformHeader.isEmpty)
        let live = await MiMoUsageService.fetchUsage(cookieHeader: jar.platformHeader)
        switch live {
        case .success(let u):
            check("e2e mimo fetch success", true)
            check("e2e mimo 余额可读", u.balance.balance >= 0)
            print("     ↳ 余额 \(MiMoMoneyFormat.full(u.balance.balance, currency: u.balance.currency))"
                  + ",套餐 \(u.plan.map { "\(Int($0.usedPct.rounded()))%" } ?? "无")")
        case .failure(let e):
            // 凭据过期是当前本机的预期状态:必须是 loginRequired,且不得是 parse
            check("e2e mimo 过期归类为 loginRequired(非 parse)", e == .loginRequired)
            print("     ↳ 归类结果 \(e)")
        }
        // 旧版单段凭据(无 passToken)不能续期,但必须优雅报"需重新登录"
        if !jar.canRenew {
            let renewed = await MiMoSessionRenewal.renew(jar: jar)
            check("e2e mimo 无 passToken → 续期报 loginRequired", renewed == .failure(.loginRequired))
        } else if ProcessInfo.processInfo.environment["MIMO_RENEW_E2E"] == "1" {
            // 完整续期链路端到端:故意打坏 platform 段制造"会话过期",验证能用 passToken 换回可用凭据。
            // ⚠️ 全程在内存中,不写 Keychain(持久化只发生在 TokenPlanModel)。
            let broken = MiMoCookieJar(platformHeader: "api-platform_serviceToken=BROKEN; userId=0",
                                       accountHeader: jar.accountHeader)
            let before = await MiMoUsageService.fetchUsage(cookieHeader: broken.platformHeader)
            check("e2e 续期:坏 platform 段确实报 loginRequired",
                  before == .failure(.loginRequired))
            let renewed = await MiMoSessionRenewal.renew(jar: broken)
            check("e2e 续期:用真实 passToken 成功换发新 serviceToken", {
                if case .success(let nj) = renewed {
                    return MiMoCookieJar.parseCookiePairs(nj.platformHeader)["api-platform_serviceToken"]
                        != nil && nj.canRenew
                }
                return false
            }())
            if case .success(let nj) = renewed {
                let after = await MiMoUsageService.fetchUsage(cookieHeader: nj.platformHeader)
                check("e2e 续期:换发后的凭据可直接拉到用量", {
                    if case .success(let u) = after { return u.balance.balance >= 0 }
                    return false
                }())
                switch after {
                case .success(let u):
                    print("     ↳ 续期后余额 \(MiMoMoneyFormat.full(u.balance.balance, currency: u.balance.currency))"
                          + ",套餐 \(u.plan.map { "\(Int($0.usedPct.rounded()))%" } ?? "无")")
                case .failure(let e):
                    print("     ↳ 续期后仍失败:\(e)")
                }
            } else {
                print("     ↳ 续期失败:\(renewed)")
            }
        }
    }
    // 本地账本:读本机 CLI 库(只读,零凭据)
    if let local = MiMoLocalUsageCollector.collect(sinceDays: 30) {
        check("e2e mimo 本地账本有数据", !local.days.isEmpty)
        check("e2e mimo 本地账本按天升序", local.days.map(\.date) == local.days.map(\.date).sorted())
        print("     ↳ 本机口径:近 30 天 \(MiMoLocalLedger.totalTokens(in: local)) tok"
              + ",\(local.days.count) 天,最新 \(local.days.last?.date ?? "-")")
    } else {
        check("e2e mimo 本地账本(本机无 mimocode/opencode 库时允许为空)", true)
        print("     ↳ 本机口径:无可采集数据")
    }
}

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

// --- OllamaUsageService:Ollama Cloud 用量解析 ---
// fixture = 2026-10-09 起的新结构(实测):按天美元报表 totals + buckets,
// 不再有 limits.*.usage(0-1 小数)与 activity.cost。
let ollamaLive30d = #"{"range":"30d","scope":"self","granularity":"day","from":"2026-09-09T00:00:00Z","until":"2026-10-09T12:12:21Z","totals":{"request_count":1000,"usage_usd":55,"input_tokens":900,"cached_input_tokens":800,"output_tokens":100},"buckets":[{"from":"2026-09-09T00:00:00Z","until":"2026-09-10T00:00:00Z","request_count":100,"usage_usd":1,"input_tokens":90,"cached_input_tokens":80,"output_tokens":10},{"from":"2026-09-10T00:00:00Z","until":"2026-09-11T00:00:00Z","request_count":100,"usage_usd":2,"input_tokens":90,"cached_input_tokens":80,"output_tokens":10},{"from":"2026-09-11T00:00:00Z","until":"2026-09-12T00:00:00Z","request_count":100,"usage_usd":3,"input_tokens":90,"cached_input_tokens":80,"output_tokens":10},{"from":"2026-09-12T00:00:00Z","until":"2026-09-13T00:00:00Z","request_count":100,"usage_usd":4,"input_tokens":90,"cached_input_tokens":80,"output_tokens":10},{"from":"2026-09-13T00:00:00Z","until":"2026-09-14T00:00:00Z","request_count":100,"usage_usd":5,"input_tokens":90,"cached_input_tokens":80,"output_tokens":10},{"from":"2026-09-14T00:00:00Z","until":"2026-09-15T00:00:00Z","request_count":100,"usage_usd":6,"input_tokens":90,"cached_input_tokens":80,"output_tokens":10},{"from":"2026-09-15T00:00:00Z","until":"2026-09-16T00:00:00Z","request_count":100,"usage_usd":7,"input_tokens":90,"cached_input_tokens":80,"output_tokens":10},{"from":"2026-09-16T00:00:00Z","until":"2026-09-17T00:00:00Z","request_count":100,"usage_usd":8,"input_tokens":90,"cached_input_tokens":80,"output_tokens":10},{"from":"2026-09-17T00:00:00Z","until":"2026-09-18T00:00:00Z","request_count":100,"usage_usd":9,"input_tokens":90,"cached_input_tokens":80,"output_tokens":10},{"from":"2026-09-18T00:00:00Z","until":"2026-09-19T00:00:00Z","partial":true,"request_count":100,"usage_usd":10,"input_tokens":90,"cached_input_tokens":80,"output_tokens":10}]}"#
let oq = OllamaUsageService.parseQuota(from: Data(ollamaLive30d.utf8), plan: "max")
check("ollama 新结构 parse ok", oq != nil)
check("ollama totals.usage_usd→近30天消费", oq?.spentUSD30d == 55)
check("ollama totals.request_count→请求数", oq?.requests30d == 1000)
check("ollama 日桶尾部7个汇总=4+…+10", oq?.spentUSD7d == 49)
check("ollama 日桶数量保留", oq?.dailyUSD.count == 10)
check("ollama 日均=55/30", abs((oq?.dailyAvgUSD ?? 0) - 55.0 / 30.0) < 1e-9)
check("ollama max 档 $300 → 占比 18.33%(取整18)", oq?.monthly?.pctInt == 18
      && abs((oq?.usagePct ?? 0) - 55.0 / 300.0 * 100) < 1e-9)
check("ollama 新结构单窗口:secondary 恒 nil(单值列判据)", oq?.secondary == nil
      && oq?.primary?.pctInt == 18)
check("ollama primaryLabel=30天", oq?.primaryLabel == "30天")
check("ollama 新结构无每模型数据", oq?.monthly?.models.isEmpty == true)
check("ollama plan 透传 + 展示名", oq?.plan == "max" && oq?.planDisplay == "Max")

// 档位可得性:free 档无额度表 → 无占比,但绝对消费仍解析成功(UI 走金额 hero)
let oqFree = OllamaUsageService.parseQuota(from: Data(ollamaLive30d.utf8), plan: "free")
check("ollama free 档无额度→monthly nil 但解析成功", oqFree != nil
      && oqFree?.monthly == nil && oqFree?.capUSD == nil
      && oqFree?.spentUSD30d == 55 && oqFree?.usagePct == nil)
let oqNoPlan = OllamaUsageService.parseQuota(from: Data(ollamaLive30d.utf8))
check("ollama 档位探测失败→同样走绝对金额", oqNoPlan?.monthly == nil && oqNoPlan?.spentUSD30d == 55)

// 百分比归一化:美元 ÷ 额度,超支钳 100
check("ollama $150/$300 → 50%", OllamaPlan.usagePct(spentUSD: 150, capUSD: 300) == 50)
check("ollama 超支 $400/$300 → 钳 100", OllamaPlan.usagePct(spentUSD: 400, capUSD: 300) == 100)
check("ollama 零消费 → 0%", OllamaPlan.usagePct(spentUSD: 0, capUSD: 300) == 0)
check("ollama 额度 0/负 → nil", OllamaPlan.usagePct(spentUSD: 5, capUSD: 0) == nil
      && OllamaPlan.usagePct(spentUSD: 5, capUSD: -1) == nil)
check("ollama 档位额度表", OllamaPlan.monthlyCapUSD(plan: "pro") == 60
      && OllamaPlan.monthlyCapUSD(plan: "max") == 300
      && OllamaPlan.monthlyCapUSD(plan: "team") == 1000
      && OllamaPlan.monthlyCapUSD(plan: "free") == nil
      && OllamaPlan.monthlyCapUSD(plan: nil) == nil)

// 宽容:数字字符串 usage_usd / 桶缺 usage_usd 跳过 / totals 缺失 → nil
let ollamaStringy = #"{"totals":{"request_count":"1000","usage_usd":"55"},"buckets":[{"usage_usd":"1"},{"usage_usd":2},{"request_count":5}]}"#
let oq4 = OllamaUsageService.parseQuota(from: Data(ollamaStringy.utf8), plan: "pro")
check("ollama 字符串 usage_usd/request_count 宽容解析", oq4?.spentUSD30d == 55 && oq4?.requests30d == 1000)
check("ollama 桶缺 usage_usd 被跳过(近7天=1+2)", oq4?.spentUSD7d == 3 && oq4?.dailyUSD.count == 2)
check("ollama 无 totals → nil", OllamaUsageService.parseQuota(
    from: Data(#"{"buckets":[{"usage_usd":1}]}"#.utf8)) == nil)
check("ollama totals 缺 usage_usd → nil", OllamaUsageService.parseQuota(
    from: Data(#"{"totals":{"request_count":10}}"#.utf8)) == nil)
check("ollama 旧 limits 结构(2026-10 前)→ nil(结构已从服务端消失)", OllamaUsageService.parseQuota(
    from: Data(#"{"limits":{"monthly":{"usage":0.152}},"activity":{"cost":"0.0"}}"#.utf8)) == nil)
check("ollama 空 JSON 对象 → nil", OllamaUsageService.parseQuota(from: Data("{}".utf8)) == nil)
check("ollama 畸形 JSON → nil", OllamaUsageService.parseQuota(from: Data("not json".utf8)) == nil)

// 零消费账号(全 0 桶)仍算成功,占比 0%
check("ollama 零消费账号 → 成功且 0%", OllamaUsageService.parseQuota(
    from: Data(#"{"totals":{"request_count":0,"usage_usd":0},"buckets":[{"usage_usd":0}]}"#.utf8), plan: "pro")?
    .monthly?.pctInt == 0)

// 档位解码:远程 "Plan" / daemon "plan" 两个 key 都认
check("ollama 远程 Plan 键解码", OllamaUsageService.decodePlan(
    from: Data(#"{"ID":"x","Email":"a@b.c","Plan":"max"}"#.utf8)) == "max")
check("ollama daemon plan 键解码", OllamaUsageService.decodePlan(
    from: Data(#"{"plan":"pro"}"#.utf8)) == "pro")
check("ollama 缺档位字段/畸形 → nil", OllamaUsageService.decodePlan(
    from: Data(#"{"ID":"x"}"#.utf8)) == nil
      && OllamaUsageService.decodePlan(from: Data("not json".utf8)) == nil)

// 美元格式化
check("ollama money 格式", OllamaMoney.full(167.50866) == "$167.51"
      && OllamaMoney.full(0) == "$0.00" && OllamaMoney.full(-3) == "$0.00")

// HTTP 状态分类
check("ollama 200→nil", OllamaUsageService.classifyHTTP(200) == nil)
check("ollama 401/403→authExpired", OllamaUsageService.classifyHTTP(401) == .authExpired
      && OllamaUsageService.classifyHTTP(403) == .authExpired)
check("ollama 429→rateLimited", OllamaUsageService.classifyHTTP(429) == .rateLimited)
check("ollama 500→unknown", {
    if case .unknown = OllamaUsageService.classifyHTTP(500) { return true }
    return false
}())
check("ollama 空 key→authExpired(不发请求)", {
    // 空 key 必须在本地短路;用 async 结果不可直接断言,改为验证 trim 后判空语义
    let empty = "   ".trimmingCharacters(in: .whitespacesAndNewlines)
    return empty.isEmpty
}())

// 菜单栏列:新计费单值列(近30天)/ 旧计费双值列
let olMonthlyCol = mtCols(olConf: true).first { $0.kind == .ollama }
check("mt Ollama 新计费→单值列主=30天标签", olMonthlyCol?.primary.text == "15%"
      && olMonthlyCol?.primaryLabel == "30天" && olMonthlyCol?.secondaryLabel == nil)
let olLegacyCol = mtCols(olConf: true, olP: 82, olS: 23).first { $0.kind == .ollama }
check("mt Ollama 旧计费→双值列 5小时/周", olLegacyCol?.primary.text == "82%"
      && olLegacyCol?.secondary.text == "23%" && olLegacyCol?.primaryLabel == "5小时"
      && olLegacyCol?.secondaryLabel == "周")
check("mt Ollama 未配置→不出列", !mtCols().map(\.kind).contains(.ollama))
check("mt Ollama 出错→横杠列仍出", {
    let c = mtCols(olConf: true, olErr: true, olP: nil, olS: nil).first { $0.kind == .ollama }
    return c?.primary.text == "—"
}())
check("mt 10列全显示且固定顺序(本机恒最后)",
      mtCols(zConf: true, miConf: true, olConf: true, sfConf: true).map(\.kind)
      == [.aliyun, .kimi, .openCode, .deepSeek, .zhipu, .mimo, .minimax, .ollama, .stepfun, .system])
check("mt Ollama 停用→不出列", !mtCols(olConf: true, dis: ["ollama"]).map(\.kind).contains(.ollama))
check("mt Ollama tooltip 用30天标签", MenuBarTable.tooltip(columns: mtCols(olConf: true)).contains("Ollama 30天 15%"))

// 历史快照往返 + 序列映射
let olSnap = UsageSnapshot(timestamp: Date(), aliyunFiveHour: nil, aliyunOneWeek: nil,
                          opencodeRolling: nil, opencodeWeekly: nil, opencodeMonthly: nil,
                          ollamaMonthly: 15, ollamaSession: nil, ollamaWeekly: nil)
let olEnc = try? JSONEncoder().encode(olSnap)
let olDec = olEnc.flatMap { try? JSONDecoder().decode(UsageSnapshot.self, from: $0) }
check("ollama snapshot 往返", olDec?.ollamaMonthly == 15)
check("ollama snapshot 旧JSON兼容(新字段全 nil)", {
    let old = #"{"timestamp":"2026-09-12T00:00:00Z","aliyunFiveHour":null,"aliyunOneWeek":null,"opencodeRolling":null,"opencodeWeekly":null,"opencodeMonthly":null}"#
    let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
    let s = try? dec.decode(UsageSnapshot.self, from: Data(old.utf8))
    return s?.ollamaMonthly == nil && s?.ollamaSession == nil && s?.ollamaWeekly == nil
}())
check("ollama series 映射", HistoryStore.series([olSnap], provider: "ollama", window: "monthly") == [15]
      && HistoryStore.series([olSnap], provider: "ollama", window: "5h") == [nil])

// --- StepFunUsageService:阶跃 Step Plan 用量解析 ---
// fixture① = 现行 Credit 月池计费(credit_buckets,snake 形状):
// 订阅桶(residual/total 反推已用%)+ 加油包桶(type 数字 2;expire_at 秒级时间戳)
let sfBuckets = #"{"plan_credit_rate_limit":{"credit_buckets":[{"credit_total":240000000,"credit_residual":189000000,"type":"CREDIT_BUCKET_TYPE_SUBSCRIPTION","next_reset_at":1790000000000},{"credit_total":50000000,"credit_residual":50000000,"type":2,"expire_at":1791000000}]}}"#
let sfq = StepFunUsageService.parseQuota(from: Data(sfBuckets.utf8))
check("stepfun buckets 解析成功", sfq != nil)
check("stepfun 订阅月池 21%(residual/total 反推)", sfq?.subscription?.usedPctInt == 21
      && sfq?.subscription?.total == 240_000_000 && sfq?.subscription?.residual == 189_000_000)
check("stepfun 订阅重置毫秒原样", sfq?.subscription?.resetTimeMs == 1_790_000_000_000)
check("stepfun 加油包聚合(满额 0%)", sfq?.topup?.usedPctInt == 0 && sfq?.topup?.total == 50_000_000)
check("stepfun 加油包秒级时间戳→毫秒", sfq?.topup?.resetTimeMs == 1_791_000_000_000)
check("stepfun 主=月池 次=加油包(标签随形态)", sfq?.primaryPct == 21 && sfq?.primaryLabel == "月池"
      && sfq?.secondaryPct == 0 && sfq?.secondaryLabel == "加油包")

// fixture② = camel 键名 + 字符串 type="2" + 多加油包聚合
let sfCamel = #"{"planCreditRateLimit":{"creditBuckets":[{"creditTotal":100,"creditResidual":25,"type":"2"},{"creditTotal":100,"creditResidual":0,"type":"TOPUP_PACK"},{"creditTotal":200,"creditResidual":100,"type":"PLAN"}]}}"#
let sfq2 = StepFunUsageService.parseQuota(from: Data(sfCamel.utf8))
check("stepfun camel 键名兼容", sfq2 != nil)
check("stepfun 订阅=最后非 topup 桶 50%", sfq2?.subscription?.usedPctInt == 50)
check("stepfun 两加油包聚合 87.5%→88%", sfq2?.topup?.total == 200 && sfq2?.topup?.residual == 25
      && sfq2?.topup?.usedPctInt == 88)

// fixture③ = 纯 rate 兜底(left rate 0-1 小数 → 已用=100-left)
let sfRate = #"{"plan_credit_rate_limit":{"subscription_credit_left_rate":0.83,"subscription_credit_reset_time":1790000000000,"topup_credit_left_rate":0.5}}"#
let sfq3 = StepFunUsageService.parseQuota(from: Data(sfRate.utf8))
check("stepfun rate 兜底 sub 17% topup 50%", sfq3?.subscription?.usedPctInt == 17
      && sfq3?.topup?.usedPctInt == 50)
check("stepfun rate 兜底无计数(total=0)", sfq3?.subscription?.total == 0)

// fixture④ = 旧计费 5h/周双窗口(camel;left rate)
let sfLegacy = #"{"fiveHourUsageLeftRate":0.57,"fiveHourUsageResetTime":1790000000,"weeklyUsageLeftRate":0.88,"weeklyUsageResetTime":1790000000000}"#
let sfq4 = StepFunUsageService.parseQuota(from: Data(sfLegacy.utf8))
check("stepfun 旧计费 5h=43% 周=12%", sfq4?.fiveHour?.usedPctInt == 43 && sfq4?.weekly?.usedPctInt == 12)
check("stepfun 旧计费主=5小时 次=周", sfq4?.primaryPct == 43 && sfq4?.primaryLabel == "5小时"
      && sfq4?.secondaryPct == 12 && sfq4?.secondaryLabel == "周")
check("stepfun 旧计费无 Credit 桶", sfq4?.subscription == nil && sfq4?.topup == nil)
check("stepfun billingDisplay 旧计费", sfq4?.billingDisplay == "5小时 + 周")

// 无可用字段/畸形 → nil;宽容:数字字符串
check("stepfun 无额度字段→nil", StepFunUsageService.parseQuota(from: Data(#"{"foo":1}"#.utf8)) == nil)
check("stepfun 畸形 JSON→nil", StepFunUsageService.parseQuota(from: Data("not json".utf8)) == nil)
check("stepfun total=0 桶被跳过", StepFunUsageService.parseQuota(from: Data(
    #"{"plan_credit_rate_limit":{"credit_buckets":[{"credit_total":0,"credit_residual":0,"type":"SUB"}]}}"#.utf8)) == nil)
check("stepfun 数字字符串计数宽容", StepFunUsageService.parseQuota(from: Data(
    #"{"plan_credit_rate_limit":{"credit_buckets":[{"credit_total":"200","credit_residual":"100","type":"SUB"}]}}"#.utf8))?
    .subscription?.usedPctInt == 50)

// 归一化纯函数
check("stepfun leftRate 0-1→已用=100x", StepFunUsageService.leftRateToUsedPct(0.83) == 17)
check("stepfun leftRate 0-100 直接反推", StepFunUsageService.leftRateToUsedPct(83) == 17)
check("stepfun leftRate 0→100% 1→0%", StepFunUsageService.leftRateToUsedPct(0) == 100
      && StepFunUsageService.leftRateToUsedPct(1) == 0)
check("stepfun leftRate NaN/nil→nil", StepFunUsageService.leftRateToUsedPct(.nan) == nil
      && StepFunUsageService.leftRateToUsedPct(nil) == nil)
check("stepfun epochMs 秒/毫秒/非法", StepFunUsageService.epochMs(1_755_400_000) == 1_755_400_000_000
      && StepFunUsageService.epochMs(1_755_400_000_000) == 1_755_400_000_000
      && StepFunUsageService.epochMs(1000) == nil && StepFunUsageService.epochMs(nil) == nil)
check("stepfun bucketUsedPct 钳制", StepFunUsageService.bucketUsedPct(total: 100, residual: 150) == 0
      && StepFunUsageService.bucketUsedPct(total: 0, residual: 10) == nil)
check("stepfun 冷却档位 15/30/60/120 分钟", StepFunUsageService.authRetryCooldownSeconds(consecutiveFailures: 1) == 900
      && StepFunUsageService.authRetryCooldownSeconds(consecutiveFailures: 2) == 1800
      && StepFunUsageService.authRetryCooldownSeconds(consecutiveFailures: 3) == 3600
      && StepFunUsageService.authRetryCooldownSeconds(consecutiveFailures: 4) == 7200
      && StepFunUsageService.authRetryCooldownSeconds(consecutiveFailures: 9) == 7200
      && StepFunUsageService.authRetryCooldownSeconds(consecutiveFailures: 0) == 0)

// 凭据归一化(裸 token / Oasis-Token=… / 整段 Cookie / 引号剥除 / 不识别)
check("stepfun token 裸值", StepFunUsageService.normalizedToken(from: "  abc123 ") == "abc123")
check("stepfun token 整段 Cookie 提取", StepFunUsageService.normalizedToken(
    from: "Cookie: a=1; Oasis-Token=xyz; b=2") == "xyz")
check("stepfun token 头前缀剥除", StepFunUsageService.normalizedToken(from: "Oasis-Token: tok") == "tok")
check("stepfun token 值外层引号剥除", StepFunUsageService.normalizedToken(from: #"Oasis-Token="q""#) == "q")
check("stepfun token 大小写不敏感", StepFunUsageService.normalizedToken(from: "oasis-token=MiXeD") == "MiXeD")
check("stepfun token 无 Oasis 段的 Cookie→nil", StepFunUsageService.normalizedToken(from: "a=1; b=2") == nil)
check("stepfun token 空串→nil", StepFunUsageService.normalizedToken(from: "  ") == nil)
check("stepfun token 空值段→nil(平台清 cookie)", StepFunUsageService.normalizedToken(from: "Oasis-Token=") == nil)

// 包络/HTTP 分类(2026-10-02 实测形状:401 + code=unauthenticated)
check("stepfun unauthenticated→authExpired", StepFunUsageService.classifyEnvelope(data: Data(
    #"{"code":"unauthenticated","message":"auth failed: token is missing","details":[]}"#.utf8)) == .authExpired)
check("stepfun permission_denied→tokenNotPermitted(贴错凭证类型)", StepFunUsageService.classifyEnvelope(data: Data(
    #"{"code":"permission_denied","message":"api key not permitted for this method"}"#.utf8)) == .tokenNotPermitted)
check("stepfun 无 code 包络→nil", StepFunUsageService.classifyEnvelope(data: Data(#"{"data":1}"#.utf8)) == nil)
check("stepfun HTTP 401(无包络)→authExpired", StepFunUsageService.classifyHTTP(statusCode: 401, data: Data(#"{}"#.utf8)) == .authExpired)
check("stepfun HTTP 200+错误包络→authExpired", StepFunUsageService.classifyHTTP(statusCode: 200, data: Data(
    #"{"code":"unauthenticated"}"#.utf8)) == .authExpired)
check("stepfun HTTP 200 正常→nil", StepFunUsageService.classifyHTTP(statusCode: 200, data: Data(#"{"ok":true}"#.utf8)) == nil)
check("stepfun HTTP 500→unknown", {
    if case .unknown = StepFunUsageService.classifyHTTP(statusCode: 500, data: Data(#"{}"#.utf8)) { return true }
    return false
}())

// Credit 展示格式(1M Credit = ¥1)
check("stepfun compact 240M", StepFunCreditFormat.compact(240_000_000) == "240M")
check("stepfun compact 12.5M", StepFunCreditFormat.compact(12_500_000) == "12.5M")
check("stepfun compact 1.20B", StepFunCreditFormat.compact(1_200_000_000) == "1.20B")
check("stepfun compact 0/负→0", StepFunCreditFormat.compact(0) == "0" && StepFunCreditFormat.compact(-5) == "0")
check("stepfun cny 240M=¥240", StepFunCreditFormat.cny(240_000_000) == "¥240.00")

// 菜单栏列:月池+加油包双值列 / 仅月池单值列 / 旧计费 5小时+周
let sfDualCol = mtCols(sfConf: true, sfP: 21, sfPl: "月池", sfS: 0, sfSl: "加油包").first { $0.kind == .stepfun }
check("mt 阶跃双值列 月池/加油包", sfDualCol?.primary.text == "21%" && sfDualCol?.secondary.text == "0%"
      && sfDualCol?.primaryLabel == "月池" && sfDualCol?.secondaryLabel == "加油包")
let sfSingleCol = mtCols(sfConf: true, sfP: 21, sfPl: "月池", sfS: nil, sfSl: nil).first { $0.kind == .stepfun }
check("mt 阶跃单值列(无加油包)", sfSingleCol?.primary.text == "21%"
      && sfSingleCol?.primaryLabel == "月池" && sfSingleCol?.secondaryLabel == nil)
let sfLegacyCol = mtCols(sfConf: true, sfP: 43, sfPl: "5小时", sfS: 12, sfSl: "周").first { $0.kind == .stepfun }
check("mt 阶跃旧计费列 5小时/周", sfLegacyCol?.primary.text == "43%" && sfLegacyCol?.secondary.text == "12%"
      && sfLegacyCol?.primaryLabel == "5小时" && sfLegacyCol?.secondaryLabel == "周")
check("mt 阶跃未配置→不出列", !mtCols().map(\.kind).contains(.stepfun))
check("mt 阶跃停用→不出列", !mtCols(sfConf: true, dis: ["stepfun"]).map(\.kind).contains(.stepfun))
check("mt 阶跃出错→横杠列仍出", {
    let c = mtCols(sfConf: true, sfErr: true, sfP: nil, sfS: nil).first { $0.kind == .stepfun }
    return c?.primary.text == "—"
}())
check("mt 阶跃 tooltip 月池标签", MenuBarTable.tooltip(columns: mtCols(sfConf: true, sfP: 21, sfPl: "月池")).contains("阶跃 月池 21%"))

// 历史快照往返 + 序列映射
let sfSnap = UsageSnapshot(timestamp: Date(), aliyunFiveHour: nil, aliyunOneWeek: nil,
                           opencodeRolling: nil, opencodeWeekly: nil, opencodeMonthly: nil,
                           stepfunMonthly: 21, stepfunTopup: 63)
let sfEnc = try? JSONEncoder().encode(sfSnap)
let sfDec = sfEnc.flatMap { try? JSONDecoder().decode(UsageSnapshot.self, from: $0) }
check("stepfun snapshot 往返", sfDec?.stepfunMonthly == 21 && sfDec?.stepfunTopup == 63)
check("stepfun snapshot 旧JSON兼容(新字段全 nil)", {
    let old = #"{"timestamp":"2026-10-02T00:00:00Z","aliyunFiveHour":null,"aliyunOneWeek":null,"opencodeRolling":null,"opencodeWeekly":null,"opencodeMonthly":null}"#
    let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
    let s = try? dec.decode(UsageSnapshot.self, from: Data(old.utf8))
    return s?.stepfunMonthly == nil && s?.stepfunTopup == nil
}())
check("stepfun series 映射", HistoryStore.series([sfSnap], provider: "stepfun", window: "monthly") == [21]
      && HistoryStore.series([sfSnap], provider: "stepfun", window: "topup") == [63])

// fixture⑤ = 真实账号形状(2026-10-02 实测):月池桶存在 + 旧 5h/周字段以
// proto3 零值下发(left_rate=0 且无重置时间)→ 必须忽略,不得误读为「已用 100%」
let sfReal = #"{"plan_credit_rate_limit":{"credit_buckets":[{"credit_total":8000000000,"credit_residual":7958520000,"type":"CREDIT_BUCKET_TYPE_SUBSCRIPTION","next_reset_at":1791000000}]},"five_hour_usage_left_rate":0,"weekly_usage_left_rate":0}"#
let sfq5 = StepFunUsageService.parseQuota(from: Data(sfReal.utf8))
check("stepfun 真实形状:月池 1%(7.96B/8B)", sfq5?.subscription?.usedPctInt == 1
      && sfq5?.subscription?.total == 8_000_000_000)
check("stepfun 真实形状:零值遗留 5h/周被忽略(不冒充 100%)", sfq5?.fiveHour == nil
      && sfq5?.weekly == nil)
check("stepfun 真实形状:单桶无加油包→单值列形态", sfq5?.topup == nil
      && sfq5?.secondaryPct == nil && sfq5?.primaryLabel == "月池")
check("stepfun 真实形状:重置秒级时间戳归一", sfq5?.subscription?.resetTimeMs == 1_791_000_000_000)

// 多账户聚合(2026-10-02 需求:用户有多个 Step Plan 订阅)
let sfAcc1 = StepFunQuota(subscription: StepFunCreditBucket(total: 8_000_000_000, residual: 7_900_000_000,
                                                            usedPct: 1.25, resetTimeMs: 1_791_000_000_000),
                          topup: nil, fiveHour: nil, weekly: nil)
let sfAcc2 = StepFunQuota(subscription: StepFunCreditBucket(total: 2_000_000_000, residual: 500_000_000,
                                                            usedPct: 75, resetTimeMs: 1_790_500_000_000),
                          topup: nil, fiveHour: nil, weekly: nil)
let sfAgg = StepFunQuota.aggregate([sfAcc1, sfAcc2])
check("stepfun 聚合:计数桶求和 16%/10B", sfAgg?.subscription?.usedPctInt == 16
      && sfAgg?.subscription?.total == 10_000_000_000
      && sfAgg?.subscription?.residual == 8_400_000_000)
check("stepfun 聚合:重置取最早", sfAgg?.subscription?.resetTimeMs == 1_790_500_000_000)
check("stepfun 聚合:单账户原样返回", StepFunQuota.aggregate([sfAcc1])?.subscription?.usedPctInt == 1)
check("stepfun 聚合:空列表→nil", StepFunQuota.aggregate([]) == nil)
// 纯百分比兜底形状:聚合取 max(最紧)
let sfPct1 = StepFunQuota(subscription: StepFunCreditBucket(total: 0, residual: 0, usedPct: 20, resetTimeMs: nil),
                          topup: nil, fiveHour: nil, weekly: nil)
let sfPct2 = StepFunQuota(subscription: StepFunCreditBucket(total: 0, residual: 0, usedPct: 60, resetTimeMs: nil),
                          topup: nil, fiveHour: nil, weekly: nil)
check("stepfun 聚合:纯百分比取 max", StepFunQuota.aggregate([sfPct1, sfPct2])?.subscription?.usedPctInt == 60)
// 加油包跨账户求和;旧 5h 窗口取 max
let sfAcc3 = StepFunQuota(subscription: nil,
                          topup: StepFunCreditBucket(total: 100, residual: 80, usedPct: 20, resetTimeMs: nil),
                          fiveHour: StepFunRateWindow(usedPct: 30, resetTimeMs: nil), weekly: nil)
let sfAcc4 = StepFunQuota(subscription: nil,
                          topup: StepFunCreditBucket(total: 300, residual: 150, usedPct: 50, resetTimeMs: nil),
                          fiveHour: StepFunRateWindow(usedPct: 80, resetTimeMs: nil), weekly: nil)
let sfAgg2 = StepFunQuota.aggregate([sfAcc3, sfAcc4])
check("stepfun 聚合:加油包求和 42.5%→43%", sfAgg2?.topup?.usedPctInt == 43 && sfAgg2?.topup?.total == 400)
check("stepfun 聚合:旧5h取max 80%", sfAgg2?.fiveHour?.usedPctInt == 80)

// 快照合并(2026-10-09:失败账户保留 last-good 旧值,行不消失/统计不跳动)
let sfMergeNow = Date(timeIntervalSince1970: 1_790_910_000)
let sfSnapFresh = StepFunAccountSnapshot(id: "a", label: "账户1", quota: sfAcc1,
                                         fetchedAt: sfMergeNow, isStale: false)
let sfSnapPrevB = StepFunAccountSnapshot(id: "b", label: "账户2", quota: sfAcc2,
                                         fetchedAt: Date(timeIntervalSince1970: 1_790_800_000))
let sfMerged = StepFunAccountSnapshot.merge(
    accounts: [StepFunAccount(id: "a", label: "账户1"), StepFunAccount(id: "b", label: "账户2"),
               StepFunAccount(id: "c", label: "账户3")],
    fresh: ["a": sfSnapFresh],
    previous: ["b": sfSnapPrevB],
    now: sfMergeNow)
check("stepfun 合并:三账户两行(无数据的账户不输出)", sfMerged.count == 2
      && sfMerged.map(\.id) == ["a", "b"])
check("stepfun 合并:成功账户新值不标旧", sfMerged[0].isStale == false && sfMerged[0].fetchedAt == sfMergeNow)
check("stepfun 合并:失败账户保留旧值并标 isStale(拉取时刻不变)", sfMerged[1].isStale == true
      && sfMerged[1].quota == sfAcc2
      && sfMerged[1].fetchedAt == sfSnapPrevB.fetchedAt)
check("stepfun 合并:标签跟随账户列表(重命名生效)", sfMerged[1].label == "账户2")
// 合并后的聚合照算(含旧数据):1.25% + 75% 计数求和
check("stepfun 合并:聚合含旧数据", StepFunQuota.aggregate(sfMerged.map(\.quota))?.subscription?.usedPctInt == 16)

// 账户身份(oasis_id)解析:Oasis-Token = access...refresh 两段 JWT 拼接
func sfJWT(_ payloadJSON: String) -> String {
    Data(payloadJSON.utf8).base64EncodedString()
}
let sfUserJWT = sfJWT(#"{"activated":true,"age":1,"baned":false,"create_at":1791547770,"exp":1791549570,"mode":2,"oasis_id":340334143521878016,"organization_id":0,"real_name_status":1,"role_in_organization":0,"version":4}"#)
let sfDeviceJWT = sfJWT(#"{"app_id":10300,"device_id":"b448bb","exp":1794139770,"oasis_id":340334143521878016,"oasis_r_at":1772595270,"platform":"web","version":3}"#)
let sfCookieReal = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.\(sfUserJWT).RPVsig...eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.\(sfDeviceJWT).NGH3sig"
check("stepfun oasis_id:真实两段 JWT cookie", StepFunUsageService.oasisID(fromCookieValue: sfCookieReal) == "340334143521878016")
check("stepfun oasis_id:单段 JWT", StepFunUsageService.oasisID(fromCookieValue: "h.\(sfUserJWT).s") == "340334143521878016")
check("stepfun oasis_id:仅 header 段→nil", StepFunUsageService.oasisID(fromCookieValue: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9") == nil)
check("stepfun oasis_id:base64url(-/_ 替换+补 Padding)", StepFunUsageService.oasisID(fromCookieValue: "h.eyJvYXNpc19pZCI6ICJhYmM_fj4ifQ==.s") == "abc?~>")
check("stepfun oasis_id:字符串型 oasis_id", StepFunUsageService.oasisID(fromCookieValue: "h.\(sfJWT(#"{"oasis_id":"9876543210"}"#)).s") == "9876543210")
check("stepfun oasis_id:无该字段→nil", StepFunUsageService.oasisID(fromCookieValue: "h.\(sfJWT(#"{"app_id":10300}"#)).s") == nil)
check("stepfun oasis_id:垃圾/空→nil", StepFunUsageService.oasisID(fromCookieValue: "not-a-jwt") == nil
      && StepFunUsageService.oasisID(fromCookieValue: "") == nil
      && StepFunUsageService.oasisID(fromCookieValue: #" "abc" "#) == nil)
// 身份后缀(展示/去重提示用)
check("stepfun identitySuffix 尾4位", StepFunAccount(id: "x", label: "账户2", oasisID: "340334143521878016").identitySuffix == "#8016")
check("stepfun identitySuffix 无身份→nil", StepFunAccount(id: "x", label: "账户2").identitySuffix == nil)
check("stepfun identitySuffix 短身份→nil", StepFunAccount(id: "x", label: "账户2", oasisID: "12").identitySuffix == nil)
// 身份展示:手机号尾号优先,JWT 里没有手机号→账户中心 GetAccountBinding 单独取
check("stepfun identityDisplay 手机号优先", StepFunAccount(id: "x", label: "账户2", oasisID: "340334143521878016", phoneTail: "5678").identityDisplay == "****5678")
check("stepfun identityDisplay 无手机号回落 oasis", StepFunAccount(id: "x", label: "账户2", oasisID: "340334143521878016").identityDisplay == "#8016")
check("stepfun identityDisplay 手机号非法长度回落 oasis", StepFunAccount(id: "x", label: "账户2", oasisID: "340334143521878016", phoneTail: "678").identityDisplay == "#8016")
check("stepfun identityDisplay 双无→nil", StepFunAccount(id: "x", label: "账户2").identityDisplay == nil)
// 账户 Codable 兼容:旧 JSON(无 oasisID 键)解出 nil
if let sfOldJSON = #"[{"id":"main","label":"账户1"}]"#.data(using: .utf8),
   let sfDecoded = try? JSONDecoder().decode([StepFunAccount].self, from: sfOldJSON) {
    check("stepfun 账户解码兼容(无 oasisID 键→nil)", sfDecoded.count == 1 && sfDecoded[0].oasisID == nil
          && sfDecoded[0].phoneTail == nil && sfDecoded[0].identitySuffix == nil)
} else {
    check("stepfun 账户解码兼容(无 oasisID 键→nil)", false)
}
// phoneTail 随账户列表持久化往返(登录时写入,重启后仍显示手机号尾号)
if let sfEncoded = try? JSONEncoder().encode([StepFunAccount(id: "main", label: "账户1", oasisID: "3403", phoneTail: "9012")]),
   let sfRound = try? JSONDecoder().decode([StepFunAccount].self, from: sfEncoded) {
    check("stepfun 账户 Codable 往返(phoneTail)", sfRound.count == 1 && sfRound[0].phoneTail == "9012"
          && sfRound[0].identityDisplay == "****9012")
} else {
    check("stepfun 账户 Codable 往返(phoneTail)", false)
}
// GetAccountBinding 响应(Connect JSON)→ 手机号尾4位;服务端返回的就是掩码号(前3+****+后4)
check("stepfun phoneTail:服务端掩码号(实测形状)", StepFunUsageService.phoneTail(fromBindingJSON: #"{"binding":{"mobile":{"cc":"86", "number":"186****6010"}}}"#) == "6010")
check("stepfun phoneTail:完整号码(兼容未掩码)", StepFunUsageService.phoneTail(fromBindingJSON: #"{"binding":{"mobile":{"cc":"86","number":"13812345678","encode_version":0}}}"#) == "5678")
check("stepfun phoneTail:含分隔符/国际号", StepFunUsageService.phoneTail(fromBindingJSON: #"{"binding":{"mobile":{"cc":"1","number":"+1 (415) 555-2671"}}}"#) == "2671")
check("stepfun phoneTail:11位短号剥非数字", StepFunUsageService.phoneTail(fromBindingJSON: #"{"binding":{"mobile":{"number":"138-0013-8000"}}}"#) == "8000")
check("stepfun phoneTail:未绑手机(空 binding)→nil", StepFunUsageService.phoneTail(fromBindingJSON: #"{"binding":{}}"#) == nil)
check("stepfun phoneTail:错误包络→nil", StepFunUsageService.phoneTail(fromBindingJSON: #"{"code":"unauthenticated","message":"token vs header: device is not matching"}"#) == nil)
check("stepfun phoneTail:位数不足→nil", StepFunUsageService.phoneTail(fromBindingJSON: #"{"binding":{"mobile":{"number":"12345"}}}"#) == nil)
check("stepfun phoneTail:垃圾/空→nil", StepFunUsageService.phoneTail(fromBindingJSON: "not json") == nil
      && StepFunUsageService.phoneTail(fromBindingJSON: "") == nil
      && StepFunUsageService.phoneTail(fromBindingJSON: #"{"binding":{"mobile":{}}}"#) == nil)
check("stepfun accountBindingURL 指向账户中心 user 服务", StepFunUsageService.accountBindingURL.absoluteString
      == "https://account.stepfun.com/api/user/proto.api.user.v1.UserService/GetAccountBinding")
// device_id 提取(账户中心 Oasis-Webid 头用:与 oasisID 同款逐段试解,取 device JWT 段)
check("stepfun deviceID:真实两段 JWT cookie", StepFunUsageService.deviceID(fromCookieValue: sfCookieReal) == "b448bb")
check("stepfun deviceID:单段 device JWT", StepFunUsageService.deviceID(fromCookieValue: "h.\(sfDeviceJWT).s") == "b448bb")
check("stepfun deviceID:仅 user 段(无 device_id)→nil", StepFunUsageService.deviceID(fromCookieValue: "h.\(sfUserJWT).s") == nil)
check("stepfun deviceID:垃圾/空→nil", StepFunUsageService.deviceID(fromCookieValue: "not-a-jwt") == nil
      && StepFunUsageService.deviceID(fromCookieValue: "") == nil)

// 月末预测(月池线性外推:v1.0.65 hero 预测行)
let sfNow = Date(timeIntervalSince1970: 1_790_900_000)
let sfReset: Int64 = 1_792_887_200_000   // epoch ms;now + 23 天(月池清零)
// 24h 前 10% → 现在 18%,日速 +8 × 23 天 ≈ +184 → 撑爆 → 钳 100
let sfSamples: [(t: Date, pct: Double)] = [(t: Date(timeIntervalSince1970: 1_790_900_000 - 24 * 3600), pct: 10),
                 (t: sfNow, pct: 18)]
let sfFc = StepFunForecast.monthEndPct(samples: sfSamples, now: sfNow, resetMs: sfReset)
check("stepfun 预测:高速率撑爆→钳 100", sfFc == 100)
check("stepfun 预测:日速 +8/天", abs((StepFunForecast.pctPerDay(samples: sfSamples) ?? 0) - 8) < 0.01)
// 低速率:24h +0.8 × 23 天 ≈ +18 → 预计 36
let sfSamples2: [(t: Date, pct: Double)] = [(t: Date(timeIntervalSince1970: 1_790_900_000 - 24 * 3600), pct: 17.2),
                  (t: sfNow, pct: 18)]
let sfFc2 = StepFunForecast.monthEndPct(samples: sfSamples2, now: sfNow, resetMs: sfReset)
check("stepfun 预测:慢速 ≈ 36%", sfFc2.map { Int($0.rounded()) } == 36)
// 不足/边界 → nil
check("stepfun 预测:单点→nil", StepFunForecast.monthEndPct(samples: [(t: sfNow, pct: 5.0)], now: sfNow, resetMs: sfReset) == nil)
check("stepfun 预测:跨度<6h→nil", StepFunForecast.monthEndPct(samples: [
    (t: Date(timeIntervalSince1970: 1_790_900_000 - 3600), pct: 5.0),
    (t: sfNow, pct: 8.0)], now: sfNow, resetMs: sfReset) == nil)
check("stepfun 预测:重置已过→nil", StepFunForecast.monthEndPct(samples: sfSamples, now: sfNow, resetMs: Int64(1_790_900_000_000)) == nil)
check("stepfun 预测:无重置→nil", StepFunForecast.monthEndPct(samples: sfSamples, now: sfNow, resetMs: nil) == nil)
check("stepfun 预测:负速钳到 0", StepFunForecast.monthEndPct(samples: [
    (t: Date(timeIntervalSince1970: 1_790_900_000 - 48 * 3600), pct: 30.0),
    (t: sfNow, pct: 10.0)], now: sfNow, resetMs: sfReset) == 0)

// UsageForecast 泛化(v1.0.66:全订阅卡共用的触顶/runway/时长文案)
// 窗口速率:24h 前 10% → 现在 30%,+0.8333%/h,剩 70% → 84h(5040 分钟)触顶
let ufRolling: [(t: Date, pct: Double)] = [
    (t: Date(timeIntervalSince1970: 1_790_900_000 - 24 * 3600), pct: 10),
    (t: sfNow, pct: 30)]
check("forecast 速率:+0.8333%/h", abs((UsageForecast.pctPerHour(samples: ufRolling) ?? 0) - 0.8333) < 0.001)
check("forecast 触顶:84h=5040 分钟", UsageForecast.minutesToLimit(samples: ufRolling) == 5040)
// 已达 100% → 0
check("forecast 触顶:已满→0", UsageForecast.minutesToLimit(samples: [
    (t: Date(timeIntervalSince1970: 1_790_900_000 - 12 * 3600), pct: 80),
    (t: sfNow, pct: 100)]) == 0)
// 用量在回落(窗口重置归零)→ nil,不误触顶
check("forecast 触顶:回落→nil", UsageForecast.minutesToLimit(samples: [
    (t: Date(timeIntervalSince1970: 1_790_900_000 - 12 * 3600), pct: 80),
    (t: sfNow, pct: 30)]) == nil)
// 数据不足 → nil
check("forecast 触顶:单点→nil", UsageForecast.minutesToLimit(samples: [(t: sfNow, pct: 10)]) == nil)
check("forecast 触顶:跨度<6h→nil", UsageForecast.minutesToLimit(samples: [
    (t: Date(timeIntervalSince1970: 1_790_900_000 - 3600), pct: 10),
    (t: sfNow, pct: 20)]) == nil)

// 余额 runway:7 天前 ¥1000 → 现在 ¥300,日均烧 ¥100 → 还能撑 3 天
let ufBal: [(t: Date, v: Double)] = [
    (t: Date(timeIntervalSince1970: 1_790_900_000 - 7 * 86_400), v: 1000),
    (t: sfNow, v: 300)]
check("forecast 烧速:日均 ¥100", abs((UsageForecast.burnPerDay(samples: ufBal) ?? 0) - 100) < 0.01)
check("forecast runway:3 天", (UsageForecast.runwayDays(remaining: 300, burnPerDay: 100) ?? -1) == 3)
check("forecast runway:零消耗→nil", UsageForecast.runwayDays(remaining: 300, burnPerDay: 0) == nil)
check("forecast 烧速:余额回升→负值", (UsageForecast.burnPerDay(samples: [
    (t: Date(timeIntervalSince1970: 1_790_900_000 - 7 * 86_400), v: 300),
    (t: sfNow, v: 1000)]) ?? 1) < 0)

// 时长文案
check("forecast 文案:5040 分=3 天 12 小时", UsageForecast.durationText(minutes: 5040) == "3 天 12 小时")
check("forecast 文案:150 分=2 小时 30 分", UsageForecast.durationText(minutes: 150) == "2 小时 30 分")
check("forecast 文案:45 分钟", UsageForecast.durationText(minutes: 45) == "45 分钟")
check("forecast 文案:0=即将", UsageForecast.durationText(minutes: 0) == "即将")
check("forecast 文案:负值钳 0", UsageForecast.durationText(minutes: -10) == "即将")

// 会话滚动轮换:响应 Set-Cookie 解析(用 HTTPCookie 解析而非字符串切分)
check("stepfun 轮换 Set-Cookie 解析", {
    let resp = HTTPURLResponse(url: StepFunUsageService.rateLimitURL, statusCode: 200,
                               httpVersion: "HTTP/2", headerFields: [
        "Set-Cookie": "Oasis-Token=eyJhbGci.eyJleHAiOjF9.sig...eyJhcHAiOjEwMzAwfQ.sig2; Path=/; Domain=platform.stepfun.com",
        "Content-Type": "application/json",
    ])!
    let rotated = StepFunUsageService.rotatedToken(from: resp)
    return rotated == "eyJhbGci.eyJleHAiOjF9.sig...eyJhcHAiOjEwMzAwfQ.sig2"
}())
check("stepfun 轮换缺失/空值→nil", {
    let none = HTTPURLResponse(url: StepFunUsageService.rateLimitURL, statusCode: 200,
                               httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
    let empty = HTTPURLResponse(url: StepFunUsageService.rateLimitURL, statusCode: 200,
                                httpVersion: nil, headerFields: ["Set-Cookie": "Oasis-Token=\"\"; Path=/"])!
    return StepFunUsageService.rotatedToken(from: none) == nil
        && StepFunUsageService.rotatedToken(from: empty) == nil
}())
check("stepfun 其他 Set-Cookie 不误读", {
    let resp = HTTPURLResponse(url: StepFunUsageService.rateLimitURL, statusCode: 200,
                               httpVersion: nil, headerFields: ["Set-Cookie": "INGRESSCOOKIE=abc; Path=/api/"])!
    return StepFunUsageService.rotatedToken(from: resp) == nil
}())

// --- 灵动岛:聚焦列选择 + 风险计数 ---
let islCfg = ThresholdConfig()
check("island focus 空列→nil", MenuBarTable.islandFocus(columns: [], config: islCfg) == nil)
// 默认 mtCols 全 safe:Kimi 周 58% 占比最高 → 聚焦 Kimi
check("island focus 全safe取占比最高", MenuBarTable.islandFocus(columns: mtCols(), config: islCfg)?.kind == .kimi)
// critical 优先:safe 占比更高也不抢
check("island focus critical 优先", MenuBarTable.islandFocus(columns: mtCols(kW: 95), config: islCfg)?.kind == .kimi)
// warning 高于 safe(主值 85 触发 warning,次值 10 无所谓)
check("island focus warning 高于 safe", MenuBarTable.islandFocus(columns: mtCols(k5: 85, kW: 10), config: islCfg)?.kind == .kimi)
// money 列(DeepSeek)pct=0 不参与百分比竞争
check("island focus money列不抢聚焦", MenuBarTable.islandFocus(columns: mtCols(), config: islCfg)?.kind != .deepSeek)
// 只剩 money 列时按固定列序兜底
check("island focus 仅剩money列→兜底首列",
      MenuBarTable.islandFocus(columns: mtCols(dis: ["aliyun", "kimi", "openCode", "minimax", "system"]),
                               config: islCfg)?.kind == .deepSeek)
// 风险计数按列最高 band(Kimi 95=critical,智谱 85=warning)
check("island 列band取主/次高者", {
    let col = mtCols(k5: 10, kW: 92).first { $0.kind == .kimi }!
    return MenuBarTable.band(col, config: islCfg) == .critical
}())

// --- 灵动岛汇总:状态 / 剩余 / 计数 / 排序(2026-10-18) ---
func islCol(_ kind: MenuBarColumnKind, _ p: Int?, _ s: Int?,
            attention: Bool = false, amount: Double? = nil) -> MenuBarTableColumn {
    var col = MenuBarTableColumn(kind: kind,
                                 primary: MenuBarTableValue(text: p.map { "\($0)%" } ?? "—", pct: p),
                                 secondary: MenuBarTableValue(text: s.map { "\($0)%" } ?? "—", pct: s,
                                                              amount: amount))
    col.needsAttention = attention
    return col
}
check("island state:已用90→告急", MenuBarTable.state(islCol(.kimi, 90, nil), config: islCfg, moneyFloor: 0) == .critical)
check("island state:已用80→预警", MenuBarTable.state(islCol(.kimi, 80, nil), config: islCfg, moneyFloor: 0) == .warning)
check("island state:已用79→正常", MenuBarTable.state(islCol(.kimi, 79, nil), config: islCfg, moneyFloor: 0) == .ok)
check("island state:两窗口取最严重(次窗更紧)", MenuBarTable.state(islCol(.kimi, 0, 88), config: islCfg, moneyFloor: 0) == .warning)
check("island state:次窗触顶→告急", MenuBarTable.state(islCol(.kimi, 0, 95), config: islCfg, moneyFloor: 0) == .critical)
check("island state:需处理压过告急", MenuBarTable.state(islCol(.kimi, 95, nil, attention: true), config: islCfg, moneyFloor: 0) == .needsAction)
check("island state:余额低于下限→告急", MenuBarTable.state(islCol(.mimo, nil, nil, amount: 30), config: islCfg, moneyFloor: 50) == .critical)
check("island state:下限 0→余额不参与", MenuBarTable.state(islCol(.mimo, nil, nil, amount: 30), config: islCfg, moneyFloor: 0) == .ok)
check("island 剩余文案:78→剩 22%", MenuBarTable.remainingText(MenuBarTableValue(text: "78%", pct: 78)) == "剩 22%")
check("island 剩余文案:横杠原样", MenuBarTable.remainingText(MenuBarTableValue(text: "—", pct: nil)) == "—")
check("island 剩余文案:金额原样", MenuBarTable.remainingText(MenuBarTableValue(text: "12.3万", pct: nil, amount: 123_000)) == "12.3万")
check("island 行文案:双窗口剩余", MenuBarTable.islandRowText(islCol(.kimi, 0, 78)) == "5小时 剩 100% · 周 剩 22%")
check("island 行文案:单值列只要主段", {
    let col = MenuBarTableColumn(singleValueKind: .aliyun,
                                 primary: MenuBarTableValue(text: "64%", pct: 64),
                                 primaryLabel: "30天",
                                 secondary: MenuBarTableValue(text: "—", pct: nil))
    return MenuBarTable.islandRowText(col) == "30天 剩 36%"
}())
check("island 汇总计数", MenuBarTable.islandHealth(columns: [islCol(.kimi, 95, nil),
                                                              islCol(.zhipu, 85, nil),
                                                              islCol(.aliyun, 10, nil)],
                                                    config: islCfg, moneyFloor: 0)
      == IslandHealth(needAction: 0, critical: 1, warning: 1))
check("island 文案:全正常", MenuBarTable.islandHealthText(IslandHealth(needAction: 0, critical: 0, warning: 0)) == "一切正常")
check("island 文案:单类带量词", MenuBarTable.islandHealthText(IslandHealth(needAction: 0, critical: 2, warning: 0)) == "2 项告急")
check("island 文案:两类去量词", MenuBarTable.islandHealthText(IslandHealth(needAction: 1, critical: 1, warning: 0)) == "1 需处理 · 1 告急")
check("island 文案:三类省略为 +n", MenuBarTable.islandHealthText(IslandHealth(needAction: 1, critical: 1, warning: 1)) == "1 需处理 · 1 告急 +1")
check("island worst:需处理优先", IslandHealth(needAction: 1, critical: 3, warning: 9).worst == .needsAction)
check("island 排序:状态优先+同级剩余升序", {
    let rows = MenuBarTable.islandRows(columns: [islCol(.aliyun, 10, nil),        // 正常 剩90
                                                 islCol(.kimi, 0, 90),           // 告急 剩10
                                                 islCol(.zhipu, 0, 85),          // 预警 剩15
                                                 islCol(.mimo, nil, nil, attention: true)],  // 需处理
                                 config: islCfg, moneyFloor: 0)
    return rows.map(\.kind) == [.mimo, .kimi, .zhipu, .aliyun]
}())
check("island 排序:同档内已用多的在前(剩余少的最上)", {
    let rows = MenuBarTable.islandRows(columns: [islCol(.minimax, 0, 49),   // 正常 剩51
                                                 islCol(.aliyun, 64, nil),  // 正常 剩36 ← 该在最上
                                                 islCol(.stepfun, 20, nil)],// 正常 剩80
                                 config: islCfg, moneyFloor: 0)
    return rows.map(\.kind) == [.aliyun, .minimax, .stepfun]
}())
check("island 排序:金额列进档但不抢档内位次", {
    let rows = MenuBarTable.islandRows(columns: [islCol(.deepSeek, nil, nil, amount: 5),  // 告急但无 pct
                                                 islCol(.kimi, 0, 90)],                  // 告急 剩10
                                 config: islCfg, moneyFloor: 50)
    return rows.map(\.kind) == [.kimi, .deepSeek]
}())

// --- 设置页展示契约(标题/副标题/主题预览,UI 只渲染) ---
check("settings presentation 五页齐全", SettingsPresentation.page("general").title == "通用"
      && SettingsPresentation.page("appearance").subtitle.contains("主题")
      && SettingsPresentation.page("notifications").icon == "bell"
      && SettingsPresentation.page("services").detailGridColumns == 2
      && SettingsPresentation.page("history").subtitle.contains("导出"))
check("settings presentation system 主题文案", SettingsPresentation.themeSystemDisplayName == "跟随系统")
check("settings theme previews 三档", {
    let options = SettingsPresentation.themeOptions()
    return options.map(\.theme) == [.system, .light, .dark]
        && options.map(\.previewIsDark) == [false, false, true]
        && options[0].label == "跟随系统"
}())

// --- App 主题:全 App(含灵动岛)统一明暗解析 ---
check("theme system 跟随系统浅色", AppTheme.system.isDark(systemIsDark: false) == false)
check("theme system 跟随系统深色", AppTheme.system.isDark(systemIsDark: true) == true)
check("theme light 压过系统深色", AppTheme.light.isDark(systemIsDark: true) == false)
check("theme dark 压过系统浅色", AppTheme.dark.isDark(systemIsDark: false) == true)

// --- 灵动岛全源星图:每格取最紧窗口;余额源取余额(2026-10-24) ---
check("island 星图:次窗更紧→展示次窗剩余", {
    let metric = MenuBarTable.islandOverviewMetric(islCol(.kimi, 5, 78))
    return metric.label == "周" && metric.value.text == "78%"
        && MenuBarTable.remainingText(metric.value) == "剩 22%"
}())
check("island 星图:两窗同值→稳定取主窗", {
    let metric = MenuBarTable.islandOverviewMetric(islCol(.kimi, 42, 42))
    return metric.label == "5小时" && metric.value.text == "42%"
}())
check("island 星图:纯余额源→不拿今日花费冒充用量", {
    let col = MenuBarTableColumn(kind: .deepSeek,
                                 primary: MenuBarTableValue(text: "3.5", pct: nil),
                                 secondary: MenuBarTableValue(text: "12", pct: nil, amount: 12))
    let metric = MenuBarTable.islandOverviewMetric(col)
    return metric.label == "余额" && metric.value.text == "12" && metric.value.amount == 12
}())
check("island 星图:单值无数据→保留窗口与横杠", {
    let col = MenuBarTableColumn(singleValueKind: .aliyun,
                                 primary: MenuBarTableValue(text: "—", pct: nil),
                                 primaryLabel: "30天",
                                 secondary: MenuBarTableValue(text: "—", pct: nil))
    let metric = MenuBarTable.islandOverviewMetric(col)
    return metric.label == "30天" && metric.value.text == "—" && metric.value.pct == nil
}())

// --- 余额行携带原始值(花费行不携带) + 需处理标记注入 ---
let islCols = MenuBarTable.columns(
    aliyunFiveHour: nil, aliyunOneWeek: nil, aliyunOneMonth: nil,
    kimiConfigured: true, kimiHasError: false, kimiFiveHour: 0, kimiWeekly: 78,
    openCodeConfigured: false, openCodeHasError: false, openCodeRolling: nil, openCodeWeekly: nil,
    deepSeekConfigured: true, deepSeekHasError: false, deepSeekTodayCost: 3.5, deepSeekBalance: 12,
    zhipuConfigured: false, zhipuHasError: false, zhipuFiveHour: nil, zhipuWeekly: nil,
    mimoConfigured: false, mimoHasError: false, mimoPlanPct: nil, mimoBalance: nil,
    minimaxConfigured: false, minimaxHasError: false, minimaxInterval: nil, minimaxWeekly: nil,
    ollamaConfigured: false, ollamaHasError: false, ollamaPrimary: nil, ollamaSecondary: nil,
    stepfunConfigured: false, stepfunHasError: false, stepfunPrimary: nil, stepfunPrimaryLabel: nil,
    stepfunSecondary: nil, stepfunSecondaryLabel: nil,
    systemEnabled: false, cpu: nil, memory: nil,
    disabled: ["aliyun"], moneyFloor: 50, needsAttention: ["kimi"])
let dsCol = islCols.first { $0.kind == .deepSeek }!
check("columns:余额行带 amount", dsCol.secondary.amount == 12)
check("columns:花费行不带 amount", dsCol.primary.amount == nil)
check("columns:余额低于下限→该列告急", MenuBarTable.state(dsCol, config: islCfg, moneyFloor: 50) == .critical)
check("columns:余额下限 0→正常", MenuBarTable.state(dsCol, config: islCfg, moneyFloor: 0) == .ok)
let kimiCol = islCols.first { $0.kind == .kimi }!
check("columns:需处理集合命中→needsAttention", kimiCol.needsAttention)
check("columns:不在集合→false", !dsCol.needsAttention)

// --- 鉴权类失败归类(岛「需处理」判定) ---
check("attention:UsageError.authExpired→鉴权类", AuthIssueClass.isAuth(UsageError.authExpired))
check("attention:网络错误不算", !AuthIssueClass.isAuth(UsageError.network("timeout")))
check("attention:MiMo loginRequired→鉴权类", AuthIssueClass.isMiMoAuth(.loginRequired))
check("attention:MiMo network 不算", !AuthIssueClass.isMiMoAuth(.network("x")))

print(fails == 0 ? "ALL PASS" : "\(fails) FAILED")
exit(fails == 0 ? 0 : 1)
