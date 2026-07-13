import Foundation

func ewInitialize(whisperPath: String, llmPath: String) throws {
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
