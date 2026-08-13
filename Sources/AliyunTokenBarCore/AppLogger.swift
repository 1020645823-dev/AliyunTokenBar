import Foundation
import OSLog

// MARK: - 结构化日志(P0-A4)
//
// 统一 OSLog 入口:所有状态迁移/刷新结果/错误落日志,线上问题可经
// 「导出诊断包」(设置页)或 Console.app 检索 subsystem。
// 隐私红线:绝不记录 cookie/token/secret 等敏感值,只记录状态与元信息。

public enum AppLog {
    public static let subsystem = "com.zww.aliyuntokenbar"

    public enum Category: String {
        case general
        case bl
        case aliyun
        case opencode
        case kimi
        case deepseek
        case keychain
        case history
        case process

        fileprivate var logger: Logger {
            Logger(subsystem: subsystem, category: rawValue)
        }
    }

    public static func info(_ message: String, category: Category = .general) {
        category.logger.info("\(message, privacy: .public)")
    }

    public static func warning(_ message: String, category: Category = .general) {
        category.logger.warning("\(message, privacy: .public)")
    }

    public static func error(_ message: String, category: Category = .general) {
        category.logger.error("\(message, privacy: .public)")
    }

    public static func debug(_ message: String, category: Category = .general) {
        category.logger.debug("\(message, privacy: .public)")
    }
}
