import Cocoa
import SwiftUI
import AVFoundation
import Carbon

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var hotKeyRef: EventHotKeyRef?
    var isRecording = false
    var modelsReady = false
    var downloadProgressTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 1. 初始化選單列圖示 (Menubar Status Item)
        setupStatusItem()

        // 2. 註冊全域雙擊 Option 鍵或全域熱鍵 (Carbon HotKey)
        registerGlobalHotKey()

        // 3. 載入本地 Rust 核心庫。傳入空字串，交由 Rust 端自動解析
        //    ~/.echowrite/models 下已下載的模型（若尚未下載會自動觸發下載）。
        do {
            try ewInitialize(whisperPath: "", llmPath: "")
            print("EchoWrite: Core initialized successfully.")
        } catch {
            print("EchoWrite: Failed to initialize core: \(error)")
        }

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
            button.action = #selector(statusBarClicked)
        }
    }
    
    @objc func statusBarClicked() {
        toggleRecording()
    }
    
    func toggleRecording() {
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
            // 觸發微弱震動 (Haptic)
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            print("EchoWrite: Recording started...")
        } catch {
            print("EchoWrite: Failed to start recording: \(error)")
        }
    }
    
    func stopAndInsertText() {
        updateStatusBarIcon(active: false)
        isRecording = false
        
        // 非同步處理，避免阻塞 UI 進程
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // 停止錄音並啟動本地 ASR + SLM 處理
                let resultText = try ewStopRecordingAndProcess(style: "professional")
                
                DispatchQueue.main.async {
                    if !resultText.isEmpty {
                        // 使用 Accessibility API / CGEvent 直接在目前焦點游標處打字
                        self.simulateTyping(text: resultText)
                    }
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                }
            } catch {
                print("EchoWrite: Process failed: \(error)")
            }
        }
    }
    
    func simulateTyping(text: String) {
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
        // 註冊 Carbon 全域快捷鍵監聽器 (雙擊 Option)
        // 此處實作略，生產環境通常使用 Carbon 的 RegisterEventHotKey
    }
}
