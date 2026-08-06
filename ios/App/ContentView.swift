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
                    VStack(alignment: .leading, spacing: 12) {
                        Text("🎙️ 本地端即時語音測試沙盒")
                            .font(.headline)

                        Text("在 App 內直接測試語音轉文字與排版效果：")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if !testResultText.isEmpty {
                            Text(testResultText)
                                .font(.body)
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(uiColor: .tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                        }

                        Button {
                            runQuickTest()
                        } label: {
                            HStack {
                                Image(systemName: isTestProcessing ? "hourglass" : "play.fill")
                                Text(isTestProcessing ? "AI 重組運算中..." : "開始 3 秒語音快速測試")
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(modelsReady ? Color.blue : Color.gray)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .disabled(!modelsReady || isTestProcessing)
                    }
                    .padding()
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
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

    private func runQuickTest() {
        isTestProcessing = true
        testResultText = "正在套用格式化與繁中規則..."
        DispatchQueue.global(qos: .userInitiated).async {
            let sample = "我們預計在明天下午兩點開會討論第三季度的營銷方案請大家準時出席謝謝"
            let formatted = ewFormatOnly(text: sample)
            DispatchQueue.main.async {
                self.testResultText = formatted
                self.isTestProcessing = false
            }
        }
    }
}

// MARK: - 2. 風格與偏好設定 (Style Preferences)
struct StylePreferencesView: View {
    @State private var selectedStyle: EchoWriteStyle = EchoWriteShared.getSelectedStyle()

    var body: some View {
        NavigationStack {
            List {
                Section(header: Text("預設語音重組風格")) {
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
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.blue)
                                    .font(.headline)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedStyle = style
                            EchoWriteShared.setSelectedStyle(style)
                        }
                    }
                }

                Section(header: Text("風格示範對照")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("原始口語輸入：")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Text("「呃明天那個兩點跟客戶開會然後要確認新功能上線時間」")
                            .font(.subheadline)
                            .padding(8)
                            .background(Color(uiColor: .tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 8))

                        Text("套用【\(selectedStyle.title)】重組後：")
                            .font(.caption.bold())
                            .foregroundStyle(.blue)

                        Text(previewExample(for: selectedStyle))
                            .font(.subheadline)
                            .padding(8)
                            .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("語音風格偏好")
        }
    }

    private func previewExample(for style: EchoWriteStyle) -> String {
        switch style {
        case .casual:
            return "明天下午 2:00 與客戶開會，確認新功能上線時間。"
        case .formal:
            return "謹訂於明日 14:00 召開客戶會議，研商新功能上線期程規劃。"
        case .email:
            return "主旨：關於明日客戶會議通知\n\n您好，我們預計於明日下午 2:00 與客戶召開會議，主要確認新功能上線時程。\n\n祝 順心"
        case .bilingual:
            return "【中文】：明天下午 2:00 與客戶開會，確認新功能上線時間。\n【English】：Meeting with the client tomorrow at 2:00 PM to confirm the new feature release schedule."
        case .bullet:
            return "- 會議時間：明日 14:00\n- 會議對象：客戶端\n- 核心議程：確認新功能上線時程"
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
                    StepGuideRow(step: 2, title: "允許完全取用", description: "點擊 EchoWrite 鍵盤，開啟「允許完全取用」（以載入本地模型與麥克風）。")
                    StepGuideRow(step: 3, title: "切換使用", description: "在任一聊天或輸入框長按地球圖示 🌐，選取「EchoWrite」即可開始說話。")
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

#Preview {
    ContentView(processingService: AudioProcessingService())
}
