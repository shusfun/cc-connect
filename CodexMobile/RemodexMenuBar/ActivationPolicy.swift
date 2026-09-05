import Foundation

enum ActivationPolicy {
    static func deadline(expiresAt: Double, serverTime: Double, now: Date) -> Date {
        now.addingTimeInterval(max(0, min(300, (expiresAt - serverTime) / 1000)))
    }
    static func delay(retryAfter: Double?, remaining: Double) -> Double {
        min(max(0, remaining), max(3, min(60, retryAfter ?? 3)))
    }
    // 保存失败时绝不发布成功；调用方负责在保存前后记录阶段。
    static func commit(save: () throws -> Void, publish: () -> Void) throws {
        try save()
        publish()
    }
}
