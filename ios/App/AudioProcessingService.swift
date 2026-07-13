import Foundation

/// 主 App 端的背景推理服務。
///
/// 監聽 Keyboard Extension 送出的 `audioReady` Darwin Notification，
/// 讀取 App Group 共享容器中的錄音檔，執行本地端 Whisper + Qwen 推理
/// （主 App 沒有 Keyboard Extension 的 120MB 限制），完成後把結果寫回
/// 共享容器，再送出 `resultReady` 通知讓鍵盤讀取、插入文字。
final class AudioProcessingService: ObservableObject {
    @Published var isProcessing = false
    @Published var lastError: String?

    private var isListening = false

    func startListening() {
        guard !isListening else { return }
        isListening = true
        DarwinNotificationCenter.observe(.audioReady) { [weak self] in
            self?.handleAudioReady()
        }
    }

    private func handleAudioReady() {
        guard let audioURL = EchoWriteShared.sharedAudioURL,
              FileManager.default.fileExists(atPath: audioURL.path) else {
            return
        }

        let style: String = {
            guard let styleURL = EchoWriteShared.sharedStyleURL,
                  let value = try? String(contentsOf: styleURL, encoding: .utf8) else {
                return "casual"
            }
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }()

        DispatchQueue.main.async {
            self.isProcessing = true
            self.lastError = nil
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var resultText = ""
            do {
                resultText = try ewProcessAudioFile(audioPath: audioURL.path, style: style)
            } catch {
                DispatchQueue.main.async { self.lastError = "\(error)" }
            }

            self.writeResultAndNotify(resultText)
            try? FileManager.default.removeItem(at: audioURL)

            DispatchQueue.main.async { self.isProcessing = false }
        }
    }

    private func writeResultAndNotify(_ text: String) {
        guard let resultURL = EchoWriteShared.sharedResultURL else { return }
        try? text.write(to: resultURL, atomically: true, encoding: .utf8)
        DarwinNotificationCenter.post(.resultReady)
    }
}
