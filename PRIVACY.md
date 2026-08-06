# EchoWrite 零雲端隱私權政策 (Zero-Cloud Privacy Policy)

**生效日期**：2026 年 8 月  
**適用版本**：EchoWrite 全平台（Windows, macOS, iOS, Android, Web Extension）

---

## 🛡️ 核心隱私原則 (Our Core Privacy Principles)

**EchoWrite 的核心理念是「本地優先、零雲端依賴 (Local-First, Zero-Cloud Dependency)」**。  
我們深知輸入法與語音文字包含個人日常溝通、商業機密與隱私密碼，因此我們在架構設計上徹底排除任何雲端資料收集。

---

### 1. 100% 晶片端離線推論 (100% On-Device Neural Inference)
- 所有的語音辨識（ASR, 如 Whisper）與語意重塑大語言模型（SLM, 如 Qwen）均在您本機的 CPU、GPU 或神經網路處理單元（Apple Neural Engine / NPU / DirectML）完全離線運算。
- 在錄音與轉寫文字的整個過程中，**絕不會將您的音訊檔案、文字草稿或處理結果上傳至任何第三方或本專案的伺服器**。即使在無網路連線（飛航模式）下，所有核心功能依然完整可用。

### 2. 零按鍵側錄與零遙測 (Zero Keylogging & Zero Telemetry)
- 軟體僅在您**主動觸發語音錄音**（如按下快捷鍵、長按錄音按鈕）的期間啟動麥克風捕捉聲音。
- 絕無背景常駐鍵盤側錄、打字監控或使用者行為追蹤（Zero Analytics / Telemetry）。

### 3. 資料僅儲存於使用者本機 (Local-Only Storage)
- 您的**自訂專屬詞庫**、**個人說話口吻範例**與**歷史轉寫紀錄**，均透過加密或本機 SQLite 資料庫儲存在您自己的裝置目錄內。
- 未經您的明確指令，資料絕不向外同步。跨裝置同步僅支援本機匯出加密字串，由您手動複製貼上完成 P2P 合併。

### 4. 系統權限使用說明 (System Permissions)
- **麥克風 (Microphone)**：僅用於捕捉輸入用語音進行本機推論。
- **輔助使用 / 完整取用權限 (Accessibility / Full Access)**：
  - **macOS / Windows**：用於將處理完成之文字自動模擬打字打入您當前聚焦之視窗。
  - **iOS / Android**：用於載入本機神經網路模型記憶體與剪貼簿歷史存取。

---

## 🔒 聯絡與開源審查 (Open Source Transparency)

EchoWrite 核心引擎採用開源架構，任何人皆可檢閱程式碼以驗證上述隱私承諾。若您有任何隱私疑慮，歡迎透過 GitHub Issues 與社群聯繫。
