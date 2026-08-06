import Foundation

enum EchoWriteStyle: String, CaseIterable, Identifiable {
    case casual = "casual"
    case formal = "formal"
    case email = "email"
    case bilingual = "bilingual"
    case bullet = "bullet"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .casual: return "⚡ 極簡口語"
        case .formal: return "🏛️ 專業公文"
        case .email: return "✉️ 商務 Email"
        case .bilingual: return "🌐 中英雙語"
        case .bullet: return "📋 條列重點"
        }
    }

    var subtitle: String {
        switch self {
        case .casual: return "去贅字、保留自然口氣、全形標點"
        case .formal: return "轉換為嚴謹公務敬語與行政書面報告"
        case .email: return "自動產生主旨、問候語與完整信件結構"
        case .bilingual: return "中文潤飾段落 + 地道專業英文對照"
        case .bullet: return "Markdown 條列式精簡重點清單"
        }
    }

    var icon: String {
        switch self {
        case .casual: return "sparkles"
        case .formal: return "building.columns.fill"
        case .email: return "envelope.fill"
        case .bilingual: return "globe.asia.australia.fill"
        case .bullet: return "list.bullet.rectangle.portrait.fill"
        }
    }
}

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

    /// Keyboard Extension 寫入的重組風格偏好（"casual" / "formal" / "email" / "bilingual" / "bullet"）。
    static var sharedStyleURL: URL? {
        containerURL?.appendingPathComponent("shared_style.txt")
    }

    /// 即時樂觀排版草稿文字檔
    static var sharedDraftURL: URL? {
        containerURL?.appendingPathComponent("shared_draft.txt")
    }

    /// 游標前文情境 Context 檔
    static var sharedContextURL: URL? {
        containerURL?.appendingPathComponent("shared_context.txt")
    }

    static func setSharedContextBefore(_ context: String) {
        guard let url = sharedContextURL else { return }
        try? context.write(to: url, atomically: true, encoding: .utf8)
    }

    static func getSharedContextBefore() -> String? {
        guard let url = sharedContextURL,
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        return text
    }

    /// 兩個進程共用的模型存放目錄（取代各自沙盒內互不相通的 `~/.echowrite/models`）。
    static var sharedModelsDirURL: URL? {
        containerURL?.appendingPathComponent("models", isDirectory: true)
    }

    /// 儲存當前選取的風格
    static func setSelectedStyle(_ style: EchoWriteStyle) {
        guard let styleURL = sharedStyleURL else { return }
        try? style.rawValue.write(to: styleURL, atomically: true, encoding: .utf8)
    }

    /// 讀取當前選取的風格，預設為 casual
    static func getSelectedStyle() -> EchoWriteStyle {
        guard let styleURL = sharedStyleURL,
              let content = try? String(contentsOf: styleURL, encoding: .utf8),
              let style = EchoWriteStyle(rawValue: content.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return .casual
        }
        return style
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
