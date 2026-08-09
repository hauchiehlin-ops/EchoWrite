import Foundation

@_silgen_name("echowrite_set_model_dir")
private func c_echowrite_set_model_dir(_ dirPath: UnsafePointer<CChar>) -> Int32

@_silgen_name("echowrite_initialize")
private func c_echowrite_initialize(_ llmPath: UnsafePointer<CChar>) -> Int32

@_silgen_name("echowrite_polish_raw_text")
private func c_echowrite_polish_raw_text(_ rawText: UnsafePointer<CChar>, _ style: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?

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

@discardableResult
func ewSetModelDir(path: String) -> Bool {
    path.withCString { cPath in
        c_echowrite_set_model_dir(cPath) == 0
    }
}

/// `whisperPath` / `llmPath` 可傳空字串，交由 Rust 端自動解析
/// `~/.echowrite/models` 下已下載的模型檔案路徑。
func ewInitialize(whisperPath: String, llmPath: String) throws {
    let result = llmPath.withCString { llm in
        c_echowrite_initialize(llm)
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


func ewPolishRawText(rawText: String, style: String) throws -> String {
    let ptr = rawText.withCString { raw in
        style.withCString { styleString in
            c_echowrite_polish_raw_text(raw, styleString)
        }
    }
    guard let ptr else { return "" }
    defer { c_echowrite_free_string(ptr) }
    return String(cString: ptr)
}

@_silgen_name("echowrite_polish_text_stream")
private func c_echowrite_polish_text_stream(
    _ rawText: UnsafePointer<CChar>,
    _ style: UnsafePointer<CChar>,
    _ contextBefore: UnsafePointer<CChar>?,
    _ onText: @convention(c) (UnsafePointer<CChar>) -> Void,
    _ onErr: @convention(c) (UnsafePointer<CChar>) -> Void
) -> UnsafeMutablePointer<CChar>?

class StreamManager {
    static var onUpdate: ((String) -> Void)? = nil
    static var onErrorCb: ((String) -> Void)? = nil
}

private func cOnTextUpdate(_ textPtr: UnsafePointer<CChar>) {
    let text = String(cString: textPtr)
    StreamManager.onUpdate?(text)
}
private func cOnError(_ errorPtr: UnsafePointer<CChar>) {
    let error = String(cString: errorPtr)
    StreamManager.onErrorCb?(error)
}

func ewPolishTextStream(rawText: String, style: String, contextBefore: String?, onUpdate: @escaping (String) -> Void, onError: @escaping (String) -> Void) throws -> String {
    StreamManager.onUpdate = onUpdate
    StreamManager.onErrorCb = onError
    
    let ptr = rawText.withCString { raw in
        style.withCString { styleString in
            if let ctx = contextBefore, !ctx.isEmpty {
                return ctx.withCString { ctxString in
                    c_echowrite_polish_text_stream(raw, styleString, ctxString, cOnTextUpdate, cOnError)
                }
            } else {
                return c_echowrite_polish_text_stream(raw, styleString, nil, cOnTextUpdate, cOnError)
            }
        }
    }
    StreamManager.onUpdate = nil
    StreamManager.onErrorCb = nil
    guard let ptr else { return "" }
    defer { c_echowrite_free_string(ptr) }
    return String(cString: ptr)
}
