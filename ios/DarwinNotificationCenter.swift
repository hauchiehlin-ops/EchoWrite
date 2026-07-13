import Foundation

/// 跨進程事件：Keyboard Extension 與主 App 是完全獨立的兩個進程，
/// 唯一能即時「叫醒」對方的機制是系統層級的 Darwin Notification Center
/// （App Group 共享容器只能傳資料，不能主動通知）。
enum EchoWriteDarwinNotification: String {
    /// Keyboard Extension → 主 App：音訊已寫入共享容器，請開始本地端推理。
    case audioReady = "com.echowrite.app.audioReady"
    /// 主 App → Keyboard Extension：推理完成，結果已寫入共享容器。
    case resultReady = "com.echowrite.app.resultReady"
}

/// 薄封裝系統的 Darwin Notify Center (`CFNotificationCenterGetDarwinNotifyCenter`)。
///
/// 重要限制：Darwin Notification 只傳遞「事件發生了」的訊號，不攜帶任何資料
/// （實際資料一律透過 `EchoWriteShared` 的共享容器檔案傳遞），且只有在
/// **接收端進程仍存活**（前景執行，或仍在背景保留 run loop）時才能收到；
/// 若主 App 已被系統徹底終止，Keyboard Extension 送出的通知會遺失。
/// 因此 Keyboard 端一律搭配逾時機制，逾時後提示使用者需先開啟 EchoWrite App 一次。
enum DarwinNotificationCenter {
    private static var handlers: [String: [() -> Void]] = [:]

    static func post(_ name: EchoWriteDarwinNotification) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name.rawValue as CFString),
            nil, nil, true
        )
    }

    /// 註冊監聽（可重複呼叫以疊加多個 handler）。
    static func observe(_ name: EchoWriteDarwinNotification, handler: @escaping () -> Void) {
        if handlers[name.rawValue] == nil {
            handlers[name.rawValue] = []
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                nil,
                { _, _, receivedName, _, _ in
                    guard let receivedName = receivedName else { return }
                    let key = receivedName.rawValue as String
                    DarwinNotificationCenter.handlers[key]?.forEach { $0() }
                },
                name.rawValue as CFString,
                nil,
                .deliverImmediately
            )
        }
        handlers[name.rawValue]?.append(handler)
    }

    /// 移除指定事件的所有監聽（例如逾時或元件銷毀時清理）。
    static func removeAllObservers(_ name: EchoWriteDarwinNotification) {
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            CFNotificationName(name.rawValue as CFString),
            nil
        )
        handlers[name.rawValue] = nil
    }
}
