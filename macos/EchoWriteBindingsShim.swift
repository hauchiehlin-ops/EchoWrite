import Foundation

@_silgen_name("echowrite_initialize")
private func c_echowrite_initialize(_ whisperPath: UnsafePointer<CChar>, _ llmPath: UnsafePointer<CChar>) -> Int32

@_silgen_name("echowrite_start_recording")
private func c_echowrite_start_recording() -> Int32

@_silgen_name("echowrite_stop_recording_and_process")
private func c_echowrite_stop_recording_and_process(_ style: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?

@_silgen_name("echowrite_process_audio_file")
private func c_echowrite_process_audio_file(_ audioPath: UnsafePointer<CChar>, _ style: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?

@_silgen_name("echowrite_free_string")
private func c_echowrite_free_string(_ ptr: UnsafeMutablePointer<CChar>?)

@_silgen_name("echowrite_is_model_ready")
private func c_echowrite_is_model_ready(_ kind: Int32) -> Int32

@_silgen_name("echowrite_start_model_download")
private func c_echowrite_start_model_download(_ kind: Int32)

@_silgen_name("echowrite_get_model_download_progress")
private func c_echowrite_get_model_download_progress(
    _ kind: Int32,
    _ downloadedOut: UnsafeMutablePointer<UInt64>,
    _ totalOut: UnsafeMutablePointer<UInt64>,
    _ stateOut: UnsafeMutablePointer<Int32>
)

enum EchoWriteMacCoreError: Error {
    case initializationFailed(Int32)
}

enum EchoWriteModelKind: Int32 {
    case whisper = 0
    case llm = 1
}

enum EchoWriteModelDownloadState: Int32 {
    case notStarted = 0
    case downloading = 1
    case verifying = 2
    case ready = 3
    case failed = 4
}

struct EchoWriteModelProgress {
    let downloadedBytes: UInt64
    let totalBytes: UInt64
    let state: EchoWriteModelDownloadState
}

/// `whisperPath` / `llmPath` 可傳空字串，交由 Rust 端自動解析
/// `~/.echowrite/models` 下已下載的模型檔案路徑。
func ewInitialize(whisperPath: String, llmPath: String) throws {
    let result = whisperPath.withCString { whisper in
        llmPath.withCString { llm in
            c_echowrite_initialize(whisper, llm)
        }
    }
    guard result == 0 else {
        throw EchoWriteMacCoreError.initializationFailed(result)
    }
}

func ewIsModelReady(kind: EchoWriteModelKind) -> Bool {
    c_echowrite_is_model_ready(kind.rawValue) == 1
}

func ewStartModelDownload(kind: EchoWriteModelKind) {
    c_echowrite_start_model_download(kind.rawValue)
}

func ewGetModelDownloadProgress(kind: EchoWriteModelKind) -> EchoWriteModelProgress {
    var downloaded: UInt64 = 0
    var total: UInt64 = 0
    var state: Int32 = 0
    c_echowrite_get_model_download_progress(kind.rawValue, &downloaded, &total, &state)
    return EchoWriteModelProgress(
        downloadedBytes: downloaded,
        totalBytes: total,
        state: EchoWriteModelDownloadState(rawValue: state) ?? .notStarted
    )
}

func ewStartRecording() throws {
    let result = c_echowrite_start_recording()
    guard result == 0 else {
        throw EchoWriteMacCoreError.initializationFailed(result)
    }
}

func ewStopRecordingAndProcess(style: String) throws -> String {
    let ptr = style.withCString { cStyle in
        c_echowrite_stop_recording_and_process(cStyle)
    }
    guard let ptr else { return "" }
    defer { c_echowrite_free_string(ptr) }
    return String(cString: ptr)
}

func ewProcessAudioFile(audioPath: String, style: String) throws -> String {
    let ptr = audioPath.withCString { audio in
        style.withCString { styleString in
            c_echowrite_process_audio_file(audio, styleString)
        }
    }
    guard let ptr else { return "" }
    defer { c_echowrite_free_string(ptr) }
    return String(cString: ptr)
}
