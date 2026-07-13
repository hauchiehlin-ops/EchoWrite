import UIKit

final class EchoWriteAppDelegate: NSObject, UIApplicationDelegate {
    let processingService = AudioProcessingService()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        EchoWriteShared.configureSharedModelDirectory()

        do {
            // 傳 nil：交由 Rust 端自動解析 App Group 共享容器下已下載的模型路徑。
            try ewInitialize(whisperPath: nil, llmPath: nil)
        } catch {
            print("EchoWrite App: core initialization failed: \(error)")
        }

        // 開始監聽鍵盤送來的錄音處理請求。App 需保持前景或短暫背景執行
        // 才能即時收到 Darwin Notification；若 App 完全被系統終止，
        // 鍵盤端會在逾時後提示使用者重新開啟 App。
        processingService.startListening()

        return true
    }
}
