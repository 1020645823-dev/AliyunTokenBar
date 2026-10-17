# Ollama Cloud 用量 API 调研(2026-09-12)

**调研问题**:AliyunTokenBar / CodingTokenBar 能否像现有 7 个数据源一样,轮询 Ollama Cloud(ollama.com)的套餐 / 用量 / 配额数据?

**证据标注**:(a) 2026-09-12 本机直接探测验证(附命令与原始输出);(b) Ollama 官方文档;(c) 社区 / 第三方源码推断(附仓库名与日期);(d) 未知。

---

## 结论(TL;DR)

**可接入,但有维护成本。** 存在真实可机读的 JSON 用量端点 —— `GET https://ollama.com/api/usage` + `Authorization: Bearer <API Key>` —— 但它**未收录于官方文档**(OpenAPI 规格里没有;社区提的正是这个需求的 issue 被静默关闭)。响应结构已被 5 个以上独立开源项目交叉印证,其中包含一个**现成的 Swift 实现**和一个做同样事情的 Rust 菜单栏 App。轮询成本:每次刷新一次 HTTPS GET;用户从 https://ollama.com/settings/keys 粘贴 API Key(与现有各源同款 UX)。JSON **不含重置时间戳**,所以只能显示百分比、无法显示倒计时。附带发现:若用户本机装有 Ollama 桌面端 App 并已登录,`POST http://127.0.0.1:11434/api/me` **零凭据**即返回套餐名(本机实测 `"pro"`)。

---

## 1. https://ollama.com/settings 暴露了什么?

**(a) 有鉴权墙。** 未登录抓取会 303 跳转登录页,无凭据时观察不到任何用量 JSON:

```
$ curl -sS -D - -o /dev/null https://ollama.com/settings
HTTP/2 303
location: /signin
set-cookie: aid=adc0203c-...; Path=/; Max-Age=31536000; HttpOnly; Secure; SameSite=Lax
x-build-commit: 99249c98a76270a682a0bbd1dca1fb5d354fb169
x-build-time: 2026-09-11T16:42:42-07:00
server: Google Frontend
```

- 后端是跑在 Google Frontend 上的自研 Go 服务(`x-build-commit` 头),**不是** Next.js / RSC 应用 —— 未登录时没有 `?_rsc=` / server action 面可枚举,也没有用量数据泄漏。**(a)**
- `/signin` 会 303 跳到 `https://api.workos.com/user_management/authorize?client_id=client_01JX0QMHD43PFFCCNXH82A6K8B&provider=authkit&redirect_uri=https://ollama.com/auth/callback` —— 浏览器会话是 **WorkOS AuthKit** 会话。**(a)**
- 会话 cookie 名 **未登录无法验证 (d)**,但基准测试工具 [Microck/ollama-quota-bench](https://github.com/Microck/ollama-quota-bench)(2026-08-20 有推送)在其已废弃的 HTML 抓取模式里发送 `Cookie: __Secure-session=<value>` 打 `/settings` —— 所以 `__Secure-session` 是**(c)**级证据,且与 WorkOS 惯例一致。
- 设置页显示的内容(来自各抓取器的 HTML 解析器,**c**):"Session usage N% used"、"Weekly usage N% used"、`data-usage-segment` 按钮、"Session resumes in …"、"Weekly limit reached"(模式出自 [ymchun/opencode-ollama-usage](https://github.com/ymchun/opencode-ollama-usage) 与 oqb 的 `parse_ollama_settings`)。可见 **HTML 里有重置倒计时,而 JSON API 没有**。

## 2. 用量端点:`GET https://ollama.com/api/usage`

**端点存在 —— (a) 已验证。** 无有效 key 时:

```
$ curl -sS -D - -H "Authorization: Bearer sk-fake-probe-000" https://ollama.com/api/usage
HTTP/2 401
content-type: application/json
{"error":"invalid credentials"}

$ curl -sS -o /dev/null -w "%{http_code}" -X POST https://ollama.com/api/usage
405        # method-not-allowed ⇒ GET 路由确实存在
```

未鉴权端点普查 **(a)**:`/api/usage` GET→401 / POST→405(存在);`/api/subscription`、`/api/account`、`/api/billing`、`/api/credits`、`/api/quota`、`/api/user/usage`、`/api/plans`、`/api/me/usage` 全部 404;`/api/tags` GET → **200 公开**(返回云端模型库,非账户数据)。`https://api.ollama.com/` → 301 跳 `https://ollama.com/`,**API 主机就是 `https://ollama.com`,不存在独立的 api 主机**。**(a)**

**响应结构(c —— 5 个以上仓库交叉印证;无真实 key 无法亲自验证)。** 活体验证样本来自 [akitaonrails/ai-usagebar `docs/ollama-setup.md`](https://github.com/akitaonrails/ai-usagebar/blob/main/docs/ollama-setup.md)(Rust 菜单栏 App,478★,2026-09-11 有推送;作者标注 "Live-verified shape",数字已打码):

```json
{
  "limits": {
    "session": { "usage": 0.82, "models": [{"name": "kimi-k3", "request_count": 180}] },
    "weekly":  { "usage": 0.23, "models": [{"name": "kimi-k3", "request_count": 180}] }
  },
  "activity": { "cost": "0.00000", "period": {"type": "last_4_weeks"} }
}
```

字段语义(除注明外均为 **c**):
- `limits.session.usage`、`limits.weekly.usage` —— **5 小时滚动会话窗**与 **7 天周窗**的 `[0,1]` 小数(窗口长度依据:[decolua/9router](https://github.com/decolua/9router) 标注 "Session (5h) / Weekly (7d) usage %";[longnh0411/ollama-cloud-usage](https://github.com/longnh0411/ollama-cloud-usage) 标注 "usage of 5h and week";[apis.io 限流页](https://apis.io/rate-limits/ollama/ollama-rate-limits/) 标注 "Cloud quotas reset on 5-hour session and 7-day weekly cycles" —— 未经验证的聚合站)。
- `limits.monthly.usage` —— **约 2026-09 起新增**,随 credits 计费模型引入;[mpartipilo/ollama-cloud-usage](https://github.com/mpartipilo/ollama-cloud-usage)(2026-09-03 推送):"Since Sept 2026 Ollama reports a single `limits.monthly` window … instead of the old `session`/`weekly` GPU-time quotas"。[lidge-jun/opencodex 的 `parseOllamaCloudQuota`](https://github.com/lidge-jun/opencodex) 采取防御式写法,**三个窗口都读**,哪个存在用哪个。**结论:窗口是否存在是可变的,必须宽容解析。**
- `limits.*.models[]` —— 该窗口内每模型的 `{name, request_count}`。
- `activity.cost` —— 近 4 周消费,**字符串**形式的美元;`activity.period.type` = `"last_4_weeks"`。
- **JSON 里没有重置时间戳,也没有套餐名**(ai-usagebar:"The JSON does not carry reset timestamps or a plan name (those exist only in the HTML UI)";mpartipilo 持同样看法 —— `activity.period` 是滚动窗口,与月度重置周年日无关)。
- 仅付费 / 超额语义近期有变动;耗尽时的信号是 HTTP 429(官方:[docs.ollama.com/api/errors](https://docs.ollama.com/api/errors) 列出 "429: Too Many Requests (e.g. when a rate limit is exceeded)"),报文体含 "session usage limit" / "weekly usage limit" 之类字符串(c:[hermes-agent issue #65563](https://github.com/NousResearch/hermes-agent/issues/65563)、[OmniRoute issue #3709](https://github.com/diegosouzapw/OmniRoute/issues/3709))。

**状态:未文档化。** Ollama 官方 `docs/openapi.yaml` 中没有任何 usage/account/quota 端点(2026-09-12 grep:只有 generate/chat/embed/tags/ps/show/create/copy/pull/push/delete/version)。[ollama/ollama#15663](https://github.com/ollama/ollama/issues/15663)"Expose account quota/usage details via Ollama Cloud API"(2026-04-18 开,已关闭)证实在 2026-04 尚无程序化配额;维护者在帖内从未回复,社区端点是在其后出现的。**所有**探测过的 ollama.com 响应里都没有出现 `x-ratelimit-*` 或 `retry-after` 头 **(a)**;开源 Go 服务端(`server/routes.go`)也完全没有限流 / 配额 / 用量处理(grep,2026-09-12)—— 计量完全在 ollama.com 服务端侧。

## 3. 账户 / 套餐端点:`POST /api/me` —— 本机实测可用

Ollama 自家客户端定义了 `Whoami()` → `POST /api/me`(`api/client.go`,返回 `UserResponse{ID, Email, Name, Bio, AvatarURL, FirstName, LastName, Plan}` —— `api/types.go:974-984`)。本机 daemon 将其代理到 `https://ollama.com/api/me`,用本机 CLI 私钥签名(`server/routes.go:2189-2241 WhoamiHandler`;签名 = 用 `~/.ollama/id_ed25519` 对 `"POST,/api/me?ts=<unix>"` 做 Ed25519,见 `api/client.go` + `server/cloud_proxy.go`)。

**本机实测 (a):**

```
$ curl -sS -X POST http://127.0.0.1:11434/api/me
HTTP 200 → {"id":"<uuid>","email":"…","name":"…","avatarurl":"…","plan":"pro"}   (值已打码)

$ curl -sS http://127.0.0.1:11434/api/status
{"cloud":{"disabled":false,"source":"none"}}

$ curl -sS -X POST https://ollama.com/api/me        # 上游,不带鉴权
HTTP/2 401 {"error":"invalid credentials"}
```

所以:**只要用户运行着 Ollama 桌面端 / daemon 且已登录(`ollama signin`),套餐名可零密钥获取**。上游未鉴权探测证实该路由存在(401 而非 404)。**(a)**

## 4. 套餐结构与用量条该显示什么

来自 https://ollama.com/pricing(2026-09-12 抓取,**b** —— Ollama 约 2026-09 切换为按 token 计费的 usage credits):

| 档位 | 价格 | 含赠 credits | 并发请求 |
|---|---|---|---|
| Free | $0 | "Starter usage credits" | 1 |
| Pro | $20/月 | $60/月 | 3 |
| Max | $100/月 | $300/月 | 10 |
| Team | $500/月 | $1,000/月(团队共享) | 10 |
| Enterprise | 定制 | — | — |

官方明示机制 **(b)**:"Usage is measured in tokens at each model's rates";"included usage resets monthly on the same day of the month your subscription started";不结转;达含赠用量的 90% 发邮件提醒;超出并发上限的请求排队;工作日 12:00–18:00 UTC 为高峰价。**未公布任何每小时 / 每日请求上限或 GPU 小时数。**

用量条该显示什么:JSON 给的是**窗口内百分比**(session/weekly/monthly),即与现有各源一致的"百分比"展示,而非 token 倒计数。重置时间**不在** payload 里:月度按订阅周年日重置(具体日不暴露),会话是滚动 5 小时窗(只有 web HTML 里有 "resumes in HH:MM")。现实设计:**2–3 条百分比条**;5 小时窗可选本地推算倒计时;`activity.cost` 作为副行。

## 5. 鉴权:轮询器该走哪条路?

| 路径 | 结论 |
|---|---|
| **API Key**(`Authorization: Bearer <key>`,来自 https://ollama.com/settings/keys,主机 `https://ollama.com`) | **推荐。** Header/主机有官方文档 **(b)**([docs/cloud.mdx](https://github.com/ollama/ollama/blob/main/docs/cloud.mdx):`curl https://ollama.com/api/chat -H "Authorization: Bearer $OLLAMA_API_KEY"`)。它同样能开 `/api/usage` 属 **(c)** —— 5 个以上项目依赖此点。注意 **(c)**:ai-usagebar 的排查笔记指出 `GET /api/usage` **会以 401 拒绝 CLI 的 Ed25519 会话** —— 只有真 API Key 有效。 |
| **浏览器 cookie** `__Secure-session` | 可行但不推荐:需要抓 `/settings` HTML(按 oqb 对两种模式的分割,JSON API 不接受该 cookie —— 我方未实测);oqb 已把该模式标为 "deprecated";cookie 过期与我们的 MiMo / MiniMax 源是同一类故障。**(c)** |
| **本机 daemon 代理**(`http://127.0.0.1:11434`) | `/api/me` 可用(**a** 已验证)拿套餐名;`/api/usage` 在 daemon 上**不存在**(404,ai-usagebar 文档 **c** + `server/routes.go` 全路由表 **a**)。不是密钥,但仅在用户装了 Ollama 且已登录时有效。 |

CLI 没有 `whoami` 子命令(`ollama --help`:serve/create/show/run/stop/pull/push/signin/signout/list/ps/cp/rm/launch/help —— **a**);`ollama signin` 是把 `~/.ollama/id_ed25519` 绑定到账户,那是**注册表(registry)凭据**。

## 6. macOS 本机产物(全部 2026-09-12 探测,密钥已打码 —— **a**)

| 路径 | 内容 | 有用? |
|---|---|---|
| `~/.ollama/id_ed25519`(+ `.pub`) | Ed25519 注册表凭据(私钥,387 B) | 否 —— 被 `/api/usage` 拒绝 |
| `~/.ollama/config.json` | `{"integrations":{"chatgpt":{"models":["deepseek-v4.1-flash:cloud"]}}}` | 否 |
| `~/.ollama/server.json` | `{"disable_ollama_cloud": false}` | 仅云端开关 |
| `~/.ollama/cache/model-recommendations.json`、`launch/`、`logs/` | 推荐缓存、会话标记、服务日志 | 否,日志里无用量 / 配额数据(grep 过) |
| `~/Library/Application Support/Ollama/db.sqlite` | 桌面端聊天库;`users` 表 = `name, email, plan, cached_at` | **是(次要)**:本机缓存套餐名 |
| `~/Library/Application Support/Ollama/ollama.pid` | daemon pid | 进程检测 |
| 桌面端本地 UI 服务(随机端口,如 `127.0.0.1:62170`) | `GET/POST /api/v1/cloud`,需其自身 `Token`(探测:`{"error":"Token is required"}`) | 否 —— 非特权拿不到 token |

## 7. 先例(全部 URL 2026-09-12 验证)

| 项目 | 做了什么 | 端点 / 鉴权 | 新鲜度 |
|---|---|---|---|
| [akitaonrails/ai-usagebar](https://github.com/akitaonrails/ai-usagebar) | Rust **菜单栏 / waybar** 用量 App,Ollama 是一等数据源(478★,2026-09-11 推送)。最佳参考文档:`docs/ollama-setup.md`,含活体验证 JSON | `/api/usage` + Bearer key | 是 |
| [vinzdg/codenotch](https://github.com/vinzdg/codenotch) | **Swift** `Sources/Providers/OllamaProvider.swift` —— `URLSession` GET + Bearer,401/403→needsAuth;key 存登录钥匙串 | `/api/usage` + Bearer key | 是 |
| [mpartipilo/ollama-cloud-usage](https://github.com/mpartipilo/ollama-cloud-usage) | Hermes 状态栏插件;记录了 2026-09 的 `limits.monthly` 迁移;无重置时间戳 | `/api/usage` + Bearer key | 是(2026-09-03) |
| [dkbjornn/ollama-quota](https://github.com/dkbjornn/ollama-quota) | Hermes 状态栏芯片;60 秒一探;记录**无 CORS 头**(对原生 App 无影响) | `/api/usage` + Bearer key | 是(2026-09-12 推送) |
| [Microck/ollama-quota-bench](https://github.com/Microck/ollama-quota-bench) | 配额消耗基准;JSON API 模式 + 已废弃的 cookie 模式(`__Secure-session`) | `/api/usage` + Bearer;`/settings` + cookie | 是(2026-08-20) |
| [ymchun/opencode-ollama-usage](https://github.com/ymchun/opencode-ollama-usage) | OpenCode 插件;**cookie + HTML 抓取** `/settings`(`data-usage-segment`、"Session resumes in") | 仅 cookie | 2026-09-01 |
| [dzackgarza/usage-limits](https://github.com/dzackgarza/usage-limits) | Python CLI,含 Ollama 源(在 ollama#15663 里被当作 workaround 链接) | `/api/usage` | 2026-05 |
| [WyliGr/ollama-quota-api](https://github.com/WyliGr/ollama-quota-api) | Docker 服务,**抓取设置页面** | cookie | 2026-08-09 |

共识:所有可轮询的实现都用 `GET https://ollama.com/api/usage` + Bearer key;cookie / HTML 路径是遗留退路。对 `ollama.com` 发普通 HTTPS GET 不会撞 Cloudflare 机器人墙(只有 `api.ollama.com` 在 Cloudflare 后面 —— 我们不需要它)。**(a/c)**

## 8. 实施建议

**作为第 8 个数据源接入 —— 可行但有维护成本。**

Swift 实现草图(对齐 codenotch 的 `OllamaProvider`):

```
GET https://ollama.com/api/usage
Authorization: Bearer <OLLAMA_API_KEY>   // 用户从 https://ollama.com/settings/keys 粘贴
Accept: application/json
```

- 把 `limits.{session,weekly,monthly}.usage` 解析为可选的 0–1 小数(任一子集都可能出现 —— 结构约 2026-09 从 session/weekly 迁移到 +monthly),`limits.*.models[]` 取每模型明细,`activity.cost`(字符串美元)。
- 用量条:每个窗口一条百分比;**无重置倒计时可用** —— 显示 "—",或客户端推算 5 小时滚动窗;月度重置 = 订阅周年日(具体日未知)。
- 可选增强:`POST http://127.0.0.1:11434/api/me`(无需鉴权)→ 若用户本机跑着 Ollama,拿 `plan` 字符串;拿不到就不显示套餐名。
- 轮询节奏参照先例:60 秒即可(oqb 自我限流;mpartipilo/dkbjornn 用 60 秒)。

已知维护成本 / 不稳定点:
1. **未文档化端点** —— 可能无预警变更或消失(2026-08→09 已经变过一次)。宽容解析;结构漂移绝不能让整个 App 硬失败。ollama#15663 显示官方没有任何承诺。
2. **结构易变**:某些套餐 / 账户可能**缺** `limits.session` / `weekly`(credits 时代只有 `monthly`)。来什么就归一化什么。
3. **无限流响应头、无重置元数据**;唯一的官方耗尽信号是 *chat* API 的 429(官方 docs.ollama.com/api/errors)。
4. cookie 路径可用但最差(过期 + HTML 解析;两个项目已废弃它)。
5. API Key 是完整账户凭据 —— 存钥匙串,绝不写日志。

未知项 (d):`/api/me` 是否接受 Bearer API Key(我们只验证了 Ed25519 签名路径);匿名 / 未付费账户是否返回 `limits` 对象;用量计数器的确切断层 / 一致性延迟(有个基准工具要等读数"稳定"才敢信差值,暗示计数器可能滞后)。

---

## 9. 交叉复核补充(第二遍验证后追加)

### 9.1 该端点经维护者确认,不只是社区逆向

[ollama/ollama#17451](https://github.com/ollama/ollama/issues/17451)"Provide api for querying plan usage" 于 2026-07-29 由 collaborator **`rick-github`** 关闭,回复仅一行:

```console
curl -H "Authorization: $OLLAMA_API_KEY" https://ollama.com/api/usage
```

**(a)** —— 这是该端点最接近官方背书的东西:维护者公开指引用户使用它。该路由仍未收录进 OpenAPI 规格,所以从支持角度仍属未文档化,但它不是偷偷摸摸的抓取。相关的开放需求 [#17421](https://github.com/ollama/ollama/issues/17421) 请求增加 `ollama usage` CLI 命令,即 Ollama 本身承认这个面的需求。

### 9.2 `usage` 单位:小数还是美元 —— 用宽容解析兜住

各实现存在分歧,这是上线前唯一值得用真 key 实测确认的细节:

| 项目 | 对 `limits.*.usage` 的处理 |
|---|---|
| [akitaonrails/ai-usagebar](https://github.com/akitaonrails/ai-usagebar) `src/ollama/types.rs` | "`usage` is a fraction in `[0.0, 1.0]`",clamp 后 ×100 |
| [vinzdg/codenotch](https://github.com/vinzdg/codenotch) `OllamaUsage.swift` | 小数 —— "0.152 means 15.2% — not dollars" |
| [mpartipilo/ollama-cloud-usage](https://github.com/mpartipilo/ollama-cloud-usage) | "`usage` is a 0–1 fraction of your monthly allowance" |
| [slkiser/opencode-quota](https://github.com/slkiser/opencode-quota) | 校验 `0 ≤ usage ≤ 1`,越界即拒绝 |
| [onllm-dev/onWatch](https://github.com/onllm-dev/onWatch) | 当作**美元**(`MonthlyUsedUSD`),上限由套餐档位推导 |

**四比一支持「小数」**,且包含两个专做 Ollama Cloud 的项目。onWatch 与其自家文档自相矛盾(其安装指南说 Free 档上限"未知",却把读数存成美元、还需要 `OLLAMA_MONTHLY_LIMIT` 覆盖),很可能是误读。**建议:按小数解析;但若取值 > 1.0 则改按"绝对美元 + 套餐档位上限"处理** —— 这个防御分支零成本,无论哪种读法正确都能活。

### 9.3 套餐档位在本类机器上可免费获取

本机实测 **(a)**:`POST http://127.0.0.1:11434/api/me` → `{"...","plan":"pro"}`,完全无需凭据;另外桌面端 App 会把 `name,email,plan` 缓存在 `~/Library/Application Support/Ollama/db.sqlite`(`users` 表;本机该表当前为空,因为 App 自身尚未完成登录刷新)。因此 Swift App 应把套餐名当**可选增强** —— 本机 daemon 有响应就读 `/api/me`,绝不让用量条依赖它。

### 9.4 与本项目架构的契合

新增 Ollama Cloud = 一个新的 `ProviderKind` case(`ollama`),Core 里一个新 `OllamaUsageService.swift`(沿用 `MiMoUsageService` 的「私有 API + 凭据」模板,把 Cookie 换成 Bearer),一个钥匙串条目(`ollama-api-key`),以及解析函数的 `Verify` fixture —— 若要在菜单栏显示两个百分比,再加第 9 列。百分比语义(`limits.session.usage`、`limits.weekly.usage`)正好对应现有 5h/周列形态(智谱 / Kimi),这是最接近的既有先例。

---

## 10. 落地实现记录(2026-09-12 已完成)

本节为调研结论的实际落地,已通过 `swift build` + `swift run Verify`(**500 条断言 ALL PASS**)。

### 10.1 新增/改动文件

| 文件 | 改动 |
|---|---|
| `Core/OllamaQuotaModel.swift` | 新增:`OllamaWindow`/`OllamaModelUsage`/`OllamaQuota` 模型 + `OllamaPlan.normalizedPct/monthlyCapUSD` 纯函数 |
| `Core/OllamaUsageService.swift` | 新增:`fetchQuota`(云端用量 + 本机档位并行)、`parseQuota`、`classifyHTTP`、`fetchLocalPlan` |
| `Core/ProviderRegistry.swift` | `ProviderKind` 加 `ollama`(8 case → 9 case;插入在 minimax 与 system 之间) |
| `Core/AppConstants.swift` | Keychain account `ollama-api-key` |
| `Core/AppLogger.swift` | Category 加 `ollama` |
| `Core/MenuBarTable.swift` | `MenuBarColumnKind` 加 `ollama`(图标位在 minimax 后);`columns(...)` 加 4 个参数;新增 `ollamaColumn` 形态自适应 + 一个显式标签的双值列 init |
| `Core/TokenPlanModel.swift` | `ollamaQuota/ollamaAPIKey/ollamaError/ollamaConfigured` 状态、`refreshOllama`/`clearOllama`、`isConfigured`/`refresh(provider:)`/`startTimer` 接线、告警与每日摘要条目、历史快照 |
| `Core/HistoryStore.swift` | `UsageSnapshot` 加 `ollamaMonthly/ollamaSession/ollamaWeekly`;`series()` 加 3 条映射 |
| `App/Menu.swift` | `ProviderTab` 加 `.ollama`(tab 顺序在 minimax 后、本机前)、内容切换接 `OllamaCard()` |
| `App/OllamaCard.swift` | 新增:品牌行 + 动态环组(按接口实际返回的窗口出 slot)+ 模型明细行 + 4 周消费行 |
| `App/PanelDesign.swift` | 品牌色 `atbBrandOllama` + `ProviderBrand` 映射 |
| `App/Settings.swift` | 服务页新增 Ollama Cloud 配置卡(粘贴 API Key / 立即刷新 / 移除) |
| `App/NotificationManager.swift` | 告警 provider 名 "Ollama Cloud" |
| `Verify/main.swift` | 新增 38 条 `ollama` 断言;registry 断言由 8 源改 9 源;`mtCols` 加 4 个参数 |

### 10.2 实现期踩到的两个真问题

1. **窗口形态双态必须显式标签**。`MenuBarTableColumn` 的两个既有 init 都从 `kind` 取默认标签,而 `kind.primaryLabel` 对 Ollama 只能有一个值。新计费(月度单值列)需要「月度」、旧计费(session+weekly 双值列)需要「5小时」—— 初版复用双值 init 导致旧套餐 tooltip 错标「月度」。已加显式标签 init 并补断言锁定。
2. **本机构建必须指定 SDK**。默认 `MacOSX27.0.sdk` 缺 SwiftUI 宏插件(`SwiftUIMacros.StateMacro` 找不到),App/Verify 目标构建失败;**Core 目标不受影响**,所以只看 Core 编译会误判为通过。改用 `SDKROOT=…/MacOSX26.5.sdk` 后全绿。已写入 CLAUDE.md 命令段。

### 10.3 端到端验证

- `fetchLocalPlan()` 走真实 daemon 实测返回 `pro`(与手工 `curl -X POST 127.0.0.1:11434/api/me` 一致)—— 套餐档位增强路径可用。
- 解析层用三段 fixture 锁定:新计费 monthly-only、旧计费 session+weekly、三窗口并存(取 monthly 为主);另覆盖数字字符串、0 请求数模型丢弃、缺 activity、畸形 JSON。
- 单位歧义(`usage` 小数 vs 美元)用 `OllamaPlan.normalizedPct` 兜底并断言(0.82→82%;30 且 plan=pro→50%;无档位时钳 100)。
- ⚠️ **仍待真 key 实测**:实际账号返回的是哪个窗口子集、`usage` 单位最终口径。用户配置 API Key 后,面板 Ollama 卡与设置页状态行会直接显示实际形态;届时按实测结果决定是否收紧解析。

---

## 更新 2026-10-09:响应结构变更(实测,旧结构已从服务端消失)

**现象**:用户面板 Ollama 卡突然只剩「月度额度 —」(刷新成功但无数据)。

**根因**:`GET /api/usage` 换了响应结构 —— 旧的 `limits.{monthly,session,weekly}.usage`(0-1 小数)与 `activity.cost` 整个消失,改为**按天美元用量报表**。用真实 Key 实测(带 `Authorization: Bearer`,HTTP 200):

```json
{
  "range": "7d", "scope": "self", "granularity": "day",
  "from": "2026-10-02T00:00:00Z", "until": "2026-10-09T12:12:21Z",
  "totals": { "request_count": 18686, "usage_usd": 56.99595,
              "input_tokens": 3150210992, "cached_input_tokens": 3092157928, "output_tokens": 35327722 },
  "buckets": [ { "from": "...", "until": "...", "request_count": 3341, "usage_usd": 5.97489, "...": "...", "partial": true }, ... ]
}
```

新响应**不含任何额度/限额字段**;旧解析器解码出 `limits=nil` → 三窗口全空 → `parse` 失败 → 卡片走不可用行。

**接口参数(实测)**:

| 请求 | 结果 |
|---|---|
| `?range=30d` | ✅ 200,30 个日桶(默认不传是 `7d`) |
| `?range=month` / `90d` | 400 `range must be 24h, 7d, or 30d` |
| `&granularity=hour` | 400 `unsupported or repeated parameter: granularity` |
| `POST /api/me`(带 Key) | ✅ 200 `{"ID":"…","Email":"…","Plan":"max"}` —— **档位权威来源**,daemon 未运行也能拿 |
| `GET /api/me` | 405(必须 POST) |
| `/api/limits`、`/api/subscription` 等 | 404(无独立限额端点) |

**实测账号**:Plan=`max`(月含赠额度 $300);近 7 天消费 $56.99、近 30 天 $167.51(≈55.8% 月额度)。

**适配方案(v1.0.68)**:

- 拉取固定 `?range=30d`(与"月度额度"同口径;默认 7d 会把占比严重低估);
- 新模型 `OllamaQuota`:近 30 天消费/请求数、日桶尾部 7 天汇总、日均;占比 = 消费 ÷ 档位额度;
- 档位探测改**远程 `POST /api/me` 优先、本机 daemon 兜底**(`decodePlan` 同时认 `Plan`/`plan` 两个 key);
- 档位可得 → 占比环;不可得(free 档无额度表/探测失败)→ 绝对金额 hero(MiMo 余额卡范式),不编百分比;
- 菜单栏列标签「月度」→「30天」(滚动窗口口径,非计费周期);
- 旧 `limits` 结构 fixture 断言转为"→ nil(结构已消失)",防止回退时静默错位。
