# EchoWrite 瀏覽器運行可行性與架構方案 (web_browser_support.md)

這是一個非常前瞻性的問題！

目前我們的 **EchoWrite** 架構是針對 **iOS, Android, macOS, Windows** 的「系統級原生輸入法」設計的，共享核心使用 Rust 編譯為原生 C-ABI 靜態/動態庫。

如果要將 EchoWrite 移植到 **瀏覽器環境**（例如：作為一個 Web App，或是 Chrome/Edge 瀏覽器擴充套件），目前的原生 Rust 程式碼**無法直接開箱即用**。但透過 **WebAssembly (Wasm)** 與瀏覽器特有的 **WebGPU / Web Speech API**，我們完全可以實現一個「網頁版/瀏覽器套件版」的 EchoWrite。

以下是瀏覽器運行的可行性分析與架構移植方案：

---

## 1. 核心技術挑戰與 Web 替代方案

在網頁（Sandbox 沙盒）環境中，原生的系統 API 與檔案 C 庫無法直接執行，必須進行以下替換：

| 原生核心模組 | 原生依賴庫 | 瀏覽器 (Web) 替代方案 | 評估與說明 |
| :--- | :--- | :--- | :--- |
| **音訊錄製** | `cpal` | **Web Audio API** (`getUserMedia`) | 透過瀏覽器安全授權麥克風，使用 Web Audio API 收集 PCM 資料。 |
| **語音轉文字** | `whisper.cpp` | **Web Speech API** 或 **ONNX Runtime Web** | 1. 優先使用瀏覽器內建 `window.SpeechRecognition` (極快、免載入模型)。<br>2. 若要純本地端，可將 Whisper 轉為 Wasm/WebNN。 |
| **AI 語意潤飾** | `llama.cpp` | **WebGPU** (`@mlc-ai/web-llm`) | 透過 WebGPU 呼叫顯示卡，在瀏覽器沙盒內直接運行量化後的 Qwen-2.5-0.5B (速度極快，可達 30+ tokens/sec)。 |
| **本地資料庫** | `rusqlite` | **IndexedDB** 或 **OPFS** | 瀏覽器不支援直接讀寫 SQLite 檔案，需改用 IndexedDB 或 Origin Private File System 儲存歷史紀錄。 |
| **游標自動打字** | 系統 API | **DOM Event / Document.execCommand** | 在網頁中，透過 JS 監聽焦點元素，直接插入文字到 `input`, `textarea` 或 `contenteditable` 容器中。 |

---

## 2. 瀏覽器運行的兩種主要形態

### 形態 A：Chrome / Edge 瀏覽器擴充套件 (Chrome Extension) —— 推薦
這是最貼近原生操作體驗的作法，可以讓使用者在「所有網頁的輸入框」中一鍵語音打字。
*   **使用者體驗**：
    -   使用者在 Chrome 任何輸入框中，按下 `Alt + S` 快捷鍵。
    -   輸入框右下角出現微型的 3D 聲波流光球。
    -   說完後，AI 直接在網頁輸入框中打出排版流暢的繁體中文。
*   **技術實現**：
    -   使用 Extension 的 **Content Script** 注入全域鍵盤監聽。
    -   使用 **Background Service Worker** 載入 WebLLM 引擎，保持模型常駐記憶體。
    -   免去下載桌面端軟體的門檻，市場接受度極高。

### 形態 B：獨立網頁應用 (Web App / PWA)
建立一個精美的 PWA (漸進式網頁應用) 網站，提供一個「智慧語音筆記本 / 語音重組板」。
*   **使用者體驗**：
    -   使用者打開 `https://echowrite.app` 網站。
    -   點擊網頁中心的 3D 聲波筆按鈕，開始說話。
    -   網頁即時呈現 ASR 轉寫字串，並在說完後以動畫顯示 LLM 潤飾段落。
    -   提供「一鍵複製」或「分享到 Line/Slack」的按鈕。

---

## 3. Web 版本移植實作指南

如果您決定開發瀏覽器版本，我們建議在專案中新增一個 `web/` 資料夾，並採取以下輕量化實作：

### 步驟 1：網頁端音訊錄製 (Javascript)
```javascript
// 取得瀏覽器麥克風音訊
const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
const audioContext = new AudioContext({ sampleRate: 16000 }); // 強制 16kHz
const source = audioContext.createMediaStreamSource(stream);
const processor = audioContext.createScriptProcessor(4096, 1, 1);

processor.onaudioprocess = (e) => {
    const inputData = e.inputBuffer.getChannelData(0);
    // 將 f32 PCM 傳送至 Wasm ASR 暫存區
};
source.connect(processor);
processor.connect(audioContext.destination);
```

### 步驟 2：利用 WebGPU 載入本地 LLM (WebLLM)
我們可以直接在網頁端透過 `@mlc-ai/web-llm` 載入 Qwen-2.5 進行本地端推理：
```javascript
import * as webLLM from "@mlc-ai/web-llm";

// 初始化 WebGPU 本地推理引擎
const api = new webLLM.Engine();
await api.reload("Qwen2.5-0.5B-Instruct-q4f16_1-MLC");

// 執行語意潤飾
const messages = [
    { role: "system", content: "你是一個專業的台灣秘書，請將口語整理為通順繁體中文段落。" },
    { role: "user", content: rawTranscript }
];
const result = await api.chat.completions.create({ messages });
console.log(result.choices[0].message.content);
```

---

## 4. 總結建言

> [!TIP]
> 1. **目前狀態**：現有 Rust 核心庫編譯產出的 `dylib/staticlib` 是專為 OS 級原生整合設計，無法直接在網頁執行。
> 2. **擴充方向**：如果您希望 EchoWrite 能在瀏覽器運行，**最佳路徑是將其開發為 Chrome Extension**。
> 3. **開發優勢**：藉由 Chrome Extension，我們可以利用 WebGPU / Web Speech API 輕鬆實現 **100% 本地端、免安裝桌面軟體** 的極速體驗，且能夠完全避開 iOS Extension 120MB 的記憶體限制。
