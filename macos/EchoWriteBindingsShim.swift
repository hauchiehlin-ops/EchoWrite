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

enum EchoWriteMacCoreError: Error {
    case initializationFailed(Int32)
}

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
