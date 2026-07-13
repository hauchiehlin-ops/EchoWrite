import UIKit
import AVFoundation

/// Keyboard Extension 只負責錄音與 UI，**絕不**在此進程內呼叫 Whisper / Qwen 推理
/// （iOS 對第三方鍵盤有嚴格的 120MB 記憶體上限，量化後的模型也遠遠超過此限制，
/// 一旦嘗試載入會被系統無預警關閉鍵盤）。
///
/// 實際推理交給主 App 背景處理，兩進程透過 App Group 共享容器交換音訊/結果檔案，
/// 並以 Darwin Notification 互相喚醒（詳見 `EchoWriteShared.swift` / `DarwinNotificationCenter.swift`）。
class KeyboardViewController: UIInputViewController {
    var recordButton: UIButton!
    var isRecording = false
    var isWaitingForResult = false
    var audioEngine: AVAudioEngine?
    var resultTimeoutTimer: Timer?

    /// 主 App 若完全沒有機會執行過（Darwin Notification 永遠不會送達已終止的進程），
    /// 逾時後改為提示使用者先開啟 App 一次。
    private let resultTimeoutSeconds: TimeInterval = 20

    /// 錄音中往左滑動超過此距離（點）即視為取消手勢。
    private let swipeToCancelThreshold: CGFloat = 60

    override func viewDidLoad() {
        super.viewDidLoad()
        EchoWriteShared.configureSharedModelDirectory()
        setupKeyboardUI()
    }

    func setupKeyboardUI() {
        recordButton = UIButton(type: .system)
        recordButton.translatesAutoresizingMaskIntoConstraints = false
        recordButton.setTitle("🎙️ 按下說話 (EchoWrite)", for: .normal)
        recordButton.backgroundColor = .systemBlue
        recordButton.setTitleColor(.white, for: .normal)
        recordButton.layer.cornerRadius = 8
        recordButton.addTarget(self, action: #selector(recordButtonTapped), for: .touchUpInside)

        view.addSubview(recordButton)

        NSLayoutConstraint.activate([
            recordButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            recordButton.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            recordButton.widthAnchor.constraint(equalToConstant: 220),
            recordButton.heightAnchor.constraint(equalToConstant: 50)
        ])

        // 錄音中「往左滑動取消」手勢：不需先停止/等待 AI 處理，直接捨棄錄音。
        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handleSwipeToCancel(_:)))
        recordButton.addGestureRecognizer(panGesture)
    }

    @objc func handleSwipeToCancel(_ gesture: UIPanGestureRecognizer) {
        guard isRecording else { return }
        let translation = gesture.translation(in: view)
        let leftwardOffset = min(0, translation.x) // 只允許往左位移，往右不跟隨

        switch gesture.state {
        case .changed:
            recordButton.transform = CGAffineTransform(translationX: leftwardOffset, y: 0)
            recordButton.alpha = 1.0 - min(0.6, abs(leftwardOffset) / (swipeToCancelThreshold * 3))
        case .ended, .cancelled:
            if leftwardOffset <= -swipeToCancelThreshold {
                cancelRecording()
            } else {
                UIView.animate(withDuration: 0.2) {
                    self.recordButton.transform = .identity
                    self.recordButton.alpha = 1.0
                }
            }
        default:
            break
        }
    }

    @objc func recordButtonTapped() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()

        if isRecording {
            stopRecordingAndDispatchToApp()
        } else if !isWaitingForResult {
            checkPermissionAndStart()
        }
    }

    func checkPermissionAndStart() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                if granted {
                    DispatchQueue.main.async {
                        self.startRecording()
                    }
                }
            }
            return
        } else if status == .denied || status == .restricted {
            recordButton.setTitle("❌ 請至系統設定啟用麥克風", for: .normal)
            recordButton.backgroundColor = .systemOrange
            return
        }

        startRecording()
    }

    func startRecording() {
        guard let audioURL = EchoWriteShared.sharedAudioURL else {
            recordButton.setTitle("❌ 未啟用 App Groups 共享空間", for: .normal)
            recordButton.backgroundColor = .systemOrange
            return
        }

        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("iOS Keyboard: Failed to setup AVAudioSession: \(error)")
            recordButton.setTitle("❌ 音訊初始化失敗", for: .normal)
            recordButton.backgroundColor = .systemOrange
            return
        }

        isRecording = true
        recordButton.setTitle("🔴 錄音中 (再按一下完成)", for: .normal)
        recordButton.backgroundColor = .systemRed

        audioEngine = AVAudioEngine()
        let inputNode = audioEngine!.inputNode
        let recordingFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!

        do {
            if FileManager.default.fileExists(atPath: audioURL.path) {
                try? FileManager.default.removeItem(at: audioURL)
            }
            let file = try AVAudioFile(forWriting: audioURL, settings: recordingFormat.settings)

            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { (buffer, _) in
                do {
                    try file.write(from: buffer)
                } catch {
                    print("iOS Keyboard: Failed to write audio buffer: \(error)")
                }
            }

            audioEngine?.prepare()
            try audioEngine?.start()
        } catch {
            print("iOS Keyboard: Failed to start AVAudioEngine: \(error)")
            recordButton.setTitle("❌ 錄音啟動失敗", for: .normal)
            recordButton.backgroundColor = .systemOrange
            isRecording = false
        }
    }

    /// 往左滑動取消：直接丟棄錄音，不寫入任何請求、不通知主 App、不觸發 AI 推理。
    func cancelRecording() {
        guard isRecording else { return }
        isRecording = false

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil

        if let audioURL = EchoWriteShared.sharedAudioURL {
            try? FileManager.default.removeItem(at: audioURL)
        }

        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.warning)

        UIView.animate(withDuration: 0.2) {
            self.recordButton.transform = .identity
            self.recordButton.alpha = 1.0
        }
        resetButton()
    }

    /// 停止錄音後，**不在本進程執行任何 AI 推理**：
    /// 1. 確認主 App 是否已把模型下載完成（僅檢查檔案是否存在，不載入模型，成本極低）。
    /// 2. 寫入風格偏好，透過 Darwin Notification 通知主 App 開始背景推理。
    /// 3. 等待主 App 回傳的 `resultReady` 通知，逾時則提示使用者。
    func stopRecordingAndDispatchToApp() {
        isRecording = false

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil

        guard ewIsModelReady(kind: .whisper), ewIsModelReady(kind: .llm) else {
            recordButton.setTitle("⚠️ 請先開啟 EchoWrite App 下載模型", for: .normal)
            recordButton.backgroundColor = .systemOrange
            return
        }

        if let styleURL = EchoWriteShared.sharedStyleURL {
            try? "casual".write(to: styleURL, atomically: true, encoding: .utf8)
        }

        isWaitingForResult = true
        recordButton.setTitle("⚙️ AI 潤飾中...", for: .normal)
        recordButton.backgroundColor = .systemGray
        recordButton.isEnabled = false

        DarwinNotificationCenter.observe(.resultReady) { [weak self] in
            DispatchQueue.main.async {
                self?.handleResultReady()
            }
        }

        resultTimeoutTimer?.invalidate()
        resultTimeoutTimer = Timer.scheduledTimer(withTimeInterval: resultTimeoutSeconds, repeats: false) { [weak self] _ in
            self?.handleResultTimeout()
        }

        DarwinNotificationCenter.post(.audioReady)
    }

    private func handleResultReady() {
        guard isWaitingForResult else { return }
        isWaitingForResult = false
        resultTimeoutTimer?.invalidate()
        DarwinNotificationCenter.removeAllObservers(.resultReady)

        guard let resultURL = EchoWriteShared.sharedResultURL,
              let text = try? String(contentsOf: resultURL, encoding: .utf8),
              !text.isEmpty else {
            recordButton.setTitle("❌ 辨識失敗，請重試", for: .normal)
            recordButton.backgroundColor = .systemOrange
            recordButton.isEnabled = true
            return
        }

        textDocumentProxy.insertText(text)
        try? FileManager.default.removeItem(at: resultURL)

        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
        resetButton()
    }

    private func handleResultTimeout() {
        guard isWaitingForResult else { return }
        isWaitingForResult = false
        DarwinNotificationCenter.removeAllObservers(.resultReady)

        recordButton.setTitle("⏱️ 逾時，請先開啟 EchoWrite App", for: .normal)
        recordButton.backgroundColor = .systemOrange
        recordButton.isEnabled = true
    }

    private func resetButton() {
        recordButton.setTitle("🎙️ 按下說話 (EchoWrite)", for: .normal)
        recordButton.backgroundColor = .systemBlue
        recordButton.isEnabled = true
    }
}
