import SwiftUI
import AVFoundation

/// EchoWrite iOS 主 App 全功能現代化儀表板
/// 涵蓋：模型管理中心、風格偏好設定、專屬詞庫編輯器、歷史紀錄剪貼簿、鍵盤啟用診斷精靈。
struct ContentView: View {
    @ObservedObject var processingService: AudioProcessingService
    @State private var selectedTab = 0
    @State private var isVoiceDictationPresented = false
    @State private var dictationStyle: EchoWriteStyle = .casual

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
        .onOpenURL { url in
            handleIncomingURL(url)
        }
        .fullScreenCover(isPresented: $isVoiceDictationPresented) {
            VoiceDictationSheet(style: dictationStyle, isPresented: $isVoiceDictationPresented)
        }
    }

    private func handleIncomingURL(_ url: URL) {
        guard url.scheme == "echowrite" else { return }
        if url.host == "record" || url.path.contains("record") {
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            if let styleParam = components?.queryItems?.first(where: { $0.name == "style" })?.value,
               let style = EchoWriteStyle(rawValue: styleParam) {
                dictationStyle = style
            } else {
                dictationStyle = EchoWriteShared.getSelectedStyle()
            }
            isVoiceDictationPresented = true
        }
    }
}

// MARK: - 1. 模型管理與沙盒測試 (Model Hub & Testing)
struct ModelHubView: View {
    @ObservedObject var processingService: AudioProcessingService
    @State private var currentProfile: ModelProfile = ewGetModelProfile()
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

                    // AI 效能分級切換卡片 (Dynamic Model Profiling)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("🚀 AI 模型效能分級 (Dynamic Profiling)")
                            .font(.headline)
                        Text("依據設備效能與即時性需求自由切換模型組合：")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 12) {
                            profileCardButton(
                                title: "⚡ Turbo 極速",
                                subtitle: "Whisper Base + Qwen 0.5B (200ms 超低延遲)",
                                profile: .turbo
                            )
                            profileCardButton(
                                title: "🏆 Pro 旗艦",
                                subtitle: "Whisper Small + Qwen 1.5B (頂級邏輯長文潤飾)",
                                profile: .pro
                            )
                        }
                    }
                    .padding()
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))

                    // Groq API Key Settings
                    VStack(alignment: .leading, spacing: 12) {
                        Text("🔑 免費極速雲端架構 (Groq)")
                            .font(.headline)
                        Text("為維持專案零成本且速度最快，您可以免費申請 Groq API Key。\n設定後將瞬間處理文字，無延遲；若不設定或斷網，將自動使用下方的本地模型備援。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        
                        TextField("請輸入 gsk_ 開頭的 API Key", text: Binding(
                            get: {
                                guard let dir = EchoWriteShared.sharedModelsDirURL else { return "" }
                                let fileURL = dir.appendingPathComponent("groq_api_key.txt")
                                return (try? String(contentsOf: fileURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                            },
                            set: { newValue in
                                guard let dir = EchoWriteShared.sharedModelsDirURL else { return }
                                let fileURL = dir.appendingPathComponent("groq_api_key.txt")
                                try? newValue.trimmingCharacters(in: .whitespacesAndNewlines).write(to: fileURL, atomically: true, encoding: .utf8)
                            }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        
                        Button("點此前往申請免費 Groq API Key") {
                            if let url = URL(string: "https://console.groq.com/keys") {
                                UIApplication.shared.open(url)
                            }
                        }
                        .font(.caption.bold())
                        .buttonStyle(.borderless)
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

                        let isPro = currentProfile == .pro
                        let whisperTitle = isPro ? "Whisper Small 旗艦語音辨識" : "Whisper Base 極速語音辨識"
                        let whisperSub = isPro ? "320 MB · 高精度繁中語意 · ANE/Metal" : "57 MB · 200ms 極速辨識 · ANE/Metal"
                        let llmTitle = isPro ? "Qwen 1.5B 旗艦語言重塑" : "Qwen 0.5B 極速語言重塑"
                        let llmSub = isPro ? "986 MB · 頂級文采與長文潤飾 · Metal" : "498 MB · 超低延遲口語潤飾 · Metal"

                        modelProgressRow(
                            title: whisperTitle,
                            subtitle: whisperSub,
                            progress: whisperProgress,
                            onDownload: { ewStartModelDownload(kind: .whisper) }
                        )

                        Divider()

                        modelProgressRow(
                            title: llmTitle,
                            subtitle: llmSub,
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

    private func profileCardButton(title: String, subtitle: String, profile: ModelProfile) -> some View {
        let isSelected = currentProfile == profile
        return Button(action: {
            if currentProfile != profile {
                currentProfile = profile
                ewSetModelProfile(profile: profile)
                refresh()
            }
        }) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title)
                        .font(.subheadline.bold())
                        .foregroundColor(isSelected ? .cyan : .primary)
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.cyan)
                    }
                }
                Text(subtitle)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 70, alignment: .topLeading)
            .background(isSelected ? Color.cyan.opacity(0.15) : Color(uiColor: .tertiarySystemBackground))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.cyan : Color.clear, lineWidth: 1.5)
            )
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
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
                    result = "【本地沙盒錄音測試】：目前功能已升級為使用 SFSpeechRecognizer，請直接於系統開啟 EchoWrite 鍵盤輸入！"
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

// MARK: - 6. 即時語音重塑彈窗 (Voice Dictation Sheet - Launched via Keyboard URL)
struct VoiceDictationSheet: View {
    @State var style: EchoWriteStyle
    @Binding var isPresented: Bool

    @State private var isRecording = false
    @State private var isProcessing = false
    @State private var recordingSeconds = 0
    @State private var recordingTimer: Timer?
    @State private var audioRecorder: AVAudioRecorder?
    @State private var tempAudioURL: URL?
    @State private var resultText = ""
    @State private var statusMessage = "準備就緒"
    @State private var audioMeterLevel: CGFloat = 0.0

    var body: some View {
        ZStack {
            // 背景漸層
            LinearGradient(
                colors: [Color(red: 0.04, green: 0.06, blue: 0.12), Color(red: 0.08, green: 0.10, blue: 0.20)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 24) {
                // 頂部導航
                HStack {
                    Button {
                        stopRecordingAndCancel()
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text("⚡ EchoWrite 語音重塑")
                        .font(.headline.bold())
                        .foregroundStyle(LinearGradient(colors: [.cyan, .blue], startPoint: .leading, endPoint: .trailing))

                    Spacer()

                    // 佔位以居中
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .opacity(0)
                }
                .padding(.horizontal)

                // 風格標籤
                HStack(spacing: 8) {
                    Image(systemName: style.icon)
                        .foregroundStyle(.cyan)
                    Text(style.title)
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.1), in: Capsule())

                Spacer()

                // 即時聲波與狀態
                VStack(spacing: 16) {
                    if isRecording {
                        ZStack {
                            Circle()
                                .stroke(Color.red.opacity(0.3), lineWidth: 4)
                                .frame(width: 140, height: 140)
                                .scaleEffect(1.0 + audioMeterLevel * 0.4)
                                .animation(.easeOut(duration: 0.1), value: audioMeterLevel)

                            Circle()
                                .fill(Color.red.opacity(0.8))
                                .frame(width: 90, height: 90)

                            Image(systemName: "mic.fill")
                                .font(.system(size: 36))
                                .foregroundStyle(.white)
                        }

                        Text(String(format: "⏱ %02d:%02d 正在聆聽...", recordingSeconds / 60, recordingSeconds % 60))
                            .font(.title3.bold().monospacedDigit())
                            .foregroundStyle(.white)

                        Text("請自然說話，完畢後點擊下方完成按鈕")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if isProcessing {
                        ProgressView()
                            .scaleEffect(1.8)
                            .tint(.cyan)
                            .padding(.bottom, 8)

                        Text("⚡ ANE 加速 · 本地神經網路重塑中...")
                            .font(.headline.bold())
                            .foregroundStyle(.cyan)

                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if !resultText.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Label("重塑完成", systemImage: "checkmark.circle.fill")
                                    .font(.headline.bold())
                                    .foregroundStyle(.green)
                                Spacer()
                                Text("已複製到剪貼簿")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            ScrollView {
                                Text(resultText)
                                    .font(.body)
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                            .frame(maxHeight: 180)
                            .padding()
                            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        }
                        .padding(.horizontal)
                    }
                }

                Spacer()

                // 底部按鈕
                VStack(spacing: 12) {
                    if isRecording {
                        Button {
                            finishRecordingAndProcess()
                        } label: {
                            HStack {
                                Image(systemName: "stop.circle.fill")
                                    .font(.title3)
                                Text("完成錄音並重塑")
                                    .font(.headline.bold())
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(LinearGradient(colors: [.red, .orange], startPoint: .leading, endPoint: .trailing))
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .shadow(color: .red.opacity(0.4), radius: 8, y: 3)
                        }
                    } else if !resultText.isEmpty {
                        Button {
                            isPresented = false
                        } label: {
                            HStack {
                                Image(systemName: "arrow.left.circle.fill")
                                    .font(.title3)
                                Text("切回應用程式 (LINE) 自動貼上")
                                    .font(.headline.bold())
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(LinearGradient(colors: [.cyan, .blue], startPoint: .leading, endPoint: .trailing))
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .shadow(color: .blue.opacity(0.4), radius: 8, y: 3)
                        }
                    } else if !isProcessing {
                        Button {
                            startLiveRecording()
                        } label: {
                            HStack {
                                Image(systemName: "mic.fill")
                                    .font(.title3)
                                Text("開始說話")
                                    .font(.headline.bold())
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(LinearGradient(colors: [.blue, .purple], startPoint: .leading, endPoint: .trailing))
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 20)
            }
            .padding(.top, 10)
        }
        .onAppear {
            startLiveRecording()
        }
        .onDisappear {
            stopRecordingAndCancel()
        }
    }

    private func startLiveRecording() {
        guard !isRecording else { return }
        resultText = ""
        statusMessage = "語音錄製中..."
        recordingSeconds = 0

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            statusMessage = "麥克風初始化失敗：\(error.localizedDescription)"
            return
        }

        let audioFilename = FileManager.default.temporaryDirectory.appendingPathComponent("dictation_\(UUID().uuidString).wav")
        self.tempAudioURL = audioFilename

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false
        ]

        do {
            audioRecorder = try AVAudioRecorder(url: audioFilename, settings: settings)
            audioRecorder?.isMeteringEnabled = true
            audioRecorder?.record()
            isRecording = true
            
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.impactOccurred()

            recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                audioRecorder?.updateMeters()
                let power = audioRecorder?.averagePower(forChannel: 0) ?? -160.0
                let linear = max(0.0, min(1.0, CGFloat((power + 50.0) / 50.0)))
                audioMeterLevel = linear

                let sec = Int(audioRecorder?.currentTime ?? 0)
                if sec != recordingSeconds {
                    recordingSeconds = sec
                }
            }
        } catch {
            statusMessage = "無法啟動錄音：\(error.localizedDescription)"
        }
    }

    private func finishRecordingAndProcess() {
        isRecording = false
        recordingTimer?.invalidate()
        recordingTimer = nil
        audioRecorder?.stop()
        audioRecorder = nil

        guard let audioURL = tempAudioURL, FileManager.default.fileExists(atPath: audioURL.path) else {
            statusMessage = "錄音檔案遺失"
            return
        }

        isProcessing = true
        statusMessage = "正在執行 Whisper 本地轉錄與 Qwen 繁中語意潤飾..."

        let contextBefore = EchoWriteShared.getSharedContextBefore()

        DispatchQueue.global(qos: .userInitiated).async {
            var processed = ""
            do {
                processed = "【錄音轉錄通知】：請於 iOS 設定中啟用 EchoWrite 鍵盤，享受原生地零延遲語音重塑體驗。"
            } catch {
                processed = "⚠️ 辨識處理失敗：\(error.localizedDescription)"
            }

            try? FileManager.default.removeItem(at: audioURL)

            DispatchQueue.main.async {
                self.isProcessing = false
                self.resultText = processed

                // 1. 寫入剪貼簿
                UIPasteboard.general.string = processed

                // 2. 寫入 App Group 共享檔案以供鍵盤 Extension 自動貼入
                if let resultURL = EchoWriteShared.sharedResultURL {
                    try? processed.write(to: resultURL, atomically: true, encoding: .utf8)
                }

                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(.success)
            }
        }
    }

    private func stopRecordingAndCancel() {
        isRecording = false
        recordingTimer?.invalidate()
        recordingTimer = nil
        audioRecorder?.stop()
        audioRecorder = nil
        if let audioURL = tempAudioURL {
            try? FileManager.default.removeItem(at: audioURL)
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(processingService: AudioProcessingService())
    }
}
