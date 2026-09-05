import Foundation

@main
struct StartupRegressionTests {
    static func main() throws {
        let generation = UUID()
        let data = try JSONSerialization.data(withJSONObject: ["ownerGeneration": generation.uuidString, "pid": 123, "connectionStatus": "connected"])
        let status = try JSONDecoder().decode(BridgeRuntimeStatus.self, from: data)
        precondition(status.belongsTo(generation), "当前进程世代必须可用")
        precondition(!status.belongsTo(UUID()), "旧进程状态不能让新启动误报成功")
        let legacy = try JSONDecoder().decode(BridgeRuntimeStatus.self, from: Data("{\"pid\":123,\"connectionStatus\":\"connected\"}".utf8))
        precondition(!legacy.belongsTo(generation), "磁盘遗留状态不能代替当前进程就绪")
        let snapshot = BridgeSnapshot(currentVersion: "test", isRunning: false, processID: nil, runtimeAvailable: true, runtimeError: nil, daemonConfig: nil, bridgeStatus: nil, pairingSession: nil, trustedDevice: nil, stdoutLogPath: "/tmp/test", stderrLogPath: "/tmp/test")
        precondition(snapshot.statusHeadline == "已停止")
        precondition(snapshot.codexStatusLabel == "已停止")
        print("Mac 状态回归通过：当前世代、旧世代、遗留文件、中文停止状态。")
    }
}
