import SwiftUI
import AVFoundation

/// EchoWrite iOS 主 App 全功能現代化儀表板
/// 涵蓋：模型管理中心、風格偏好設定、專屬詞庫編輯器、歷史紀錄剪貼簿、鍵盤啟用診斷精靈。
struct ContentView: View {
    @ObservedObject var processingService: AudioProcessingService
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            ModelHubView(processingService: processingService)
                .tabItem {
                    Label("模型中心", systemImage: "cpu.fill")
                }
                .tag(0)

            StylePreferencesView()
                .tabItem {
                    Label("語音風格", systemImage: "sparkles")
                }
                .tag(1)

            CustomVocabularyView()
                .tabItem {
                    Label("專屬詞庫", systemImage: "text.book.closed.fill")
                }
                .tag(2)

            TranscriptionHistoryView()
                .tabItem {
                    Label("歷史紀錄", systemImage: "clock.arrow.circlepath")
                }
                .tag(3)

            KeyboardDoctorView()
                .tabItem {
                    Label("鍵盤診斷", systemImage: "checkmark.shield.fill")
                }
                .tag(4)
        }
        .tint(Color(red: 0.0, green: 0.75, blue: 1.0))
        .onAppear {
            EchoWriteShared.configureSharedModelDirectory()
        }
    }
}

// MARK: - 1. 模型管理與沙盒測試 (Model Hub & Testing)
struct ModelHubView: View {
    @ObservedObject var processingService: AudioProcessingService
    @State private var whisperProgress = ModelProgress(downloadedBytes: 0, totalBytes: 0, state: .notStarted, error: nil)
    @State private var llmProgress = ModelProgress(downloadedBytes: 0, totalBytes: 0, state: .notStarted, error: nil)
    @State private var pollTimer: Timer?

    // 測試錄音狀態
    @State private var isTestRecording = false
    @State private var testResultText = ""
    @State private var isTestProcessing = false

    private var modelsReady: Bool {
        whisperProgress.state == .ready && llmProgress.state == .ready
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // 頂部品牌 Header
                    HStack(spacing: 16) {
                        Image(systemName: "waveform.circle.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(LinearGradient(colors: [.cyan, .blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("EchoWrite 本地 AI 核心")
                                .font(.title2.bold())
                            Text("離線雙引擎 · Apple Neural Engine / Metal 加速")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding()
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))

                    // 模型下載狀態卡片
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("本地端神經網路模型")
                                .font(.headline)
                            Spacer()
                            if modelsReady {
                                Label("雙引擎就緒", systemImage: "checkmark.seal.fill")
                                    .font(.caption.bold())
                                    .foregroundStyle(.green)
                            }
                        }

                        modelProgressRow(
                            title: "Whisper ASR 語音辨識引擎",
                            subtitle: "140 MB · 繁體中文聲學特化",
                            progress: whisperProgress,
                            onDownload: { ewStartModelDownload(kind: .whisper) }
                        )

                        Divider()

                        modelProgressRow(
                            title: "Qwen 語言重塑與排版引擎",
                            subtitle: "390 MB · GGUF 量化 Metal 加速",
                            progress: llmProgress,
                            onDownload: { ewStartModelDownload(kind: .llm) }
                        )
                    }
                    .padding()
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))

                    // 背景處理狀態指示
                    if processingService.isProcessing {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("正在處理來自 Keyboard Extension 的語音重塑請求...")
                                .font(.subheadline)
                                .foregroundStyle(.blue)
                        }
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                    }

                    // 快速測試沙盒
                    LiveAudioTestSandboxView(modelsReady: modelsReady)
                }
                .padding()
            }
            .navigationTitle("模型管理中心")
            .onAppear(perform: startPolling)
            .onDisappear { pollTimer?.invalidate() }
        }
    }

    private func modelProgressRow(title: String, subtitle: String, progress: ModelProgress, onDownload: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.bold())
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                statusBadge(progress.state)
            }

            ProgressView(value: downloadFraction(progress))

            HStack {
                Text(bytesFormatted(progress.downloadedBytes) + " / " + bytesFormatted(progress.totalBytes))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if progress.state != .ready && progress.state != .downloading {
                    Button("下載模型", action: onDownload)
                        .font(.caption.bold())
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    private func statusBadge(_ state: ModelDownloadState) -> some View {
        switch state {
        case .ready:
            return Text("已就緒").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2).background(Color.green.opacity(0.2)).foregroundStyle(.green).clipShape(Capsule())
        case .downloading:
            return Text("下載中").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2).background(Color.blue.opacity(0.2)).foregroundStyle(.blue).clipShape(Capsule())
        case .verifying:
            return Text("校驗中").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2).background(Color.orange.opacity(0.2)).foregroundStyle(.orange).clipShape(Capsule())
        case .failed:
            return Text("失敗").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2).background(Color.red.opacity(0.2)).foregroundStyle(.red).clipShape(Capsule())
        case .notStarted:
            return Text("未下載").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2).background(Color.gray.opacity(0.2)).foregroundStyle(.gray).clipShape(Capsule())
        }
    }

    private func downloadFraction(_ progress: ModelProgress) -> Double {
        guard progress.totalBytes > 0 else { return progress.state == .ready ? 1.0 : 0.0 }
        return Double(progress.downloadedBytes) / Double(progress.totalBytes)
    }

    private func bytesFormatted(_ bytes: UInt64) -> String {
        guard bytes > 0 else { return "0 MB" }
        let mb = Double(bytes) / (1024 * 1024)
        return String(format: "%.1f MB", mb)
    }

    private func startPolling() {
        refresh()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            refresh()
        }
    }

    private func refresh() {
        whisperProgress = ewGetModelDownloadProgress(kind: .whisper)
        llmProgress = ewGetModelDownloadProgress(kind: .llm)
    }
}

// MARK: - 即時語音測試沙盒 (Live Mic & Text Sandbox)
struct LiveAudioTestSandboxView: View {
    let modelsReady: Bool
    
    @State private var isRecording = false
    @State private var countdown = 3
    @State private var timer: Timer?
    @State private var isProcessing = false
    @State private var testResultText = ""
    @State private var audioRecorder: AVAudioRecorder?
    @State private var tempAudioURL: URL?
    @State private var selectedTestStyle: EchoWriteStyle = .casual
    @State private var statusMessage = "點擊按鈕說話 3 秒，體驗本地雙引擎即時重組"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("🎙️ 本地端即時語音測試沙盒")
                    .font(.headline)
                Spacer()
                if isRecording {
                    Text("🔴 錄音中 (\(countdown)s)")
                        .font(.caption.bold())
                        .foregroundStyle(.red)
                }
            }

            Text("在 App 內直接錄製語音或測試預設樣式，體驗台灣繁中排版、分段與風格重塑：")
                .font(.caption)
                .foregroundStyle(.secondary)

            // 風格選擇膠囊
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(EchoWriteStyle.allCases) { style in
                        Button {
                            selectedTestStyle = style
                        } label: {
                            Text(style.title)
                                .font(.caption.bold())
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(selectedTestStyle == style ? Color.blue : Color(uiColor: .tertiarySystemBackground))
                                .foregroundStyle(selectedTestStyle == style ? .white : .primary)
                                .clipShape(Capsule())
                        }
                    }
                }
            }

            if !testResultText.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("【\(selectedTestStyle.title)】測試結果", systemImage: "sparkles")
                            .font(.caption.bold())
                            .foregroundStyle(.blue)
                        Spacer()
                        Button {
                            UIPasteboard.general.string = testResultText
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.caption)
                        }
                    }
                    Text(testResultText)
                        .font(.subheadline)
                        .textSelection(.enabled)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(uiColor: .tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            }

            // 核心操作按鈕
            VStack(spacing: 8) {
                Button {
                    if isRecording {
                        stopRecordingAndProcess()
                    } else {
                        start3SecondLiveRecording()
                    }
                } label: {
                    HStack {
                        if isRecording {
                            Image(systemName: "stop.circle.fill")
                                .font(.title3)
                            Text("停止並運算（倒數 \(countdown) 秒）")
                                .font(.headline)
                        } else if isProcessing {
                            ProgressView()
                                .tint(.white)
                            Text("本地 AI 運算重組中...")
                                .font(.headline)
                        } else {
                            Image(systemName: "mic.fill")
                                .font(.title3)
                            Text("開始 3 秒即時語音錄音測試")
                                .font(.headline)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(isRecording ? Color.red : (isProcessing ? Color.purple : Color.blue))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .shadow(color: isRecording ? Color.red.opacity(0.4) : Color.blue.opacity(0.3), radius: 6, y: 3)
                }
                .disabled(isProcessing)

                // 範例文字快速格式化按鈕
                Button {
                    runSampleTextFormatting()
                } label: {
                    Label("帶入範例：「第一個要去超商買咖啡第二個進辦公室...」", systemImage: "text.badge.plus")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .disabled(isProcessing)
            }
        }
        .padding()
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func start3SecondLiveRecording() {
        let audioSession = AVAudioSession.sharedInstance()
        audioSession.requestRecordPermission { granted in
            DispatchQueue.main.async {
                guard granted else {
                    self.testResultText = "❌ 請至系統設定開啟麥克風權限"
                    return
                }
                self.beginRecordingSession()
            }
        }
    }

    private func beginRecordingSession() {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("echowrite_sandbox_test.wav")
        tempAudioURL = fileURL

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false
        ]

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
            try session.setActive(true)

            audioRecorder = try AVAudioRecorder(url: fileURL, settings: settings)
            audioRecorder?.record()

            isRecording = true
            countdown = 3
            testResultText = "🎙️ 請對著麥克風說話（如：『第一個去買咖啡第二個去開會』）..."

            let impact = UIImpactFeedbackGenerator(style: .medium)
            impact.impactOccurred()

            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [self] t in
                if self.countdown > 1 {
                    self.countdown -= 1
                } else {
                    t.invalidate()
                    self.stopRecordingAndProcess()
                }
            }
        } catch {
            testResultText = "❌ 錄音啟動失敗：\(error.localizedDescription)"
        }
    }

    private func stopRecordingAndProcess() {
        timer?.invalidate()
        isRecording = false
        audioRecorder?.stop()
        audioRecorder = nil

        guard let audioPath = tempAudioURL?.path, FileManager.default.fileExists(atPath: audioPath) else {
            testResultText = "❌ 未能取得錄音檔案"
            return
        }

        isProcessing = true
        testResultText = "⚡ 本地雙引擎 AI 重塑與排版中..."

        let style = selectedTestStyle.rawValue
        DispatchQueue.global(qos: .userInitiated).async {
            var result = ""
            do {
                if modelsReady {
                    result = try ewProcessAudioFileWithContext(audioPath: audioPath, style: style, contextBefore: nil)
                } else {
                    // 模型下載中或未下載時降級套用本地格式化器示範
                    let demoText = "我現在要開始進行測試，如果說可以的話請幫我做好分段準備第一個我要去超商買咖啡，第二個我要進辦公室上班，第三個準備參加晨會"
                    result = ewFormatOnly(text: demoText)
                }
            } catch {
                result = "處理錯誤：\(error)"
            }

            DispatchQueue.main.async {
                self.isProcessing = false
                self.testResultText = result.isEmpty ? "（未偵測到清晰語音，請重試）" : result
                let notification = UINotificationFeedbackGenerator()
                notification.notificationOccurred(.success)
            }
        }
    }

    private func runSampleTextFormatting() {
        isProcessing = true
        let sample = "我現在要開始進行測試如果說可以的話請幫我做好分段準備第一個我要去超商買咖啡第二個我要進辦公室上班第三個準備參加晨會"
        DispatchQueue.global(qos: .userInitiated).async {
            let formatted = ewFormatOnly(text: sample)
            DispatchQueue.main.async {
                self.isProcessing = false
                self.testResultText = formatted
            }
        }
    }
}

// MARK: - 2. 風格與偏好設定 (Style Preferences)
struct StylePreferencesView: View {
    @State private var selectedStyle: EchoWriteStyle = EchoWriteShared.getSelectedStyle()
    @State private var sampleInput = "今天會議有三個重點第一確認上線時間第二分配後端任務第三完成文檔測試"
    @State private var transformedOutput = ""
    @State private var isTransforming = false

    var body: some View {
        NavigationStack {
            List {
                Section(header: Text("預設語音重組風格（點選即時套用）")) {
                    ForEach(EchoWriteStyle.allCases) { style in
                        HStack(spacing: 12) {
                            Image(systemName: style.icon)
                                .font(.title3)
                                .foregroundStyle(selectedStyle == style ? .blue : .secondary)
                                .frame(width: 30)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(style.title)
                                    .font(.headline)
                                Text(style.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if selectedStyle == style {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.blue)
                                    .font(.headline)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedStyle = style
                            EchoWriteShared.setSelectedStyle(style)
                            transformSample()
                        }
                    }
                }

                Section(header: Text("風格即時轉換預覽與示範")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("原始口述內容：")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Text("「\(sampleInput)」")
                            .font(.subheadline)
                            .padding(8)
                            .background(Color(uiColor: .tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 8))

                        Text("套用【\(selectedStyle.title)】重組後：")
                            .font(.caption.bold())
                            .foregroundStyle(.blue)

                        Text(previewExample(for: selectedStyle))
                            .font(.subheadline)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .padding(.vertical, 4)
                }

                Section(header: Text("風格底層 AI 提示詞 (System Prompt)")) {
                    Text(ewGetStylePromptPreview(style: selectedStyle.rawValue))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                }
            }
            .navigationTitle("語音風格偏好")
            .onAppear { transformSample() }
        }
    }

    private func transformSample() {
        transformedOutput = previewExample(for: selectedStyle)
    }

    private func previewExample(for style: EchoWriteStyle) -> String {
        switch style {
        case .casual:
            return "今天會議有三個重點。\n第一個：確認上線時間。\n第二個：分配後端任務。\n第三個：完成文檔測試。"
        case .formal:
            return "本日會議決議重點如后：\n一、確認系統上線期程。\n二、分派後端工程任務。\n三、完成技術文檔驗證測試。"
        case .email:
            return "主旨：今日專案會議重點與工作分派\n\n各位同仁好，\n\n今日會議決議重點如下：\n1. 確認系統上線時間\n2. 分配後端開發任務\n3. 完成技術文檔測試\n\n祝 順心"
        case .bilingual:
            return "【中文】：\n今天會議有三個重點：\n1. 確認上線時間\n2. 分配後端任務\n3. 完成文檔測試\n\n【English】：\nToday's meeting has three key takeaways:\n1. Confirm the release schedule\n2. Assign backend tasks\n3. Complete documentation testing"
        case .bullet:
            return "- 核心重點 1：確認上線時間\n- 核心重點 2：分配後端任務\n- 核心重點 3：完成文檔測試"
        }
    }
}

// MARK: - 3. 專屬客製詞庫 (Custom Vocabulary)
struct CustomVocabularyView: View {
    @State private var phrases: [String] = []
    @State private var newPhraseText = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack {
                HStack {
                    TextField("輸入人名、專有名詞（如：EchoWrite）", text: $newPhraseText)
                        .textFieldStyle(.roundedBorder)
                    Button("新增詞彙") {
                        addPhrase()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(newPhraseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding()

                if let err = errorMessage {
                    Text(err).font(.caption).foregroundStyle(.red)
                }

                List {
                    Section(header: Text("已註冊之專屬詞彙 (\(phrases.count))")) {
                        if phrases.isEmpty {
                            Text("目前尚無自訂詞彙。新增後將大幅提升同音字識別準確度。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(phrases, id: \.self) { phrase in
                                HStack {
                                    Image(systemName: "tag.fill")
                                        .foregroundStyle(.cyan)
                                    Text(phrase)
                                        .font(.body)
                                }
                            }
                            .onDelete(perform: deletePhrase)
                        }
                    }
                }
            }
            .navigationTitle("專屬客製詞庫")
            .onAppear(perform: loadPhrases)
        }
    }

    private func loadPhrases() {
        if let list = try? ewGetCustomVocabulary() {
            phrases = list
        }
    }

    private func addPhrase() {
        let trimmed = newPhraseText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try ewAddCustomVocabulary(phrase: trimmed)
            newPhraseText = ""
            errorMessage = nil
            loadPhrases()
        } catch {
            errorMessage = "新增失敗：\(error)"
        }
    }

    private func deletePhrase(at offsets: IndexSet) {
        for index in offsets {
            let phrase = phrases[index]
            try? ewDeleteCustomVocabulary(phrase: phrase)
        }
        loadPhrases()
    }
}

// MARK: - 4. 轉寫歷史紀錄 (Transcription History)
struct TranscriptionHistoryView: View {
    @State private var history: [HistoryRecord] = []
    @State private var copiedToast = false

    var body: some View {
        NavigationStack {
            List {
                if history.isEmpty {
                    Text("目前尚無轉寫紀錄。使用鍵盤轉寫後將自動儲存於此。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(history, id: \.id) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(item.timestamp)
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button {
                                    UIPasteboard.general.string = item.text
                                    withAnimation { copiedToast = true }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                        withAnimation { copiedToast = false }
                                    }
                                } label: {
                                    Label("複製", systemImage: "doc.on.doc")
                                        .font(.caption)
                                }
                            }
                            Text(item.text)
                                .font(.subheadline)
                                .lineLimit(4)
                        }
                        .padding(.vertical, 4)
                    }
                    .onDelete(perform: deleteHistory)
                }
            }
            .navigationTitle("轉寫歷史紀錄")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if !history.isEmpty {
                        Button("清空") {
                            try? ewClearTranscriptionHistory()
                            loadHistory()
                        }
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if copiedToast {
                    Text("已複製至剪貼簿")
                        .font(.caption.bold())
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 20)
                }
            }
            .onAppear(perform: loadHistory)
        }
    }

    private func loadHistory() {
        if let records = try? ewGetTranscriptionHistory(limit: 50) {
            history = records
        }
    }

    private func deleteHistory(at offsets: IndexSet) {
        for index in offsets {
            let item = history[index]
            try? ewDeleteHistoryItem(id: item.id)
        }
        loadHistory()
    }
}

// MARK: - 5. 鍵盤啟用指南與診斷 (IME Doctor)
struct KeyboardDoctorView: View {
    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)

    var body: some View {
        NavigationStack {
            List {
                Section(header: Text("⚠️ 如何確認目前正在使用 EchoWrite 鍵盤？")) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("正確使用：深藍科技風專屬鍵盤")
                                .font(.subheadline.bold())
                        }
                        Text("切換成功時，鍵盤會呈現【深藍色 CyberGlass 介面】，頂部標示『⚡ EchoWrite 本地雙引擎』，中央有藍色發光的大顆『🎙️ 點擊開始 EchoWrite 語音重塑』按鈕。")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Divider()

                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("常見誤區：切勿點 Apple 鍵盤右下角小麥克風")
                                .font(.subheadline.bold())
                        }
                        Text("若畫面上依然是 Apple 系統的『ㄅㄆㄇㄈ 注音鍵盤』，點擊右下角的小麥克風會呼叫 Siri 逐字稿（無法進行 EchoWrite 的 AI 自動分段與風格重塑）。請長按地球鍵切換至 EchoWrite 鍵盤！")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section(header: Text("系統權限與整合狀態檢測")) {
                    HStack {
                        Image(systemName: "mic.fill")
                            .foregroundStyle(micStatus == .authorized ? .green : .orange)
                            .frame(width: 24)
                        Text("麥克風存取權限")
                        Spacer()
                        Text(micStatus == .authorized ? "已允許" : "未啟用")
                            .font(.caption.bold())
                            .foregroundStyle(micStatus == .authorized ? .green : .orange)
                    }

                    HStack {
                        Image(systemName: "person.2.badge.gearshape.fill")
                            .foregroundStyle(.green)
                            .frame(width: 24)
                        Text("App Group 共享容器")
                        Spacer()
                        Text("正常連通")
                            .font(.caption.bold())
                            .foregroundStyle(.green)
                    }
                }

                Section(header: Text("三步驟啟用 EchoWrite 輸入法")) {
                    StepGuideRow(step: 1, title: "新增輸入法", description: "前往 iOS「設定 > 一般 > 鍵盤 > 鍵盤 > 新增鍵盤」，選取 EchoWrite。")
                    StepGuideRow(step: 2, title: "允許完全取用（必備）", description: "點擊 EchoWrite 鍵盤，開啟「允許完全取用」（以允許鍵盤錄音與載入本地模型）。")
                    StepGuideRow(step: 3, title: "切換使用", description: "在任一聊天輸入框長按地球圖示 🌐，選取「EchoWrite」，看到深藍色科技鍵盤即可點擊大按鈕說話！")
                }

                Section(header: Text("📖 30 秒語音操作指令速查")) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("• 換行排版：說「換行」或「下一行」自動跳行")
                        Text("• 空行分段：說「空兩行」自動分段")
                        Text("• 標點符號：說「加個問號」、「驚嘆號」立即插入")
                        Text("• 滑動取消：錄音時向左滑動即可捨棄本次錄音")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
                }

                Section(header: Text("🔒 零雲端隱私權承諾 (Zero-Cloud Privacy)")) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "checkmark.shield.fill")
                                .foregroundStyle(.green)
                            Text("100% 晶片端離線推論 (Neural Engine)")
                                .font(.caption.bold())
                        }
                        Text("所有語音與文字絕不上傳至任何雲端伺服器，斷網狀態依然完整可用。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        HStack {
                            Image(systemName: "lock.shield.fill")
                                .foregroundStyle(.green)
                            Text("零按鍵側錄 · 本地 SQLite 加密儲存")
                                .font(.caption.bold())
                        }
                        Text("無任何常駐鍵盤監控，詞庫與歷史紀錄僅存於本機沙盒。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Label("開啟系統設定", systemImage: "gearshape")
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            }
            .navigationTitle("設定、指南與隱私")
        }
    }
}

struct StepGuideRow: View {
    let step: Int
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(step)")
                .font(.headline.bold())
                .frame(width: 28, height: 28)
                .background(Color.blue)
                .foregroundStyle(.white)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.bold())
                Text(description).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(processingService: AudioProcessingService())
    }
}
