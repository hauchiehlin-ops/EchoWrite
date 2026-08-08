import UIKit
import AVFoundation

/// EchoWrite iOS 專屬高辨識度 AI 鍵盤
/// 遵循 120MB 記憶體限制，音訊由主 App 背景處理，具備：
/// 1. 獨特品牌視覺（頂部 AI 狀態晶片、風格切換膠囊、動態聲波視覺化）。
/// 2. 即時串流／樂觀排版 (Optimistic Streaming Typing)。
/// 3. 5 大語意風格一鍵切換。
/// 4. 滑動取消手勢與防呆觸覺回饋。
@objc(KeyboardViewController)
class KeyboardViewController: UIInputViewController {
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
    
    // MARK: - 狀態管理
    private var currentStyle: EchoWriteStyle = .casual
    private var heightConstraint: NSLayoutConstraint?

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
            let h = view.heightAnchor.constraint(equalToConstant: 260)
            h.priority = UILayoutPriority(999)
            h.isActive = true
            heightConstraint = h
        }
        
        checkForPendingTranscriptionResult()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
    }

    // MARK: - UI 佈局建置
    private func setupCyberGlassUI() {
        view.backgroundColor = UIColor(red: 0.04, green: 0.06, blue: 0.12, alpha: 1.0)

        let rootContainer = UIStackView()
        rootContainer.translatesAutoresizingMaskIntoConstraints = false
        rootContainer.axis = .vertical
        rootContainer.alignment = .fill
        rootContainer.spacing = 8
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
        hardwareAccelBadge.text = "● ANE 加速"
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
        styleScrollView.heightAnchor.constraint(equalToConstant: 34).isActive = true

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
            btn.contentEdgeInsets = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
            btn.tag = EchoWriteStyle.allCases.firstIndex(of: style) ?? 0
            btn.addTarget(self, action: #selector(styleButtonTapped(_:)), for: .touchUpInside)
            styleButtons[style] = btn
            styleStackView.addArrangedSubview(btn)
        }
        rootContainer.addArrangedSubview(styleScrollView)

        // 3. 樂觀即時轉寫預覽盒 + 聲波波形 (Preview & Waveform)
        previewContainer = UIView()
        previewContainer.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.backgroundColor = UIColor(red: 0.08, green: 0.12, blue: 0.20, alpha: 0.8)
        previewContainer.layer.cornerRadius = 10
        previewContainer.layer.borderWidth = 1
        previewContainer.layer.borderColor = UIColor(red: 0.15, green: 0.22, blue: 0.35, alpha: 1.0).cgColor

        previewTextLabel = UILabel()
        previewTextLabel.translatesAutoresizingMaskIntoConstraints = false
        previewTextLabel.text = "💬 點擊下方按鈕開始說話，說話時即時串流打入草稿..."
        previewTextLabel.font = .systemFont(ofSize: 12, weight: .medium)
        previewTextLabel.textColor = UIColor(white: 0.75, alpha: 1.0)
        previewTextLabel.numberOfLines = 2
        previewContainer.addSubview(previewTextLabel)

        waveformView = AudioWaveformView()
        waveformView.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.addSubview(waveformView)

        rootContainer.addArrangedSubview(previewContainer)

        // 4. 錄音核心按鈕與滑動取消引導 (Record & Gesture Action)
        let actionStack = UIStackView()
        actionStack.translatesAutoresizingMaskIntoConstraints = false
        actionStack.axis = .vertical
        actionStack.alignment = .center
        actionStack.spacing = 4

        recordButton = UIButton(type: .system)
        recordButton.translatesAutoresizingMaskIntoConstraints = false
        recordButton.setTitle("🎙️ 點擊開始 EchoWrite 語音重塑", for: .normal)
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
        statusLabel.text = "完全離線本地端 AI · 絕不上傳雲端"
        statusLabel.font = .systemFont(ofSize: 10, weight: .medium)
        statusLabel.textColor = UIColor(white: 0.45, alpha: 1.0)

        actionStack.addArrangedSubview(recordButton)
        actionStack.addArrangedSubview(statusLabel)
        rootContainer.addArrangedSubview(actionStack)

        // 5. 底部快捷操作列 (Globe Switcher / Space / Backspace / Return)
        let bottomBar = UIStackView()
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.axis = .horizontal
        bottomBar.spacing = 6
        bottomBar.distribution = .fill
        bottomBar.alignment = .fill

        let globeButton = UIButton(type: .system)
        globeButton.translatesAutoresizingMaskIntoConstraints = false
        globeButton.setTitle("🌐", for: .normal)
        globeButton.titleLabel?.font = .systemFont(ofSize: 18)
        globeButton.backgroundColor = UIColor(white: 0.15, alpha: 0.8)
        globeButton.layer.cornerRadius = 8
        globeButton.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)

        let spaceButton = UIButton(type: .system)
        spaceButton.translatesAutoresizingMaskIntoConstraints = false
        spaceButton.setTitle("空白", for: .normal)
        spaceButton.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
        spaceButton.setTitleColor(UIColor(white: 0.85, alpha: 1.0), for: .normal)
        spaceButton.backgroundColor = UIColor(white: 0.18, alpha: 0.8)
        spaceButton.layer.cornerRadius = 8
        spaceButton.addTarget(self, action: #selector(spaceKeyTapped), for: .touchUpInside)

        let deleteButton = UIButton(type: .system)
        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        deleteButton.setTitle("⌫", for: .normal)
        deleteButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .bold)
        deleteButton.setTitleColor(UIColor(white: 0.85, alpha: 1.0), for: .normal)
        deleteButton.backgroundColor = UIColor(white: 0.15, alpha: 0.8)
        deleteButton.layer.cornerRadius = 8
        deleteButton.addTarget(self, action: #selector(deleteKeyTapped), for: .touchUpInside)

        let returnButton = UIButton(type: .system)
        returnButton.translatesAutoresizingMaskIntoConstraints = false
        returnButton.setTitle("換行", for: .normal)
        returnButton.titleLabel?.font = .systemFont(ofSize: 13, weight: .bold)
        returnButton.setTitleColor(.white, for: .normal)
        returnButton.backgroundColor = UIColor(red: 0.0, green: 0.45, blue: 0.85, alpha: 0.8)
        returnButton.layer.cornerRadius = 8
        returnButton.addTarget(self, action: #selector(returnKeyTapped), for: .touchUpInside)

        bottomBar.addArrangedSubview(globeButton)
        bottomBar.addArrangedSubview(spaceButton)
        bottomBar.addArrangedSubview(deleteButton)
        bottomBar.addArrangedSubview(returnButton)
        rootContainer.addArrangedSubview(bottomBar)

        // Constraints
        NSLayoutConstraint.activate([
            rootContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            rootContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            rootContainer.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            rootContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -6),
            
            styleStackView.leadingAnchor.constraint(equalTo: styleScrollView.leadingAnchor),
            styleStackView.trailingAnchor.constraint(equalTo: styleScrollView.trailingAnchor),
            styleStackView.topAnchor.constraint(equalTo: styleScrollView.topAnchor),
            styleStackView.bottomAnchor.constraint(equalTo: styleScrollView.bottomAnchor),
            styleStackView.heightAnchor.constraint(equalTo: styleScrollView.heightAnchor),

            previewContainer.heightAnchor.constraint(equalToConstant: 58),
            previewTextLabel.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor, constant: 10),
            previewTextLabel.trailingAnchor.constraint(equalTo: waveformView.leadingAnchor, constant: -8),
            previewTextLabel.topAnchor.constraint(equalTo: previewContainer.topAnchor, constant: 6),
            previewTextLabel.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor, constant: -6),

            waveformView.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor, constant: -10),
            waveformView.centerYAnchor.constraint(equalTo: previewContainer.centerYAnchor),
            waveformView.widthAnchor.constraint(equalToConstant: 50),
            waveformView.heightAnchor.constraint(equalToConstant: 28),

            recordButton.widthAnchor.constraint(equalTo: rootContainer.widthAnchor, multiplier: 0.96),
            recordButton.heightAnchor.constraint(equalToConstant: 44),

            globeButton.widthAnchor.constraint(equalToConstant: 42),
            deleteButton.widthAnchor.constraint(equalToConstant: 42),
            returnButton.widthAnchor.constraint(equalToConstant: 56),
            bottomBar.heightAnchor.constraint(equalToConstant: 34)
        ])
    }

    // MARK: - 輔助按鍵動作
    @objc private func spaceKeyTapped() {
        textDocumentProxy.insertText(" ")
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    @objc private func deleteKeyTapped() {
        textDocumentProxy.deleteBackward()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
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

    // MARK: - 語音重塑喚醒與結果自動打入
    @objc private func recordButtonTapped() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()

        // 1. 提取游標前文情境 Context 與當前風格
        let contextBefore = textDocumentProxy.documentContextBeforeInput ?? ""
        EchoWriteShared.setSharedContextBefore(contextBefore)
        EchoWriteShared.setSelectedStyle(currentStyle)

        recordButton.setTitle("🎙️ 正在喚醒 EchoWrite 語音重塑...", for: .normal)
        previewTextLabel.text = "⚡ 正在喚醒本地 AI 雙引擎語音介面..."
        previewTextLabel.textColor = UIColor(red: 0.0, green: 0.9, blue: 1.0, alpha: 1.0)

        // 2. 透過 URL Scheme 喚醒主 App 進行全功能即時語音錄製與 ANE 神經網路重塑
        guard let url = URL(string: "echowrite://record?style=\(currentStyle.rawValue)") else { return }
        openContainingApp(url: url)
    }

    private func openContainingApp(url: URL) {
        // 方法 1: 使用 Responder Chain 尋找 UIApplication
        var responder: UIResponder? = self
        while let r = responder {
            if let app = r as? UIApplication {
                app.open(url, options: [:], completionHandler: nil)
                return
            }
            responder = r.next
        }

        // 方法 2: 使用 selector 透過 Responder Chain 呼叫 openURL:
        let selector = sel_registerName("openURL:")
        responder = self
        while let r = responder {
            if r.responds(to: selector) {
                r.perform(selector, with: url)
                return
            }
            responder = r.next
        }

        // 方法 3: 使用 extensionContext?.open
        self.extensionContext?.open(url, completionHandler: nil)
    }

    /// 檢查是否有剛在主 App 完成的 AI 重塑結果，若有則自動貼入
    private func checkForPendingTranscriptionResult() {
        guard let resultURL = EchoWriteShared.sharedResultURL,
              FileManager.default.fileExists(atPath: resultURL.path),
              let text = try? String(contentsOf: resultURL, encoding: .utf8),
              !text.isEmpty else {
            resetButton()
            return
        }

        // 自動打入最新重塑文字！
        textDocumentProxy.insertText(text)
        try? FileManager.default.removeItem(at: resultURL)

        previewTextLabel.text = "✅ 已自動填入：\(text.prefix(25))..."
        previewTextLabel.textColor = UIColor(red: 0.3, green: 0.9, blue: 0.4, alpha: 1.0)
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.resetButton()
        }
    }

    private func resetButton() {
        recordButton.setTitle("🎙️ 點擊開始 EchoWrite 語音重塑", for: .normal)
        recordButton.backgroundColor = UIColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 1.0)
        recordButton.isEnabled = true
        timerLabel.text = "⏱ 00:00"
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
        for i in 0..<barCount {
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
            let dynamicHeight = max(4, height * level * factor * CGFloat.random(in: 0.7...1.2))
            let x = CGFloat(i) * (barWidth + spacing)
            layer.frame = CGRect(x: x, y: (height - dynamicHeight) / 2, width: barWidth, height: dynamicHeight)
        }
    }

    func reset() {
        layoutSubviews()
    }
}
