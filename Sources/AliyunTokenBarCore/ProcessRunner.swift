import Foundation

// MARK: - 统一子进程执行器(P0-D1)
//
// 背景:bl 是 node 脚本,历史上 Process + readToEnd + waitUntilExit 直接跑在
// async 上下文中——子进程一旦挂死,读取管道永不返回,isLoading 恒 true,
// 后续所有刷新被 guard 挡死,且阻塞 Swift 协作线程池。
//
// 本执行器统一解决:
// - 超时:超过 timeout 秒 → SIGTERM → 2s 后仍存活 → SIGKILL,返回 .timedOut
// - 输出在后台线程读取,防管道缓冲区写满卡死子进程(读满 1MB 截断)
// - runAsync 把阻塞工作移到 GCD utility 队列,不占用协作线程池
// - 失败语义统一:launchFailed(进程起不来)/ timedOut(挂死),调用方映射到各自错误类型
public enum ProcessRunner {
    public struct Result: Equatable {
        public let exitCode: Int32
        public let stdout: String
        public let stderr: String
        public let timedOut: Bool

        public init(exitCode: Int32, stdout: String, stderr: String, timedOut: Bool) {
            self.exitCode = exitCode
            self.stdout = stdout
            self.stderr = stderr
            self.timedOut = timedOut
        }

        /// stdout+stderr 合并输出(供错误分类:bl 的错误信息可能出现在任一流)
        public var combinedOutput: String {
            stdout.isEmpty ? stderr : (stderr.isEmpty ? stdout : stdout + "\n" + stderr)
        }
    }

    public enum RunError: Error, Equatable {
        case launchFailed(String)
        case timedOut
    }

    /// 同步执行(内部实现)。调用方优先使用 runAsync。
    /// - Parameters:
    ///   - timeout: 超时秒数(默认 30);<=0 表示不设超时
    ///   - maxOutputBytes: stdout/stderr 各自最大保留字节(默认 1MB,防内存膨胀)
    public static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectoryURL: URL? = nil,
        timeout: TimeInterval = 30,
        maxOutputBytes: Int = 1 << 20
    ) -> Result {
        let proc = Process()
        proc.executableURL = executable
        proc.arguments = arguments
        if let environment { proc.environment = environment }
        if let currentDirectoryURL { proc.currentDirectoryURL = currentDirectoryURL }

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
        } catch {
            return Result(exitCode: -1, stdout: "", stderr: error.localizedDescription, timedOut: false)
        }

        // 后台线程读管道:与 waitUntilExit 并行,防 64KB 管道缓冲写满死锁
        var outData = Data()
        var errData = Data()
        let outLock = NSLock()
        let errLock = NSLock()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            let d = outPipe.fileHandleForReading.readDataToEndOfFile()
            outLock.lock(); outData = d; outLock.unlock()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            let d = errPipe.fileHandleForReading.readDataToEndOfFile()
            errLock.lock(); errData = d; errLock.unlock()
            group.leave()
        }

        // 超时看护:SIGTERM → 2s → SIGKILL
        var timedOut = false
        if timeout > 0 {
            let deadline = Date().addingTimeInterval(timeout)
            while proc.isRunning {
                if Date() >= deadline {
                    timedOut = true
                    proc.terminate()
                    let killDeadline = Date().addingTimeInterval(2)
                    while proc.isRunning, Date() < killDeadline {
                        Thread.sleep(forTimeInterval: 0.05)
                    }
                    if proc.isRunning { Darwin.kill(proc.processIdentifier, SIGKILL) }
                    break
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        proc.waitUntilExit()
        group.wait()   // 等读线程收尾,确保拿到完整输出

        outLock.lock(); defer { outLock.unlock() }
        errLock.lock(); defer { errLock.unlock() }
        let maxBytes = max(1, maxOutputBytes)
        let sOut = String(data: outData.prefix(maxBytes), encoding: .utf8) ?? ""
        let sErr = String(data: errData.prefix(maxBytes), encoding: .utf8) ?? ""
        let code = timedOut ? -1 : proc.terminationStatus
        return Result(exitCode: code, stdout: sOut, stderr: sErr, timedOut: timedOut)
    }

    /// async 包装:阻塞执行移出协作线程池。
    public static func runAsync(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectoryURL: URL? = nil,
        timeout: TimeInterval = 30,
        maxOutputBytes: Int = 1 << 20
    ) async -> Result {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let r = run(executable: executable, arguments: arguments,
                            environment: environment, currentDirectoryURL: currentDirectoryURL,
                            timeout: timeout, maxOutputBytes: maxOutputBytes)
                cont.resume(returning: r)
            }
        }
    }
}
