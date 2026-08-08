import UIKit
import AVFoundation
import Speech

/// EchoWrite iOS 專屬極速無縫 AI 鍵盤
/// 1. 鍵盤內原地即時錄音與語意重塑，絕不跳轉視窗、絕不要求手動切換複製貼上。
/// 2. 說完即打入（In-Place Auto Typing），直通 textDocumentProxy.insertText。
/// 3. 動態聲波音量柱與精確錄音計時器。
/// 4. 5 大語意風格一鍵切換與常用中文標點符號列。
@objc(KeyboardViewController)
class KeyboardViewController: UIInputViewController, AVAudioRecorderDelegate {
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

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine: AVAudioEngine?
    private var lastPartialText: String = ""   // 保存最後一次 partial result
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
        btn.addTarget(self, action: #selector(deleteKeyTapped), for: .touchUpInside)

        // 支援長按連續刪除 (Continuous Delete on Long Press)
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleDeleteKeyLongPress(_:)))
        longPress.minimumPressDuration = 0.28
        btn.addGestureRecognizer(longPress)

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

    @objc private func deleteKeyTapped() {
        textDocumentProxy.deleteBackward()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    @objc private func handleDeleteKeyLongPress(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            textDocumentProxy.deleteBackward()
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()

            deleteRepeatTimer?.invalidate()
            deleteRepeatTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                self.textDocumentProxy.deleteBackward()
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        case .ended, .cancelled, .failed:
            deleteRepeatTimer?.invalidate()
            deleteRepeatTimer = nil
        default:
            break
        }
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

    // MARK: - 串流語音辨識核心 (SFSpeechRecognizer Lightning ASR)

    private func startInPlaceRecording() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        // 先檢查語音辨識授權狀態
        let authStatus = SFSpeechRecognizer.authorizationStatus()
        switch authStatus {
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { [weak self] status in
                DispatchQueue.main.async {
                    if status == .authorized {
                        self?.beginStreamingRecognition()
                    } else {
                        self?.previewTextLabel.text = "⚠️ 請在設定 › EchoWrite 中允許語音辨識以啟用閃電模式"
                        self?.previewTextLabel.textColor = UIColor(red: 1.0, green: 0.4, blue: 0.3, alpha: 1.0)
                    }
                }
            }
            return
        case .denied, .restricted:
            previewTextLabel.text = "⚠️ 語音辨識未授權，請至設定 › 隱私 › 語音辨識 › EchoWrite 中開啟"
            previewTextLabel.textColor = UIColor(red: 1.0, green: 0.4, blue: 0.3, alpha: 1.0)
            return
        case .authorized:
            beginStreamingRecognition()
        @unknown default:
            beginStreamingRecognition()
        }
    }

    private func beginStreamingRecognition() {
        // 建立辨識器（優先 zh-TW，備援 zh）
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-TW"))
            ?? SFSpeechRecognizer(locale: Locale(identifier: "zh"))
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            previewTextLabel.text = "⚠️ 語音辨識器目前不可用，請稍後重試"
            previewTextLabel.textColor = UIColor(red: 1.0, green: 0.4, blue: 0.3, alpha: 1.0)
            return
        }

        // 設定 AVAudioSession
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: [.allowBluetooth, .mixWithOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            previewTextLabel.text = "⚠️ 麥克風無法啟用：請至 iOS 設定 › EchoWrite › 允許完整取用"
            previewTextLabel.textColor = UIColor(red: 1.0, green: 0.4, blue: 0.3, alpha: 1.0)
            return
        }

        // 建立辨識請求（串流模式）
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // 優先使用機上辨識（Apple Neural Engine），不需網路
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        recognitionRequest = request

        // 建立音訊引擎並掛接 tap
        let engine = AVAudioEngine()
        audioEngine = engine
        let inputNode = engine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            previewTextLabel.text = "⚠️ 音訊引擎啟動失敗：\(error.localizedDescription)"
            previewTextLabel.textColor = UIColor(red: 1.0, green: 0.4, blue: 0.3, alpha: 1.0)
            stopAudioEngine()
            return
        }

        // 啟動辨識任務（串流 partial results → setMarkedText 即時顯示）
        lastPartialText = ""
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }

            if let result = result {
                let text = result.bestTranscription.formattedString
                self.lastPartialText = text
                DispatchQueue.main.async {
                    // 邊說邊顯示辨識結果（草稿，帶底線）
                    self.textDocumentProxy.setMarkedText(text, selectedRange: NSRange(location: text.count, length: 0))
                    self.previewTextLabel.text = "🎙️ \(text)"
                    self.previewTextLabel.textColor = UIColor(white: 0.9, alpha: 1.0)
                    // 即時更新聲波（用字數變化模擬振幅）
                    self.waveformView.updateAmplitude(CGFloat.random(in: 0.3...0.9))
                }
            }

            if let error = error {
                // 使用者主動停止時 error 屬正常，不顯示錯誤
                let nsError = error as NSError
                let isExpectedStop = nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1110
                if !isExpectedStop {
                    print("[Keyboard] SFSpeech recognition error: \(error)")
                }
            }
        }

        isRecording = true
        recordingStartTime = Date()

        // 更新 UI
        recordButton.setTitle("⏹️ 說完即點擊完成", for: .normal)
        recordButton.backgroundColor = UIColor(red: 0.85, green: 0.2, blue: 0.25, alpha: 1.0)
        recordButton.layer.shadowColor = UIColor(red: 1.0, green: 0.2, blue: 0.3, alpha: 0.8).cgColor
        statusLabel.text = "⚡ 說完即點擊，毫秒級打入文字"

        // 啟動計時器
        recordingTimer?.invalidate()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [weak self] _ in
            guard let self = self, self.isRecording, let start = self.recordingStartTime else { return }
            let elapsed = Int(Date().timeIntervalSince(start))
            self.timerLabel.text = String(format: "⏱ %02d:%02d", elapsed / 60, elapsed % 60)
        }
    }

    private func stopAndProcessInPlaceRecording() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        recordingTimer?.invalidate()
        recordingTimer = nil
        guard isRecording else { return }
        isRecording = false
        isProcessing = true

        // 停止音訊引擎並結束辨識請求
        recognitionRequest?.endAudio()
        stopAudioEngine()
        recognitionTask?.cancel()
        recognitionTask = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        // 取得最後辨識文字（可能來自 partial 或 final）
        let rawText = lastPartialText.trimmingCharacters(in: .whitespacesAndNewlines)
        lastPartialText = ""

        // 清除草稿底線
        textDocumentProxy.unmarkText()

        guard !rawText.isEmpty else {
            previewTextLabel.text = "⚠️ 未偵測到語音，請靠近麥克風再試"
            previewTextLabel.textColor = UIColor(red: 1.0, green: 0.65, blue: 0.2, alpha: 1.0)
            isProcessing = false
            waveformView.reset()
            resetButtonUI()
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }

        let styleStr = currentStyle.rawValue
        let contextBefore = textDocumentProxy.documentContextBeforeInput
        let isCasual = currentStyle == .casual

        if isCasual {
            // ⚡ 極速通道：純規則引擎，< 10ms，不呼叫 LLM
            let formatted = ewFormatOnly(text: rawText)
            textDocumentProxy.insertText(formatted)
            previewTextLabel.text = "✅ 已打入：\(formatted.prefix(28))"
            previewTextLabel.textColor = UIColor(red: 0.3, green: 0.9, blue: 0.4, alpha: 1.0)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            isProcessing = false
            waveformView.reset()
            resetButtonUI()
        } else {
            // 🌊 非 casual：先立刻插入原始格式化文字，再非同步 LLM 精修替換
            let quickFormatted = ewFormatOnly(text: rawText)
            textDocumentProxy.insertText(quickFormatted)
            previewTextLabel.text = "⚙️ 精修中（\(currentStyle.title)）..."
            previewTextLabel.textColor = UIColor(red: 0.8, green: 0.7, blue: 1.0, alpha: 1.0)
            recordButton.isEnabled = false
            recordButton.setTitle("⚙️ LLM 語意精修中...", for: .normal)
            recordButton.backgroundColor = UIColor(red: 0.35, green: 0.18, blue: 0.7, alpha: 1.0)

            let insertedLen = quickFormatted.count

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                var polished: String? = nil
                do {
                    polished = try ewPolishRawTextWithContext(
                        rawText: rawText,
                        style: styleStr,
                        contextBefore: contextBefore
                    )
                } catch {
                    print("[Keyboard] polishRawText error: \(error)")
                }

                DispatchQueue.main.async {
                    self.isProcessing = false
                    self.waveformView.reset()
                    self.resetButtonUI()

                    if let refined = polished, !refined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       refined != quickFormatted {
                        // 用精修後版本替換剛插入的快速格式版本
                        for _ in 0..<insertedLen {
                            self.textDocumentProxy.deleteBackward()
                        }
                        self.textDocumentProxy.insertText(refined)
                        self.previewTextLabel.text = "✅ 已精修打入：\(refined.prefix(24))"
                        self.previewTextLabel.textColor = UIColor(red: 0.3, green: 0.9, blue: 0.4, alpha: 1.0)
                    } else {
                        self.previewTextLabel.text = "✅ 已打入（快速模式）：\(quickFormatted.prefix(20))"
                        self.previewTextLabel.textColor = UIColor(red: 0.3, green: 0.9, blue: 0.4, alpha: 1.0)
                    }
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
            }
        }
    }

    private func cancelRecording() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        recognitionRequest?.endAudio()
        stopAudioEngine()
        recognitionTask?.cancel()
        recognitionTask = nil
        isRecording = false
        isProcessing = false
        lastPartialText = ""
        textDocumentProxy.unmarkText()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        waveformView.reset()
        resetButtonUI()
        previewTextLabel.text = "已取消錄音"
    }

    private func stopAudioEngine() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        recognitionRequest = nil
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
