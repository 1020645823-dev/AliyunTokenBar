import Foundation
import AliyunTokenBarCore

typealias MiMoError = MiMoUsageService.MiMoError

/// 脚本化 transport:按调用顺序吐出预置响应,用于离线驱动 MiMo 续期链路。
/// 真机端到端由 `MIMO_RENEW_E2E=1` 门控集成断言覆盖;此处锁的是**编排契约**。
///
/// ⚠️ 预置的 `setCookies` 是**单行** Set-Cookie 串,发送时用 ", " 拼成单值再交给
/// `MiMoResponseCookie.parseHeaderFields` —— 刻意复现 URLSession 的响应头折叠行为,
/// 让每条续期断言都走真实的折叠容忍解析器(真机曾因手写 split 而"假成功")。
final class MiMoTransportScript: MiMoTransport {
    struct Step {
        var status: Int
        var location: String?
        var setCookies: [String]
        var body: Data
        var error: MiMoError?

        init(status: Int = 200, location: String? = nil,
             setCookies: [String] = [], body: Data = Data(), error: MiMoError? = nil) {
            self.status = status
            self.location = location
            self.setCookies = setCookies
            self.body = body
            self.error = error
        }
    }

    private var steps: [Step]
    /// 已发出的请求(断言 URL / Cookie 头用)
    private(set) var requests: [URLRequest] = []

    init(steps: [Step]) { self.steps = steps }

    func send(_ request: URLRequest) async -> Result<MiMoHTTPResponse, MiMoError> {
        requests.append(request)
        guard !steps.isEmpty else { return .failure(.unknown("script exhausted")) }
        let step = steps.removeFirst()
        if let error = step.error { return .failure(error) }
        let url = request.url ?? URL(string: "https://platform.xiaomimimo.com")!
        let cookies = MiMoResponseCookie.parseHeaderFields(
            ["Set-Cookie": step.setCookies.joined(separator: ", ")], for: url)
        return .success(MiMoHTTPResponse(statusCode: step.status,
                                         location: step.location,
                                         setCookies: cookies,
                                         body: step.body))
    }
}
