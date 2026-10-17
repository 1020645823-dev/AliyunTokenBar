# 百炼 Token Plan 周限→月限(v1.0.48)

日期:2026-09-23 · 影响:`BlUsageService.parseUsage` 及全部展示层

## 背景

官方调整 Token Plan 个人版限额规则(来源:阿里云百炼官方 Token Plan 个人版 FAQ):

> Token Plan 个人版采用**月限额,限额单位为 Credits**,**无周额度使用限制**;
> 以订阅日为起点每 30 天为一个订阅月,每个订阅月开始时额度自动重置;
> 订阅周期内累计消耗达到套餐额度后暂停服务。

在此之前 5 小时窗口已于 2026-08-15 被官方取消。

## 实测证据(2026-09-23)

`zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage`(bl console call,端点名未变)
现返回**仅月度字段**:

```json
{ "per1MonthPercentage": 0.101517822, "per1MonthResetTime": 1792425600000 }
```

- `per5Hour*`、`per1Week*` 字段已消失 → 旧代码把周窗按 0 解析,菜单栏恒显 0%(本次修复根因)。
- `per1MonthResetTime` = 1792425600000 ms = 北京时间 2026-10-16 00:00(订阅月重置点)。
- `subscription` / `addon/summary` 两个 RPC 形状未变。
- bl CLI(2.0.1)自带 `usage token-plan` 命令同样只认 5h/周字段,也已过时;
  其 `usage coding-plan`(Coding Plan,另一产品)走 `queryCodingPlanInstanceInfoV2`,
  含 perBillMonth 月窗,与 Token Plan 无关。

## 改动

- `UsageWindows`:三窗口(5h/周/月)全可选 + `activeWindows` 遍历;解析规则统一为
  「两字段均缺失 → 窗口 nil(隐藏,不显 0%)」。
- 展示层主窗口 = 月 ?? 周:菜单栏迷你表格列标签「30天」、云朵/单行样式「30d」、
  进度环外环;面板「月度限额」卡;趋势行/每日汇总「阿里云 月」。
- 通知窗口名:`aliyun/monthly`(NotificationManager 已有「每月限额」文案)。
- 历史:`UsageSnapshot` 新增 `aliyunOneMonth`(旧记录宽容解码为 nil);
  CSV 新列 `aliyunMonthly` 追加在行尾(旧行前缀兼容);达限预测默认窗口改月窗。
- 月窗重置点加入 `scheduleResetBoundaryRefresh` 候选。

## 验证

- `swift run Verify`:`usageMonthlyFixture` 系列断言(5h/周 nil、月 10.15%、
  activeWindows 仅 30d)+ mt 月窗列形态 + CSV/预测断言,ALL PASS。
- `BL_LIVE=1`(借 App AK/SK 短期会话)对真实 RPC 端到端解析通过。
