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

        // 热修复(2026-08-13):管道读改非阻塞轮询——
        // 旧实现 readDataToEndOfFile + DispatchGroup.wait 在「孙进程继承管道」
        // 场景(bl/npm 偶发 fork 子进程)会永久阻塞,runAsync 永不返回,
        // isLoading 恒真 = 面板一直 loading。非阻塞方案在任何情况下都能返回。
        // 读端设 O_NONBLOCK,用 POSIX read 轮询——
        // 不用 NSFileHandle.availableData:非阻塞描述符上遇 EAGAIN 会抛
        // NSFileHandleOperationException(实测 crash)。
        let outFD = outPipe.fileHandleForReading.fileDescriptor
        let errFD = errPipe.fileHandleForReading.fileDescriptor
        let outFlags = fcntl(outFD, F_GETFL)
        if outFlags >= 0 { _ = fcntl(outFD, F_SETFL, outFlags | O_NONBLOCK) }
        let errFlags = fcntl(errFD, F_GETFL)
        if errFlags >= 0 { _ = fcntl(errFD, F_SETFL, errFlags | O_NONBLOCK) }

        var outData = Data()
        var errData = Data()
        let maxBytes = max(1, maxOutputBytes)
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false

        while true {
            // 排空管道(非阻塞,EAGAIN/EOF 立即返回)
            drainNonBlocking(fd: outFD, into: &outData, maxBytes: maxBytes)
            drainNonBlocking(fd: errFD, into: &errData, maxBytes: maxBytes)

            if !proc.isRunning {
                // 进程已退出:有限轮排空(孙进程可能仍持有管道,最多 ~0.5s 后放弃)
                var rounds = 10
                while rounds > 0 {
                    let before = outData.count + errData.count
                    drainNonBlocking(fd: outFD, into: &outData, maxBytes: maxBytes)
                    drainNonBlocking(fd: errFD, into: &errData, maxBytes: maxBytes)
                    if outData.count + errData.count == before {
                        rounds -= 1
                        Thread.sleep(forTimeInterval: 0.05)
                    } else {
                        rounds = 10
                    }
                }
                break
            }

            if timeout > 0, Date() >= deadline {
                timedOut = true
                proc.terminate()                       // SIGTERM
                let killDeadline = Date().addingTimeInterval(2)
                while proc.isRunning, Date() < killDeadline {
                    drainNonBlocking(fd: outFD, into: &outData, maxBytes: maxBytes)
                    drainNonBlocking(fd: errFD, into: &errData, maxBytes: maxBytes)
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if proc.isRunning {
                    Darwin.kill(proc.processIdentifier, SIGKILL)
                }
                // 最多再等 1s 确认退出;无论死活都收尾返回(看护自身不死锁)
                let confirmDeadline = Date().addingTimeInterval(1)
                while proc.isRunning, Date() < confirmDeadline {
                    Thread.sleep(forTimeInterval: 0.02)
                }
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        if !proc.isRunning { proc.waitUntilExit() }
        let code = timedOut ? -1 : (proc.isRunning ? -1 : proc.terminationStatus)
        let sOut = String(data: outData.prefix(maxBytes), encoding: .utf8) ?? ""
        let sErr = String(data: errData.prefix(maxBytes), encoding: .utf8) ?? ""
        return Result(exitCode: code, stdout: sOut, stderr: sErr, timedOut: timedOut)
    }

    /// 非阻塞排空一个管道读端:EAGAIN/EWOULDBLOCK/EOF 立即返回,不抛异常。
    private static func drainNonBlocking(fd: Int32, into data: inout Data, maxBytes: Int) {
        guard data.count < maxBytes else { return }
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count < maxBytes {
            let n = read(fd, &buf, buf.count)
            if n > 0 {
                data.append(contentsOf: buf.prefix(n).prefix(maxBytes - data.count))
                continue
            }
            // n == 0 → EOF;-1 且 EAGAIN/EWOULDBLOCK/EINTR → 当前无数据;其余 → 放弃
            if n < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return }
            return
        }
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
