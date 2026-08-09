import Foundation

/// 薄封裝層，統一 iOS 端對 UniFFI 產生介面的呼叫方式（與 macOS 手寫 C FFI shim 提供相同函式名稱）。
/// `whisperPath` / `llmPath` 可傳 `nil`，交由 Rust 端自動解析 App Group 共享容器或
/// `~/.echowrite/models` 下已下載完成的模型路徑。
func ewInitialize(llmPath: String?) throws {
    try initialize(llmPath: llmPath)
}


func ewPolishRawText(rawText: String, style: String) throws -> String {
    try polishRawText(rawText: rawText, style: style)
}

func ewPolishRawTextWithContext(rawText: String, style: String, contextBefore: String?) throws -> String {
    try polishRawTextWithContext(rawText: rawText, style: style, contextBefore: contextBefore)
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

func ewGetCustomVocabulary() throws -> [String] {
    try getCustomVocabulary()
}

func ewAddCustomVocabulary(phrase: String) throws {
    try addCustomVocabulary(phrase: phrase)
}

func ewDeleteCustomVocabulary(phrase: String) throws {
    try deleteCustomVocabulary(phrase: phrase)
}

func ewGetPersonalToneSamples() throws -> [String] {
    try getPersonalToneSamples()
}

func ewAddPersonalToneSample(sampleText: String) throws {
    try addPersonalToneSample(sampleText: sampleText)
}

func ewClearPersonalToneSamples() throws {
    try clearPersonalToneSamples()
}

func ewGetTranscriptionHistory(limit: UInt32) throws -> [HistoryRecord] {
    try getTranscriptionHistory(limit: limit)
}

func ewDeleteHistoryItem(id: Int64) throws {
    try deleteHistoryItem(id: id)
}

func ewClearTranscriptionHistory() throws {
    try clearTranscriptionHistory()
}

func ewExportSyncData() throws -> String {
    try exportSyncData()
}

func ewImportSyncData(jsonStr: String) throws -> UInt32 {
    try importSyncData(jsonStr: jsonStr)
}

func ewGetModelProfile() -> ModelProfile {
    getModelProfile()
}

func ewSetModelProfile(profile: ModelProfile) {
    setModelProfile(profile: profile)
}

func ewGetStylePromptPreview(style: String) -> String {
    getStylePromptPreview(style: style)
}

func ewFormatOnly(text: String) -> String {
    formatOnly(text: text)
}

