import Foundation
import CryptoKit

/// 阿里云 OpenAPI ACS3 签名与 CLI access token 交换。
/// 长期 AK/SK 只在调用栈内存中出现,不进入 Process 参数、日志或配置文件。
public enum AliyunOpenAPIService {
    public static let host = "modelstudio.cn-beijing.aliyuncs.com"
    public static let path = "/modelstudio/cli/generateAccessToken"
    public static let action = "GenerateCLIAccessToken"
    public static let version = "2026-02-10"

    /// 构造可测试的 ACS3 请求。timestamp/nonce 注入便于 Verify 固定签名输入。
    public static func makeTokenRequest(
        credential: AliyunOpenAPICredential,
        timestamp: String = ISO8601DateFormatter().string(from: Date()),
        nonce: String = UUID().uuidString
    ) -> URLRequest {
        let body = Data()
        let bodyHash = sha256Hex(body)
        let headers: [(String, String)] = [
            ("content-type", "application/json"),
            ("host", host),
            ("x-acs-action", action),
            ("x-acs-content-sha256", bodyHash),
            ("x-acs-date", timestamp),
            ("x-acs-signature-nonce", nonce),
            ("x-acs-version", version)
        ].sorted { $0.0 < $1.0 }
        let canonicalHeaders = headers.map { "\($0.0):\($0.1)\n" }.joined()
        let signedHeaders = headers.map(\.0).joined(separator: ";")
        let canonicalRequest = [
            "POST", path, "", canonicalHeaders, signedHeaders, bodyHash
        ].joined(separator: "\n")
        let stringToSign = "ACS3-HMAC-SHA256\n\(sha256Hex(Data(canonicalRequest.utf8)))"
        let signature = hmacHex(key: credential.accessKeySecret, message: stringToSign)
        let authorization = "ACS3-HMAC-SHA256 Credential=\(credential.accessKeyID),SignedHeaders=\(signedHeaders),Signature=\(signature)"

        var request = URLRequest(url: URL(string: "https://\(host)\(path)")!)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue(action, forHTTPHeaderField: "x-acs-action")
        request.setValue(bodyHash, forHTTPHeaderField: "x-acs-content-sha256")
        request.setValue(timestamp, forHTTPHeaderField: "x-acs-date")
        request.setValue(nonce, forHTTPHeaderField: "x-acs-signature-nonce")
        request.setValue(version, forHTTPHeaderField: "x-acs-version")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        return request
    }

    public static func parseAccessToken(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return findToken(in: root)
    }

    /// 使用 AK/SK 交换短期 CLI access token。
    public static func exchangeAccessToken(
        credential: AliyunOpenAPICredential,
        session: URLSession = .shared
    ) async throws -> String {
        let request = makeTokenRequest(credential: credential)
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw BlAuthError.invalidResponse
            }
            guard (200..<300).contains(http.statusCode) else {
                if http.statusCode == 401 || http.statusCode == 403 { throw BlAuthError.unauthorized }
                throw BlAuthError.network("OpenAPI HTTP \(http.statusCode)")
            }
            guard let token = parseAccessToken(data), !token.isEmpty else {
                throw BlAuthError.invalidResponse
            }
            return token
        } catch let error as BlAuthError {
            throw error
        } catch {
            throw BlAuthError.network(error.localizedDescription)
        }
    }

    private static func findToken(in value: Any) -> String? {
        if let object = value as? [String: Any] {
            for key in ["cliAccessToken", "access_token", "accessToken"] {
                if let token = object[key] as? String, !token.isEmpty { return token }
            }
            for child in object.values {
                if let token = findToken(in: child) { return token }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let token = findToken(in: child) { return token }
            }
        }
        return nil
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func hmacHex(key: String, message: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: Data(key.utf8)))
        return mac.map { String(format: "%02x", $0) }.joined()
    }
}
