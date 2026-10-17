# 小米 MiMo Token Plan 监控:如何做得更好更稳(2026-09-25)

**调研问题**:现有 MiMo 监控(控制台 Cookie 抓 `/api/v1/tokenPlan/*`)会话频繁过期、需人工重抄 Cookie,能否做得更稳?

**证据标注**:(a) 2026-09-25 本机直接探测/源码验证(附命令与原始输出);(b) 官方第一方源码(本机安装的 `@mimo-ai/mimocode-darwin-arm64` 二进制);(c) 社区/推断;(d) 未知。

**本机探测环境**:`mimo` CLI 已装(`/opt/homebrew/lib/node_modules/@mimo-ai/mimocode-darwin-arm64/bin/mimo`,95 MB Bun 单文件);CodingTokenBar.app 运行中;钥匙串 `com.aliyuntokenbar/mimo-console-cookie` 有值但**已失效**。

---

## 结论(TL;DR)

**"更稳"的瓶颈不在解析层,而在鉴权层。** 实测三条链路后可以确定:**用量数据只有控制台 Cookie 一条来源**,而这个 Cookie 是会过期的会话态。因此"更稳"只有两条路,且应当**同时**做:

1. **治本 —— 把"人工重抄 Cookie"换成 WebView 登录 + 自动续期。** 401 响应体自带可续期的 `loginUrl`(指向 `account.xiaomi.com/pass/serviceLogin`,可凭 `passToken` 静默换发 `api-platform_serviceToken`)。本 App 已有 Kimi/OpenCode 两个 WKWebView 登录先例,补一个 MiMo 登录窗即可**一次性根治**,并把续期交给代码。**(a)(c)**
2. **兜底 —— 加本地用量账本。** 官方 CLI 的本地库 `~/.local/share/mimocode/mimocode.db` 里逐条 assistant message 都带 `tokens{input,output,reasoning,cache.read,cache.write}` 与 `cost`,**零凭据、零网络、永不过期**。**(a)**
   ⚠️ 但它与控制台数字**不是同一个量**(单位与控制面都不同,详见 §1.4),只能作为"本机 CLI 活动量 + 趋势",**不能**当套餐余量的界线。这与本仓已有的 `DeepSeekDailyLedger` 余额差账本是同一套**实现**思路,但**语义不同**。

另外查出**三个已实现但没接上的缺陷**,其中"会话过期被误报成响应格式变化"会直接误导用户,值得先修。

---

## 1. 三条可能的鉴权链路,实测结论

| # | 链路 | 凭据 | 能拿用量? | 凭据寿命 | 结论 |
|---|------|------|:--:|------|------|
| A | `platform.xiaomimimo.com/api/v1/tokenPlan/{detail,usage}` + `/balance` | 控制台 Cookie(`api-platform_serviceToken` + `userId`) | ✅ **唯一来源** | **天级,会过期** | 保留,改为自动续期 |
| B | `token-plan-{cn,ams,sgp}.xiaomimimo.com/v1/*` | Token Plan API Key(`tp-…`) | ❌ | 长期 / 不过期 | 只能当"账号存活探针" |
| C | `~/.local/share/mimocode/mimocode.db` | 无 | ✅(仅本机 CLI 产生的那部分) | **永不过期** | 做兜底账本 |

### 1.1 链路 A(控制台 Cookie)—— 唯一真源,但会过期 **(a)**

本机钥匙串里的 Cookie 实测已失效:

```
$ security find-generic-password -s com.aliyuntokenbar -a mimo-console-cookie -w
Cookie: api-platform_ph="…"; api-platform_serviceToken="…"   # 有值

$ curl -s -D - -H "Cookie: $H" …/api/v1/balance
HTTP=401  0.12s
{"code":401,"loginUrl":"https://account.xiaomi.com/pass/serviceLogin?callback=
  https%3A%2F%2Fplatform.xiaomimimo.com%2Fsts%3Fsign%3DuaLUJuns…%26followup%3D…
  api%2Fv1%2Fbalance&sid=api-platform&_group=DEFAULT"}
```

三个端点全部 401,响应体同时给出 HTTP 401 **和** `code:401`。这正是现网稳定性痛点的现场。

### 1.2 链路 B(Token Plan API Key)—— 长期有效,但查不到用量 **(a)**

本机 `~/.local/share/mimocode/auth.json` 与另一 App(`reasonix`)钥匙串里都有 `tp-` key。实测:

```
$ curl -H "Authorization: Bearer tp-…" https://token-plan-cn.xiaomimimo.com/v1/models
HTTP=200      # key 有效
{"object":"list","data":[{"id":"mimo-v2.6-flash",…},{"id":"mimo-v2.6-pro",…}]}
```

但**用量端点全部不存在**,而且**聊天响应头不带任何配额信息**:

```
/v1/usage /v1/quota /v1/subscription /v1/me /v1/user
/v1/token_plan/remains /v1/dashboard/billing/usage /v1/credits …   → 全部 HTTP=404 (openresty)

$ curl -D - …/v1/chat/completions -d '{"model":"mimo-v2.6-flash",…}'
HTTP/2 200
content-length / vary / cache-control / server: MiFE/3.4.34 / x-mife-upstream-status   ← 无 x-ratelimit-* 无 quota
```

把 key 换成各种 header 形态打控制台 API 也一律 401:

```
Authorization: Bearer tp-…  /  X-Api-Key: tp-…  /  api-platform_serviceToken: tp-…  → 全部 401
```

**所以链路 B 永远拿不到用量**,它的价值只剩下:验证账号/套餐是否还活着,以及读出 `metadata.base_url` 判断区域(cn/ams/sgp)。

### 1.3 链路 C(本地库)—— 零凭据、永不过期 **(a)**

`mimocode.db` 的 `message.data` 就是完整 JSON,逐条带用量:

```json
{"role":"assistant","modelID":"mimo-x-pro-preview","providerID":"xiaomi",
 "cost":0,
 "tokens":{"input":…,"output":…,"reasoning":…,"cache":{"read":…,"write":…}}}
```

本机聚合结果:

```
provider=xiaomi  近30天: 43 条  input=478,895  output=43,501  reasoning=440  cache.read=3,307,968
                 按月: 2026-09 → 522,836 tok / 43 条
```

⚠️ **重要限定**:这**只覆盖本机 CLI 产生的用量**(mimocode + opencode,后者也有 xiaomi 记录)。作为"本机活动量 + 趋势"够用;但**不可**与控制台数字互相界定 —— 见下节。

### 1.4 ⚠️ 单位是 Credits,不是 tokens(2026-09-25 由用户质疑后确证)

**这一条是本报告初版的重大错误,记录在此以免重犯。**

控制台 `/api/v1/tokenPlan/usage` 返回:

```json
{"monthUsage":{"percent":0.1919,"items":[{"name":"month_total_token",
  "used":2110405051,"limit":11000000000,"percent":0.1919}]},
 "usage":{"items":[{"name":"plan_total_token", …},{"name":"compensation_total_token",…}]}}
```

API 的**字段名**到处是 `*_token`,于是初版据此把单位当成 tokens —— **错的**。响应里
**根本没有单位字段**,字段命名不等于单位规格。

权威口径来自控制台自己的套餐目录 `GET /api/v1/tokenPlan/list`:

| planCode | 价格 | tokenQuotaCn | API `limit` |
|---|---|---|---|
| lite | ¥39 | **41 亿 Credits** | 4,100,000,000 |
| standard | ¥99 | **110 亿 Credits** | 11,000,000,000 ✅ |
| pro | ¥329 | **380 亿 Credits** | 38,000,000,000 |
| max | ¥659 | **820 亿 Credits** | 82,000,000,000 |

`standard` 的 110 亿 Credits 与 API 的 `limit` **完全吻合** → **单位是 Credits**。

旁证(控制台前端 bundle 文案):
- 套餐权益:`每 5 小时 100万 tokens(200 万 Credits),6000 万 Credits 总量` → **1 token = 2 Credits**
- 同一字段在前端被标为 `creditsUsed:"Token 总消耗"` —— 单位与标签本来就混用
- 用量控件 i18n 是 `usageUsedLimitTokens:"{{used}} / {{limit}}"` —— **控制台自己都不带单位后缀**

**后果**:API 的 `used`/`limit` 是 Credits,所以 UI 标 "tokens" 是错的(已改为 `Credits`);
`usedPct` 与单位无关,故菜单栏百分比列不受影响。

**对 P2 的连带修正**:初版把本机账本称为控制台数字的"**下限**",这在两个方向上都不成立:

| 维度 | 控制台 | 本机账本 |
|---|---|---|
| 单位 | Credits(1 token = 2 Credits) | 原始 tokens |
| 覆盖面 | 全部客户端 | 仅本机 mimocode/opencode |
| 量级(实测) | 月 ≈ 21.1 亿 Credits ≈ 10.6 亿 tokens | 4 天 ≈ 52.3 万 tokens |

差约 2000 倍且单位不同 → 本机账本**与套餐余量无关**,只能当"本机活动量"看。UI 与文档已按此改写。

> **教训**:面对未公开 API,**不能把字段命名当单位规格**;必须找到平台自己展示/定义口径的地方
> (这里就是 `/tokenPlan/list` 的 `tokenQuotaCn`)。响应里没有单位字段时,应当**更**警惕而不是更放心。

---

## 2. 顺带挖到的官方鉴权模型(解释了为什么 Cookie 这么脆) **(b)**

反编译官方 CLI 二进制(`strings` + 定位源码段)拿到了完整的 MiMo 鉴权实现,这决定了我们的设计空间:

**① 官方登录 = 浏览器 OAuth → 铸一把长期 API Key,不是拿 Cookie**

```js
// plugin.mimo —— kX = https://platform.xiaomimimo.com
auth:{provider:"xiaomi", methods:[{label:"浏览器登录", type:"oauth", authorize:async()=>{
  let {publicKey, privateKeyDer} = cZ0();          // X25519 临时密钥对
  // GET ${kX}/authorize?pk=<pub>&redirect_uri=http://localhost:<port>/&kn=mimocode&key_name=<名字>
  // 回调带 u=<密文> → xI() 解密:X25519 ECDH → SHA256 → AES-256-GCM
  // 明文 = {uid, url, sk}  → 存成 {type:"api", key: sk, metadata:{uid, base_url: url}}
}]}
// 请求时附加: X-Mimo-Source: mimocode-cli
```

即:`sk` 就是那把 `tp-` key,`base_url` 就是 `token-plan-{region}.xiaomimimo.com/v1`。**官方自己也拿不到用量** —— 它只把用量交给浏览器控制台。

**② 但同一二进制里暴露了"免费匿名通道"的完整做法**(说明平台确实提供免登录自动签发):

```js
// plugin.mimo-free
POST https://api.xiaomimimo.com/api/free-ai/bootstrap   body:{"client":"<hostname|cpu|user 的 sha256>"}
  → {"jwt":"…"}   # payload 只含 {iss:"xiaomi-ai", data:<不透明>, iat, exp},exp-iat = 3600s
头: Authorization: Bearer <jwt> + X-Mimo-Source: mimocode-cli-free
缓存: exp 前 5 分钟自动重新 bootstrap(实测本机 POST 返回 HTTP 200)
```

**(a) 本机实测该 bootstrap 端点可用**(HTTP 200,返回 591 字符 JWT)。它不是 Token Plan 的用量来源,但证明了平台的"自动续期"惯例 —— 这正是我们该对控制台 Cookie 做的事。

---

## 3. 控制台会话能不能自动续期?—— 链路已完整可见 **(a)**,可行性 **(c)**

跟踪 401 给出的 `loginUrl`:

```
GET https://account.xiaomi.com/pass/serviceLogin?callback=https://platform.xiaomimimo.com/sts?sign=…&followup=…&sid=api-platform
→ HTTP/1.1 302
   Set-Cookie: deviceId=…       Max-Age=33696000   (约 390 天)
   Set-Cookie: pass_ua=web      Max-Age=7689600
   Set-Cookie: serviceToken=EXPIRED; Domain=.xiaomi.com
   Set-Cookie: cUserId=EXPIRED
   Set-Cookie: userId=EXPIRED
   Location: https://account.xiaomi.com/fe/service/login?…&_sign=…&serviceParam=…
```

链路形状很清楚,是**标准小米 SSO**:

```
[过期] → platform 401 + loginUrl
       → account.xiaomi.com/pass/serviceLogin (sid=api-platform)
            ├─ 带上有效的 passToken  → 静默换发 serviceToken,302 到 callback
            └─ 没带                   → 跳 /fe/service/login 要求交互登录   ← 现在卡在这一步
       → platform.xiaomimimo.com/sts?sign=…   (实测无 sign 时 HTTP 400,是回调端点)
            → Set-Cookie: api-platform_serviceToken
       → followup 回原 API,200
```

**结论**:只要手里有 `passToken`(长寿命、滑动续期),整条链可以**全自动**跑完,用户不必再碰 Cookie。**(a)** 是链路事实,**(c)** 是"passToken 一定还在响应里"这一环——本机无有效 Cookie,无法端到端验证,列为 P1 必须实测的验收点。

---

## 4. 现有实现的三个缺陷(已实现但没接上)

| # | 位置 | 问题 |
|---|------|------|
| D1 | [`MiMoUsageService.swift:144-147`](../Sources/AliyunTokenBarCore/MiMoUsageService.swift#L144-L147) `successData` | `tokenPlan/detail` 与 `tokenPlan/usage` 的**失败被静默吞掉**,成败只看 `balance`(`:113-115`)。会话过期恰好只影响这两个端点时,面板显示"暂无用量数据"(`MiMoCard.swift:190`)而不是"重新登录" |
| D2 | [`MiMoUsageService.swift:190-197`](../Sources/AliyunTokenBarCore/MiMoUsageService.swift#L190-L197) `classifyEnvelope` | **死代码**:`Verify/main.swift:1249-1254` 有断言,但生产路径从不调用。`fetchAuthenticated`(`:168`)只按 HTTP 状态判;一旦平台改成 **HTTP 200 + `{"code":401,…}`**,就会掉进 `parseBalance` 失败 → `.parse("balance 响应无法解析")`(`:122`),错误文案误导为"响应格式变化" |
| D3 | [`MiMoUsageService.swift:269`](../Sources/AliyunTokenBarCore/MiMoUsageService.swift#L269) / [`:243`](../Sources/AliyunTokenBarCore/MiMoUsageService.swift#L243) | `parsePlanUsage` 取 `items.first`(多项时口径武断);`parsePlanDetail` 的 `expired` 缺失时默认 `false`(宁可"未知"也别默认"没过期") |

补充:`refreshMiMo()` 未参与 `consecutiveFailures` 退避(见 `TokenPlanModel.swift:453`),MiMo 失败不会像其他源一样降频——会话过期后会按正常间隔**持续打无效请求**。

---

## 5. 推荐方案(分层,按性价比排序)

### P0 — 修缺陷(半天,零风险)

1. **让 auth 失败可见**:`fetchUsage` 改为收集三端点的错误,只要任一返回 `loginRequired` / `invalidCredentials` 就整体判该错误;`detail`/`usage` 的**非鉴权类**失败仍静默降级(保持"有余额就显示余额"的现语义)。
2. **接上 `classifyEnvelope`**:`fetchAuthenticated` 对 2xx 响应先解包 `code`,非 0 走 `classifyEnvelope`。同时覆盖 HTTP 200 + `code:401` 这一形态,并补一条 Verify fixture。
3. **`items` 选优**:多项时按 `limit` 最大者(或聚合),不再盲取 `first`;`expired` 缺失 → 用 `Optional`/三态,不再默认 `false`。
4. **接入退避**:把 MiMo 纳入 `consecutiveFailures` 节流,`loginRequired` 时额外降频(例如封顶 30 min),避免无效轮询。

### P1 — WebView 登录 + 自动续期(治本,1–2 天)

1. 新增 `MiMoLoginView`(照抄 [`KimiLoginView.swift`](../Sources/AliyunTokenBar/KimiLoginView.swift) 的 WKWebView + `WKWebsiteDataStore.default()` 模式),加载 `platform.xiaomimimo.com` 余额页,用户在窗内完成登录。
2. 登录后用 `httpCookieStore.getAllCookies()` **抓整段 Cookie jar**,按域分两类落 Keychain:
   - `platform.xiaomimimo.com`:`api-platform_serviceToken`、`api-platform_ph`、`userId`
   - `account.xiaomi.com` / `.xiaomi.com`:**`passToken`**、`serviceToken`、`cUserId`、`userId`   ← 续期钥匙
3. `MiMoUsageService` 新增 `renewSession(jar:) -> Result<String, MiMoError>`:按 §3 的链路走 `serviceLogin → sts → followup`,从 `Set-Cookie` 里摘出新的 `api-platform_serviceToken` 回写,然后**重试一次**原请求。
4. 触发点:`loginRequired` 时先试续期;续期成功 → 静默重试,用户无感;续期失败 → 才走现有的"重新登录"引导(并直接弹 WebView,而非让用户手工复制)。
5. **凭据存储向后兼容**:保留 `mimo-console-cookie` 单键作为"整段 Cookie 请求头"的兼容形态(`normalizedCookie` 继续认),新增 jar 形态优先;旧值可平滑迁移。

> ⚠️ 这是唯一需要**真机端到端验证**的一步(passToken 是否随 `/pass/serviceLogin` 静默换发)。建议先写一个 20 行的探针脚本,用真实 jar 跑一遍再动 UI。

### P2 — 本地用量账本兜底(1 天)

新增 `MiMoLocalLedger`(对齐 [`DeepSeekDailyLedger.swift`](../Sources/AliyunTokenBarCore/DeepSeekDailyLedger.swift) 的形态):

1. 只读打开 `~/.local/share/mimocode/mimocode.db`(**readonly**,`file:…?mode=ro`,避免与 CLI 争锁),SQL 聚合 `providerID='xiaomi'` 的 `tokens.*` 按天分组;另可并联 `~/.local/share/opencode/opencode.db`。
2. 产出"本机已消耗 token"曲线,写入 `~/Library/Application Support/AliyunTokenBar/mimo-local.json`。
3. 面板呈现:`limit` 已知时显示"控制台 X% · 本机口径 Y";控制台不可用时,降级显示"本机口径 ≈ Y tok(仅本机 CLI)+ 上次成功快照(时间)"。
4. **诚实标注口径**:控制台单位是 **Credits**、本机账本是**原始 tokens**且只覆盖本机 CLI,
   两者不可互相界定 → UI 只把它呈现为"本机 CLI 消耗(与控制台 Credits 不同口径)",不冒充官方百分比、不称作上下界。

### P3 — 契约加固(顺手)

- 把 §1 的实测响应作为 fixture 落进 [`Verify/main.swift`](../Sources/Verify/main.swift#L1203)(401 响应体、`code:401` 包络、`items` 多条),锁住契约。
- 文档同步:CLAUDE.md 的数据契约表补 MiMo 的 401/`code` 形态与本账本。

---

## 6. 明确**不**做的事

- ❌ **改用 API Key 拿用量** —— 实测不存在该端点(§1.2),不要为此重构。
- ❌ **解析浏览器 Cookie 数据库**(Chrome/Safari) —— 需 Full Disk Access + 解密 Safe Storage,又脆又涉隐私,收益不如 P1 的 WebView。
- ❌ **让本地库当唯一真源** —— 只覆盖本机 CLI,会低估(§1.3)。
- ❌ **伪造百分比** —— 拿不到就显示"控制台不可用 + 本机口径",不猜。

---

## 7. 验收清单

### P0 —— 已完成(TDD:先加断言见红,再实现转绿)

- [x] HTTP 200 + `{"code":401}` → 归类为 `loginRequired`,文案不出现"响应格式变化"
      → 新增 `MiMoUsageService.envelopeError(from:)`,接线进 `fetchAuthenticated`
- [x] `tokenPlan/*` 端点鉴权失败不再被静默吞掉
      → `successData` 的三端点归并抽成纯函数 `combine(balance:detail:usage:)`:
      balance 失败优先;plan 端点**鉴权类**失败整体暴露;网络/解析类仍静默降级
- [x] `items` 多项时按 `limit` 最大者选主窗口(全 0 时退化取 `percent` 最大者),
      并新增"item 无 percent → 回退外层 `monthUsage.percent`"
- [x] `expired` 改三态 `Bool?`:接口未下发即为 `nil`,不再默认"未过期"
- [x] 鉴权失败退避:`authRetryCooldownSeconds` 5→10→20→30 分钟封顶,
      手动刷新/保存新 Cookie 走 `force: true` 绕过冷却

### P1 —— 已完成(离线 TDD;真机 WebView 登录待你操作)

- [x] `MiMoCookieJar` 两域 jar + `parseCookiePairs`/`header`/`cookieValue`/`merging` 纯函数
- [x] 旧版单键 `mimo-console-cookie` 平滑迁移(无 account 段 → 不可续期,行为不劣化)
- [x] `MiMoSessionRenewal.renew` 续期编排:probe 取新鲜 `loginUrl` → `serviceLogin`(带 passToken)
      → **域判定**是否通过(仍在 `account.xiaomi.com` = passToken 失效)→ 回调摘新 serviceToken → 回写(含旋转的 passToken)
- [x] 可注入 `MiMoTransport`,用脚本化响应离线驱动整条链路(替代真机探针)
- [x] `refreshMiMo` 接入:会话过期 → 静默续期 → 重试一次;失败才降频并提示重登
- [x] `MiMoLoginView`(WKWebView)登录后抓 `WKWebsiteDataStore` 两域 Cookie
- [x] 面板与设置的「自动续期已启用/未启用」状态行 + 登录入口
- [ ] **真机验证**:点「登录平台」在窗内登录 → 确认 `mimoJar.canRenew == true`、
      且过期时能自动续期(唯一需要人工的一步)
- [x] `MIMO_E2E=1` 门控真实 API 集成断言:实测过期会话被正确归类为 `loginRequired`(非 parse)

### P2 —— 已完成(离线 TDD + 真机采集验证)

- [x] `MiMoLocalLedger`:纯函数 `querySQL` / `parseRows` / `aggregate(时区可注入)` / `todayTokens` / `totalTokens`
- [x] `MiMoLocalUsageCollector`:`candidateDBPaths(home:)` + `collect(sinceDays:home:store:)`,
      **`sqlite3 -readonly`** 只读打开 `~/.local/share/{mimocode,opencode}/*.db`,绝不写他方数据库
- [x] `MiMoUsageService.planQuotaUnit = "Credits"` 单位契约 + Verify 断言守住(防再次被 `*_token` 误导)
- [x] `MiMoLocalUsageStore` 落盘 `mimo-local.json`(v1,按天聚合)
- [x] `MiMoLastUsageStore` 落盘 `mimo-last.json`(v1,上次**控制台成功**快照,跨重启保留)
- [x] 面板:控制台不可用时展示「上次成功查询(含时间)」+「本机 CLI 消耗(与控制台 Credits 不同口径)」,
      不再出现空横杠
- [x] **真机采集实测通过**:近 30 天 522,836 tok / 4 天,落盘 JSON 与手工 SQL 结果一致
      (`2026-09-10 53150 / 09-11 209091 / 09-12 53822 / 09-15 206773`)
- [x] 采集走 `Task.detached(priority: .utility)`,不阻塞主线程;节流 10 分钟

### 回归

- [x] `swift build` 0 error / 0 warning;`swift run Verify` **572 条断言 ALL PASS**(原 515 条,+57)
- [x] `MIMO_E2E=1` 真实 API + 真实本地库集成断言全 PASS

---

## 8. 实施记录(2026-09-25)

| 文件 | 变更 |
|------|------|
| `Sources/AliyunTokenBarCore/MiMoUsageService.swift` | `envelopeError` / `combine` / `authFailure` / `authRetryCooldownSeconds` / `primaryItem`;`expired` 改 `Bool?`;`parsePlanUsage` 选主窗口 + 外层 percent 回退;三个模型加 `Codable, Sendable` |
| `Sources/AliyunTokenBarCore/MiMoSessionRenewal.swift` | **新增**:`MiMoCookieJar`、`MiMoTransport`/`MiMoHTTPResponse`/`URLSessionMiMoTransport`、`MiMoSessionRenewal` |
| `Sources/AliyunTokenBarCore/MiMoLocalLedger.swift` | **新增**:`MiMoLocalUsageRow`/`MiMoLocalUsage`/`MiMoLocalLedger`/`MiMoLocalUsageStore`/`MiMoLocalUsageCollector`/`MiMoLastUsage`/`MiMoLastUsageStore` |
| `Sources/AliyunTokenBarCore/TokenPlanModel.swift` | `mimoJar` 取代 `mimoCookie` 存储(后者降为计算属性);`persistMiMoJar` 带加载守卫(防 init 误删);鉴权冷却 + 续期重试;`mimoAutoRenewEnabled`;`loadMiMoLocalSide`/`collectMiMoLocal` |
| `Sources/AliyunTokenBarCore/AppConstants.swift` | 新增 `KeychainAccounts.mimoCookieJar` |
| `Sources/AliyunTokenBar/MiMoLoginView.swift` | **新增**:WKWebView 登录窗 + 两域 Cookie 抓取 |
| `Sources/AliyunTokenBar/MiMoCard.swift` | 登录入口、自动续期状态行、错误卡片改引导登录、`fallbackCards`(上次快照)、`localLedgerRow`(本机口径) |
| `Sources/AliyunTokenBar/Settings.swift` | 登录入口 + 自动续期状态 |
| `Sources/Verify/main.swift` | +57 条断言(包络/归并/选优/三态/退避/jar/续期链路/本地账本/快照/E2E 门控) |
| `Sources/Verify/MiMoTransportScript.swift` | **新增**:脚本化 transport |

### 已知未验证项(诚实标注)

1. **`passToken` 静默换发的"最后一跳"**:已实测确认——带真实 `passToken` 请求
   `account.xiaomi.com/pass/serviceLogin` 会 **302 落到 `platform.xiaomimimo.com/sts`**
   (Location 带 `auth=` 票据),平台随后下发新的 `api-platform_serviceToken`。
   机制成立;唯一未能稳定复现的是"完整链路一次跑通",见下方发现 ②。

## 9. 真机联调发现(2026-09-25,装 v1.0.55 后)

装上真机后把 P1 跑成了,并暴露了 2 个**离线测试抓不到**的问题和一个重要运行特性。

### ① `Set-Cookie` 折叠 + 引号保留 → 续期"假成功"(已修)

**症状**:真机日志显示续期成功,但换发的凭据立刻 401。

**根因**(两层,都要踩到才会暴露):

| 层 | 事实 | 后果 |
|---|---|---|
| `URLSession` | `allHeaderFields` 把重复 `Set-Cookie` **折叠成逗号分隔的单值**,而 `Expires=Thu, 01-Jan-1970 …` 自身含逗号 | 手写 `split(",")` / 取首段必然错;原实现只解析了**第一段** |
| `HTTPCookie` | `value` **保留外层引号**:`api-platform_serviceToken=""` 的值是两个引号字符,**不是空串** | 平台的"清除"cookie 被当成有效 token |

两层叠加:原实现取到折叠串第一段 = 空清除 cookie = 非空(引号)→ 判定"续期成功" → 回写废凭据。

**修法**:改用 `HTTPCookie.cookies(withResponseHeaderFields:for:)` 解析(它会正确还原 5 条),
再 `unquote` 剥离外层引号、把 `""` 认成空值剔除。回归断言用**真实折叠头**锁定:
`Sources/Verify/main.swift` 的 `mimo 折叠 Set-Cookie …` 系列。

> 这一条尤其值得记:`MiMoTransportScript` 现在会把 fixture 的多个 Set-Cookie 也用 `", "` 拼成
> 单值后再交给同一解析器 —— 让**每一条**续期断言都走真实的折叠容忍路径,而不是只测理想形状。

### ② 小米 SSO 会对密集自动尝试**软拒绝**(退避是必需的)

连续多次自动跑 `serviceLogin` 后,即使 `passToken` 有效,响应也会退化成
`302 → account.xiaomi.com/fe/service/login`(登录页)。静置几分钟后同一凭据又恢复正常。

后果与启示:
- 应用侧必须把"续期失败"当正常结果处理并**降频**,否则会自锁。—— 已有的
  `authRetryCooldownSeconds`(15/30/60/120 分钟)正好承担这个职责,**不是可选优化而是必需**。
- 手工反复跑探针会把这个现象引出来,验证时要有耐心(本次即因此多花了几轮)。

### ③ 账号域 cookie 会**轮换**,必须回写

成功那一跳的 `Set-Cookie` 里除了平台 cookie,还可能有账号域的新值。
若只回写平台段、丢掉账号段的轮换结果,下一次续期就会失败。
实现已按域拆分回写(`isPlatformDomain` / `isAccountDomain`),并有断言锁定。

### 真机验证结论(v1.0.55,装到 `/Applications` 后)

| 项 | 证据 | 结果 |
|---|---|---|
| P1 WebView 登录 + 两域抓取 | 钥匙串 `mimo-cookie-jar` account 段含 `passToken`/`cUserId`/`deviceId`/`pass_ua`/`identity_session`/`passInfo`/`uLocale`;`canRenew == true` | ✅ |
| P0 过期归类正确 | 日志:`MiMo 刷新失败: MiMo 登录已过期…`(而非"响应格式变化") | ✅ |
| P0 鉴权退避生效 | 日志:`MiMo 鉴权失败,15 分钟内不再重试(第 1 次)`(首档已按 ② 上调) | ✅ |
| 控制台拉取真实数据 | `mimo-last.json`:余额 ¥8.36 / 套餐 standard / 19.19%(2,110,405,051 / 11,000,000,000) | ✅ |
| P2 本机账本在 App 内跑通 | `mimo-local.json` 由 App 写于 09:56:44,内容与手工 SQL 一致 | ✅ |
| 续期链路机制 | 带 passToken 的 serviceLogin 302 落到平台域并带回 `auth` 票据 | ✅ 机制成立 |
| 续期链路一次跑通 | 受 ② 的软拒绝影响,未能稳定复现 | ⚠️ 见 ② |



