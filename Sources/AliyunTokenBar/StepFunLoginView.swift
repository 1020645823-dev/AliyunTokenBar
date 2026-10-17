import SwiftUI
import WebKit
import AliyunTokenBarCore

/// 阶跃星辰开放平台登录窗口(绑定单个账户):内嵌 `StepFunSessionController`
/// 为该账户准备的常驻会话 WebView,用户在窗内完成登录。
///
/// 登录判定 = **页面内同源 fetch 额度 RPC 成功**:
/// - 游客会话(未登录时平台立刻种下 activated:false 的游客 Cookie)→ RPC 401,
///   窗口保持打开等真正登录;
/// - 登录成功 → RPC 返回额度 JSON → 新账户登记(addStepFunAccount)/既有账户
///   置位会话标记、关窗、立即刷数据;
/// - 窗口关闭后该 WebView 由控制器保留(脱离视图树),作为常驻会话页持续供
///   后续刷新使用(Cookie 自动轮换——静态复制的 token 会被滚动轮换作废)。
@MainActor
struct StepFunLoginView: View {
    @StateObject private var model = TokenPlanModel.shared
    @State private var loading = false
    @State private var message = "正在打开平台页面..."
    @Environment(\.dismiss) private var dismiss

    /// 本次登录的账户(nil = 既有首账户/未指定;新账户由调用方预生成 UUID)。
    let accountID: String?
    /// 新账户的展示名(nil = 既有账户)。
    let newAccountLabel: String?

    init(accountID: String? = nil, newAccountLabel: String? = nil) {
        self.accountID = accountID
        self.newAccountLabel = newAccountLabel
    }

    private var effectiveAccountID: String { accountID ?? "main" }
    private let controller = StepFunSessionController.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DesignTokens.spacingS) {
                Image(systemName: "stairs").foregroundStyle(Color.atbBrandStepFun)
                Text(titleText).font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(ATBTextButtonStyle(color: .atbTextSecondary))
            }
            .padding(DesignTokens.spacingM)

            Text("在下方页面完成登录(手机号/扫码)。登录成功后窗口自动关闭,"
                 + "App 会在后台保持此会话以持续读取 Step Plan 额度;登录态失效后再点一次登录即可。")
                .font(.system(size: 10))
                .foregroundStyle(Color.atbTextSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DesignTokens.spacingM)
                .padding(.bottom, DesignTokens.spacingS)

            StepFunSessionWebView(accountID: effectiveAccountID)
                .frame(minWidth: 520, minHeight: 620)

            HStack(spacing: DesignTokens.spacingS) {
                if loading { LoadingRing().frame(width: 14, height: 14) }
                Text(message)
                    .font(.system(size: 12)).foregroundStyle(Color.atbTextSecondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DesignTokens.spacingM - 2)
        }
        .background(Color.atbPanelBackground)
        .task { await pollLogin() }
    }

    private var titleText: String {
        newAccountLabel.map { "登录阶跃开放平台(\($0))" } ?? "登录阶跃星辰开放平台"
    }

    /// 轮询页面内 RPC:游客会话 401(继续等),真实登录返回额度(完成)。
    /// 5s 一轮(游客态也在打真实业务端点,保持温和;MiMo SSO 软拒绝教训)。
    private func pollLogin() async {
        let accountID = effectiveAccountID
        message = "正在监控登录状态(每 5 秒验证一次)..."
        for round in 1...120 {
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            message = "第 \(round) 轮验证中..."
            guard case .json(let raw) = await controller.fetchQuota(accountID: accountID) else {
                // 登录流程会途经 account.stepfun.com(登录域),拿不到平台域响应都算「还没登上」
                message = "会话页面尚未就绪(可能仍在加载/跳转),继续等待..."
                continue
            }
            let data = Data(raw.utf8)
            if let envelope = StepFunUsageService.classifyEnvelope(data: data) {
                switch envelope {
                case .authExpired, .tokenNotPermitted:
                    message = "尚未登录,请在上方页面完成登录..."
                    continue
                default:
                    message = "平台返回异常(\(raw.prefix(60))),稍后重试..."
                    continue
                }
            }
            guard let quota = StepFunUsageService.parseQuota(from: data) else {
                // 登录有效但响应形状未知:也算登录成功(解析层另行排查),不阻塞用户
                AppLog.warning("阶跃[\(accountID)]登录验证:响应可鉴权但解析为空: \(raw.prefix(120))", category: .stepfun)
                message = "登录成功(响应格式待适配,详见日志)"
                _ = await completeLogin()
                return
            }
            loading = true
            message = "登录成功(月池 \(quota.subscription?.usedPctInt ?? 0)%),正在读取额度..."
            guard await completeLogin() else { return }
            message = model.stepfunQuota != nil
                ? "登录成功,已开始读取 Step Plan 额度"
                : "登录成功,但用量拉取失败:\(model.stepfunError ?? "未知原因")"
            loading = false
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            dismiss()
            return
        }
        message = "等待登录超时(10 分钟),可关闭后重试"
    }

    /// 登录成功后的登记:识别身份(oasis_id)→ 防重复添加 → 登记/点亮 → 刷新。
    /// - 既有账户重登:点亮会话标记并刷新身份;
    /// - 新账户但 oasis_id 与已有账户相同(= 同一个阶跃账户):**不重复添加**,
    ///   清掉刚建好的临时会话仓库并关窗(避免重复登录+重复计算);
    /// - 真正的新账户:登记(带身份)并立即刷数据。
    /// - Returns: true = 正常流程继续(调用方关窗);false = 重复登录已处理并关窗。
    @discardableResult
    private func completeLogin() async -> Bool {
        let id = accountID ?? "main"
        let oasis = await controller.currentOasisID(accountID: id)
        if model.stepfunAccounts.contains(where: { $0.id == id }) {
            model.stepfunSessionActive = true
            if let oasis { model.setStepFunAccountOasisID(id, oasis) }
        } else if let oasis,
                  let existing = model.stepfunAccounts.first(where: { $0.oasisID == oasis }) {
            message = "该账户已登录为「\(existing.label)」,不会重复添加"
            AppLog.info("阶跃重复登录被阻止:新会话 \(id) 与 \(existing.id) 同为 oasis_id=\(oasis)", category: .stepfun)
            controller.logout(accountID: id)
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            dismiss()
            return false
        } else {
            let label = newAccountLabel ?? "账户\(model.stepfunAccounts.count + 1)"
            model.addStepFunAccount(StepFunAccount(id: id, label: label, oasisID: oasis))
        }
        // 手机号尾号(面板身份展示优先项;JWT 里没有,走账户中心 RPC 单独取)。
        // 失败不阻塞登录——身份展示回落 oasis_id 尾4位,刷新时还会惰性补抓。
        if let tail = await controller.currentPhoneTail(accountID: id), !tail.isEmpty {
            model.setStepFunAccountPhoneTail(id, tail)
        }
        await model.refreshStepFun(force: true)
        return true
    }
}

/// 控制器会话 WebView 的 SwiftUI 包装:同一实例,登录窗只是临时把它挂进视图树。
struct StepFunSessionWebView: NSViewRepresentable {
    let accountID: String

    func makeNSView(context: Context) -> WKWebView {
        StepFunSessionController.shared.ensureWebView(accountID: accountID)
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
