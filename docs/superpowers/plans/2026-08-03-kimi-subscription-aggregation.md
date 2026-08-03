# Kimi 订阅共享额度统计 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Correct Kimi subscription usage so the panel reports the shared account total and visually separates Work/Kimi usage from Kimi Code usage using the shared pool as the only denominator.

**Architecture:** Keep Code 5-hour/7-day windows in the existing `GetUsages` path. Parse the shared subscription pool from `GetSubscriptionStats.subscriptionBalance`, model it separately from `KimiWindow`, and render a dedicated segmented subscription card. Work usage is derived only when the server returns both shared `amountUsedRatio` and `kimiCodeUsedRatio`; no unverified `FEATURE_WORK` request is introduced.

**Tech Stack:** Swift 5.9, SwiftUI/AppKit, Swift Package Manager, Foundation JSONSerialization, `swift run Verify` assertion harness.

---

## File Map

- Modify `Sources/AliyunTokenBarCore/KimiQuotaModel.swift`: add the ratio-based shared subscription model and attach it to `KimiQuota` without changing the meaning of `KimiWindow`.
- Modify `Sources/AliyunTokenBarCore/KimiUsageService.swift`: parse `GetSubscriptionStats.subscriptionBalance`, merge it into the web quota result, and select `FEATURE_CODING` by scope instead of array position.
- Modify `Sources/AliyunTokenBar/Menu.swift`: replace the single-value monthly `UsageCard` with a shared-pool Work/Code segmented card and preserve the existing unavailable state.
- Modify `Sources/Verify/main.swift`: add fixtures and pure-parser/model assertions for shared-pool aggregation, clamping, missing Code detail, and scope selection.
- Do not modify or revert the existing unrelated changes in `Sources/AliyunTokenBar/Menu.swift`, `Sources/AliyunTokenBarCore/Models.swift`, `Sources/AliyunTokenBarCore/TokenPlanModel.swift`, or `Sources/Verify/main.swift`; merge changes around them.
- Do not add a new `FEATURE_WORK` network request; current public evidence only supports `FEATURE_CODING` for `GetUsages` and the shared pool fields in `GetSubscriptionStats`.

## Task 1: Add the shared subscription model

**Files:**
- Modify: `Sources/AliyunTokenBarCore/KimiQuotaModel.swift:70-106`
- Test: `Sources/Verify/main.swift` near the existing Kimi model assertions

- [ ] **Step 1: Write the failing model assertions**

Add assertions after the current `KimiWindow` boundary checks. They must exercise the shared denominator and the derived Work segment:

```swift
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
```

- [ ] **Step 2: Run the assertion harness and verify it fails**

Run:

```bash
swift run Verify
```

Expected: compilation fails because `KimiSubscriptionBalance` and its computed properties do not yet exist.

- [ ] **Step 3: Implement the ratio model**

Add this model before `KimiQuota` in `KimiQuotaModel.swift`:

```swift
/// Kimi 网页订阅共享额度。Work/Kimi 与 Code 共用同一账户池，比例都以该池为分母。
public struct KimiSubscriptionBalance: Equatable {
    /// 账户共享池总使用比例(0...1)。
    public let totalUsedRatio: Double
    /// Code 在共享池中的使用比例(0...1);服务端未返回时为 nil。
    public let codeUsedRatio: Double?
    /// 订阅池重置/到期时间(ms epoch)。
    public let expireTimeMs: Int64?

    public init(totalUsedRatio: Double, codeUsedRatio: Double?, expireTimeMs: Int64?) {
        self.totalUsedRatio = Self.clamp(totalUsedRatio)
        self.codeUsedRatio = codeUsedRatio.map(Self.clamp)
        self.expireTimeMs = expireTimeMs
    }

    /// 账户共享池总使用百分比。
    public var totalUsedPercent: Double { roundedPercent(totalUsedRatio) }

    /// Code 占共享池的百分比;没有服务端分项时为 nil。
    public var codeUsedPercent: Double? {
        guard let codeUsedRatio else { return nil }
        return roundedPercent(min(codeUsedRatio, totalUsedRatio))
    }

    /// Work/Kimi 占共享池的百分比;没有 Code 分项时为 nil。
    public var workUsedPercent: Double? {
        guard let codeUsedRatio else { return nil }
        return roundedPercent(max(0, totalUsedRatio - min(codeUsedRatio, totalUsedRatio)))
    }

    /// 共享池剩余百分比。
    public var remainingPercent: Double {
        roundedPercent(1 - totalUsedRatio)
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    private func roundedPercent(_ ratio: Double) -> Double {
        (ratio * 100 * 100).rounded() / 100
    }
}
```

Add the optional property and defaulted initializer argument to `KimiQuota`:

```swift
/// 网页订阅共享池(Work/Kimi + Code);未登录网页控制台时为 nil。
public let subscriptionBalance: KimiSubscriptionBalance?
```

and update the initializer to accept:

```swift
subscriptionBalance: KimiSubscriptionBalance? = nil
```

then assign `self.subscriptionBalance = subscriptionBalance`. Keep `monthly` and its existing initializer behavior for compatibility with old `totalQuota` data; the new UI must use `subscriptionBalance` instead of treating `monthly` as the shared subscription pool.

- [ ] **Step 4: Run the harness and verify the model assertions pass**

Run:

```bash
swift run Verify
```

Expected: the new shared model checks pass. Existing checks may still fail to compile at Kimi `KimiQuota` construction sites if they require a non-default argument; update only those call sites to use the defaulted argument, without touching unrelated behavior.

## Task 2: Parse and merge the shared subscription response

**Files:**
- Modify: `Sources/AliyunTokenBarCore/KimiUsageService.swift:241-340`
- Modify: `Sources/AliyunTokenBarCore/KimiUsageService.swift:318-340`
- Test: `Sources/Verify/main.swift` in the Kimi Web parser section

- [ ] **Step 1: Add failing parser fixtures and assertions**

Add a GetSubscriptionStats fixture next to `kimiWebFixture`:

```swift
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
```

Add a multi-entry GetUsages fixture where a non-Code entry appears first and assert the Code window is selected by scope, not by array index:

```swift
let kimiWebMultiScopeFixture = #"{
  "usages":[
    {"scope":"FEATURE_OMNI","detail":{"limit":"100","used":"99","remaining":"1"}},
    {"scope":"FEATURE_CODING","detail":{"limit":"100","used":"58","remaining":"42"},"limits":[]}
  ],
  "totalQuota":{}
}"#
let multiScope = KimiUsageService.parseWebUsages(Data(kimiWebMultiScopeFixture.utf8))
check("web parser selects coding scope", multiScope?.weekly.used == 58)
```

- [ ] **Step 2: Run Verify and confirm the new parser tests fail**

Run:

```bash
swift run Verify
```

Expected: compilation fails because `parseSubscriptionStats` is not exposed and `KimiWebQuota` has no shared-balance field; the multi-scope assertion also fails while the parser uses `usages.first`.

- [ ] **Step 3: Extend `KimiWebQuota` and parse `subscriptionBalance`**

Change `KimiWebQuota` to carry the parsed shared pool:

```swift
public let subscriptionBalance: KimiSubscriptionBalance?
public init(fiveHour: KimiWindow, weekly: KimiWindow, monthly: KimiWindow?,
            subscriptionExpireMs: Int64?, subscriptionBalance: KimiSubscriptionBalance? = nil) {
    self.fiveHour = fiveHour
    self.weekly = weekly
    self.monthly = monthly
    self.subscriptionExpireMs = subscriptionExpireMs
    self.subscriptionBalance = subscriptionBalance
}
```

Add this pure parser near `parseWebUsages`:

```swift
/// 解析 GetSubscriptionStats.subscriptionBalance 的共享订阅池。
public static func parseSubscriptionStats(_ data: Data) -> KimiSubscriptionBalance? {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let raw = root["subscriptionBalance"] as? [String: Any],
          let total = ratioValue(raw["amountUsedRatio"]) else { return nil }
    return KimiSubscriptionBalance(totalUsedRatio: total,
                                   codeUsedRatio: ratioValue(raw["kimiCodeUsedRatio"]),
                                   expireTimeMs: dateMs(raw["expireTime"]))
}
```

Add a ratio helper beside `intValue`:

```swift
/// 字符串或数字 → 0...1 比例。
private static func ratioValue(_ value: Any?) -> Double? {
    let raw: Double?
    if let s = value as? String { raw = Double(s) }
    else if let n = value as? Double { raw = n }
    else if let n = value as? Int { raw = Double(n) }
    else if let n = value as? NSNumber { raw = n.doubleValue }
    else { raw = nil }
    guard let raw else { return nil }
    return min(max(raw, 0), 1)
}
```

Do not require `ratelimitCode5h` or `ratelimitCode7d` for this feature; those are separate rate-limit data and the existing Code windows remain the source for the current 5h/7d cards.

- [ ] **Step 4: Select the Code usage entry by scope**

Replace the `usages.first` guard in `parseWebUsages` with a scope-aware lookup:

```swift
guard let coding = usages.first(where: {
    ($0["scope"] as? String)?.uppercased() == "FEATURE_CODING"
}) else { return nil }
let weekly = makeWindow(coding["detail"] as? [String: Any])
```

Use `coding["limits"]` for the 5-hour lookup. Do not fall back to `usages.first`, because a future multi-scope response must not silently show another feature's quota.

Also update the `duration` match to accept JSON string or number and require the minute unit:

```swift
let duration = intValue(window["duration"])
let unit = (window["timeUnit"] as? String)?.uppercased()
if duration == 300,
   unit == nil || unit == "TIME_UNIT_MINUTE" || unit == "MINUTE",
   let detail = limit["detail"] as? [String: Any] {
    fiveHour = makeWindow(detail)
    break
}
```

Apply the same duration/unit compatibility in the top-level coding parser if that parser has the same `limits` loop; this keeps web and fallback parsing consistent.

- [ ] **Step 5: Make Web fetch parse stats as an optional enrichment**

In `fetchWebWithToken`, leave the Code `GetUsages` request body as:

```swift
{"scope":["FEATURE_CODING"]}
```

After the Code usage response succeeds, request `GetSubscriptionStats` as today. Replace the current `expireMs`-only extraction with:

```swift
let statsBalance: KimiSubscriptionBalance?
if let (statsData, statsResponse) = try? await URLSession.shared.data(for: statsReq),
   let http = statsResponse as? HTTPURLResponse,
   http.statusCode == 200 {
    statsBalance = parseSubscriptionStats(statsData)
} else {
    statsBalance = nil
}

return .success(KimiWebQuota(
    fiveHour: parsed.fiveHour,
    weekly: parsed.weekly,
    monthly: parsed.monthly,
    subscriptionExpireMs: statsBalance?.expireTimeMs,
    subscriptionBalance: statsBalance
))
```

A stats failure must not turn a successful Code response into `.failure`; the shared card can show unavailable while the 5h/7d cards remain usable.

- [ ] **Step 6: Map the shared balance into `KimiQuota`**

In the Web success branch of `fetchQuota`, pass through:

```swift
subscriptionBalance: wq.subscriptionBalance
```

The coding API fallback should leave this property as `nil`, because it has no verified shared subscription response.

- [ ] **Step 7: Run Verify and verify all parser assertions pass**

Run:

```bash
swift run Verify
```

Expected: all new stats, missing-field, scope-selection, and existing Kimi assertions pass. The command must end with `ALL PASS`.

## Task 3: Render the shared Work/Code segmented card

**Files:**
- Modify: `Sources/AliyunTokenBar/Menu.swift:677-699`
- Add: `Sources/AliyunTokenBar/Menu.swift` near the existing Kimi card components

- [ ] **Step 1: Implement the dedicated card without changing existing window cards**

In `KimiCodeCard`, replace the current `if let m = q.monthly { UsageCard(title: "订阅总额度", ...) }` block with:

```swift
if let balance = q.subscriptionBalance {
    KimiSubscriptionCard(balance: balance)
} else if model.kimiWebLoggedIn {
    UsageCard(title: "总使用量", percentage: nil, resetText: nil,
              color: .orange, isLoading: false,
              thresholdConfig: model.thresholdConfig,
              dataUnavailable: true)
}
```

Add this view below `KimiCodeCard` and before `KimiBoosterRow`:

```swift
/// Kimi 共享订阅池:Work/Kimi 与 Code 分段显示,总量只使用共享池分母。
struct KimiSubscriptionCard: View {
    let balance: KimiSubscriptionBalance
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("总使用量")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.atbTextPrimary)
                Spacer()
                Text(String(format: "%.2f%%", balance.totalUsedPercent))
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.atbTextPrimary)
            }

            GeometryReader { proxy in
                HStack(spacing: 2) {
                    if let work = balance.workUsedPercent,
                       let code = balance.codeUsedPercent {
                        Rectangle()
                            .fill(Color.black.opacity(0.88))
                            .frame(width: proxy.size.width * CGFloat(work / 100))
                        Rectangle()
                            .fill(Color.atbBlue)
                            .frame(width: proxy.size.width * CGFloat(code / 100))
                    } else {
                        Rectangle()
                            .fill(Color.atbBlue)
                            .frame(width: proxy.size.width * CGFloat(balance.totalUsedPercent / 100))
                    }
                    Rectangle()
                        .fill(Color.black.opacity(0.08))
                }
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .frame(height: 8)

            HStack(spacing: 12) {
                if let work = balance.workUsedPercent,
                   let code = balance.codeUsedPercent {
                    KimiSubscriptionLegend(color: .black, title: "Kimi/Work", percent: work)
                    KimiSubscriptionLegend(color: .atbBlue, title: "Code", percent: code)
                } else {
                    Text("Code/Work 分项暂不可用")
                        .font(.system(size: 10))
                        .foregroundStyle(.atbTextTertiary)
                }
                Spacer(minLength: 0)
            }

            if let ms = balance.expireTimeMs {
                Text("重置时间 \(Self.dateText(ms))")
                    .font(.system(size: 9))
                    .foregroundStyle(.atbTextTertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.atbCardBackground)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.black.opacity(0.08)))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private static func dateText(_ ms: Int64) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
    }
}

struct KimiSubscriptionLegend: View {
    let color: Color
    let title: String
    let percent: Double
    var body: some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 8, height: 8)
            Text("\(title) \(String(format: \"%.2f%%\", percent))")
                .font(.system(size: 10))
                .foregroundStyle(.atbTextSecondary)
                .monospacedDigit()
        }
    }
}
```

Use `Color.atbBlue` for the Code segment to match the existing app palette. Keep the card's dimensions stable: the `GeometryReader` has a fixed 8-point track height and all dynamic labels are in fixed-size rows.

- [ ] **Step 2: Build the app target and fix only compile errors from the new view**

Run:

```bash
swift build
```

Expected: the package builds successfully. If SwiftUI type inference reports an issue around conditional branches, preserve the existing `@ViewBuilder` context and split the segment into a small private `@ViewBuilder` property; do not alter unrelated UI.

- [ ] **Step 3: Verify the existing unavailable and login states**

Run:

```bash
swift run Verify
```

Expected: `ALL PASS`. The no-Web-token path still shows the existing login hint; the Web-token/no-stats path shows a dash card; a successful stats parse shows the new segmented card.

## Task 4: End-to-end verification and diff hygiene

**Files:**
- Inspect only: all changed files and current worktree

- [ ] **Step 1: Run the full assertion harness**

Run:

```bash
swift run Verify
```

Expected: output ends with `ALL PASS`. Do not run `KIMI_LIVE=1` or `KIMI_WEB_LIVE=1` unless the user explicitly supplies/authorizes live credentials; fixture tests are the deterministic regression coverage.

- [ ] **Step 2: Build the application package**

Run:

```bash
swift build
```

Expected: exit code `0` with no compile errors.

- [ ] **Step 3: Inspect the final diff and preserve unrelated edits**

Run:

```bash
git diff --check
git status --short
git diff -- Sources/AliyunTokenBarCore/KimiQuotaModel.swift Sources/AliyunTokenBarCore/KimiUsageService.swift Sources/AliyunTokenBar/Menu.swift Sources/Verify/main.swift
```

Expected:

- `git diff --check` reports no whitespace errors.
- Existing unrelated changes in `Menu.swift`, `Models.swift`, `TokenPlanModel.swift`, and `Verify/main.swift` remain intact.
- Only the Kimi aggregation changes and the approved spec/plan are added by this work.
- Do not commit or push unless the user separately requests it.

- [ ] **Step 4: Report verification accurately**

Final report must include the exact commands run, whether `swift run Verify` ended in `ALL PASS`, whether `swift build` succeeded, and any live API verification that was intentionally skipped.
