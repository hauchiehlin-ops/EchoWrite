// EchoWrite Offscreen processor (offscreen.js)
// NOTE: web-llm is loaded via dynamic import() to prevent module load failures
// from killing the onMessage listener registration.

let recognition = null;
let isRecording = false;
let rawTranscript = "";
let llmEngine = null;
let initPromise = null;
let isProcessingPending = false;
let latestInterim = "";
let webllmModule = null;
let micPermissionPromptOpen = false;
let autoFinalizeTimer = null;
let hasSpeechResult = false;

// ASR 信心度門檻：低於此值的辨識結果將被過濾（0.0 ~ 1.0）
const ASR_CONFIDENCE_THRESHOLD = 0.4;
const AUTO_FINALIZE_AFTER_SILENCE_MS = 1200;

const SYSTEM_PROMPT = [
  "你是一個極致精準的台灣繁體中文語音轉文字助理。你的唯一任務是將語音辨識產出的零碎口語逐字稿，重塑為正確、流暢、段落分明的書面中文。",
  "",
  "## 核心規則",
  "1. **同音字與語音辨識錯字修正**（最高優先）：",
  "   - 語音辨識經常混淆同音字，你必須根據上下文語意自動修正。",
  "   - 常見錯誤範例：的/得/地、在/再、做/作、那/哪、他/她/它、已/以、會/回、是/式/視/試、因為/因位、所以/所已、可以/可已、這個/者個、那個/拿個、什麼/甚麼、怎麼/真麼、應該/因該。",
  "   - 專有名詞與品牌亦須修正：iPhone/愛瘋、YouTube/優兔、Google/估狗、LINE/賴。",
  "",
  "2. **標點符號重建**：",
  "   - 口語轉寫通常無標點，你必須分析語意在正確位置添加逗號（，）、句號（。）、問號（？）、驚嘆號（！）。",
  "   - 說話引用使用繁體引號「」，引號中的引號使用『』。",
  "   - 列舉項目之間使用頓號（、）。",
  "",
  "3. **智慧分段**：主題轉換時插入換行分段，避免冗長字牆。",
  "",
  "4. **口語贅詞橋接**：",
  "   - 自動移除思考停頓（呃、嗯、那個、就是說、然後然後、對對對）。",
  "   - 將改口重複修正為最終意圖，如『我明天...不對後天要開會』→『我後天要開會。』",
  "",
  "5. **台灣在地化**：",
  "   - 使用台灣繁體用語：螢幕（非屏幕）、記憶體（非內存）、軟體（非軟件）、網路（非網絡）、程式（非程序）、資料（非數據）。",
  "   - 中英文/數字之間自動加半形空格。",
  "",
  "6. **嚴格輸出限制**：只輸出重構後的文本。絕對禁止包含任何你自己的說明、旁白、引言、評論或客套語。"
].join("\n");

// 動態載入 WebLLM 模組（不阻擋核心 ASR 流程）
async function loadWebLLMModule() {
  if (webllmModule) return webllmModule;
  try {
    webllmModule = await import("./web-llm.js");
    console.log("EchoWrite: web-llm.js 模組載入成功。");
    return webllmModule;
  } catch (err) {
    console.warn("EchoWrite: web-llm.js 載入失敗，將使用規則排版降級。", err);
    return null;
  }
}

// 初始化 WebGPU MLC 引擎
async function initWebLLM() {
  if (llmEngine) return llmEngine;
  if (initPromise) return initPromise;

  initPromise = (async () => {
    if (!navigator.gpu) {
      console.warn("EchoWrite: 此瀏覽器不支援 WebGPU，將降級為規則排版模式。");
      return null;
    }

    const mod = await loadWebLLMModule();
    if (!mod || !mod.MLCEngine) {
      console.warn("EchoWrite: WebLLM 模組無法使用，降級為規則排版。");
      return null;
    }

    try {
      const engine = new mod.MLCEngine();
      
      // 取得使用者選擇的模型
      const modelName = await new Promise((resolve) => {
        chrome.runtime.sendMessage({ target: 'background', type: 'get-model' }, (response) => {
          resolve(response?.model || 'Qwen2.5-0.5B-Instruct-q4f16_1-MLC');
        });
      });

      console.log(`EchoWrite: 正在載入本地端模型 (${modelName})...`);
      
      // 監聽加載進度
      engine.setInitProgressCallback((report) => {
        chrome.runtime.sendMessage({
          target: 'content',
          type: 'model-progress',
          progress: Math.round(report.progress * 100)
        });
      });

      await engine.reload(modelName);
      console.log(`EchoWrite: 本地 WebGPU 模型載入完成 (${modelName})！`);
      llmEngine = engine;
      return llmEngine;
    } catch (error) {
      console.error("EchoWrite: 載入 WebLLM 失敗: ", error);
      llmEngine = null;
      initPromise = null; // 重置以允許下次重新嘗試
      return null;
    }
  })();

  return initPromise;
}

// 啟動 Speech Recognition
async function ensureMicrophoneAccess() {
  if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
    console.warn("EchoWrite: navigator.mediaDevices.getUserMedia 不可用，仍嘗試啟動 Web Speech API。");
    return true;
  }

  try {
    const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    stream.getTracks().forEach((track) => track.stop());
    return true;
  } catch (err) {
    const message = err?.message || String(err);
    console.warn("EchoWrite: 麥克風授權檢查失敗，將開啟授權頁。", err?.name || "", message);
    requestMicrophonePermission();
    return false;
  }
}

function requestMicrophonePermission() {
  if (micPermissionPromptOpen) return;
  micPermissionPromptOpen = true;

  chrome.runtime.sendMessage({ target: 'background', type: 'request-mic-permission' });
  chrome.runtime.sendMessage({ target: 'content', type: 'processing-finished', text: "" });

  setTimeout(() => {
    micPermissionPromptOpen = false;
  }, 5000);
}

function clearAutoFinalizeTimer() {
  if (autoFinalizeTimer) {
    clearTimeout(autoFinalizeTimer);
    autoFinalizeTimer = null;
  }
}

function scheduleAutoFinalize() {
  clearAutoFinalizeTimer();
  const textToProcess = (rawTranscript + latestInterim).trim();
  if (!textToProcess) return;

  autoFinalizeTimer = setTimeout(() => {
    autoFinalizeTimer = null;
    if (isRecording && (rawTranscript + latestInterim).trim()) {
      console.log("EchoWrite: Auto-finalizing after speech pause.");
      stopRecording();
    }
  }, AUTO_FINALIZE_AFTER_SILENCE_MS);
}

async function startSpeechRecognition() {
  if (isRecording) return;

  const hasMicAccess = await ensureMicrophoneAccess();
  if (!hasMicAccess) {
    isRecording = false;
    return false;
  }

  const SpeechRecognition = window.SpeechRecognition || window.webkitSpeechRecognition;
  if (!SpeechRecognition) {
    console.error("EchoWrite: 瀏覽器不支援 Web Speech API");
    return false;
  }

  isRecording = true;
  rawTranscript = "";
  latestInterim = "";
  isProcessingPending = false;
  hasSpeechResult = false;
  clearAutoFinalizeTimer();

  recognition = new SpeechRecognition();
  recognition.lang = 'zh-TW';
  recognition.continuous = true;
  recognition.interimResults = true;

  recognition.onstart = () => {
    console.log("EchoWrite: SpeechRecognition started.");
    chrome.runtime.sendMessage({ target: 'content', type: 'recording-started' });
  };

  recognition.onresult = (event) => {
    let interimTranscript = "";

    for (let i = event.resultIndex; i < event.results.length; ++i) {
      const result = event.results[i];
      const transcript = result[0]?.transcript || "";

      if (result.isFinal) {
        rawTranscript += transcript;
      } else {
        interimTranscript += transcript;
      }
    }
    latestInterim = interimTranscript;

    console.log("EchoWrite onresult: final='" + rawTranscript + "' interim='" + interimTranscript + "'");

    // 將即時轉寫文字送回頁面（樂觀排版 / 即時回饋）
    const visibleTranscript = rawTranscript + interimTranscript;
    if (visibleTranscript.trim()) {
      hasSpeechResult = true;
      scheduleAutoFinalize();
    }
    chrome.runtime.sendMessage({
      target: 'content',
      type: 'interim-result',
      text: visibleTranscript
    });
  };

  recognition.onerror = (event) => {
    if (event.error === 'not-allowed') {
      console.warn("EchoWrite: Speech recognition needs microphone permission.");
      requestMicrophonePermission();
      stopRecording(true);
    } else if (event.error === 'no-speech') {
      // 忽略 no-speech 錯誤，讓 onend 自動重啟，不要中斷使用者的錄音狀態
      console.log("EchoWrite: 忽略 no-speech 錯誤，保持錄音狀態...");
      if (hasSpeechResult) {
        scheduleAutoFinalize();
      }
    } else {
      stopRecording(true);
    }
  };

  recognition.onend = () => {
    console.log("EchoWrite: SpeechRecognition onend. isRecording=" + isRecording + " isProcessingPending=" + isProcessingPending);
    if (isRecording) {
      // 若非手動停止（例如環境太靜音自動中斷），則重新啟動以維持錄音連續性
      try { recognition.start(); } catch (e) {}
    } else if (isProcessingPending) {
      isProcessingPending = false;
      processAndSendResult();
    }
  };

  recognition.start();
  return true;
}

// 取消錄音：捨棄已轉寫的文字，不觸發 AI 重組，也不寫入歷史紀錄。
function cancelRecording() {
  if (!isRecording) return;
  isRecording = false;
  isProcessingPending = false;
  rawTranscript = "";
  latestInterim = "";
  hasSpeechResult = false;
  clearAutoFinalizeTimer();

  console.log("EchoWrite: cancelRecording called, discarding transcript.");

  if (recognition) {
    recognition.onend = null;
    recognition.stop();
  }
  chrome.runtime.sendMessage({ target: 'content', type: 'recording-cancelled' });
}

// 停止錄音
function stopRecording(isError = false) {
  if (!isRecording) return;
  isRecording = false;
  clearAutoFinalizeTimer();

  console.log("EchoWrite: stopRecording called. isError=" + isError + " rawTranscript='" + rawTranscript + "' latestInterim='" + latestInterim + "'");

  chrome.runtime.sendMessage({ target: 'content', type: 'recording-stopped' });

  if (isError) {
    if (recognition) {
      recognition.onend = null;
      recognition.stop();
    }
    chrome.runtime.sendMessage({ target: 'content', type: 'processing-finished', text: "" });
    return;
  }

  if (recognition) {
    isProcessingPending = true;
    recognition.stop(); // 這會觸發最後一發 onresult 與隨後的 onend
  } else {
    chrome.runtime.sendMessage({ target: 'content', type: 'processing-finished', text: "" });
  }
}

// 逐一消費 WebLLM 的串流 chunk，邊生成邊回報累積文字給 content.js 即時顯示。
async function consumeStreamAndReport(chunkStream) {
  let text = "";
  for await (const chunk of chunkStream) {
    const delta = chunk.choices?.[0]?.delta?.content || "";
    if (delta) {
      text += delta;
      chrome.runtime.sendMessage({ target: 'content', type: 'processing-stream', text: text });
    }
  }
  return text;
}

// 處理並發送重組潤飾結果
async function processAndSendResult() {
  const textToProcess = (rawTranscript + latestInterim).trim();

  console.log("EchoWrite processAndSendResult: textToProcess='" + textToProcess + "'");

  if (!textToProcess) {
    console.log("EchoWrite: 轉寫文本為空，不進行 AI 重組。");
    chrome.runtime.sendMessage({ target: 'content', type: 'processing-finished', text: "" });
    return;
  }

  // 1. 透過 background 取得使用者偏好風格
  const style = await new Promise((resolve) => {
    chrome.runtime.sendMessage({ target: 'background', type: 'get-style' }, (response) => {
      resolve(response?.style || 'smart');
    });
  });

  // 2. 進行 AI 重組潤飾
  chrome.runtime.sendMessage({ target: 'content', type: 'processing-started' });
  
  let resultText = "";
  const engine = await initWebLLM();

  if (engine) {
    try {
      const messages = [
        { role: "system", content: SYSTEM_PROMPT },
        { role: "user", content: `[風格偏好: ${style}] 請優化以下逐字稿：\n${textToProcess}` }
      ];

      // 使用串流輸出：Token 一產生就送回頁面即時顯示，降低使用者感知延遲，
      // 不用像過去一樣整段生成完才有任何畫面回饋。
      const chunkStream = await engine.chat.completions.create({
        messages: messages,
        temperature: 0.3,
        stream: true,
      });

      // 加入超時保護，避免 WebGPU worker 崩潰導致永遠卡住
      resultText = await Promise.race([
        consumeStreamAndReport(chunkStream),
        new Promise((_, reject) => setTimeout(() => reject(new Error("AI 推理超時 (WebGPU 可能已崩潰)")), 15000))
      ]);
    } catch (err) {
      console.error("WebLLM 推理失敗，降級為規則排版", err);
      resultText = fallbackFormat(textToProcess);
    }
  } else {
    // 降級為規則排版
    resultText = fallbackFormat(textToProcess);
  }

  resultText = ensureReadablePunctuation(resultText || textToProcess);

  console.log("EchoWrite: 最終輸出文字='" + resultText + "'");

  // 3. 透過 background 儲存歷史紀錄
  chrome.runtime.sendMessage({ target: 'background', type: 'save-history', text: resultText });

  // 4. 將成品送回頁面
  chrome.runtime.sendMessage({
    target: 'content',
    type: 'processing-finished',
    text: resultText
  });
}

// 規則排版引擎 (Fallback Formatter)
function fallbackFormat(text) {
  // A. 大陸詞彙轉換
  const map = {
    "屏幕": "螢幕",
    "內存": "記憶體",
    "軟件": "軟體",
    "硬件": "硬體",
    "項目": "專案",
    "信息": "訊息",
    "支持": "支援"
  };
  let formatted = text;
  for (const [k, v] of Object.entries(map)) {
    formatted = formatted.replaceAll(k, v);
  }

  // B. 全形標點轉換
  formatted = formatted
    .replace(/，/g, "，")
    .replace(/。/g, "。")
    .replace(/\?/g, "？")
    .replace(/!/g, "！");

  // C. 中英文空格
  formatted = formatted.replace(/([\u4e00-\u9fa5])([A-Za-z0-9])/g, "$1 $2");
  formatted = formatted.replace(/([A-Za-z0-9])([\u4e00-\u9fa5])/g, "$1 $2");

  return ensureReadablePunctuation(formatted);
}

function ensureReadablePunctuation(text) {
  if (!text) return "";

  let formatted = text
    .replace(/\s+/g, " ")
    .replace(/\s*([，。！？、：；])\s*/g, "$1")
    .trim();

  if (!formatted) return "";

  formatted = formatted
    .replace(/([嗎呢])(?=[\u4e00-\u9fa5A-Za-z0-9])/g, "$1？")
    .replace(/(為什麼|怎麼|可不可以|能不能|是不是|會不會)(?=[\u4e00-\u9fa5A-Za-z0-9])/g, "$1")
    .replace(/吧(?=(你|我|他|她|它|這|那|看來|為什麼|怎麼|可|不|但|所以|然後))/g, "吧。")
    .replace(/(看來|不過|但是|可是|所以|然後|另外|接著|那)(?=[\u4e00-\u9fa5A-Za-z0-9])/g, "，$1")
    .replace(/([\u4e00-\u9fa5])([A-Za-z0-9])/g, "$1 $2")
    .replace(/([A-Za-z0-9])([\u4e00-\u9fa5])/g, "$1 $2")
    .replace(/^，/, "");

  const clauses = splitLongUnpunctuatedClauses(formatted);
  formatted = clauses
    .map((clause) => punctuateClause(clause))
    .join("")
    .replace(/([。！？])([，、；：])/g, "$1")
    .replace(/，([。！？])/g, "$1")
    .replace(/([。！？])(?=[\u4e00-\u9fa5A-Za-z0-9])/g, "$1\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();

  return formatted;
}

function splitLongUnpunctuatedClauses(text) {
  const parts = text.split(/([，。！？；：\n])/);
  const clauses = [];
  for (let i = 0; i < parts.length; i += 2) {
    const body = parts[i] || "";
    const punct = parts[i + 1] || "";
    if (!body) {
      if (punct && clauses.length) clauses[clauses.length - 1] += punct;
      continue;
    }

    if (body.length <= 32 || punct) {
      clauses.push(body + punct);
      continue;
    }

    const chunks = body.split(/(?=(?:那|但是|可是|不過|所以|然後|另外|接著|看來|你為什麼|我覺得|如果))/g)
      .filter(Boolean);
    if (chunks.length <= 1) {
      clauses.push(body + punct);
    } else {
      chunks.forEach((chunk, index) => {
        clauses.push(chunk + (index === chunks.length - 1 ? punct : "，"));
      });
    }
  }
  return clauses;
}

function punctuateClause(clause) {
  if (!clause) return "";
  if (/[。！？；：\n]$/.test(clause)) return clause;
  if (/[，、]$/.test(clause)) return clause;
  if (/(嗎|呢|為什麼|怎麼|可不可以|能不能|是不是|會不會)$/.test(clause)) {
    return clause + "？";
  }
  if (clause.length >= 18) {
    return clause + "。";
  }
  return clause;
}

// ============================================================
// 訊息監聽器 — 此區塊 **必須** 在全域作用域同步註冊，
// 不可被任何 import 或 async 操作阻擋！
// ============================================================
console.log("EchoWrite: offscreen.js loaded, registering onMessage listener.");

chrome.runtime.onMessage.addListener((message) => {
  if (message.target === 'offscreen') {
    console.log("EchoWrite offscreen received:", message.type);
    if (message.type === 'toggle-recording') {
      if (isRecording) {
        stopRecording();
      } else {
        startSpeechRecognition().then((started) => {
          if (started !== false) initWebLLM(); // 背景默默熱加載 WebLLM
        });
      }
    } else if (message.type === 'start-recording') {
      startSpeechRecognition();
    } else if (message.type === 'stop-recording') {
      stopRecording();
    } else if (message.type === 'cancel-recording') {
      cancelRecording();
    } else if (message.type === 'model-changed') {
      console.log("EchoWrite: 模型設定變更，準備重新載入引擎: " + message.model);
      // 清空舊引擎，觸發重新載入
      llmEngine = null;
      initPromise = null;
      initWebLLM();
    }
  }
});

// 通知 background.js：offscreen 已就緒，可以安全接收訊息
chrome.runtime.sendMessage({ target: 'background', type: 'offscreen-ready' }).catch(() => {
  // 如果 background 尚未就緒（極罕見），靜默忽略
});
console.log("EchoWrite: offscreen-ready signal sent.");
