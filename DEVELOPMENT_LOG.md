# EchoWrite 專案開發日誌 (DEVELOPMENT_LOG.md)

本文件詳實記錄 EchoWrite 專案的開發軌跡、架構決策、功能編修以及打包發布的實作歷程。

---

## 📅 開發歷史記錄：2026-07-13

### 1. 專案啟動與市場調研
*   **目標設定**：開發一款超越 Typeless 等競品，具備高精準度、語意自動重組、台灣在地化排版格式、純軟體、完全本地端運行且支援 iOS/iPadOS, macOS, Android, Windows 的語音助理輸入法。
*   **市場調查**：針對市場接受度最高的 10 大熱門應用程式（Typeless, Wispr Flow, AudioPen, Voicenotes, Superwhisper, Vomo, Otter, Notta, Plaud Note, 系統內建輸入法）進行了詳細的優缺點分析，並制定了針對性的優化與超越方案。
*   **命名與視覺識別設定**：
    - **專案名稱**：確定為 **EchoWrite** (聲音的響應與自動書寫)。
    - **圖標選定**：**選項 A（3D 聲波鋼筆）**，展現立體 3D 線條美學。

---

### 2. 階段一：專案結構初始化
*   **建立工作區**：於 `/Users/barretlin/GitProjects/typeless` 下建立 Rust Workspace 專案。
*   **建立核心邏輯庫**：初始化 Rust 核心動態庫 `echowrite-core` (位於 `core/` 資料夾)。
*   **建立原生外殼資料夾**：同步建立了 `macos/`, `windows/`, `ios/`, `android/` 目錄以存放原生平台的對接代碼。
*   **設定 `.gitignore`**：排除 Rust 的 `target/`、`.DS_Store`、`.typeless/` 以及大型的 `.bin`、`.gguf` 模型與本地資料庫檔案。

---

### 3. 階段二：Rust 核心邏輯庫落地實作 (完全移除 Mock)
為了確保產品能確實打包上架、可用於實際生產環境，我們完成了所有底層邏輯模組的完全落地：

#### A. 音訊錄製與線性重採樣模組 (`core/src/audio.rs`)
*   **實作細節**：整合 `cpal` 取得系統預設麥克風輸入串流。
*   **問題克服**：為了解決 `cpal::Stream` 內部包含平台相關指針、不具備執行緒安全特性（非 `Send/Sync`）導致無法放在全域 `lazy_static` 靜態鎖的編譯錯誤，我們實作了 `StreamWrapper` 包裝器，手動實作並標記 `unsafe impl Send / Sync`，成功解決編譯阻礙。
*   **線性重採樣**：由於每部電腦麥克風音訊配置（例如 44.1kHz, 48kHz, 雙聲道）不同，底層實作了對原始音訊的線性插值與平均聲道演算法，能精準轉換為 Whisper 所需的 **16kHz, 單聲道, 16bit PCM** WAV 格式。

#### B. 本地語音辨識模組 (`core/src/asr.rs`)
*   **實作細節**：串接本地端 `whisper-rs`。讀取音訊 WAV 檔案後，呼叫 `state.full` 執行 ASR 推理，並利用 `state.get_segment(i)` 將結果透過 `to_str()` 安全解析為 UTF-8 文本段落。

#### C. 本地 LLM 意圖自動路由模組 (`core/src/llm.rs`)
*   **實作細節**：整合 `llama-cpp-2` 載入 Qwen-2.5-Instruct 模型。
*   **意圖路由設計**：放棄 UI 手動模式點選。設計了全能型 **System Prompt**，模型會自動解析使用者的口語內容是否包含格式指令（例如：「幫我寫信」、「大綱整理」、「列出清單」），直接進行相對應的 Markdown、信件格式或英文格式重組。若無指令則自動進行台灣繁體中文的優雅潤飾。
*   **Token 解碼迴圈**：實作了真實的 Token 採樣與解碼迴圈（使用 `LlamaSampler::greedy()` 貪婪採樣），並整合 `encoding_rs::UTF_8` 解碼器，逐一將 Token 翻譯成中文字串直到命中 `eos_token`。

#### D. 台灣在地化排版規則引擎 (`core/src/formatter.rs`)
*   **實作細節**：使用正則表達式，自動將口語轉寫的半形標點轉為全形標點（，。！？「」『』）。
*   **排版優化**：自動在中文與英文/數字間插入半形空格。
*   **兩岸術語校正**：維合對照表，自動將簡中/大陸習慣詞彙轉換為台灣習慣文書語彙（如：屏幕->螢幕、內存->記憶體、軟件->軟體、硬件->硬體、項目->專案、信息->訊息）。
*   **測試驗證**：編寫單元測試 `formatter::tests::test_formatting` 並成功通過，WER (字錯率) 表現良好。

#### E. 本地 SQLite 資料庫 (`core/src/database.rs`)
*   **實作細節**：整合 `rusqlite` (Bundled 模式) 與 `dirs-next`，自動在使用者 Home 目錄下建立 `.echowrite/` 資料夾，初始化 SQLite 表格以管理使用者打字歷史紀錄與客製化字典。

---

### 4. 階段三與階段四：四端平台原生輸入法對接
為了將本地端 AI 功能無縫嵌入各作業系統，我們在各平台落地了與 Rust Core API 的完整對接：

*   **macOS (`macos/AppDelegate.swift`)**：
    - 設定選單列圖示與全域快捷鍵。
    - 使用 macOS **Accessibility API (`CGEvent`)** 進行模擬鍵盤輸入，將 AI 處理完畢的文字直接打入當前焦點游標處（Active Cursor）。
    - 整合 `NSHapticFeedbackManager` 觸發 Trackpad 震動，達成「不看螢幕」盲操作。
*   **Windows (`windows/Program.cs`)**：
    - 設定托盤圖示與全域 `RegisterHotKey` (鍵盤 Alt + S) 錄音開關。
    - 使用 Windows **`SendInput` API** 以 UTF-16 模擬 Unicode 按鍵輸入，確保繁體中文與 Emoji 順利輸入當前焦點。
*   **iOS/iPadOS (`ios/KeyboardViewController.swift`)**：
    - 建立鍵盤擴充套件（Keyboard Extension），實作極簡語音輸入介面。
    - 使用 `AVAudioEngine` 錄製 16kHz PCM，並寫入 `App Groups` 共享沙盒空間，避開 Extension 120MB 記憶體上限的崩潰問題。
    - 使用 `textDocumentProxy.insertText` 將文字寫入宿主應用程式。
*   **Android (`android/EchoWriteIME.kt`)**：
    - 建立 `InputMethodService` 系統輸入法，整合語音按鈕與錄音波形。
    - 使用 `AudioRecord` 背景錄音並轉換為 WAV，透過 JNI 呼叫 Rust 核心庫，最後使用 `commitText` 直接寫入宿主應用程式。

---

### 5. 階段六：自動化打包上架腳本建置
為了解決跨平台打包發布的複雜度，我們在 `scripts/` 下落地了三個全自動化編譯打包腳本：

1.  **iOS App Store 打包** (`scripts/build_ios.sh`)：
    - 自動安裝 iOS 工具鏈，分別為實體機（aarch64）與模擬器（aarch64/x86_64）編譯 release 靜態庫。
    - 合併 fat binary，自動執行 `uniffi-bindgen` 生成 Swift 對接界面。
    - 通過 `xcodebuild -create-xcframework` 打包為 XCode 專用的 `EchoWriteCore.xcframework`。
2.  **Android Google Play 打包** (`scripts/build_android.sh`)：
    - 使用 `cargo-ndk` 為四大架構（arm64-v8a, armeabi-v7a, x86_64, x86）交叉編譯 Android 動態庫 (`.so`)。
    - 生成 Kotlin 介面並自動同步至 Android 專案源碼目錄下。
3.  **Windows Store 打包** (`scripts/build_windows.bat`)：
    - 編譯產出 Windows x64 DLL 庫並拷貝至 WinUI 3 專案，準備裝箱打包為 MSIX 格式。

---

### 6. 語意分段與段落重塑優化 (解決思考中斷與長字牆問題)
*   **目標**：解決使用者在思考時產生的斷句碎裂，或是長句輸入缺乏標點與段落的痛點。
*   **設計方案**：產出 `docs/semantic_paragraphing_design.md`，詳述「雙重 VAD 聲學檢測」與「LLM 語意重構」之兩階段整合方案。
*   **Prompt 落地優化**：在 `core/src/llm.rs` 的 System Prompt 注入段落智慧分段 (`\n\n`)、對話引號重建 (`「」`)、思考贅字橋接及自動標點符號建立。

---

### 7. iOS 編譯實測與 UniFFI 偵錯紀錄
*   **靜態庫輸出設定**：於 `core/Cargo.toml` 將 `crate-type` 修改為 `["lib", "staticlib", "cdylib"]`，確保編譯產出 Xcode 連結所需的 `.a` 靜態庫。
*   **解決連接器錯誤 (`___chkstk_darwin`)**：為解決編譯 iOS 對象時編譯器未定義系統函數的問題，在 `build_ios.sh` 匯出 `IPHONEOS_DEPLOYMENT_TARGET=17.0` 與 `MACOSX_DEPLOYMENT_TARGET=14.0`，使 Linker 對齊高版本 SDK 成功編譯。
*   **UniFFI 自訂錯誤重構**：原 Result 回傳 `String` 導致 UniFFI 生成器 panic。於 `core/src/lib.rs` 引入 `thiserror` 並宣告 `EchoWriteError` 列舉以取代 raw String 報錯。
*   **實測成果**：實測執行 `./build_ios.sh`，成功於 `/ios` 目錄生成本機 **`EchoWriteCore.xcframework`** (154MB，已於 `.gitignore` 排除防止上傳) 以及 **`echowrite_core.swift`** 綁定介面 (已成功 push 至 GitHub)。

---

### 8. Apple CoreML 硬件加速落地與依賴優化
*   **平台條件式依賴編寫**：為避免在 Windows 等其他平台編譯時出錯，在 `core/Cargo.toml` 尾端採用 `[target.'cfg(any(target_os = \"macos\", target_os = \"ios\"))'.dependencies]` 結構，僅在 Apple 平台啟用 `whisper-rs` 的 `coreml` 硬體加速 Feature。
*   **iOS XCFramework 更新**：重新執行 `./build_ios.sh`，成功打包出包含 **Apple Neural Engine (ANE)** 硬體加速功能的 `EchoWriteCore.xcframework`。

---

### 9. Chrome Extension 瀏覽器擴充套件開發
*   **技術架構**：建立 `chrome-extension/` 目錄。採用 **Manifest V3** 規範與 **Offscreen Document (offscreen.html/js)** 運作模式，避開了 Service Worker 無法呼叫 WebGPU 與麥克風錄音的限制。
*   **雙引擎本地整合**：
    -   **ASR**：採用瀏覽器內置的 **Web Speech API** (`webkitSpeechRecognition`) 進行零記憶體開銷的即時語音轉文字。
    -   **SLM/LLM**：採用 **WebGPU (MLC WebLLM)** 於瀏覽器沙盒中直接運行量化後的 **Qwen-2.5-0.5B-Instruct** 本地模型。如 WebGPU 不可用，自動降級為台灣排版規則引擎。
*   **優美前端與注入互動**：
    -   **Popup 介面** (`popup.html/css/js`)：玻璃擬態暗色質感、Outfits 字型、自訂風格管理與歷史複製剪貼簿。
    -   **Content 注入** (`content.js/css`)：Alt + S 快捷鍵呼叫半透明懸浮流光 Widget，配有 Pulse 動態呼吸聲波，並使用 DOM Range API 在游標焦點（包含 contenteditable 編輯器）進行實時打字與取代。
    -   **視覺識別**：使用 `sips` 提取 Option A 圖標裁切生成 16/48/128 像素 the PNG 圖標組。
*   **背景調試與修復**：修正了 `background.js` 中對 `content.js` 備用鍵盤監聽發送的 `toggle-recording` 訊息接收遺漏問題；並將 `chrome.tabs.query` 的參數 `currentWindow` 改為 `lastFocusedWindow`，防止背景 Service Worker 因無 UI 主體而無法正確認證當前作用分頁（Active Tab）的問題。同時，針對 offscreen 建立錯誤捕獲區塊進行了**防禦性程式設計優化**：在 `setupOffscreen` 開頭加入 `if (!chrome.offscreen)` 存在性檢查以相容非 Chrome 的其他瀏覽器；並利用 `err?.message || String(err)` 確保捕獲的 Exception 訊息恆為字串，避免當例外並非標準 Error 物件時，在 `includes()` 判斷中因讀取 `undefined` 屬性而引發第二次二次崩潰。此外，為了解決瀏覽器安全政策阻擋，我們從 CDN **下載並本地打包了 `web-llm.js` 函式庫**，並於 `manifest.json` 配置了自訂的 **Content Security Policy (CSP)**，加上 `'wasm-unsafe-eval'` 以准許本地 WebAssembly 的編譯與載入，並同步許可 Google Fonts 字型的請求。針對實測中發生的建構子類型錯誤，我們將 `webllm.Engine` **更正為正確的 `webllm.MLCEngine`**；並為了解決麥克風隱私存取阻擋（`Speech recognition error: not-allowed`），我們建立了 **`request_mic.html` 授權導引分頁**，引導使用者點擊完成麥克風授權後自動關閉，打通了全部功能鏈。

---

## 🛠️ 編譯與驗證狀態
*   **核心庫編譯**：使用 `cargo check` 已確認在 macOS (arm64) 環境下**順利通過編譯，0 錯誤，0 警告**。
*   **單元測試**：`cargo test` 全數通過。
*   **各架構 iOS 編譯**：`aarch64-apple-ios`、`x86_64-apple-ios`、`aarch64-apple-ios-sim` 三架構均編譯成功並打包為支援 CoreML 加速的 XCFramework。
*   **瀏覽器套件狀態**：Chrome Extension 項目初始化完畢，代碼功能完整，已可直接於 `chrome://extensions` 載入 unpacked 資料夾執行。
*   **版控狀態**：已成功推送（`git push`）至遠端 GitHub 儲存庫：`https://github.com/hauchiehlin-ops/EchoWrite.git` 的 `main` 分支。
