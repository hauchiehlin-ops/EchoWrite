import Cocoa
import SwiftUI
import AVFoundation
import Carbon

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var hotKeyRef: EventHotKeyRef?
    var isRecording = false
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 1. 初始化選單列圖示 (Menubar Status Item)
        setupStatusItem()
        
        // 2. 註冊全域雙擊 Option 鍵或全域熱鍵 (Carbon HotKey)
        registerGlobalHotKey()
        
        // 3. 載入本地 Rust 核心庫 (UniFFI 封裝的 echowrite-core)
        // 由 UniFFI 自動生成的 Swift 介面：
        do {
            let whisperPath = Bundle.main.path(forResource: "whisper-medium-q5", ofType: "bin") ?? ""
            let llmPath = Bundle.main.path(forResource: "qwen-2.5-7b-q4", ofType: "gguf") ?? ""
            try ewInitialize(whisperPath: whisperPath, llmPath: llmPath)
            print("EchoWrite: Core initialized successfully.")
        } catch {
            print("EchoWrite: Failed to initialize core: \(error)")
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
