import Cocoa
import SwiftUI

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
            try echowrite_core.initialize(whisperPath: whisperPath, llmPath: llmPath)
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
        do {
            try echowrite_core.startRecording()
            isRecording = true
            updateStatusBarIcon(active: true)
            // 觸發微弱震動 (Haptic)
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, when: .now)
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
                let resultText = try echowrite_core.stopRecordingAndProcess(style: "professional")
                
                DispatchQueue.main.async {
                    if !resultText.isEmpty {
                        // 使用 Accessibility API / CGEvent 直接在目前焦點游標處打字
                        self.simulateTyping(text: resultText)
                    }
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, when: .now)
                }
            } catch {
                print("EchoWrite: Process failed: \(error)")
            }
        }
    }
    
    func simulateTyping(text: String) {
        // 利用 CGEvent 模擬鍵盤輸入，將文字寫入目前的文字焦點區 (Active Cursor)
        let source = CGEventSource(stateID: .combinedSessionState)
        
        // 將字串轉為 UTF-16 陣列，這對 emoji 和中文字元尤為重要
        let utf16Chars = Array(text.utf16)
        
        let postEvent = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
        postEvent?.keyboardGetUnicodeString(maxStringLength: utf16Chars.count, actualStringLength: nil, unicodeString: UnsafeMutablePointer(mutating: utf16Chars))
        postEvent?.post(tap: .cguiEventTap)
        
        let releaseEvent = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        releaseEvent?.post(tap: .cguiEventTap)
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
