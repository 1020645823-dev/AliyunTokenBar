# AliyunTokenBar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a native SwiftUI macOS menu-bar app that shows Aliyun Bailian Token Plan subscription usage (5-hour / 7-day limits), mirroring KimiCodeBar's form factor, sourcing data via `bl console call`.

**Architecture:** SwiftUI `MenuBarExtra(.window)` app built with Swift Package Manager (no .xcodeproj). Data layer shells out to the `bl` CLI (3 console RPCs) and parses 3-layer-nested JSON. Auth reuses `bl`'s console login state; the app detects expiry and guides re-login. State managed by a `@MainActor ObservableObject` with 10-min timer + manual refresh.

**Tech Stack:** Swift 5.9+, SwiftUI, AppKit, Swift Package Manager, macOS 13+ deployment target (for `SMAppService` and `MenuBarExtra`). No external dependencies.

**Reference:** Design spec at `docs/superpowers/specs/2026-08-01-aliyun-token-bar-design.md`. KimiCodeBar source patterns reused (color tokens, `MenuBarTextRenderer`, `UsageCard` layout).

> **⚠️ IMPLEMENTATION NOTE (applies to ALL tasks — supersedes older XCTest references in the plan body):** This machine has **no full Xcode**, so XCTest is unavailable. The package has THREE targets: `AliyunTokenBarCore` (library — all logic/models/parsing/auth/state), `AliyunTokenBar` (executable — `@main` SwiftUI App + UI views), and `Verify` (executable — pure Swift assertions, run via `swift run Verify`). Rules: (1) All logic code goes in `Sources/AliyunTokenBarCore/*.swift` (NOT `Sources/AliyunTokenBar/`) and types/funcs must be `public`. (2) Tests are assertions appended to `Sources/Verify/main.swift` using the `check(name, cond)` helper — never XCTest. (3) Run tests with `swift run Verify` (exit 0 = pass), never `swift test`. Wherever the plan body says `Sources/AliyunTokenBar/<Logic>.swift` or `swift test`, apply this note instead.

**Build/run:** `swift build` then `swift run AliyunTokenBar` (or `.build/debug/AliyunTokenBar`). No Xcode required.

---

## File Structure

```
AliyuntokenCal/
├── Package.swift                          # SPM manifest
├── Sources/
│   └── AliyunTokenBar/
│       ├── App.swift                      # @main entry, MenuBarExtra, color tokens, icon renderer
│       ├── Models.swift                   # TokenPlanQuota, UsageDetail, SubscriptionDetail, AddonSummary, AuthState
│       ├── BlUsageService.swift           # Process-based bl caller + JSON parser (unit-testable)
│       ├── TokenPlanModel.swift           # @MainActor ObservableObject state, refresh logic, timer
│       ├── BlAuthManager.swift            # detect bl install + console login state
│       ├── Menu.swift                     # TokenPlanMenu (dropdown panel), UsageCard, AuthOverlay
│       └── Settings.swift                 # SettingsWindow, refresh interval, launch-at-login
├── Tests/
│   └── AliyunTokenBarTests/
│       ├── BlUsageServiceTests.swift      # JSON parsing from captured fixtures
│       └── AuthManagerTests.swift         # bl status parsing
└── docs/...                               # spec + this plan
```

**Responsibility per file:**
- `App.swift` — app bootstrap, theming, menu-bar icon rendering (pure UI, no logic)
- `Models.swift` — plain data structs (no dependencies, fully unit-testable via parsing)
- `BlUsageService.swift` — the ONE file that knows the RPC contract + JSON shape; the riskiest code, heavily tested
- `TokenPlanModel.swift` — orchestration: calls service, holds state, timer
- `BlAuthManager.swift` — preflight checks (is bl installed? logged in?)
- `Menu.swift` — all SwiftUI views for the dropdown
- `Settings.swift` — settings UI + launch-at-login

---

## Task 1: SPM project scaffold + buildable empty MenuBarExtra

**Files:**
- Create: `Package.swift`
- Create: `Sources/AliyunTokenBar/App.swift`

- [ ] **Step 1: Create Package.swift**

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AliyunTokenBar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "AliyunTokenBar",
            path: "Sources/AliyunTokenBar"
        ),
        .testTarget(
            name: "AliyunTokenBarTests",
            dependencies: ["AliyunTokenBar"],
            path: "Tests/AliyunTokenBarTests"
        ),
    ]
)
```

- [ ] **Step 2: Create minimal App.swift**

```swift
import SwiftUI

@main
struct AliyunTokenBarApp: App {
    var body: some Scene {
        MenuBarExtra("AliyunTokenBar", systemImage: "speedometer") {
            Text("AliyunTokenBar")
                .padding()
        }
        .menuBarExtraStyle(.window)
    }
}
```

- [ ] **Step 3: Build and verify**

Run: `swift build`
Expected: `Build complete!` (no errors)

- [ ] **Step 4: Run to verify menu-bar icon appears**

Run: `swift run AliyunTokenBar &` then wait 3s, then `kill %1`
Expected: A speedometer icon appears in the menu bar; clicking shows "AliyunTokenBar" text. (Manual visual check — this is the first sign of life.)

- [ ] **Step 5: Init git and commit**

```bash
cd /Users/weiwei.g.zhang/Documents/worker_space/AliyuntokenCal
git init
echo -e ".build/\n.swiftpm/\nPackages/\n*.xcodeproj\nDerivedData/\n.DS_Store" > .gitignore
git add Package.swift Sources/ .gitignore
git commit -m "chore: scaffold SPM MenuBarExtra app"
```

---

## Task 2: Data models

> **Testing note (env constraint):** This machine has no full Xcode → XCTest unavailable. Tests use the `Verify` executable target (pure Swift assertions in `Sources/Verify/main.swift`, `swift run Verify`, exit code = pass/fail). All logic now lives in `AliyunTokenBarCore` (library); types must be `public` so Verify and the App target can use them.

**Files:**
- Create: `Sources/AliyunTokenBarCore/Models.swift`
- Modify: `Sources/Verify/main.swift` (replace placeholder with assertions)

- [ ] **Step 1: Write failing assertions in Verify/main.swift**

Replace the entire contents of `Sources/Verify/main.swift` with:

```swift
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

print(fails == 0 ? "ALL PASS" : "\(fails) FAILED")
exit(fails == 0 ? 0 : 1)
```

- [ ] **Step 2: Run Verify to verify it fails**

Run: `swift run Verify`
Expected: FAIL to compile — `cannot find type 'UsageDetail' in scope` (Core has only Placeholder.swift).

- [ ] **Step 3: Implement Models.swift at `Sources/AliyunTokenBarCore/Models.swift`**

```swift
import Foundation

public struct UsageDetail: Equatable {
    public let percentageRaw: Double
    public let resetTimeMs: Int64

    public init(percentageRaw: Double, resetTimeMs: Int64) {
        self.percentageRaw = percentageRaw
        self.resetTimeMs = resetTimeMs
    }

    /// 0–100 整数百分比(从 0.x 浮点四舍五入,钳制到 0...100)
    public var percentage: Int {
        let pct = Int((percentageRaw * 100).rounded())
        return min(max(pct, 0), 100)
    }

    /// "X小时Y分钟后重置" / "X天后重置" / "即将重置" / "未知"
    public var timeUntilReset: String {
        guard resetTimeMs > 0 else { return "未知" }
        let reset = Date(timeIntervalSince1970: TimeInterval(resetTimeMs) / 1000)
        let now = Date()
        if reset <= now { return "即将重置" }
        let comps = Calendar.current.dateComponents([.day, .hour, .minute], from: now, to: reset)
        if let day = comps.day, day > 0 {
            return "\(day)天\(comps.hour ?? 0)小时后重置"
        }
        if let hour = comps.hour, hour > 0 {
            return "\(hour)小时\(comps.minute ?? 0)分钟后重置"
        }
        if let minute = comps.minute, minute > 0 {
            return "\(minute)分钟后重置"
        }
        return "即将重置"
    }
}

public struct SubscriptionDetail: Equatable {
    public let specCode: String
    public let status: String
    public let remainingDays: Int
    public let startTimeMs: Int64?
    public let endTimeMs: Int64?
    public let autoRenewFlag: Bool

    public init(specCode: String, status: String, remainingDays: Int,
                startTimeMs: Int64?, endTimeMs: Int64?, autoRenewFlag: Bool) {
        self.specCode = specCode; self.status = status; self.remainingDays = remainingDays
        self.startTimeMs = startTimeMs; self.endTimeMs = endTimeMs; self.autoRenewFlag = autoRenewFlag
    }

    public var specDisplay: String { specCode.capitalized }
    public var statusDisplay: String { status == "VALID" ? "生效中" : status }
}

public struct AddonSummary: Equatable {
    public let remainingCredits: Double
    public let totalCredits: Double
    public let activeCount: Int
    public init(remainingCredits: Double, totalCredits: Double, activeCount: Int) {
        self.remainingCredits = remainingCredits; self.totalCredits = totalCredits; self.activeCount = activeCount
    }
}

public struct TokenPlanQuota: Equatable {
    public let fiveHour: UsageDetail
    public let oneWeek: UsageDetail
    public let subscription: SubscriptionDetail?
    public let addon: AddonSummary?
    public init(fiveHour: UsageDetail, oneWeek: UsageDetail,
                subscription: SubscriptionDetail?, addon: AddonSummary?) {
        self.fiveHour = fiveHour; self.oneWeek = oneWeek
        self.subscription = subscription; self.addon = addon
    }
}

public enum AuthState: Equatable {
    case unknown
    case ok
    case blNotInstalled
    case notLoggedIn      // bl 装了,但控制台未登录
    case expired          // 登录过但 token 失效
}

public enum UsageError: Error, Equatable {
    case authExpired
    case network(String)
    case parse
    case unknown(String)
}
```

- [ ] **Step 4: Run Verify to confirm it passes**

Run: `swift run Verify`
Expected: `ALL PASS` (8 checks), exit code 0.

- [ ] **Step 5: Commit**

```bash
git add Sources/AliyunTokenBarCore/Models.swift Sources/Verify/main.swift
git commit -m "feat: add data models for quota/subscription/addon"
```

---

## Task 3: bl usage service — JSON parsing (the risky code)

This is the contract-sensitive code. The JSON shape was captured from the live API on 2026-08-01. Capture fixture strings as test data so parsing is locked. (Verify-mode, not XCTest — see Task 2 testing note.)

**Files:**
- Create: `Sources/AliyunTokenBarCore/BlUsageService.swift`
- Modify: `Sources/Verify/main.swift` (append fixture assertions)

- [ ] **Step 1: Add failing fixture assertions to Verify/main.swift**

Append these assertions BEFORE the final `print(fails...)` / `exit(...)` lines in `Sources/Verify/main.swift`:

```swift
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
```

- [ ] **Step 2: Run Verify to verify it fails**

Run: `swift run Verify`
Expected: FAIL to compile — `cannot find 'BlUsageService' in scope`.

- [ ] **Step 3: Implement BlUsageService.swift at `Sources/AliyunTokenBarCore/BlUsageService.swift`**

```swift
import Foundation

/// 数据层:shell out 调 bl console call,解析三层嵌套 JSON。
/// 唯一掌握 RPC 契约的文件,改动需配合同步更新 Verify fixture。
public final class BlUsageService {
    // 三个控制台私有 RPC(2026-08-01 Playwright 抓包 + bl 验证)
    public static let usageAPI = "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage"
    public static let subscriptionAPI = "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/subscription"
    public static let addonAPI = "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/addon/summary"

    // MARK: - Parsing (pure functions, fully tested)

    /// 解析 usage 响应。JSON 三层嵌套:data.DataV2.data.data.<字段>
    public static func parseUsage(_ data: Data) throws -> UsageWindows {
        let p = try extractInnerPayload(data)
        return UsageWindows(
            fiveHour: UsageDetail(
                percentageRaw: try p.value("per5HourPercentage", as: Double.self),
                resetTimeMs: try p.value("per5HourResetTime", as: Int64.self)
            ),
            oneWeek: UsageDetail(
                percentageRaw: try p.value("per1WeekPercentage", as: Double.self),
                resetTimeMs: try p.value("per1WeekResetTime", as: Int64.self)
            )
        )
    }

    public static func parseSubscription(_ data: Data) throws -> SubscriptionDetail {
        let p = try extractInnerPayload(data)
        return SubscriptionDetail(
            specCode: try p.value("specCode", as: String.self),
            status: try p.value("status", as: String.self),
            remainingDays: try p.value("remainingDays", as: Int.self),
            startTimeMs: try? p.value("startTime", as: Int64.self),
            endTimeMs: try? p.value("endTime", as: Int64.self),
            autoRenewFlag: (try? p.value("autoRenewFlag", as: Bool.self)) ?? false
        )
    }

    public static func parseAddon(_ data: Data) throws -> AddonSummary {
        let p = try extractInnerPayload(data)
        return AddonSummary(
            remainingCredits: (try? p.value("remainingCredits", as: Double.self)) ?? 0,
            totalCredits: (try? p.value("totalCredits", as: Double.self)) ?? 0,
            activeCount: (try? p.value("activeCount", as: Int.self)) ?? 0
        )
    }

    /// 从 bl 的输出判断是否 token 过期(返回 .authExpired)或其他错误。
    public static func classifyError(_ data: Data, httpOk: Bool) -> UsageError {
        if let s = String(data: data, encoding: .utf8),
           s.contains("not logged in") || s.contains("has expired") {
            return .authExpired
        }
        return .network(String(data: data, encoding: .utf8) ?? "unknown error")
    }

    /// 抽取三层嵌套的最内层 data: data.DataV2.data.data
    private static func extractInnerPayload(_ data: Data) throws -> [String: Any] {
        struct ParseErr: Error {}
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d1 = root["data"] as? [String: Any],
              let d2 = d1["DataV2"] as? [String: Any],
              let d3 = d2["data"] as? [String: Any],
              let inner = d3["data"] as? [String: Any] else {
            throw ParseErr()
        }
        return inner
    }
}

// MARK: - [String:Any] 类型安全取值辅助
private extension Dictionary where Key == String, Value == Any {
    func value<T>(_ key: String, as type: T.Type) throws -> T {
        struct Mismatch: Error {}
        guard let v = self[key] as? T else { throw Mismatch() }
        return v
    }
}
```

> **Note:** This task folds in the Task 5 fix (parseUsage returns `UsageWindows` with both 5h/7d) directly, since the parser is being written fresh. The `UsageWindows` struct must be added to Models.swift (Task 2's Models.swift). Add it if not present:
> ```swift
> public struct UsageWindows: Equatable {
>     public let fiveHour: UsageDetail
>     public let oneWeek: UsageDetail
>     public init(fiveHour: UsageDetail, oneWeek: UsageDetail) { self.fiveHour = fiveHour; self.oneWeek = oneWeek }
> }
> ```
> And update `TokenPlanQuota` to use `UsageWindows` instead of separate fiveHour/oneWeek fields (see Task 5).

- [ ] **Step 4: Run Verify to confirm it passes**

Run: `swift run Verify`
Expected: `ALL PASS` (prior checks + the 13 new Task 3 checks), exit code 0.

- [ ] **Step 5: Commit**

```bash
git add Sources/AliyunTokenBarCore/BlUsageService.swift Sources/Verify/main.swift
git commit -m "feat: add bl usage service with JSON parsing + fixtures"
```

---

## Task 4: bl usage service — Process execution

Add the live `Process` execution that shells out to `bl console call`. Keep it separate from parsing so tests stay hermetic.

**Files:**
- Modify: `Sources/AliyunTokenBar/BlUsageService.swift` (add execution methods)
- Test: `Tests/AliyunTokenBarTests/BlUsageServiceTests.swift` (add a smoke test gated on env)

- [ ] **Step 1: Add execution methods to BlUsageService**

Append to `BlUsageService` (after the parsing section):

```swift
    // MARK: - Execution (shell out to bl)

    /// 调一个 RPC,返回 stdout 的 Data。失败时抛 UsageError(authExpired/network/unknown)。
    static func callRPC(_ api: String) async throws -> Data {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["NO_COLOR=1", "bl", "console", "call",
                          "--api", api, "--data", "{}", "--output", "json"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        proc.environment = ProcessInfo.processInfo.environment

        do {
            try proc.run()
        } catch {
            throw UsageError.unknown("bl 启动失败: \(error.localizedDescription)")
        }

        // 收集全部输出(等待进程结束)
        let outData = try pipe.fileHandleForReading.readToEnd() ?? Data()
        proc.waitUntilExit()

        // 先按文本判断 token 过期(bl 对 auth 错误仍可能 exit 0 返回 JSON error)
        let text = String(data: outData, encoding: .utf8) ?? ""
        if text.contains("not logged in") || text.contains("has expired") {
            throw UsageError.authExpired
        }
        if proc.terminationStatus != 0 {
            throw UsageError.network(text.isEmpty ? "bl exit \(proc.terminationStatus)" : text)
        }
        return outData
    }

    /// 一次拉取完整套餐数据(3 个 RPC 并发)。
    static func fetchQuota() async -> Result<TokenPlanQuota, UsageError> {
        async let usageRes = try? callRPC(usageAPI).flatMap { try parseUsage($0) }
        async let subRes = try? callRPC(subscriptionAPI).flatMap { try parseSubscription($0) }
        async let addonRes = try? callRPC(addonAPI).flatMap { try parseAddon($0) }

        let usage = await usageRes
        let sub = await subRes
        let addon = await addonRes

        // usage 是必须项;其他缺失则置 nil(容错)
        guard let fiveHour = try? usage else {
            // 重新触发以捕获精确错误类型
            do { _ = try await callRPC(usageAPI) }
            catch let e as UsageError { return .failure(e) }
            catch { return .failure(.unknown(error.localizedDescription)) }
            // 不可达:return .failure(.parse)
        }
        // usage 响应里同时含 5h 和 7d 字段,需分别取(见下)
        return .success(TokenPlanQuota(fiveHour: fiveHour, oneWeek: fiveHour,
                                        subscription: sub, addon: addon))
    }
```

> **NOTE for implementer:** The `fetchQuota` above has a known bug — `parseUsage` only reads the 5-hour fields, but the same RPC returns BOTH 5h and 7d. Task 5 fixes `parseUsage` to return both windows. Do not "fix" it here; the intermediate state is intentional to keep tasks bite-sized. Carry the note into Task 5.

- [ ] **Step 2: Add a live smoke test (skipped unless BL_LIVE=1)**

Append to `BlUsageServiceTests`:

```swift
    func testLiveCallUsageRPC() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BL_LIVE"] == "1",
                          "set BL_LIVE=1 to run live bl call")
        let data = try await BlUsageService.callRPC(BlUsageService.usageAPI)
        let d = try BlUsageService.parseUsage(data)
        XCTAssertGreaterThanOrEqual(d.percentage, 0)
    }
```

- [ ] **Step 3: Build to verify it compiles**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 4: Run unit tests (skip live)**

Run: `swift test --filter BlUsageServiceTests`
Expected: PASS (5 prior + 1 skipped live)

- [ ] **Step 5: Commit**

```bash
git add Sources/AliyunTokenBar/BlUsageService.swift Tests/AliyunTokenBarTests/BlUsageServiceTests.swift
git commit -m "feat: add Process-based bl console call execution"
```

---

## Task 5: Fix usage parsing to return both 5h and 7d windows

The usage RPC returns both windows in one response. Update the model + parser so `fetchQuota` returns correct 5h/7d.

**Files:**
- Modify: `Sources/AliyunTokenBar/Models.swift`
- Modify: `Sources/AliyunTokenBar/BlUsageService.swift`
- Modify: `Tests/AliyunTokenBarTests/BlUsageServiceTests.swift`

- [ ] **Step 1: Add a combined-usage type and update test expectation**

In `Models.swift`, add after `UsageDetail`:

```swift
/// usage RPC 一次返回 5小时 + 7天两个窗口
struct UsageWindows: Equatable {
    let fiveHour: UsageDetail
    let oneWeek: UsageDetail
}
```

Update `TokenPlanQuota` to use it:

```swift
struct TokenPlanQuota: Equatable {
    let usage: UsageWindows
    let subscription: SubscriptionDetail?
    let addon: AddonSummary?
}
```

- [ ] **Step 2: Update parseUsage to return UsageWindows**

In `BlUsageService.swift`, replace the `parseUsage` signature/body:

```swift
    static func parseUsage(_ data: Data) throws -> UsageWindows {
        let p = try extractInnerPayload(data)
        return UsageWindows(
            fiveHour: UsageDetail(
                percentageRaw: try p.value("per5HourPercentage", as: Double.self),
                resetTimeMs: try p.value("per5HourResetTime", as: Int64.self)
            ),
            oneWeek: UsageDetail(
                percentageRaw: try p.value("per1WeekPercentage", as: Double.self),
                resetTimeMs: try p.value("per1WeekResetTime", as: Int64.self)
            )
        )
    }
```

Update `fetchQuota` to use it:

```swift
    static func fetchQuota() async -> Result<TokenPlanQuota, UsageError> {
        async let usageRes = try? callRPC(usageAPI).flatMap { try parseUsage($0) }
        async let subRes = try? callRPC(subscriptionAPI).flatMap { try parseSubscription($0) }
        async let addonRes = try? callRPC(addonAPI).flatMap { try parseAddon($0) }

        guard let usage = await usageRes else {
            do { _ = try await callRPC(usageAPI) }
            catch let e as UsageError { return .failure(e) }
            catch { return .failure(.unknown(error.localizedDescription)) }
        }
        return .success(TokenPlanQuota(
            usage: usage,
            subscription: await subRes,
            addon: await addonRes
        ))
    }
```

- [ ] **Step 3: Update the test to expect UsageWindows**

In `BlUsageServiceTests.testParseUsage`, replace body:

```swift
    func testParseUsage() throws {
        let w = try BlUsageService.parseUsage(Data(usageFixture.utf8))
        XCTAssertEqual(w.fiveHour.percentage, 35)
        XCTAssertEqual(w.fiveHour.resetTimeMs, 1785560220000)
        XCTAssertEqual(w.oneWeek.percentage, 61)       // 0.6142... → 61
        XCTAssertEqual(w.oneWeek.resetTimeMs, 1785687360000)
    }
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter BlUsageServiceTests`
Expected: PASS (testParseUsage updated; others unchanged)

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "fix: parse both 5h/7d usage windows from single RPC"
```

---

## Task 6: Auth manager — detect bl install + console login

**Files:**
- Create: `Sources/AliyunTokenBar/BlAuthManager.swift`
- Test: `Tests/AliyunTokenBarTests/AuthManagerTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import AliyunTokenBar

final class AuthManagerTests: XCTestCase {
    // `bl auth status --output json` 的真实结构(captured)
    func testParseAuthStatus_loggedIn() throws {
        let json = #"{"authenticated":true,"config":"token-plan","console":{"source":"config","masked":"b2cb...24ef","region":"cn-beijing","site":"domestic"}}"#
        let state = BlAuthManager.parseAuthStatus(Data(json.utf8))
        XCTAssertEqual(state, .ok)
    }

    func testParseAuthStatus_notLoggedIn() {
        // console 字段缺失或 source 不是 config
        let json = #"{"authenticated":true,"console":{"source":"env","masked":""}}"#
        let state = BlAuthManager.parseAuthStatus(Data(json.utf8))
        XCTAssertEqual(state, .notLoggedIn)
    }

    func testParseAuthStatus_noConsoleField() {
        let json = #"{"authenticated":true}"#
        let state = BlAuthManager.parseAuthStatus(Data(json.utf8))
        XCTAssertEqual(state, .notLoggedIn)
    }
}
```

- [ ] **Step 2: Run to verify fail**

Run: `swift test --filter AuthManagerTests`
Expected: FAIL — `cannot find 'BlAuthManager' in scope`

- [ ] **Step 3: Implement BlAuthManager.swift**

```swift
import Foundation

/// 环境与鉴权检测:bl 是否安装、控制台是否已登录。
final class BlAuthManager {
    /// 检测 bl 是否在 PATH 中。
    static func isBlInstalled() -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["which", "bl"]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do { try proc.run(); proc.waitUntilExit() }
        catch { return false }
        return proc.terminationStatus == 0
    }

    /// 解析 `bl auth status --output json` 判断控制台登录态。
    /// 只看结构(console.source == "config" 且有 masked token)→ .ok;否则 .notLoggedIn。
    static func parseAuthStatus(_ data: Data) -> AuthState {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let console = root["console"] as? [String: Any],
              let source = console["source"] as? String,
              source == "config",
              let masked = console["masked"] as? String,
              !masked.isEmpty else {
            return .notLoggedIn
        }
        return .ok
    }

    /// 综合:bl 未装 → .blNotInstalled;装了但解析不出 console → .notLoggedIn;否则 .ok。
    /// 注意:.ok 只表示配置存在,**实际是否过期要靠调用 RPC 才知道**。
    static func currentAuthState() async -> AuthState {
        guard isBlInstalled() else { return .blNotInstalled }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["NO_COLOR=1", "bl", "auth", "status", "--output", "json"]
        let pipe = Pipe(); proc.standardOutput = pipe; proc.standardError = pipe
        proc.environment = ProcessInfo.processInfo.environment
        do { try proc.run() } catch { return .notLoggedIn }
        let out = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        proc.waitUntilExit()
        return parseAuthStatus(out)
    }

    /// 拉起浏览器控制台登录:`bl auth login --console --console-site domestic`
    static func relogin() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["bl", "auth", "login", "--console", "--console-site", "domestic"]
        proc.environment = ProcessInfo.processInfo.environment
        try? proc.run()
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter AuthManagerTests`
Expected: PASS (3 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/AliyunTokenBar/BlAuthManager.swift Tests/AliyunTokenBarTests/AuthManagerTests.swift
git commit -m "feat: add bl auth state detection"
```

---

## Task 7: TokenPlanModel — state + refresh orchestration

**Files:**
- Create: `Sources/AliyunTokenBar/TokenPlanModel.swift`

- [ ] **Step 1: Implement the model (no separate unit test — it's thin orchestration over tested services; verified via build + manual run in Task 10)**

```swift
import Foundation
import SwiftUI
import Combine

@MainActor
final class TokenPlanModel: ObservableObject {
    static let shared = TokenPlanModel()

    @Published var quota: TokenPlanQuota?
    @Published var isLoading = false
    @Published var authState: AuthState = .unknown
    @Published var lastError: String?
    @Published var lastUpdated: Date?

    /// 刷新间隔(分钟),用户可在设置改;默认 10
    @Published var refreshIntervalMinutes: Int = 10 {
        didSet { UserDefaults.standard.set(refreshIntervalMinutes, forKey: "refreshIntervalMinutes"); resetTimer() }
    }

    private var timer: AnyCancellable?

    private init() {
        refreshIntervalMinutes = UserDefaults.standard.object(forKey: "refreshIntervalMinutes") as? Int ?? 10
    }

    /// 启动定时刷新
    func startTimer() {
        resetTimer()
        Task { await checkAuthAndRefresh() }
    }

    private func resetTimer() {
        timer?.cancel()
        timer = Timer.publish(every: TimeInterval(refreshIntervalMinutes * 60), on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task { await self?.refresh() }
            }
    }

    /// 先查环境,环境 OK 再拉数据
    func checkAuthAndRefresh() async {
        authState = await BlAuthManager.currentAuthState()
        guard authState == .ok else { return }
        await refresh()
    }

    /// 拉一次数据。失败时:auth 错误 → 置 .expired;其他 → 保留旧数据 + 记录错误。
    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        let result = await BlUsageService.fetchQuota()
        switch result {
        case .success(let q):
            quota = q
            lastUpdated = Date()
            lastError = nil
        case .failure(let e):
            if e == .authExpired { authState = .expired }
            lastError = errorMessage(e)
        }
    }

    private func errorMessage(_ e: UsageError) -> String {
        switch e {
        case .authExpired: return "控制台登录已过期"
        case .network(let s): return "网络错误: \(s)"
        case .parse: return "数据解析失败"
        case .unknown(let s): return s
        }
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/AliyunTokenBar/TokenPlanModel.swift
git commit -m "feat: add TokenPlanModel state + refresh orchestration"
```

---

## Task 8: Color tokens + menu-bar icon renderer

**Files:**
- Modify: `Sources/AliyunTokenBar/App.swift` (replace minimal content)

- [ ] **Step 1: Replace App.swift with full version (color tokens + icon renderer + theming)**

```swift
import SwiftUI
import AppKit

// MARK: - 配色 token(复刻 KimiCodeBar 动态色)

private func dynamicColor(light: NSColor, dark: NSColor) -> Color {
    Color(NSColor(name: nil, dynamicProvider: { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark ? dark : light
    }))
}

extension ShapeStyle where Self == Color {
    static var atbPanelBackground: Color {
        dynamicColor(
            light: NSColor(red: 0.91, green: 0.91, blue: 0.93, alpha: 1.0),
            dark: NSColor(red: 0.06, green: 0.08, blue: 0.13, alpha: 1.0)
        )
    }
    static var atbCardBackground: Color {
        dynamicColor(
            light: NSColor(white: 0.99, alpha: 1.0),
            dark: NSColor(red: 0.11, green: 0.14, blue: 0.21, alpha: 1.0)
        )
    }
    static var atbBlue: Color { Color(red: 0.23, green: 0.51, blue: 0.96) }
    static var atbTextPrimary: Color {
        dynamicColor(light: NSColor(white: 0.12, alpha: 1.0), dark: NSColor(white: 1.0, alpha: 1.0))
    }
    static var atbTextSecondary: Color {
        dynamicColor(light: NSColor(white: 0.35, alpha: 1.0), dark: NSColor(white: 1.0, alpha: 0.55))
    }
    static var atbTextTertiary: Color {
        dynamicColor(light: NSColor(white: 0.50, alpha: 1.0), dark: NSColor(white: 1.0, alpha: 0.40))
    }
}

// MARK: - 菜单栏图标渲染

enum MenuBarTextRenderer {
    /// 渲染 "5h/7d" 双行百分比(模板图,系统按明暗自动染色)。
    static func image(fiveHour: Int, oneWeek: Int) -> NSImage {
        let content = VStack(alignment: .trailing, spacing: -1) {
            HStack(spacing: 2) {
                Text("5h").font(.system(size: 10, weight: .medium)).monospacedDigit().frame(width: 16, alignment: .leading)
                Text("\(fiveHour)%").font(.system(size: 10, weight: .medium)).monospacedDigit().frame(width: 30, alignment: .trailing)
            }
            HStack(spacing: 2) {
                Text("7d").font(.system(size: 10, weight: .medium)).monospacedDigit().frame(width: 16, alignment: .leading)
                Text("\(oneWeek)%").font(.system(size: 10, weight: .medium)).monospacedDigit().frame(width: 30, alignment: .trailing)
            }
        }
        .foregroundStyle(.black)
        .frame(width: 48, height: 20, alignment: .trailing)

        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2.0
        guard let img = renderer.nsImage else { return NSImage(size: NSSize(width: 48, height: 20)) }
        img.isTemplate = true   // 关键:模板图,菜单栏自动适配明暗
        return img
    }
}

// MARK: - App 入口

@main
struct AliyunTokenBarApp: App {
    @StateObject private var model = TokenPlanModel.shared

    init() {
        // 启动即检测登录态并拉数据(在首帧后)
    }

    var body: some Scene {
        MenuBarExtra {
            TokenPlanMenu()
                .onAppear { model.startTimer() }
        } label: {
            if let q = model.quota {
                Image(nsImage: MenuBarTextRenderer.image(fiveHour: q.usage.fiveHour.percentage,
                                                         oneWeek: q.usage.oneWeek.percentage))
            } else {
                Image(systemName: "speedometer")
            }
        }
        .menuBarExtraStyle(.window)
    }
}
```

- [ ] **Step 2: Build (will fail — TokenPlanMenu not yet defined; that's expected, Task 9 adds it)**

Run: `swift build`
Expected: FAIL — `cannot find 'TokenPlanMenu' in scope`. This is correct; proceed to Task 9.

- [ ] **Step 3: Commit (WIP — compiles after Task 9)**

```bash
git add Sources/AliyunTokenBar/App.swift
git commit -m "wip: add color tokens + icon renderer (menu pending)"
```

---

## Task 9: Menu panel + UsageCard + AuthOverlay views

**Files:**
- Create: `Sources/AliyunTokenBar/Menu.swift`

- [ ] **Step 1: Create Menu.swift with all panel views**

```swift
import SwiftUI
import AppKit

// MARK: - 主面板

struct TokenPlanMenu: View {
    @StateObject private var model = TokenPlanModel.shared
    private let consoleURL = URL(string: "https://bailian.console.aliyun.com/cn-beijing?tab=plan#/efm/subscription/token-plan/personal")!

    var body: some View {
        VStack(spacing: 14) {
            header
            if model.authState == .ok || model.authState == .unknown {
                usageSection
            }
            actionButtons
            if let sub = model.quota?.subscription { subscriptionRow(sub) }
        }
        .padding(16)
        .frame(width: 340)
        .background(Color.atbPanelBackground)
        .overlay { if needsAuthOverlay { AuthOverlay() } }
        .task { await model.checkAuthAndRefresh() }
    }

    private var needsAuthOverlay: Bool {
        model.authState == .blNotInstalled || model.authState == .notLoggedIn || model.authState == .expired
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "speedometer")
                .font(.system(size: 24))
                .foregroundStyle(.atbBlue)
            Text("AliyunTokenBar").font(.system(size: 18, weight: .bold)).foregroundStyle(.atbTextPrimary)
            Spacer()
            Button { NSWorkspace.shared.open(consoleURL) } label: {
                Image(systemName: "arrow.up.right.square").foregroundStyle(.atbTextTertiary)
            }.buttonStyle(.plain)
        }
    }

    private var usageSection: some View {
        HStack(spacing: 12) {
            if let q = model.quota {
                UsageCard(title: "5小时限额", detail: q.usage.fiveHour, color: .atbBlue, isLoading: model.isLoading)
                UsageCard(title: "7天限额", detail: q.usage.oneWeek, color: .orange, isLoading: model.isLoading)
            } else if model.isLoading {
                Spacer(); LoadingRing(); Spacer()
            } else {
                Text(model.lastError ?? "加载中…").foregroundStyle(.atbTextSecondary)
            }
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            ActionButton(title: "刷新", icon: "arrow.clockwise") { Task { await model.refresh() } }
            ActionButton(title: "控制台", icon: "globe") { NSWorkspace.shared.open(consoleURL) }
            ActionButton(title: "设置", icon: "gearshape") { SettingsWindowManager.shared.show() }
            ActionButton(title: "退出", icon: "power") { NSApplication.shared.terminate(nil) }
        }
    }

    private func subscriptionRow(_ sub: SubscriptionDetail) -> some View {
        HStack(spacing: 8) {
            Text("\(sub.specDisplay) 套餐").font(.system(size: 13, weight: .medium)).foregroundStyle(.atbTextPrimary)
            tagPill(sub.statusDisplay, color: .green)
            Spacer()
            Text("剩余 \(sub.remainingDays) 天").font(.system(size: 12)).foregroundStyle(.atbTextSecondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.atbCardBackground))
    }

    private func tagPill(_ text: String, color: Color) -> some View {
        Text(text).font(.system(size: 9, weight: .medium)).foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - 用量卡片(复刻 KimiCodeBar UsageCard)

struct UsageCard: View {
    let title: String
    let detail: UsageDetail
    let color: Color
    let isLoading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(.atbTextPrimary)
            ZStack(alignment: .leading) {
                if !isLoading {
                    Text("\(detail.percentage)%").font(.system(size: 32, weight: .bold, design: .rounded))
                        .monospacedDigit().foregroundStyle(.atbTextPrimary)
                } else { LoadingRing().frame(width: 24, height: 24) }
            }.frame(height: 38)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().frame(height: 4).foregroundStyle(Color.atbTextPrimary.opacity(0.10))
                    Capsule().frame(width: proxy.size.width * CGFloat(min(detail.percentage, 100)) / 100, height: 4)
                        .foregroundStyle(color)
                }
            }.frame(height: 4)
            Text(detail.timeUntilReset).font(.system(size: 11)).foregroundStyle(.atbTextSecondary)
        }
        .padding(14).frame(maxWidth: .infinity)
        .background(Color.atbCardBackground).clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - 鉴权遮罩

struct AuthOverlay: View {
    @StateObject private var model = TokenPlanModel.shared
    var body: some View {
        ZStack {
            Color.atbPanelBackground.opacity(0.94)
            VStack(spacing: 14) {
                Image(systemName: iconName).font(.system(size: 40)).foregroundStyle(.orange)
                Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(.atbTextPrimary)
                Text(hint).font(.system(size: 12)).foregroundStyle(.atbTextSecondary).multilineTextAlignment(.center)
                if model.authState != .blNotInstalled {
                    Button("重新登录") { BlAuthManager.relogin() }
                        .buttonStyle(.plain).foregroundStyle(.white)
                        .padding(.horizontal, 20).padding(.vertical, 8)
                        .background(Color.atbBlue).clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }.padding(24)
        }
    }
    private var iconName: String { model.authState == .blNotInstalled ? "exclamationmark.triangle" : "lock.rotation" }
    private var title: String {
        switch model.authState {
        case .blNotInstalled: return "未检测到 bl CLI"
        case .notLoggedIn: return "请先登录百炼控制台"
        case .expired: return "控制台登录已过期"
        default: return ""
        }
    }
    private var hint: String {
        switch model.authState {
        case .blNotInstalled: return "请在终端安装:npm install -g bailian-cli"
        case .notLoggedIn: return "点击下方登录(将打开浏览器授权)"
        case .expired: return "token 已失效,点击下方重新登录"
        default: return ""
        }
    }
}

// MARK: - 复用小组件

struct ActionButton: View {
    let title: String; let icon: String; let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 16))
                Text(title).font(.system(size: 11))
            }.frame(maxWidth: .infinity).padding(.vertical, 8).foregroundStyle(.atbTextSecondary)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.atbCardBackground))
        }.buttonStyle(.plain)
    }
}

struct LoadingRing: View {
    @State private var rotate = false
    var body: some View {
        Image(systemName: "circle.dashed")
            .rotationEffect(.degrees(rotate ? 360 : 0))
            .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: rotate)
            .onAppear { rotate = true }
    }
}
```

- [ ] **Step 2: Build (SettingsWindowManager still missing — Task 10 adds it; expect failure)**

Run: `swift build`
Expected: FAIL — `cannot find 'SettingsWindowManager' in scope`. Correct; proceed.

- [ ] **Step 3: Commit (WIP)**

```bash
git add Sources/AliyunTokenBar/Menu.swift
git commit -m "wip: add menu panel, usage card, auth overlay"
```

---

## Task 10: Settings window + launch-at-login + final wiring

**Files:**
- Create: `Sources/AliyunTokenBar/Settings.swift`
- Modify: `Sources/AliyunTokenBar/App.swift` (add Settings scene)

- [ ] **Step 1: Create Settings.swift**

```swift
import SwiftUI
import AppKit
import ServiceManagement

// MARK: - 开机自启

@MainActor
final class LaunchAtLoginManager: ObservableObject {
    static let shared = LaunchAtLoginManager()
    @Published private(set) var isEnabled = SMAppService.mainApp.status == .enabled
    func toggle(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { /* 系统设置手动改动时保持现状 */ }
        isEnabled = SMAppService.mainApp.status == .enabled
    }
}

// MARK: - 设置窗口管理(单例,Settings 环境注入)

@MainActor
final class SettingsWindowManager: ObservableObject {
    static let shared = SettingsWindowManager()
    func show() { SettingsWindow.shared.show() }
}

private final class SettingsWindow {
    static let shared = SettingsWindow()
    private var panel: NSPanel?
    func show() {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 220),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
            p.title = "AliyunTokenBar 设置"
            p.isFloatingPanel = true
            p.center()
            panel = p
        }
        panel?.contentView = NSHostingView(rootView: SettingsView())
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct SettingsView: View {
    @StateObject private var model = TokenPlanModel.shared
    @StateObject private var launch = LaunchAtLoginManager.shared
    var body: some View {
        Form {
            Section("刷新") {
                Picker("刷新间隔", selection: $model.refreshIntervalMinutes) {
                    Text("5 分钟").tag(5); Text("10 分钟").tag(10); Text("30 分钟").tag(30); Text("60 分钟").tag(60)
                }
            }
            Section("通用") {
                Toggle("开机自动启动", isOn: Binding(get: { launch.isEnabled }, set: { launch.toggle($0) }))
            }
        }.padding(16)
    }
}
```

- [ ] **Step 2: Add Settings scene to App.swift**

In `App.swift`, add a second scene inside `var body: some Scene` (after the `MenuBarExtra` block):

```swift
        Settings {
            SettingsView()
        }
```

(Requires `import ServiceManagement` is already in Settings.swift; `Settings` scene needs no import in App.swift.)

- [ ] **Step 3: Build — everything should now compile**

Run: `swift build`
Expected: `Build complete!` (first fully-compiling state since Task 8)

- [ ] **Step 4: Run all tests**

Run: `swift test`
Expected: PASS (8 unit tests: 5 Models + 5 BlUsageService-incl-skipped + 3 AuthManager)

- [ ] **Step 5: Commit**

```bash
git add Sources/AliyunTokenBar/Settings.swift Sources/AliyunTokenBar/App.swift
git commit -m "feat: add settings window + launch-at-login, wire up scenes"
```

---

## Task 11: Manual end-to-end verification

No code changes — verify the whole thing works against the live API.

- [ ] **Step 1: Ensure bl is logged in**

Run: `bl auth status --output text`
Expected: `Console gateway: config ... (cn-beijing, domestic)`. If expired, run `bl auth login --console --console-site domestic` first.

- [ ] **Step 2: Launch the app**

Run: `swift run AliyunTokenBar &` (background it), wait 5s.

- [ ] **Step 3: Verify menu-bar icon shows percentages**

Expected: A two-line "5h NN% / 7d NN%" icon appears in the menu bar (matching the console page's current values). If icon shows a speedometer, data hasn't loaded yet — wait for the timer.

- [ ] **Step 4: Verify the dropdown panel**

Click the icon. Expected panel shows:
- 5小时限额 card with percentage + progress bar + "X小时Y分钟后重置"
- 7天限额 card with percentage + progress bar + reset time
- Pro 套餐 · 生效中 · 剩余 N 天 row
- 刷新 / 控制台 / 设置 / 退出 buttons

- [ ] **Step 5: Cross-check values against the console page**

Open `https://bailian.console.aliyun.com/cn-beijing?tab=plan#/efm/subscription/token-plan/personal` in a browser. The 5h% and 7d% in the panel must match the console's "5小时限额"/"7天限额" bars (within refresh interval lag).

- [ ] **Step 6: Verify the auth-expired overlay**

Run `bl auth logout --console`, then click 刷新 in the panel.
Expected: Panel shows "控制台登录已过期" overlay with a "重新登录" button. Re-login via `bl auth login --console --console-site domestic` to restore.

- [ ] **Step 7: Kill the app and final commit**

```bash
kill %1   # or pkill -f AliyunTokenBar
git add -A
git commit --allow-empty -m "chore: verified end-to-end against live API"
```

---

## Self-Review (completed by plan author)

**1. Spec coverage check:**
- ✅ Menu-bar icon with usage % → Task 8 (renderer) + Task 11 (verify)
- ✅ Dropdown panel with 5h/7d cards → Task 9
- ✅ Subscription status (Pro/生效中/剩余天数) → Task 9 `subscriptionRow`
- ✅ Addon (加购包) → parsed (Task 5), display omitted from MVP panel (acceptable; spec says "如有余额" — defer to follow-up). **GAP noted**: addon card not rendered. Decision: acceptable for v1 since user has no addon; can add a row when needed. No task change.
- ✅ Refresh / console / settings / quit buttons → Task 9
- ✅ Token-expiry detection + re-login guidance → Task 7 (model) + Task 9 (overlay) + Task 11 step 6 (verify)
- ✅ bl-not-installed guidance → Task 9 AuthOverlay
- ✅ Launch-at-login → Task 10
- ✅ 10-min + manual refresh → Task 7
- ✅ Data contract (3 RPCs, 3-layer JSON, % + timestamps) → Task 3/5 + fixtures

**2. Placeholder scan:** None. All code blocks complete. The Task 4 "known bug" is explicitly carried to Task 5 (intentional bite-sized split, not a placeholder).

**3. Type consistency:** Checked across tasks — `UsageWindows`, `TokenPlanQuota.usage`, `AuthState` cases, `BlAuthManager.parseAuthStatus` all match between definition (Task 2/6) and use (Task 5/7/9). `SettingsWindowManager.shared.show()` used in Task 9, defined in Task 10 — order is correct (Task 10 makes it compile).

---

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-08-01-aliyun-token-bar.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

**Which approach?**
