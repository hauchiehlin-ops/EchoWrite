import UIKit
import AVFoundation

class KeyboardViewController: UIInputViewController {
    var recordButton: UIButton!
    var isRecording = false
    var audioEngine: AVAudioEngine?
    var audioFileUrl: URL?
    
    override func updateViewConstraints() {
        super.updateViewConstraints()
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // 1. 初始化輸入法鍵盤介面 (如：EchoWrite 麥克風圖標按鈕)
        setupKeyboardUI()
        
        // 2. 獲取 App Groups 共用路徑 (因為 Keyboard Extension 權限受限，音訊需放入共用容器中)
        if let sharedContainer = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.echowrite.app") {
            audioFileUrl = sharedContainer.appendingPathComponent("shared_audio.wav")
        }
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
    }
    
    @objc func recordButtonTapped() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
        
        if isRecording {
            stopRecordingAndProcess()
        } else {
            startRecording()
        }
    }
    
    func startRecording() {
        isRecording = true
        recordButton.setTitle("🔴 錄音中 (再按一下完成)", for: .normal)
        recordButton.backgroundColor = .systemRed
        
        // 使用 AVAudioEngine 本地錄音
        audioEngine = AVAudioEngine()
        let inputNode = audioEngine!.inputNode
        let recordingFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!
        
        // 建立 WAV 檔案寫入器
        guard let url = audioFileUrl else { return }
        do {
            let file = try AVAudioFile(forWriting: url, settings: recordingFormat.settings)
            
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
        }
    }
    
    func stopRecordingAndProcess() {
        isRecording = false
        recordButton.setTitle("⚙️ AI 潤飾中...", for: .normal)
        recordButton.backgroundColor = .systemGray
        
        // 停止 AVAudioEngine 錄音
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        
        // 為了避免 Keyboard Extension 的 120MB RAM 限制導致本地 LLM 崩潰，
        // 理想作法是將音訊路徑傳遞給背景運行的 Main App Service，
        // 或者是調用超輕量化封裝。此處為簡化架構，呼叫我們的 Rust Core 處理：
        DispatchQueue.global(qos: .userInitiated).async {
            guard let audioPath = self.audioFileUrl?.path else { return }
            
            do {
                // 直接調用 UniFFI 跨平台接口
                // 這裡傳入寫好的 WAV 音訊檔案與潤飾風格
                let whisperModel = Bundle.main.path(forResource: "whisper-small-q4", ofType: "bin") ?? ""
                let llmModel = Bundle.main.path(forResource: "qwen-2.5-1.5b-q4", ofType: "gguf") ?? ""
                
                // 1. 初始化模型 (如果尚未初始化)
                try echowrite_core.initialize(whisperPath: whisperModel, llmPath: llmModel)
                
                // 2. 進行 ASR + LLM 本地端推理
                let resultText = try echowrite_core.stopRecordingAndProcess(style: "casual")
                
                DispatchQueue.main.async {
                    // 3. 將文字直接插入目前的 App 輸入框 (如 LINE, Safari)
                    self.textDocumentProxy.insertText(resultText)
                    
                    self.recordButton.setTitle("🎙️ 按下說話 (EchoWrite)", for: .normal)
                    self.recordButton.backgroundColor = .systemBlue
                    
                    let generator = UIImpactFeedbackGenerator(style: .light)
                    generator.impactOccurred()
                }
            } catch {
                print("iOS Keyboard: AI processing failed: \(error)")
                DispatchQueue.main.async {
                    self.recordButton.setTitle("❌ 辨識失敗，請重試", for: .normal)
                    self.recordButton.backgroundColor = .systemOrange
                }
            }
        }
    }
}
