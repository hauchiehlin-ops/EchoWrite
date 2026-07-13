import Foundation

/// 薄封裝層，統一 iOS 端對 UniFFI 產生介面的呼叫方式（與 macOS 手寫 C FFI shim 提供相同函式名稱）。
/// `whisperPath` / `llmPath` 可傳 `nil`，交由 Rust 端自動解析 App Group 共享容器或
/// `~/.echowrite/models` 下已下載完成的模型路徑。
func ewInitialize(whisperPath: String?, llmPath: String?) throws {
    try initialize(whisperPath: whisperPath, llmPath: llmPath)
}

func ewStartRecording() throws {
    try startRecording()
}

func ewStopRecordingAndProcess(style: String) throws -> String {
    try stopRecordingAndProcess(style: style)
}

func ewProcessAudioFile(audioPath: String, style: String) throws -> String {
    try processAudioFile(audioPath: audioPath, style: style)
}

func ewIsModelReady(kind: ModelKind) -> Bool {
    isModelReady(kind: kind)
}

func ewStartModelDownload(kind: ModelKind) {
    startModelDownload(kind: kind)
}

func ewGetModelDownloadProgress(kind: ModelKind) -> ModelProgress {
    getModelDownloadProgress(kind: kind)
}
