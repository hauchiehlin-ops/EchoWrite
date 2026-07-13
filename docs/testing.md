# 測試涵蓋範圍與手動 QA 檢查清單

## 自動化測試（可在任何開發機 / CI 上執行）

```bash
cargo test -p echowrite-core --lib     # 單元測試
cargo bench -p echowrite-core          # 效能基準
```

- `core/src/formatter.rs`：台灣在地化排版規則的完整單元測試（詞彙轉換、全形標點、
  中英文間距、空輸入、冪等性）。
- `core/src/models.rs`：模型目錄解析（`ECHOWRITE_MODEL_DIR` 覆寫）、`is_model_ready`、
  下載進度狀態機（`NotStarted → Downloading → Ready/Failed`）、已就緒時 `start_download`
  的短路邏輯。這些測試序列化執行（`ENV_LOCK`），因為 `ECHOWRITE_MODEL_DIR` 是行程層級
  的環境變數，並在隔離的臨時目錄中執行，不會互相污染或污染開發機上的真實模型目錄。
- `core/benches/formatter_bench.rs`：`format_text` 在短句與 5KB 長文本下的效能基準
  （criterion）。

## 為什麼沒有自動化 Whisper / LLM 整合測試

`asr::transcribe` 與 `llm::polish_text` 需要：
1. 實際下載 Whisper（約 140MB）與 Qwen（約 400MB～1GB）模型檔案。
2. 真實麥克風錄音或至少一段已知內容的 WAV 音訊檔案。
3. 在 CI/沙箱環境中通常沒有 GPU/ANE，純 CPU 推理一次呼叫可能耗時數十秒。

因此這類測試不適合放進一般 `cargo test`（會拖慢每次開發迭代、且需要網路存取
外部模型倉庫），改為下方的手動 QA 檢查清單，建議在每次觸及 `asr.rs` / `llm.rs` /
`models.rs` 下載邏輯後，於至少一個真機/模擬器上跑過一輪。

## 手動 QA 檢查清單

### 模型下載（各平台皆須驗證一次）
- [ ] 首次啟動、無本地模型時，UI 正確顯示「下載中」與百分比進度
- [ ] 下載完成後 UI 自動切換為「就緒」，錄音按鈕從鎖定變為可用
- [ ] 中斷網路後啟動下載，UI 顯示失敗狀態而非卡死
- [ ] 已下載完成後重啟 App／擴充套件，不會重新觸發下載（`is_model_ready` 短路生效）

### 端對端語音流程（各平台皆須驗證一次）
- [ ] 錄下一段包含常見同音字錯誤情境的中文語音（如「因為」vs「因位」），確認
      重組後文字修正正確
- [ ] 加入一筆自訂詞彙（如產品名/人名），確認同樣發音下 ASR 優先辨識為該詞彙
- [ ] 錄音中途取消（Chrome：Esc 或 ✕ 按鈕；iOS/Android：向左滑動）：確認**沒有**任何
      文字被插入，也沒有觸發 AI 推理（可用網路請求記錄或日誌確認）
- [ ] 中文/英文/數字夾雜語句：確認格式化後正確加上半形空格
- [ ] 標點符號自動補齊：語音無明顯停頓時仍能產生合理句讀

### Chrome 擴充套件專項
- [ ] `popup.html` 的 WebGPU 狀態徽章與真實 `navigator.gpu` 可用性一致（可透過
      `chrome://flags` 停用 WebGPU 測試降級路徑是否顯示「規則排版模式」）
- [ ] 串流輸出：觀察懸浮視窗文字是否逐字/逐詞出現，而非整段一次跳出
- [ ] 樂觀打字：在純 `<input>`/`<textarea>` 欄位測試邊說邊打入；在 contenteditable
      編輯器（如實際的 Notion/Slack 頁面）測試維持「說完才插入」且沒有把畫面弄亂
- [ ] 錄音時長顯示與實際錄音秒數一致

### iOS 專項
- [ ] Keyboard Extension 記憶體佔用（Xcode Debug Navigator 或 Instruments）全程低於
      120MB —— 這是最容易在新增功能時不小心破壞的紅線
- [ ] 主 App 未啟動時使用鍵盤錄音：確認逾時後正確提示「請先開啟 EchoWrite App」，
      而非無限轉圈
- [ ] 主 App 啟動後，鍵盤發出的請求能在合理時間內收到結果並插入文字

### Android 專項
- [ ] IME 服務記憶體與主要 App 進程分離運作正常（背景服務未被系統回收前提下）
- [ ] 滑動取消手勢與一般點擊互不干擾（快速點擊不會被誤判為取消）

### macOS / Windows 專項
- [ ] 選單列／系統匣圖示在下載中／就緒／失敗三種狀態下文字正確
- [ ] Metal（macOS）/ CoreML 是否實際生效：可透過 Activity Monitor 的 GPU 分頁或
      `Console.app` 過濾 "Core ML" 關鍵字觀察是否有 ANE 相關日誌
