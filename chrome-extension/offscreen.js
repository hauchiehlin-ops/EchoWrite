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

const SYSTEM_PROMPT = 
  "你是一個極致智慧的台灣語音助理，專門將零碎、雜亂的口語轉寫稿重塑為優雅、邏輯清晰、段落分明的書面文章。請嚴格遵守以下重構規範：\n" +
  "1. 標點重建：分析語意結構，在合理處添加逗號與句號。若有說話引用，必須使用繁體引號「」與『』。\n" +
  "2. 智慧分段：當說話內容出現主題轉換（如從敘事轉為條列、或討論不同議題）時，自動插入換行符號（\\n\\n）進行分段，避免產生冗長字牆。\n" +
  "3. 智慧橋接：自動修正使用者的思考停頓、口吃、改口與贅詞（例如：將『我們明天...呃...那個...兩點開會』自動橋接為『我們明天兩點開會。』）。\n" +
  "4. 在地化規範：使用台灣繁體標點。中英文/數字夾雜時自動加空格。將大陸用語（如：屏幕、內存、軟件）轉換為台灣用語（如：螢幕、記憶體、軟體）。\n" +
  "5. 輸出限制：直接輸出重構後的文本，絕對不可包含 any 你自己的說明、旁白、引言或客套回應。";

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
      console.log("EchoWrite: 正在載入本地端 Qwen 0.5B 模型...");
      
      // 監聽加載進度
      engine.setInitProgressCallback((report) => {
        chrome.runtime.sendMessage({
          target: 'content',
          type: 'model-progress',
          progress: Math.round(report.progress * 100)
        });
      });

      await engine.reload("Qwen2.5-0.5B-Instruct-q4f16_1-MLC");
      console.log("EchoWrite: 本地 WebGPU 模型載入完成！");
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
function startSpeechRecognition() {
  if (isRecording) return;
  isRecording = true;
  rawTranscript = "";
  latestInterim = "";
  isProcessingPending = false;

  const SpeechRecognition = window.SpeechRecognition || window.webkitSpeechRecognition;
  if (!SpeechRecognition) {
    console.error("EchoWrite: 瀏覽器不支援 Web Speech API");
    return;
  }

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
    rawTranscript = "";

    for (let i = 0; i < event.results.length; ++i) {
      if (event.results[i].isFinal) {
        rawTranscript += event.results[i][0].transcript;
      } else {
        interimTranscript += event.results[i][0].transcript;
      }
    }
    latestInterim = interimTranscript;

    console.log("EchoWrite onresult: final='" + rawTranscript + "' interim='" + interimTranscript + "'");

    // 將即時轉寫文字送回頁面（樂觀排版 / 即時回饋）
    chrome.runtime.sendMessage({
      target: 'content',
      type: 'interim-result',
      text: rawTranscript + interimTranscript
    });
  };

  recognition.onerror = (event) => {
    console.error("Speech recognition error: ", event.error);
    if (event.error === 'not-allowed') {
      chrome.runtime.sendMessage({ target: 'background', type: 'request-mic-permission' });
    }
    stopRecording(true);
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
}

// 停止錄音
function stopRecording(isError = false) {
  if (!isRecording) return;
  isRecording = false;

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

// 處理並發送重組潤飾結果
async function processAndSendResult() {
  let textToProcess = rawTranscript.trim();
  if (!textToProcess) {
    textToProcess = latestInterim.trim();
  }

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

      const reply = await engine.chat.completions.create({
        messages: messages,
        temperature: 0.3
      });
      resultText = reply.choices[0].message.content;
    } catch (err) {
      console.error("WebLLM 推理失敗，降級為規則排版", err);
      resultText = fallbackFormat(textToProcess);
    }
  } else {
    // 降級為規則排版
    resultText = fallbackFormat(textToProcess);
  }

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

  return formatted;
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
        startSpeechRecognition();
        initWebLLM(); // 背景默默熱加載 WebLLM
      }
    } else if (message.type === 'start-recording') {
      startSpeechRecognition();
    } else if (message.type === 'stop-recording') {
      stopRecording();
    }
  }
});
