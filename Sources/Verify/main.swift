import Foundation
import Darwin
import AliyunTokenBarCore

var fails = 0
func check(_ name: String, _ cond: Bool) {
    if cond { print("PASS \(name)") } else { print("FAIL \(name)"); fails += 1 }
}

// --- Task 2: Models ---
let d1 = UsageDetail(percentageRaw: 0.349956963, resetTimeMs: 1785560220000)
check("pct 0.3499->35", d1.percentage == 35)
check("resetTimeMs stored", d1.resetTimeMs == 1785560220000)

check("pct clamp at 100", UsageDetail(percentageRaw: 1.5, resetTimeMs: 0).percentage == 100)
check("pct negative -> 0", UsageDetail(percentageRaw: -0.1, resetTimeMs: 0).percentage == 0)

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
let usageFixture = #"{"code":"200","data":{"DataV2":{"ret":["SUCCESS::接口调用成功"],"data":{"msg":"Success.","code":"SUCCESS","data":{"per5HourPercentage":0.349956963,"per1WeekResetTime":1785687360000,"per5HourResetTime":1785560220000,"per1WeekPercentage":0.61428294255},"requestId":"x","success":true}},"success":true,"httpStatus":200,"errorCode":"","api":"x","errorMsg":""},"httpStatusCode":"200","requestId":"x","successResponse":true}"#
let subscriptionFixture = #"{"code":"200","data":{"DataV2":{"ret":["SUCCESS::接口调用成功"],"data":{"msg":"Success.","code":"SUCCESS","data":{"instanceCode":"sfm_x","specCode":"pro","remainingDays":291,"startTime":1784451307000,"endTime":1810742400000,"autoRenewFlag":false,"status":"VALID"},"requestId":"x","success":true}},"success":true,"httpStatus":200,"errorCode":"","api":"x","errorMsg":""},"httpStatusCode":"200","requestId":"x","successResponse":true}"#
let addonFixture = #"{"code":"200","data":{"DataV2":{"ret":["SUCCESS::接口调用成功"],"data":{"msg":"Success.","code":"SUCCESS","data":{"remainingCredits":0.0,"activeCount":0,"totalCredits":0.0},"requestId":"x","success":true}},"success":true,"httpStatus":200,"errorCode":"","api":"x","errorMsg":""},"httpStatusCode":"200","requestId":"x","successResponse":true}"#
let expiredFixture = #"{"error":{"code":3,"message":"Console session is not logged in or has expired.","hint":"Run `bl auth login --console` to sign in or refresh your console session."}}"#

let u = try? BlUsageService.parseUsage(Data(usageFixture.utf8))
check("usage 5h pct 35", u?.fiveHour.percentage == 35)
check("usage 5h reset", u?.fiveHour.resetTimeMs == 1785560220000)
check("usage 7d pct 61", u?.oneWeek.percentage == 61)
check("usage 7d reset", u?.oneWeek.resetTimeMs == 1785687360000)

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

print(fails == 0 ? "ALL PASS" : "\(fails) FAILED")
exit(fails == 0 ? 0 : 1)
