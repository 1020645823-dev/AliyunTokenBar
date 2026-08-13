import XCTest
@testable import AliyunTokenBarCore

// P2-A2:XCTest 双轨薄封装(CI 运行;本地开发用 swift run Verify)。
// 覆盖 Core 纯函数的关键路径,断言与 Verify fixture 同一数据契约。
final class CoreSmokeTests: XCTestCase {
    func testUsageParsing() throws {
        let fixture = #"{"code":"200","data":{"DataV2":{"ret":["SUCCESS::接口调用成功"],"data":{"msg":"Success.","code":"SUCCESS","data":{"per5HourPercentage":0.349956963,"per1WeekResetTime":1785687360000,"per5HourResetTime":1785560220000,"per1WeekPercentage":0.61428294255},"requestId":"x","success":true}},"success":true,"httpStatus":200,"errorCode":"","api":"x","errorMsg":""},"httpStatusCode":"200","requestId":"x","successResponse":true}"#
        let usage = try BlUsageService.parseUsage(Data(fixture.utf8))
        XCTAssertEqual(usage.fiveHour.percentage, 35.0)
        XCTAssertEqual(usage.oneWeek.percentage, 61.43)
    }

    func testThresholdBand() {
        let config = ThresholdConfig(warning: 80, critical: 90)
        XCTAssertEqual(config.band(for: 30), .safe)
        XCTAssertEqual(config.band(for: 80), .warning)
        XCTAssertEqual(config.band(for: 90), .critical)
    }

    func testNotificationHysteresis() {
        let config = ThresholdConfig(warning: 80, critical: 90)
        var state = NotificationState()
        XCTAssertNotNil(state.update(percentage: 30, config: config))   // 首见
        XCTAssertNil(state.update(percentage: 60, config: config))      // 同级
        XCTAssertEqual(state.update(percentage: 85, config: config), .warning)
        XCTAssertNil(state.update(percentage: 50, config: config))      // 回落不打扰
    }

    func testNotificationTrackerSilentSeed() {
        let config = ThresholdConfig(warning: 80, critical: 90)
        var tracker = NotificationTracker()
        XCTAssertTrue(tracker.evaluate([(WatchKey(provider: "aliyun", window: "5h"), 95)], config: config).isEmpty)
        XCTAssertTrue(tracker.evaluate([(WatchKey(provider: "aliyun", window: "5h"), 97)], config: config).isEmpty)
    }

    func testSelfUpdaterVersionCompare() {
        XCTAssertTrue(SelfUpdater.isNewer("1.0.28", than: "1.0.27"))
        XCTAssertFalse(SelfUpdater.isNewer("1.0.26", than: "1.0.27"))
    }

    func testProcessRunner() {
        let result = ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sh"),
                                       arguments: ["-c", "echo hello"], timeout: 5)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
        let slow = ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sh"),
                                     arguments: ["-c", "sleep 5"], timeout: 0.5)
        XCTAssertTrue(slow.timedOut)
    }

    func testHistoryCSV() {
        let snap = UsageSnapshot(timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                                 aliyunFiveHour: 11, aliyunOneWeek: 22,
                                 opencodeRolling: nil, opencodeWeekly: nil, opencodeMonthly: nil)
        let csv = HistoryStore.csv([snap])
        XCTAssertTrue(csv.hasPrefix("timestamp,aliyun5h"))
        XCTAssertEqual(csv.split(separator: "\n").count, 2)
    }
}
