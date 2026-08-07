import Cocoa
import SwiftUI
import AVFoundation
import Carbon
import ApplicationServices

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var hotKeyRef: EventHotKeyRef?
    var hotKeyEventHandler: EventHandlerRef?
    var isRecording = false
    var modelsReady = false
    var downloadProgressTimer: Timer?
    
    // 桌面端靈動島控制器 (Dynamic Island Controller)
    var dynamicIslandController: DynamicIslandController?
    var currentStyle: String = "casual"

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 1. 初始化靈動島浮動膠囊控制器
        dynamicIslandController = DynamicIslandController()

        // 2. 初始化選單列圖示 (Menubar Status Item)
        setupStatusItem()

        // 3. 註冊全域快捷鍵 (Command+Shift+E)
        registerGlobalHotKey()

        // 4. 設定模型專屬目錄並載入本地 Rust 核心庫
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let modelsDir = appSupport.appendingPathComponent("EchoWrite/models")
            try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
            ewSetModelDir(path: modelsDir.path)
        }

        do {
            try ewInitialize(whisperPath: "", llmPath: "")
            print("EchoWrite: Core initialized successfully.")
        } catch {
            print("EchoWrite: Failed to initialize core: \(error)")
        }

        runPermissionOnboardingForInstallOrUpdate()
        ensureModelsReady()
    }

    /// 檢查 Whisper / LLM 模型是否已存在本地；若缺少任一個則啟動背景下載，
    /// 並每秒輪詢一次進度，更新選單列圖示提示，下載完成後才允許錄音。
    func ensureModelsReady() {
        let whisperReady = ewIsModelReady(kind: .whisper)
        let llmReady = ewIsModelReady(kind: .llm)

        if whisperReady && llmReady {
            modelsReady = true
            updateStatusBarTooltip(text: "EchoWrite：就緒")
            return
        }

        modelsReady = false
        updateStatusBarTooltip(text: "EchoWrite：下載模型中…")
        if !whisperReady { ewStartModelDownload(kind: .whisper) }
        if !llmReady { ewStartModelDownload(kind: .llm) }

        downloadProgressTimer?.invalidate()
        downloadProgressTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let w = ewGetModelDownloadProgress(kind: .whisper)
            let l = ewGetModelDownloadProgress(kind: .llm)

            if w.state == .failed || l.state == .failed {
                self.updateStatusBarTooltip(text: "EchoWrite：模型下載失敗，請檢查網路後重試")
                timer.invalidate()
                return
            }

            if w.state == .ready && l.state == .ready {
                self.modelsReady = true
                self.updateStatusBarTooltip(text: "EchoWrite：就緒")
                timer.invalidate()
                return
            }

            let downloaded = w.downloadedBytes + l.downloadedBytes
            let total = max(w.totalBytes + l.totalBytes, 1)
            let percent = Int(Double(downloaded) / Double(total) * 100)
            self.updateStatusBarTooltip(text: "EchoWrite：下載模型中… \(percent)%")
        }
    }

    func updateStatusBarTooltip(text: String) {
        DispatchQueue.main.async {
            self.statusItem?.button?.toolTip = text
        }
    }
    
    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "EchoWrite")
            button.toolTip = "EchoWrite：左鍵錄音 / 右鍵選單 (Command+Shift+E)"
            button.action = #selector(statusBarClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }
    
    @objc func statusBarClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            showStatusContextMenu()
        } else {
            toggleRecording()
        }
    }

    func showStatusContextMenu() {
        let menu = NSMenu()

        // 狀態與風格
        let statusTitle = modelsReady ? "🟢 核心狀態：已就緒" : "⏳ 核心狀態：模型下載中..."
        let statusHeaderItem = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        statusHeaderItem.isEnabled = false
        menu.addItem(statusHeaderItem)

        menu.addItem(NSMenuItem.separator())

        // 風格切換子選單
        let styleSubMenu = NSMenu()
        let styles = [
            ("⚡ 極簡口語", "casual"),
            ("🏛️ 專業公文", "formal"),
            ("✉️ 商務 Email", "email"),
            ("🌐 中英雙語", "bilingual"),
            ("📋 條列重點", "bullet")
        ]
        for (title, id) in styles {
            let item = NSMenuItem(title: title + (currentStyle == id ? " ✓" : ""), action: #selector(changeStyleClicked(_:)), keyEquivalent: "")
            item.representedObject = id
            styleSubMenu.addItem(item)
        }
        let styleMenuItem = NSMenuItem(title: "🎭 語意風格切換", action: nil, keyEquivalent: "")
        styleMenuItem.submenu = styleSubMenu
        menu.addItem(styleMenuItem)

        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(title: "📖 簡易操作指南 (⌘+Shift+E)...", action: #selector(showQuickGuideClicked), keyEquivalent: "g"))
        menu.addItem(NSMenuItem(title: "🔒 零雲端隱私權政策...", action: #selector(showPrivacyPolicyClicked), keyEquivalent: "p"))

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "🚪 結束 EchoWrite", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        self.statusItem?.menu = menu
        self.statusItem?.button?.performClick(nil)
        // 彈出後清空 menu 避免後續左鍵點擊失效
        DispatchQueue.main.async {
            self.statusItem?.menu = nil
        }
    }

    @objc func changeStyleClicked(_ sender: NSMenuItem) {
        if let style = sender.representedObject as? String {
            currentStyle = style
        }
    }

    @objc func showQuickGuideClicked() {
        let alert = NSAlert()
        alert.messageText = "📖 EchoWrite macOS 快速上手指南"
        alert.informativeText = """
        1. 🎙️ 快捷輸入：
           在任何軟體 (VS Code、Word、LINE、瀏覽器) 按下 ⌘ + Shift + E 開始說話，說完再次按下即可自動打入游標處。

        2. 🗣️ 語音編輯指令：
           • 說「換行」或「下一行」➔ 插入換行符號
           • 說「空兩行」➔ 插入空行分段
           • 說「加個問號」➔ 插入全形問號
           • 說「驚嘆號」➔ 插入全形驚嘆號

        3. 🏝️ 靈動島浮動膠囊：
           錄音時螢幕上方會出現半透明膠囊，支援點擊完成或取消。
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "我知道了")
        alert.runModal()
    }

    @objc func showPrivacyPolicyClicked() {
        let alert = NSAlert()
        alert.messageText = "🔒 EchoWrite 零雲端隱私權政策"
        alert.informativeText = """
        🛡️ 100% 晶片端離線推論：
        所有的 Whisper ASR 與 Qwen SLM 完全在您的 Mac 本機 (Apple Neural Engine / Metal) 離線運算。

        🚫 零網路資料傳輸：
        音訊與文字絕不上傳至任何伺服器，斷網依然 100% 正常運作。

        🔑 零按鍵記錄 (Zero Keylogging)：
        僅在按下 ⌘+Shift+E 錄音時啟動麥克風，絕無背景側錄。

        💾 本地透明儲存：
        自訂詞庫與紀錄僅儲存在 ~/.echowrite 本機目錄。
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "確定")
        alert.runModal()
    }
    
    func toggleRecording() {
        guard ensureAccessibilityPermission(prompt: true) else {
            return
        }

        if isRecording {
            stopAndInsertText()
        } else {
            startRecording()
        }
    }
    
    func startRecording() {
        guard modelsReady else {
            print("EchoWrite: Models not ready yet, ignoring record request.")
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "模型下載中"
                alert.informativeText = "本地端語音與潤飾模型仍在下載，請稍候片刻再試一次。"
                alert.alertStyle = .informational
                alert.addButton(withTitle: "確定")
                alert.runModal()
            }
            return
        }

        // 檢查 Mac 系統麥克風授權狀態
        let authStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if authStatus == .denied || authStatus == .restricted {
            print("EchoWrite: Microphone permission denied.")
            DispatchQueue.main.async {
                self.openPrivacyPane("Privacy_Microphone")
                let alert = NSAlert()
                alert.messageText = "麥克風授權已被禁用"
                alert.informativeText = "請至 Mac 「系統設定 > 隱私權與安全性 > 麥克風」勾選並啟用 EchoWrite 的存取權限，以啟用本地端語音重組輸入。"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "確定")
                alert.runModal()
            }
            return
        } else if authStatus == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                if granted {
                    DispatchQueue.main.async {
                        self.startRecording()
                    }
                }
            }
            return
        }

        do {
            try ewStartRecording()
            isRecording = true
            updateStatusBarIcon(active: true)
            
            // 顯示桌面端靈動島浮動膠囊
            dynamicIslandController?.show(styleName: currentStyle, onFinish: { [weak self] in
                self?.stopAndInsertText()
            }, onCancel: { [weak self] in
                self?.cancelRecording()
            })

            // 觸發微弱震動 (Haptic)
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            print("EchoWrite: Recording started with Dynamic Island...")
        } catch {
            print("EchoWrite: Failed to start recording: \(error)")
        }
    }

    func cancelRecording() {
        guard isRecording else { return }
        isRecording = false
        updateStatusBarIcon(active: false)
        dynamicIslandController?.hide()
        _ = try? ewStopRecordingAndProcess(style: "casual") // 終止錄音檔並捨棄
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        print("EchoWrite: Recording cancelled.")
    }
    
    func stopAndInsertText() {
        guard isRecording else { return }
        updateStatusBarIcon(active: false)
        isRecording = false
        
        dynamicIslandController?.setProcessing()
        
        // 非同步處理，避免阻塞 UI 進程
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // 停止錄音並啟動本地 ASR + SLM 處理
                let resultText = try ewStopRecordingAndProcess(style: self.currentStyle)
                
                DispatchQueue.main.async {
                    if !resultText.isEmpty {
                        self.dynamicIslandController?.setCompleted(preview: resultText)
                        // 使用 Accessibility API / CGEvent 直接在目前焦點游標處打字
                        self.simulateTyping(text: resultText)
                    } else {
                        self.dynamicIslandController?.hide()
                    }
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                }
            } catch {
                print("EchoWrite: Process failed: \(error)")
                DispatchQueue.main.async {
                    self.dynamicIslandController?.hide()
                }
            }
        }
    }
    
    func simulateTyping(text: String) {
        guard ensureAccessibilityPermission(prompt: true) else {
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cghidEventTap)
    }
    
    func updateStatusBarIcon(active: Bool) {
        if let button = statusItem?.button {
            button.image = NSImage(
                systemSymbolName: active ? "waveform.circle.fill" : "waveform",
                accessibilityDescription: "EchoWrite Status"
            )
        }
    }
    
    func registerGlobalHotKey() {
        let hotKeyID = EventHotKeyID(signature: 0x45575254, id: 1) // EWRT
        let modifiers = UInt32(cmdKey | shiftKey)
        let keyCode = UInt32(kVK_ANSI_E)

        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if registerStatus != noErr {
            print("EchoWrite: Failed to register global hotkey Command+Shift+E: \(registerStatus)")
            return
        }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let userData = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async {
                    delegate.toggleRecording()
                }
                return noErr
            },
            1,
            &eventType,
            userData,
            &hotKeyEventHandler
        )

        if handlerStatus != noErr {
            print("EchoWrite: Failed to install global hotkey handler: \(handlerStatus)")
            return
        }

        print("EchoWrite: Global hotkey registered: Command+Shift+E")
    }

    @discardableResult
    func ensureAccessibilityPermission(prompt: Bool) -> Bool {
        let trusted = AXIsProcessTrusted()
        if trusted {
            return true
        }

        if prompt {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
            openPrivacyPane("Privacy_Accessibility")

            let alert = NSAlert()
            alert.messageText = "需要啟用輔助使用權限"
            alert.informativeText = "EchoWrite 需要「系統設定 > 隱私權與安全性 > 輔助使用」權限，才能在郵件、備忘錄、Word 等其他 App 的游標位置貼上轉寫文字。開啟後請重新啟動 EchoWrite。"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "確定")
            alert.runModal()
        }

        return false
    }

    func runPermissionOnboardingForInstallOrUpdate() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let onboardingVersion = "\(version)-\(build)"
        let defaultsKey = "LastPermissionOnboardingVersion"

        guard UserDefaults.standard.string(forKey: defaultsKey) != onboardingVersion else {
            return
        }

        UserDefaults.standard.set(onboardingVersion, forKey: defaultsKey)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            if !AXIsProcessTrusted() {
                self.ensureAccessibilityPermission(prompt: true)
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                self.ensureMicrophonePermission(prompt: true)
            }
        }
    }

    @discardableResult
    func ensureMicrophonePermission(prompt: Bool) -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            if prompt {
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
            }
            return false
        case .denied, .restricted:
            if prompt {
                openPrivacyPane("Privacy_Microphone")
                let alert = NSAlert()
                alert.messageText = "需要啟用麥克風權限"
                alert.informativeText = "EchoWrite 需要「系統設定 > 隱私權與安全性 > 麥克風」權限，才能錄音並轉成文字。"
                alert.alertStyle = .informational
                alert.addButton(withTitle: "確定")
                alert.runModal()
            }
            return false
        @unknown default:
            return false
        }
    }

    func openPrivacyPane(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - 桌面端靈動島浮動膠囊 UI (Desktop Dynamic Island Floating Capsule)

enum DynamicIslandState {
    case recording
    case processing
    case completed(String)
}

class DynamicIslandModel: ObservableObject {
    @Published var state: DynamicIslandState = .recording
    @Published var seconds: Int = 0
    @Published var styleTitle: String = "⚡ 極簡"
    @Published var previewText: String = ""

    var onFinish: (() -> Void)?
    var onCancel: (() -> Void)?
}

class DynamicIslandPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        self.isFloatingPanel = true
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = true
        self.isMovableByWindowBackground = true
    }
}

class DynamicIslandController {
    private var panel: DynamicIslandPanel?
    private var model = DynamicIslandModel()
    private var timer: Timer?

    init() {
        setupPanel()
    }

    private func setupPanel() {
        let width: CGFloat = 380
        let height: CGFloat = 68
        let screenSize = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = screenSize.origin.x + (screenSize.width - width) / 2
        let y = screenSize.origin.y + screenSize.height - height - 12

        let panel = DynamicIslandPanel(contentRect: NSRect(x: x, y: y, width: width, height: height))
        let hostingView = NSHostingView(rootView: DynamicIslandView(model: model))
        panel.contentView = hostingView
        self.panel = panel
    }

    func show(styleName: String, onFinish: @escaping () -> Void, onCancel: @escaping () -> Void) {
        model.state = .recording
        model.seconds = 0
        model.styleTitle = styleDisplayName(for: styleName)
        model.onFinish = onFinish
        model.onCancel = onCancel

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.model.seconds += 1
        }

        if let panel = panel {
            panel.alphaValue = 0.0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                panel.animator().alphaValue = 1.0
            }
        }
    }

    func setProcessing() {
        timer?.invalidate()
        model.state = .processing
    }

    func setCompleted(preview: String) {
        model.state = .completed(preview)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.hide()
        }
    }

    func hide() {
        timer?.invalidate()
        if let panel = panel {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                panel.animator().alphaValue = 0.0
            }, completionHandler: {
                panel.orderOut(nil)
            })
        }
    }

    private func styleDisplayName(for id: String) -> String {
        switch id {
        case "formal": return "🏛️ 公文"
        case "email": return "✉️ Email"
        case "bilingual": return "🌐 雙語"
        case "bullet": return "📋 條列"
        default: return "⚡ 極簡"
        }
    }
}

struct DynamicIslandView: View {
    @ObservedObject var model: DynamicIslandModel
    @State private var wavePhase = 0.0

    var body: some View {
        HStack(spacing: 12) {
            switch model.state {
            case .recording:
                // 錄音中脈衝紅點與聲波動效
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 10, height: 10)
                        .scaleEffect(1.0 + sin(wavePhase) * 0.2)
                        .animation(.easeInOut(duration: 0.6).repeatForever(), value: wavePhase)

                    // 模擬聲波柱
                    HStack(spacing: 2) {
                        ForEach(0..<4) { i in
                            RoundedRectangle(cornerRadius: 1)
                                .fill(Color.cyan)
                                .frame(width: 2.5, height: CGFloat(8 + (i % 3) * 5) + CGFloat(sin(wavePhase + Double(i)) * 4))
                        }
                    }
                }
                .padding(.leading, 8)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("正在聆聽...")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)
                        Text(String(format: "%02d:%02d", model.seconds / 60, model.seconds % 60))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.cyan)
                    }
                    Text("【\(model.styleTitle)】本地 ASR 即時辨識中")
                        .font(.system(size: 10))
                        .foregroundColor(.gray)
                }

                Spacer()

                // 完成與取消微型膠囊按鈕
                HStack(spacing: 6) {
                    Button(action: { model.onCancel?() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.gray)
                    }
                    .buttonStyle(.plain)

                    Button(action: { model.onFinish?() }) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.green)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.trailing, 8)

            case .processing:
                ProgressView()
                    .scaleEffect(0.8)
                    .progressViewStyle(CircularProgressViewStyle(tint: .cyan))
                    .padding(.leading, 8)

                VStack(alignment: .leading, spacing: 2) {
                    Text("⚡ LLM 語意重塑中...")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.cyan)
                    Text("去除贅字 · 句構重組 · 標點排版")
                        .font(.system(size: 10))
                        .foregroundColor(.gray)
                }

                Spacer()

            case .completed(let preview):
                Image(systemName: "checkmark.seal.fill")
                    .foregroundColor(.green)
                    .font(.system(size: 18))
                    .padding(.leading, 8)

                VStack(alignment: .leading, spacing: 2) {
                    Text("✅ 已自動打入游標處")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                    Text(preview.prefix(20) + (preview.count > 20 ? "..." : ""))
                        .font(.system(size: 10))
                        .foregroundColor(.gray)
                        .lineLimit(1)
                }

                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: 380, height: 60)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 30)
                    .fill(Color.black.opacity(0.82))
                RoundedRectangle(cornerRadius: 30)
                    .stroke(
                        LinearGradient(
                            colors: [Color.cyan.opacity(0.6), Color.purple.opacity(0.4), Color.clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.2
                    )
            }
        )
        .onAppear {
            withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                wavePhase = .pi * 2
            }
        }
    }
}
