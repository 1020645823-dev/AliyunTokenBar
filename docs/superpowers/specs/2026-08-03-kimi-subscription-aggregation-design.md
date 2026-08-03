# Kimi 订阅共享额度统计设计

日期：2026-08-03

## 背景

Kimi 网页控制台的订阅额度是 Work/Kimi 与 Kimi Code 共用的一个账户池。当前实现把 Kimi Code `GetUsages` 的数据直接作为“订阅总额度”，因此只显示 Code 侧用量，不能还原截图中的账户总使用量及 Work/Code 分段。

## 目标

- 订阅总使用量使用账户共享池口径。
- 在同一条总进度条中区分 Work/Kimi 与 Code 的实际使用占比。
- 保留现有 5 小时、7 天窗口统计，不改变其 Code 限流语义。
- 兼容未返回订阅统计、缺少分项字段以及旧版仅有 `totalQuota` 的响应。
- 不把 Work 和 Code 的独立限额相加作为总额度分母。

## 数据契约与口径

### Code 窗口

继续请求：

```text
POST https://www.kimi.com/apiv2/kimi.gateway.billing.v1.BillingService/GetUsages
body: {"scope":["FEATURE_CODING"]}
```

该接口只负责 Code 的 5 小时和 7 天窗口。解析时按 `scope == FEATURE_CODING` 查找条目，不依赖 `usages.first`。旧版顶层 coding API 仍保留作为无 Web 登录时的 fallback。

`totalQuota` 不再作为官方订阅共享池的主要来源；它可能为空或只代表 Code 计划汇总，因此只作为兼容字段保留，不用于新的 Work/Code 分段卡。

### 共享订阅池

继续请求：

```text
POST https://www.kimi.com/apiv2/kimi.gateway.membership.v2.MembershipService/GetSubscriptionStats
body: {}
```

读取：

- `subscriptionBalance.amountUsedRatio`：账户共享池总使用比例。
- `subscriptionBalance.kimiCodeUsedRatio`：Code 在同一共享池中的使用比例。
- `subscriptionBalance.expireTime`：订阅池重置/到期时间。

两项比例都以共享订阅总额度为分母，取值范围为 `0...1`。Work 不是服务端独立返回的限额，而是共享池中的剩余分项：

```text
codeUsedRatio = min(max(kimiCodeUsedRatio, 0), amountUsedRatio)
workUsedRatio = max(amountUsedRatio - codeUsedRatio, 0)
```

这样总段长度恒等于 `amountUsedRatio`，剩余段为 `1 - amountUsedRatio`。若 Code 分项字段缺失，则只显示总使用量，不推测 Work/Code 分配。

## 模型设计

在 Core 中新增独立的 `KimiSubscriptionBalance`，避免把比例型共享池数据塞进 `KimiWindow`：

- `totalUsedRatio: Double`
- `codeUsedRatio: Double?`
- `expireTimeMs: Int64?`
- `codeUsedPercent`、`workUsedPercent`、`totalUsedPercent` 只读计算属性，负责钳制和换算。

`KimiQuota` 增加可选 `subscriptionBalance` 字段；已有 `monthly` 字段保留为旧 `totalQuota` 兼容数据，但新 UI 不再把它当作订阅共享池。

## 数据流

1. `fetchWebWithToken` 请求 Code `GetUsages`，解析 5h/7d。
2. 同一 token 请求 `GetSubscriptionStats`，用纯函数解析 `subscriptionBalance`。
3. 两个结果合并为 `KimiWebQuota`，再映射到 `KimiQuota`。
4. 若订阅统计请求失败，5h/7d 仍成功展示；订阅共享卡显示不可用状态，不覆盖 Code 窗口数据。
5. 无 Web 登录时继续使用 coding API；订阅共享卡不显示或显示不可用，不伪造总额。

## UI 设计

Kimi 面板保留 5 小时和每周限额卡，替换原“订阅总额度”单值 `UsageCard`：

- 标题：`总使用量`。
- 顶部显示 `amountUsedRatio` 的百分比。
- 进度条由三段组成：Work/Kimi 黑色、Code 蓝色、剩余灰色。
- 图例或明细行显示 Work/Kimi 与 Code 各自占共享总额度的实际百分比。
- 右侧显示订阅重置时间。
- `codeUsedRatio` 缺失时显示单色总进度，并明确分项不可用，避免把总量误标成 Work 或 Code。
- 服务/网络失败显示横杠，沿用现有不可用视觉。

## 错误与兼容

- `GetUsages.usages` 为空或找不到 `FEATURE_CODING`：按现有 parse 错误处理。
- `GetSubscriptionStats` 失败：不影响 Code 窗口；共享订阅卡为不可用。
- 缺少 `kimiCodeUsedRatio`：保留总使用量，不推导分项。
- 负值和超过总量的比例统一钳制，避免进度条越界。
- 兼容字符串、整数和浮点数形式的 ratio；兼容带/不带小数秒的 ISO8601 时间。

## 验证

在 `Sources/Verify/main.swift` 增加纯函数 fixture：

- `amountUsedRatio = 0.4173`、`kimiCodeUsedRatio = 0.2173`，断言总使用量 41.73%、Code 21.73%、Work 20.00%。
- 断言总量分母仍是共享池，不会得到 `41.73 / 2` 或把两个 limit 相加。
- Code 比总量大时断言钳制到总量，Work 为 0。
- 缺少 Code 分项时断言共享池仍可解析但分项为 nil。
- 保留现有 Kimi coding/web parser 和旧版工作区断言。

## 范围外

- 不请求未经证实的 `FEATURE_WORK` scope。
- 不把本地 `wire.jsonl` 逐请求扫描结果混入订阅额度统计。
- 不改变 5h/7d 通知、历史快照和菜单栏 compact 图标的既有窗口语义；订阅卡只在面板展示共享池分项。
