import Foundation

@main
struct ProcessTests {
    static func main() async throws {
        let node = URL(fileURLWithPath: CommandLine.arguments[1])
        let flood = AsyncProcessRunner(executable: node, arguments: ["-e", "process.stderr.write('x'.repeat(2*1024*1024));process.stdout.write('y'.repeat(2*1024*1024));"])
        try await flood.run(timeout: 5)
        let before = ProcessInfo.processInfo.systemUptime
        let hang = AsyncProcessRunner(executable: node, arguments: ["-e", "process.on('SIGTERM',()=>{});setInterval(()=>{},1000);"])
        do { try await hang.run(timeout: 0.1); preconditionFailure("超时命令不能成功") }
        catch ControlProcessFailure.timeout { }
        precondition(ProcessInfo.processInfo.systemUptime - before < 5)
        let cancel = Task {
            let runner = AsyncProcessRunner(executable: node, arguments: ["-e", "setInterval(()=>{},1000)"])
            try await runner.run()
        }
        cancel.cancel()
        do { try await cancel.value; preconditionFailure("已取消命令不能成功") }
        catch ControlProcessFailure.cancelled { }
        let missing = AsyncProcessRunner(executable: URL(fileURLWithPath: "/remodex-does-not-exist"), arguments: [])
        do { try await missing.run(); preconditionFailure("缺失命令不能成功") }
        catch ControlProcessFailure.launch { }
        await testOperationQueue()
        print("macos_async_process_output_timeout_cancel_and_launch_passed")
    }

    @MainActor
    static func testOperationQueue() async {
        let operations = BridgeOperationQueue()
        var active = 0
        var completed = 0
        let tasks = (0..<12).map { _ in
            Task { @MainActor in
                try await operations.perform {
                    active += 1
                    precondition(active == 1)
                    defer { active -= 1 }
                    try await Task.sleep(for: .milliseconds(5))
                    completed += 1
                }
            }
        }
        for task in tasks { try! await task.value }
        precondition(completed == 12 && !operations.isBusy)
        let waiting = Task { @MainActor in
            try await operations.perform { try await Task.sleep(for: .seconds(30)) }
        }
        while !operations.isBusy { await Task.yield() }
        operations.cancel()
        do { try await waiting.value; preconditionFailure("取消串行操作不得成功") }
        catch is CancellationError { }
        catch { preconditionFailure("取消必须保留错误类型") }
        try! await operations.perform { completed += 1 }
        precondition(completed == 13 && !operations.isBusy)
    }
}
