import Foundation

/// 主 App 與 Keyboard Extension 共用的 App Group 常數與共享容器路徑。
/// 此檔案同時被兩個 Target 引用，是兩個進程之間唯一的資料交換媒介
/// （因為 Keyboard Extension 出於 120MB 記憶體限制，不能自行載入
/// Whisper / Qwen 模型，必須把音訊丟給主 App 背景處理）。
enum EchoWriteShared {
    static let appGroupId = "group.com.echowrite.app"

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId)
    }

    /// Keyboard Extension 寫入的錄音檔。
    static var sharedAudioURL: URL? {
        containerURL?.appendingPathComponent("shared_audio.wav")
    }

    /// 主 App 寫入的推理結果（本地端 ASR + LLM 潤飾後文字）。
    static var sharedResultURL: URL? {
        containerURL?.appendingPathComponent("shared_result.txt")
    }

    /// Keyboard Extension 寫入的重組風格偏好（"casual" / "professional" / "smart"）。
    static var sharedStyleURL: URL? {
        containerURL?.appendingPathComponent("shared_style.txt")
    }

    /// 兩個進程共用的模型存放目錄（取代各自沙盒內互不相通的 `~/.echowrite/models`）。
    static var sharedModelsDirURL: URL? {
        containerURL?.appendingPathComponent("models", isDirectory: true)
    }

    /// 讓 Rust 核心 (`core/src/models.rs`) 的模型自動解析／下載邏輯改用
    /// App Group 共享容器，使主 App 下載好的模型，Keyboard Extension 也能立即看到。
    /// 必須在呼叫任何 `ew*` 函式（`ewInitialize` / `ewIsModelReady` / `ewStartModelDownload`）之前執行一次。
    static func configureSharedModelDirectory() {
        guard let dir = sharedModelsDirURL else {
            print("EchoWrite: App Group container unavailable — check 'App Groups' capability & entitlements.")
            return
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("ECHOWRITE_MODEL_DIR", dir.path, 1)
    }
}
