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

## 🛠️ 編譯與驗證狀態
*   **核心庫編譯**：使用 `cargo check` 已確認在 macOS (arm64) 環境下**順利通過編譯，0 錯誤，0 警告**。
*   **單元測試**：`cargo test` 全數通過。
*   **版控狀態**：已成功推送（`git push`）至遠端 GitHub 儲存庫：`https://github.com/hauchiehlin-ops/EchoWrite.git` 的 `main` 分支。
