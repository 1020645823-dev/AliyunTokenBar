import Foundation

// MARK: - 检查更新(P1-C1)
//
// GitHub Releases API 比对版本,提示 + 跳转下载页(不下载不安装,零签名成本)。
// 完整自动更新(Sparkle + Developer ID + 公证)列为 P3 可选。
// 数据源:https://github.com/1020645823/AliyunTokenBar/releases

public struct ReleaseInfo: Equatable {
    public let version: String      // 纯数字版本,如 "1.0.28"
    public let name: String         // release 标题
    public let url: URL?            // 下载/详情页
    public init(version: String, name: String, url: URL?) {
        self.version = version
        self.name = name
        self.url = url
    }
}

public enum SelfUpdater {
    public static let repoOwner = "1020645823"
    public static let repoName = "AliyunTokenBar"

    public static var apiURL: URL {
        URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest")!
    }
    public static var releasesPageURL: URL {
        URL(string: "https://github.com/\(repoOwner)/\(repoName)/releases/latest")!
    }

    /// 当前 App 版本(打包自 Info.plist;swift run 裸二进制无版本 → "0.0.0")。
    public static func currentVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// 拉 GitHub 最新 release。失败(网络/限流/无 release)返回 nil,静默。
    public static func fetchLatest(session: URLSession = .shared) async -> ReleaseInfo? {
        var request = URLRequest(url: apiURL)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("CodingTokenBar/\(currentVersion())", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = root["tag_name"] as? String else { return nil }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let url = (root["html_url"] as? String).flatMap(URL.init)
            return ReleaseInfo(version: version, name: (root["name"] as? String) ?? version, url: url)
        } catch {
            AppLog.warning("检查更新失败: \(error.localizedDescription)", category: .general)
            return nil
        }
    }

    /// 语义化版本比较:latest > current → true。解析失败按字符串不等兜底。
    public static func isNewer(_ latest: String, than current: String) -> Bool {
        let a = latest.split(separator: ".").compactMap { Int($0) }
        let b = current.split(separator: ".").compactMap { Int($0) }
        guard !a.isEmpty, !b.isEmpty else { return latest != current }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
