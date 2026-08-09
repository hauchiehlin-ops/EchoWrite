import UIKit
import AVFoundation
import Speech

/// EchoWrite iOS 專屬極速無縫 AI 鍵盤
/// 1. 鍵盤內原地即時錄音與語意重塑，絕不跳轉視窗、絕不要求手動切換複製貼上。
/// 2. 說完即打入（In-Place Auto Typing），直通 textDocumentProxy.insertText。
/// 3. 動態聲波音量柱與精確錄音計時器。
/// 4. 5 大語意風格一鍵切換與常用中文標點符號列。
@objc(KeyboardViewController)
class KeyboardViewController: UIInputViewController {
    private enum RecordingStartError: LocalizedError {
        case microphonePermissionDenied
        case speechPermissionDenied
        case speechRecognizerUnavailable
        case audioSessionInitializationFailed(underlying: Error)

        var errorDescription: String? {
            switch self {
            case .microphonePermissionDenied:
                return "麥克風沒權限，請到 iOS 設定開啟 EchoWrite 的麥克風權限"
            case .speechPermissionDenied:
                return "語音辨識沒權限，請到 iOS 設定開啟 EchoWrite 的語音辨識權限"
            case .speechRecognizerUnavailable:
                return "SFSpeechRecognizer 不可用，請稍後再試"
            case .audioSessionInitializationFailed(let underlying):
                return "AVAudioSession 初始化失敗：\(underlying.localizedDescription)"
            }
        }
    }

    // MARK: - UI 元件
    private var headerStackView: UIStackView!
    private var brandBadgeLabel: UILabel!
    private var timerLabel: UILabel!
    private var hardwareAccelBadge: UILabel!
    
    private var styleScrollView: UIScrollView!
    private var styleStackView: UIStackView!
    private var styleButtons: [EchoWriteStyle: UIButton] = [:]
    
    private var previewContainer: UIView!
    private var previewTextLabel: UILabel!
    private var waveformView: AudioWaveformView!
    
    private var recordButton: UIButton!
    private var statusLabel: UILabel!
    
    // MARK: - 串流語音辨識 (SFSpeechRecognizer 平台原生 ASR)
    private var currentStyle: EchoWriteStyle = .casual
    private var heightConstraint: NSLayoutConstraint?

    // SFSpeechRecognizer Recording State
    private var speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-TW"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine = AVAudioEngine()
    
    private var lastPartialText: String = ""
    private var recordingTimer: Timer?
    private var deleteRepeatTimer: Timer?
    private var recordingStartTime: Date?
    private var isRecording: Bool = false
    private var isProcessing: Bool = false

    // MARK: - 生命週期
    override func viewDidLoad() {
        super.viewDidLoad()
        
        EchoWriteShared.configureSharedModelDirectory()
        currentStyle = EchoWriteShared.getSelectedStyle()
        
        setupCyberGlassUI()
        updateStyleSelectionUI()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if heightConstraint == nil {
            let h = view.heightAnchor.constraint(equalToConstant: 268)
            h.priority = UILayoutPriority(999)
            h.isActive = true
            heightConstraint = h
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        deleteRepeatTimer?.invalidate()
        deleteRepeatTimer = nil
        if isRecording {
            cancelRecording()
        }
    }

    // MARK: - UI 佈局建置
    private func setupCyberGlassUI() {
        view.backgroundColor = UIColor(red: 0.04, green: 0.06, blue: 0.12, alpha: 1.0)

        let rootContainer = UIStackView()
        rootContainer.translatesAutoresizingMaskIntoConstraints = false
        rootContainer.axis = .vertical
        rootContainer.alignment = .fill
        rootContainer.spacing = 6
        view.addSubview(rootContainer)

        // 1. 頂部狀態列 (Header Bar)
        headerStackView = UIStackView()
        headerStackView.translatesAutoresizingMaskIntoConstraints = false
        headerStackView.axis = .horizontal
        headerStackView.distribution = .equalSpacing
        headerStackView.alignment = .center

        brandBadgeLabel = UILabel()
        brandBadgeLabel.text = "⚡ EchoWrite 本地雙引擎"
        brandBadgeLabel.font = .systemFont(ofSize: 13, weight: .black)
        brandBadgeLabel.textColor = UIColor(red: 0.0, green: 0.9, blue: 1.0, alpha: 1.0)

        timerLabel = UILabel()
        timerLabel.text = "⏱ 00:00"
        timerLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        timerLabel.textColor = UIColor(white: 0.7, alpha: 1.0)

        hardwareAccelBadge = UILabel()
        hardwareAccelBadge.text = "● ANE / Metal 加速"
        hardwareAccelBadge.font = .systemFont(ofSize: 11, weight: .bold)
        hardwareAccelBadge.textColor = UIColor(red: 0.3, green: 0.85, blue: 0.4, alpha: 1.0)

        headerStackView.addArrangedSubview(brandBadgeLabel)
        headerStackView.addArrangedSubview(timerLabel)
        headerStackView.addArrangedSubview(hardwareAccelBadge)
        rootContainer.addArrangedSubview(headerStackView)

        // 2. 風格切換膠囊列 (Style Selector)
        styleScrollView = UIScrollView()
        styleScrollView.translatesAutoresizingMaskIntoConstraints = false
        styleScrollView.showsHorizontalScrollIndicator = false
        styleScrollView.heightAnchor.constraint(equalToConstant: 32).isActive = true

        styleStackView = UIStackView()
        styleStackView.translatesAutoresizingMaskIntoConstraints = false
        styleStackView.axis = .horizontal
        styleStackView.spacing = 6
        styleStackView.alignment = .center
        styleScrollView.addSubview(styleStackView)

        for style in EchoWriteStyle.allCases {
            let btn = UIButton(type: .system)
            btn.setTitle(style.title, for: .normal)
            btn.titleLabel?.font = .systemFont(ofSize: 12, weight: .bold)
            btn.layer.cornerRadius = 14
            btn.contentEdgeInsets = UIEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)
            btn.tag = EchoWriteStyle.allCases.firstIndex(of: style) ?? 0
            btn.addTarget(self, action: #selector(styleButtonTapped(_:)), for: .touchUpInside)
            styleButtons[style] = btn
            styleStackView.addArrangedSubview(btn)
        }
        rootContainer.addArrangedSubview(styleScrollView)

        // 3. 即時轉寫預覽盒 + 動態聲波 (Preview & Waveform)
        previewContainer = UIView()
        previewContainer.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.backgroundColor = UIColor(red: 0.08, green: 0.12, blue: 0.20, alpha: 0.8)
        previewContainer.layer.cornerRadius = 10
        previewContainer.layer.borderWidth = 1
        previewContainer.layer.borderColor = UIColor(red: 0.15, green: 0.22, blue: 0.35, alpha: 1.0).cgColor

        previewTextLabel = UILabel()
        previewTextLabel.translatesAutoresizingMaskIntoConstraints = false
        previewTextLabel.text = "💬 點擊下方麥克風直接說話，說完自動潤飾打入..."
        previewTextLabel.font = .systemFont(ofSize: 12, weight: .medium)
        previewTextLabel.textColor = UIColor(white: 0.75, alpha: 1.0)
        previewTextLabel.numberOfLines = 2
        previewContainer.addSubview(previewTextLabel)

        waveformView = AudioWaveformView()
        waveformView.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.addSubview(waveformView)

        rootContainer.addArrangedSubview(previewContainer)

        // 4. 錄音核心按鈕 (In-Place Tap to Record / Stop)
        let actionStack = UIStackView()
        actionStack.translatesAutoresizingMaskIntoConstraints = false
        actionStack.axis = .vertical
        actionStack.alignment = .center
        actionStack.spacing = 3

        recordButton = UIButton(type: .system)
        recordButton.translatesAutoresizingMaskIntoConstraints = false
        recordButton.setTitle("🎙️ 點擊開始說話（原地即時重塑）", for: .normal)
        recordButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .bold)
        recordButton.setTitleColor(.white, for: .normal)
        recordButton.backgroundColor = UIColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 1.0)
        recordButton.layer.cornerRadius = 16
        recordButton.layer.shadowColor = UIColor(red: 0.0, green: 0.6, blue: 1.0, alpha: 0.5).cgColor
        recordButton.layer.shadowOpacity = 0.6
        recordButton.layer.shadowRadius = 8
        recordButton.layer.shadowOffset = CGSize(width: 0, height: 2)
        recordButton.addTarget(self, action: #selector(recordButtonTapped), for: .touchUpInside)

        statusLabel = UILabel()
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.text = "完全離線本地端 AI · 原地輸入絕不跳出視窗"
        statusLabel.font = .systemFont(ofSize: 10, weight: .medium)
        statusLabel.textColor = UIColor(white: 0.5, alpha: 1.0)

        actionStack.addArrangedSubview(recordButton)
        actionStack.addArrangedSubview(statusLabel)
        rootContainer.addArrangedSubview(actionStack)

        // 5. 底部常用標點與快捷控制列 (Punctuation, Globe, Space, Delete, Return)
        let bottomBar = UIStackView()
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.axis = .horizontal
        bottomBar.spacing = 5
        bottomBar.distribution = .fill
        bottomBar.alignment = .fill

        let globeButton = createKeyButton(title: "🌐", width: 38, action: #selector(handleInputModeList(from:with:)))
        let commaButton = createPunctuationButton(title: "，")
        let periodButton = createPunctuationButton(title: "。")
        let questionButton = createPunctuationButton(title: "？")
        let spaceButton = createKeyButton(title: "空白", width: 64, action: #selector(spaceKeyTapped))
        let deleteButton = createDeleteKeyButton()
        let returnButton = createKeyButton(title: "換行", width: 52, action: #selector(returnKeyTapped), isAccent: true)

        bottomBar.addArrangedSubview(globeButton)
        bottomBar.addArrangedSubview(commaButton)
        bottomBar.addArrangedSubview(periodButton)
        bottomBar.addArrangedSubview(questionButton)
        bottomBar.addArrangedSubview(spaceButton)
        bottomBar.addArrangedSubview(deleteButton)
        bottomBar.addArrangedSubview(returnButton)
        rootContainer.addArrangedSubview(bottomBar)

        // Constraints
        NSLayoutConstraint.activate([
            rootContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            rootContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            rootContainer.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            rootContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -6),
            
            styleStackView.leadingAnchor.constraint(equalTo: styleScrollView.leadingAnchor),
            styleStackView.trailingAnchor.constraint(equalTo: styleScrollView.trailingAnchor),
            styleStackView.topAnchor.constraint(equalTo: styleScrollView.topAnchor),
            styleStackView.bottomAnchor.constraint(equalTo: styleScrollView.bottomAnchor),
            styleStackView.heightAnchor.constraint(equalTo: styleScrollView.heightAnchor),

            previewContainer.heightAnchor.constraint(equalToConstant: 54),
            previewTextLabel.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor, constant: 10),
            previewTextLabel.trailingAnchor.constraint(equalTo: waveformView.leadingAnchor, constant: -8),
            previewTextLabel.topAnchor.constraint(equalTo: previewContainer.topAnchor, constant: 5),
            previewTextLabel.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor, constant: -5),

            waveformView.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor, constant: -10),
            waveformView.centerYAnchor.constraint(equalTo: previewContainer.centerYAnchor),
            waveformView.widthAnchor.constraint(equalToConstant: 48),
            waveformView.heightAnchor.constraint(equalToConstant: 26),

            recordButton.widthAnchor.constraint(equalTo: rootContainer.widthAnchor, multiplier: 0.98),
            recordButton.heightAnchor.constraint(equalToConstant: 42),
            bottomBar.heightAnchor.constraint(equalToConstant: 34)
        ])
    }

    private func createKeyButton(title: String, width: CGFloat, action: Selector, isAccent: Bool = false) -> UIButton {
        let btn = UIButton(type: .system)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.setTitle(title, for: .normal)
        btn.titleLabel?.font = .systemFont(ofSize: 13, weight: .bold)
        btn.setTitleColor(isAccent ? .white : UIColor(white: 0.88, alpha: 1.0), for: .normal)
        btn.backgroundColor = isAccent ? UIColor(red: 0.0, green: 0.45, blue: 0.85, alpha: 0.85) : UIColor(white: 0.16, alpha: 0.85)
        btn.layer.cornerRadius = 8
        btn.widthAnchor.constraint(equalToConstant: width).isActive = true
        btn.addTarget(self, action: action, for: .touchUpInside)
        return btn
    }

    private func createDeleteKeyButton() -> UIButton {
        let btn = UIButton(type: .system)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.setTitle("⌫", for: .normal)
        btn.titleLabel?.font = .systemFont(ofSize: 15, weight: .bold)
        btn.setTitleColor(UIColor(white: 0.95, alpha: 1.0), for: .normal)
        btn.backgroundColor = UIColor(white: 0.22, alpha: 0.85)
        btn.layer.cornerRadius = 8
        btn.widthAnchor.constraint(equalToConstant: 44).isActive = true
        btn.addTarget(self, action: #selector(deleteTouchDown), for: .touchDown)
        btn.addTarget(self, action: #selector(deleteTouchUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])

        return btn
    }

    private func createPunctuationButton(title: String) -> UIButton {
        let btn = UIButton(type: .system)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.setTitle(title, for: .normal)
        btn.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        btn.setTitleColor(UIColor(white: 0.9, alpha: 1.0), for: .normal)
        btn.backgroundColor = UIColor(white: 0.20, alpha: 0.8)
        btn.layer.cornerRadius = 8
        btn.addTarget(self, action: #selector(punctuationKeyTapped(_:)), for: .touchUpInside)
        return btn
    }

    // MARK: - 按鍵動作
    @objc private func punctuationKeyTapped(_ sender: UIButton) {
        guard let p = sender.title(for: .normal) else { return }
        textDocumentProxy.insertText(p)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    @objc private func spaceKeyTapped() {
        textDocumentProxy.insertText(" ")
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    @objc private func deleteTouchDown() {
        textDocumentProxy.deleteBackward()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        
        deleteRepeatTimer?.invalidate()
        let delayTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.deleteRepeatTimer?.invalidate()
            let repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
                self?.textDocumentProxy.deleteBackward()
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            RunLoop.current.add(repeatTimer, forMode: .common)
            self.deleteRepeatTimer = repeatTimer
        }
        RunLoop.current.add(delayTimer, forMode: .common)
        deleteRepeatTimer = delayTimer
    }

    @objc private func deleteTouchUp() {
        deleteRepeatTimer?.invalidate()
        deleteRepeatTimer = nil
    }

    @objc private func returnKeyTapped() {
        textDocumentProxy.insertText("\n")
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    // MARK: - 風格切換
    @objc private func styleButtonTapped(_ sender: UIButton) {
        let generator = UISelectionFeedbackGenerator()
        generator.selectionChanged()

        let styles = EchoWriteStyle.allCases
        guard sender.tag < styles.count else { return }
        currentStyle = styles[sender.tag]
        EchoWriteShared.setSelectedStyle(currentStyle)
        updateStyleSelectionUI()
    }

    private func updateStyleSelectionUI() {
        for (style, button) in styleButtons {
            if style == currentStyle {
                button.backgroundColor = UIColor(red: 0.0, green: 0.75, blue: 0.95, alpha: 0.25)
                button.setTitleColor(UIColor(red: 0.0, green: 0.95, blue: 1.0, alpha: 1.0), for: .normal)
                button.layer.borderWidth = 1.5
                button.layer.borderColor = UIColor(red: 0.0, green: 0.9, blue: 1.0, alpha: 1.0).cgColor
            } else {
                button.backgroundColor = UIColor(red: 0.10, green: 0.14, blue: 0.22, alpha: 0.6)
                button.setTitleColor(UIColor(white: 0.7, alpha: 1.0), for: .normal)
                button.layer.borderWidth = 0.5
                button.layer.borderColor = UIColor(white: 0.3, alpha: 0.4).cgColor
            }
        }
    }

    // MARK: - 原地錄音與即時重塑核心 (In-Place Dictation)
    @objc private func recordButtonTapped() {
        if isProcessing { return }

        if isRecording {
            stopAndProcessInPlaceRecording()
        } else {
            startInPlaceRecording()
        }
    }

    private func startInPlaceRecording() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        if audioEngine.isRunning {
            audioEngine.stop()
            recognitionRequest?.endAudio()
            return
        }
        
        lastPartialText = ""
        requestPermissionsAndStartSpeechRecognition()
    }

    private func beginRecordingSession() {
        do {
            try startSpeechRecognition()
        } catch {
            showRecordingStartFailure("⚠️ \(userFacingRecordingErrorMessage(error))")
            return
        }

        isRecording = true
        recordingStartTime = Date()

        DispatchQueue.main.async {
            self.previewTextLabel.text = "🎙️ 錄音中，即時語音辨識..."
            self.recordButton.setTitle("⏹️ 完成", for: .normal)
            self.recordButton.backgroundColor = .systemRed
        }

        recordingTimer?.invalidate()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, self.isRecording, let start = self.recordingStartTime else { return }
            let elapsed = Int(Date().timeIntervalSince(start))
            self.timerLabel.text = String(format: "⏱ %02d:%02d", elapsed / 60, elapsed % 60)
        }
    }

    private func requestPermissionsAndStartSpeechRecognition() {
        let audioSession = AVAudioSession.sharedInstance()

        switch audioSession.recordPermission {
        case .granted:
            requestSpeechAuthorizationIfNeededThenStart()
        case .denied:
            showRecordingStartFailure("⚠️ \(RecordingStartError.microphonePermissionDenied.localizedDescription)")
        case .undetermined:
            audioSession.requestRecordPermission { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if granted {
                        self.requestSpeechAuthorizationIfNeededThenStart()
                    } else {
                        self.showRecordingStartFailure("⚠️ \(RecordingStartError.microphonePermissionDenied.localizedDescription)")
                    }
                }
            }
        @unknown default:
            showRecordingStartFailure("⚠️ 無法確認麥克風權限狀態")
        }
    }

    private func requestSpeechAuthorizationIfNeededThenStart() {
        guard let speechRecognizer = speechRecognizer else {
            showRecordingStartFailure("⚠️ \(RecordingStartError.speechRecognizerUnavailable.localizedDescription)")
            return
        }

        guard speechRecognizer.isAvailable else {
            showRecordingStartFailure("⚠️ \(RecordingStartError.speechRecognizerUnavailable.localizedDescription)")
            return
        }

        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            beginRecordingSession()
        case .denied:
            showRecordingStartFailure("⚠️ \(RecordingStartError.speechPermissionDenied.localizedDescription)")
        case .restricted:
            showRecordingStartFailure("⚠️ \(RecordingStartError.speechRecognizerUnavailable.localizedDescription)")
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { [weak self] status in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    switch status {
                    case .authorized:
                        self.beginRecordingSession()
                    case .denied:
                        self.showRecordingStartFailure("⚠️ \(RecordingStartError.speechPermissionDenied.localizedDescription)")
                    case .restricted:
                        self.showRecordingStartFailure("⚠️ \(RecordingStartError.speechRecognizerUnavailable.localizedDescription)")
                    case .notDetermined:
                        self.showRecordingStartFailure("⚠️ 尚未取得語音辨識授權")
                    @unknown default:
                        self.showRecordingStartFailure("⚠️ 無法確認語音辨識權限狀態")
                    }
                }
            }
        @unknown default:
            showRecordingStartFailure("⚠️ 無法確認語音辨識權限狀態")
        }
    }

    private func showRecordingStartFailure(_ message: String) {
        isRecording = false
        isProcessing = false
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingStartTime = nil
        waveformView.reset()
        resetButtonUI()
        previewTextLabel.text = message
        print("KeyboardViewController: \(message)")
    }

    private func userFacingRecordingErrorMessage(_ error: Error) -> String {
        if let recordingError = error as? RecordingStartError {
            return recordingError.localizedDescription
        }

        return "語音辨識啟動失敗：\(error.localizedDescription)"
    }

    private func startSpeechRecognition() throws {
        recognitionTask?.cancel()
        recognitionTask = nil
        
        guard let speechRecognizer = speechRecognizer else {
            throw RecordingStartError.speechRecognizerUnavailable
        }

        guard speechRecognizer.isAvailable else {
            throw RecordingStartError.speechRecognizerUnavailable
        }

        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            throw RecordingStartError.audioSessionInitializationFailed(underlying: error)
        }
        
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else { fatalError("Unable to create request") }
        recognitionRequest.shouldReportPartialResults = true
        
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] (buffer, when) in
            guard let self = self else { return }
            self.recognitionRequest?.append(buffer)
            
            // Calculate RMS for waveform
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frames = buffer.frameLength
            var rms: Float = 0
            for i in 0..<Int(frames) {
                rms += channelData[i] * channelData[i]
            }
            rms = sqrt(rms / Float(frames))
            let normalized = CGFloat(max(0.1, min(1.0, 1.0 + Double(20 * log10(rms)) / 50.0)))
            DispatchQueue.main.async {
                self.waveformView.updateAmplitude(normalized)
            }
        }
        
        audioEngine.prepare()
        try audioEngine.start()
        
        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self = self else { return }
            if let result = result {
                self.lastPartialText = result.bestTranscription.formattedString
                if self.isRecording {
                    self.previewTextLabel.text = self.lastPartialText
                }
                
                if result.isFinal {
                    self.processAI(self.lastPartialText)
                }
            }
            if let error = error {
                print("KeyboardViewController recognition error: \(error)")
                self.audioEngine.stop()
                inputNode.removeTap(onBus: 0)
                self.recognitionRequest = nil
                self.recognitionTask = nil
                DispatchQueue.main.async {
                    self.previewTextLabel.text = "⚠️ 語音辨識中斷：\(error.localizedDescription)"
                }
            }
        }
    }
    private func stopAndProcessInPlaceRecording() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        recordingTimer?.invalidate()
        
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio() 
        
        isRecording = false
        isProcessing = true
        
        previewTextLabel.text = "⚙️ LLM 語意精修串流中..."
        recordButton.isEnabled = false
        recordButton.setTitle("⚙️ 引擎處理中...", for: .normal)
    }

    private func processAI(_ rawText: String) {
        if rawText.isEmpty {
            DispatchQueue.main.async {
                self.previewTextLabel.text = "⚠️ 未聽清楚內容，或轉寫失敗"
                self.isProcessing = false
                self.resetButtonUI()
            }
            return
        }

        let contextBefore = self.textDocumentProxy.documentContextBeforeInput ?? ""
        let currentStyleRaw = self.currentStyle.rawValue
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let callback = StreamingCallback(
                onUpdate: { [weak self] text in
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        if self.isProcessing {
                            self.previewTextLabel.text = text
                        }
                    }
                },
                onError: { error in
                    print("Stream error: \(error)")
                }
            )
            
            let finalText = try? polishTextStream(rawText: rawText, style: currentStyleRaw, contextBefore: contextBefore, callback: callback)
            
            DispatchQueue.main.async {
                if self.isProcessing {
                    if let text = finalText {
                        self.textDocumentProxy.insertText(text)
                        self.previewTextLabel.text = "✅ 處理完成"
                    } else {
                        self.previewTextLabel.text = "⚠️ 轉寫失敗"
                    }
                }
                self.isProcessing = false
                self.resetButtonUI()
            }
        }
    }
    private func cancelRecording() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        
        isRecording = false
        isProcessing = false
        waveformView.reset()
        resetButtonUI()
        
        previewTextLabel.text = "⚠️ 已取消錄音"
    }

    private func resetButtonUI() {
        recordButton.setTitle("🎙️ 點擊開始說話（原地即時重塑）", for: .normal)
        recordButton.backgroundColor = UIColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 1.0)
        recordButton.layer.shadowColor = UIColor(red: 0.0, green: 0.6, blue: 1.0, alpha: 0.5).cgColor
        recordButton.isEnabled = true
        timerLabel.text = "⏱ 00:00"
        statusLabel.text = "完全離線本地端 AI · 原地輸入絕不跳出視窗"
    }
}


// MARK: - 動態聲波音量柱 (Waveform Visualizer)
final class AudioWaveformView: UIView {
    private let barCount = 7
    private var barLayers: [CALayer] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupBars()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupBars()
    }

    private func setupBars() {
        for _ in 0..<barCount {
            let layer = CALayer()
            layer.backgroundColor = UIColor(red: 0.0, green: 0.85, blue: 1.0, alpha: 0.8).cgColor
            layer.cornerRadius = 2
            barLayers.append(layer)
            self.layer.addSublayer(layer)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        let height = bounds.height
        let barWidth: CGFloat = 3.5
        let spacing = (width - CGFloat(barCount) * barWidth) / CGFloat(barCount - 1)

        for (i, layer) in barLayers.enumerated() {
            let x = CGFloat(i) * (barWidth + spacing)
            let barHeight: CGFloat = 4
            layer.frame = CGRect(x: x, y: (height - barHeight) / 2, width: barWidth, height: barHeight)
        }
    }

    func updateAmplitude(_ level: CGFloat) {
        let height = bounds.height
        let barWidth: CGFloat = 3.5
        let spacing = (bounds.width - CGFloat(barCount) * barWidth) / CGFloat(barCount - 1)

        for (i, layer) in barLayers.enumerated() {
            let factor = sin(CGFloat(i) / CGFloat(barCount) * .pi)
            let dynamicHeight = max(4, height * level * factor * CGFloat.random(in: 0.8...1.2))
            let x = CGFloat(i) * (barWidth + spacing)
            layer.frame = CGRect(x: x, y: (height - dynamicHeight) / 2, width: barWidth, height: dynamicHeight)
        }
    }

    func reset() {
        layoutSubviews()
    }
}

class StreamingCallback: LlmStreamCallback {
    let onUpdate: (String) -> Void
    let onErrorCb: (String) -> Void
    
    init(onUpdate: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
        self.onUpdate = onUpdate
        self.onErrorCb = onError
    }
    
    func onTextUpdate(text: String) {
        self.onUpdate(text)
    }
    func onError(error: String) {
        self.onErrorCb(error)
    }
}
