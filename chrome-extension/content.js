// EchoWrite Content Script (content.js)

let activeElement = null;
let widgetEl = null;
let originalValue = "";
let originalPlaceholder = "";

// 監聽鍵盤 Alt + S 快捷鍵 (如果 commands 失敗時的備用)
window.addEventListener('keydown', (e) => {
  if (e.altKey && (e.key === 's' || e.key === 'S')) {
    e.preventDefault();
    // 取得當前聚焦元素
    activeElement = document.activeElement;
    // 請求背景 Service Worker 開啟/關閉錄音
    chrome.runtime.sendMessage({ target: 'background', type: 'toggle-recording' });
  }
});

// 監聽來自 background.js 的事件 (來自 offscreen)
chrome.runtime.onMessage.addListener((message) => {
  if (message.target === 'content') {
    switch (message.type) {
      case 'recording-started':
        activeElement = document.activeElement;
        showWidget();
        updateWidgetText("🎤 正在聆聽，請開始說話...");
        setWaveState('recording');
        break;

      case 'interim-result':
        // 即時逐字稿回饋 (樂觀顯示)
        updateWidgetText(message.text);
        break;

      case 'recording-stopped':
        updateWidgetText("🧠 錄音結束，正在呼叫本地 WebGPU 進行重組潤飾...");
        setWaveState('processing');
        break;

      case 'model-progress':
        // WebGPU 模型載入進度
        updateWidgetText(`💾 正在下載本地 AI 模型... ${message.progress}%`);
        break;

      case 'processing-started':
        updateWidgetText("✨ AI 正在進行台灣語意格式段落重塑...");
        break;

      case 'processing-finished':
        // 最終成果輸出
        insertTextIntoElement(message.text);
        hideWidget();
        break;
    }
  }
});

// 建立美麗的懸浮 UI Widget
function showWidget() {
  if (widgetEl) return;

  widgetEl = document.createElement('div');
  widgetEl.id = 'echowrite-floating-widget';
  widgetEl.innerHTML = `
    <div class="ew-card">
      <div class="ew-header">
        <div class="ew-logo-group">
          <div class="ew-dot green"></div>
          <span class="ew-title">EchoWrite AI</span>
        </div>
        <span class="ew-shortcut">Alt + S 停止</span>
      </div>
      <div class="ew-wave-wrapper">
        <div class="ew-wave-bar"></div>
        <div class="ew-wave-bar"></div>
        <div class="ew-wave-bar"></div>
        <div class="ew-wave-bar"></div>
        <div class="ew-wave-bar"></div>
        <div class="ew-wave-bar"></div>
        <div class="ew-wave-bar"></div>
        <div class="ew-wave-bar"></div>
      </div>
      <div class="ew-content-area" id="ewContent">
        🎤 正在初始化錄音...
      </div>
    </div>
  `;
  document.body.appendChild(widgetEl);
}

function hideWidget() {
  if (widgetEl) {
    widgetEl.classList.add('ew-fade-out');
    setTimeout(() => {
      if (widgetEl && widgetEl.parentNode) {
        widgetEl.parentNode.removeChild(widgetEl);
      }
      widgetEl = null;
    }, 300);
  }
}

function updateWidgetText(text) {
  const contentEl = document.getElementById('ewContent');
  if (contentEl) {
    contentEl.textContent = text || "聆聽中...";
  }
}

function setWaveState(state) {
  if (!widgetEl) return;
  const waveWrapper = widgetEl.querySelector('.ew-wave-wrapper');
  if (waveWrapper) {
    waveWrapper.className = `ew-wave-wrapper ew-state-${state}`;
  }
}

// 將文字打入當前網頁輸入焦點元素
function insertTextIntoElement(text) {
  // 優先使用啟動時捕獲的元素，若為空或 body 則降級為目前聚焦的 activeElement
  let target = activeElement;
  if (!target || target === document.body) {
    target = document.activeElement;
  }
  if (!target || !text) return;

  // 確保目標元素擁有焦點
  target.focus();

  // 優先使用 execCommand('insertText') — 這會模擬真實使用者打字，
  // 觸發所有原生瀏覽器事件（input, change, compositionend 等），
  // 確保 React / Vue / Angular / Google 等所有前端框架都能正確感知。
  const success = document.execCommand('insertText', false, text);

  if (success) {
    return; // 成功！所有事件均已被瀏覽器自動觸發
  }

  // ========== Fallback：execCommand 不支援時手動處理 ==========

  // 1. 如果是標準 Input 或 Textarea
  if (target.tagName === 'INPUT' || target.tagName === 'TEXTAREA') {
    const start = target.selectionStart;
    const end = target.selectionEnd;
    const val = target.value;
    
    target.value = val.substring(0, start) + text + val.substring(end);
    target.selectionStart = target.selectionEnd = start + text.length;
    
    // 觸發多種事件以最大化框架相容性
    target.dispatchEvent(new InputEvent('input', { bubbles: true, data: text, inputType: 'insertText' }));
    target.dispatchEvent(new Event('change', { bubbles: true }));
  } 
  // 2. 如果是富文本編輯框 (如 Notion, Slack 編輯框 contenteditable)
  else if (target.getAttribute('contenteditable') === 'true' || target.isContentEditable) {
    const selection = window.getSelection();
    if (selection.rangeCount > 0) {
      const range = selection.getRangeAt(0);
      range.deleteContents();
      const textNode = document.createTextNode(text);
      range.insertNode(textNode);
      
      range.setStartAfter(textNode);
      range.setEndAfter(textNode);
      selection.removeAllRanges();
      selection.addRange(range);
      
      target.dispatchEvent(new InputEvent('input', { bubbles: true, data: text, inputType: 'insertText' }));
    }
  }
}
