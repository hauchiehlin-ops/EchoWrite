// EchoWrite Content Script (content.js)

let activeElement = null;
let widgetEl = null;
let originalValue = "";
let originalPlaceholder = "";
let isCurrentlyRecording = false;
let durationTimer = null;
let recordingStartedAt = 0;

// 樂觀打字狀態：只在標準 <input>/<textarea> 上啟用（見 isDraftTarget 說明），
// 記錄目前已插入的「草稿文字」所在區間，讓後續更新能整段替換而非不斷疊加。
let draftStart = -1;
let draftLength = 0;

// 監聽鍵盤 Alt + S 快捷鍵 (如果 commands 失敗時的備用)
window.addEventListener('keydown', (e) => {
  if (e.altKey && (e.key === 's' || e.key === 'S')) {
    e.preventDefault();
    // 取得當前聚焦元素
    activeElement = document.activeElement;
    // 請求背景 Service Worker 開啟/關閉錄音
    chrome.runtime.sendMessage({ target: 'background', type: 'toggle-recording' });
    return;
  }

  // Esc 鍵：錄音中可直接取消，不觸發 AI 重組
  if (e.key === 'Escape' && isCurrentlyRecording) {
    e.preventDefault();
    cancelRecording();
  }
});

function cancelRecording() {
  chrome.runtime.sendMessage({ target: 'background', type: 'cancel-recording-request' });
}

function startDurationTimer() {
  recordingStartedAt = Date.now();
  stopDurationTimer();
  durationTimer = setInterval(updateDurationDisplay, 1000);
  updateDurationDisplay();
}

function stopDurationTimer() {
  if (durationTimer) {
    clearInterval(durationTimer);
    durationTimer = null;
  }
}

function updateDurationDisplay() {
  const el = widgetEl && widgetEl.querySelector('#ewDuration');
  if (!el) return;
  const elapsedSec = Math.floor((Date.now() - recordingStartedAt) / 1000);
  const mm = String(Math.floor(elapsedSec / 60)).padStart(2, '0');
  const ss = String(elapsedSec % 60).padStart(2, '0');
  el.textContent = `${mm}:${ss}`;
}

// 監聽來自 background.js 的事件 (來自 offscreen)
chrome.runtime.onMessage.addListener((message) => {
  if (message.target === 'content') {
    switch (message.type) {
      case 'recording-started':
        activeElement = document.activeElement;
        isCurrentlyRecording = true;
        showWidget();
        updateWidgetText("🎤 正在聆聽，請開始說話...");
        setWaveState('recording');
        startDurationTimer();
        beginOptimisticDraft();
        break;

      case 'interim-result':
        // 即時逐字稿回饋 (樂觀顯示)：懸浮視窗一律顯示，標準輸入框額外邊聽邊打
        updateWidgetText(message.text);
        applyDraftText(message.text);
        break;

      case 'recording-stopped':
        isCurrentlyRecording = false;
        stopDurationTimer();
        updateWidgetText("🧠 錄音結束，正在呼叫本地 WebGPU 進行重組潤飾...");
        setWaveState('processing');
        break;

      case 'recording-cancelled':
        // 使用者主動取消：捨棄轉寫內容，不插入任何文字，並清除已樂觀打入的草稿
        isCurrentlyRecording = false;
        stopDurationTimer();
        applyDraftText("");
        endOptimisticDraft();
        hideWidget();
        break;

      case 'model-progress':
        // WebGPU 模型載入進度
        updateWidgetText(`💾 正在下載本地 AI 模型... ${message.progress}%`);
        break;

      case 'processing-started':
        updateWidgetText("✨ AI 正在進行台灣語意格式段落重塑...");
        break;

      case 'processing-stream':
        // 串流 Token 即時顯示，讓使用者邊等邊看到生成內容，降低感知延遲
        updateWidgetText(message.text);
        applyDraftText(message.text);
        break;

      case 'processing-finished':
        // 最終成果輸出
        isCurrentlyRecording = false;
        stopDurationTimer();
        if (isDraftTarget()) {
          // 標準輸入框已經邊生成邊打字，這裡只需要把草稿收斂為最終版本
          applyDraftText(message.text);
        } else {
          // contenteditable 等富文本編輯器風險較高，維持「說完才一次插入」的原行為
          insertTextIntoElement(message.text);
        }
        endOptimisticDraft();
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
          <span class="ew-duration" id="ewDuration">00:00</span>
        </div>
        <div class="ew-header-actions">
          <span class="ew-shortcut">Esc 取消 · Alt+S 停止</span>
          <button type="button" class="ew-cancel-btn" id="ewCancelBtn" title="取消錄音（不會輸入任何文字）">✕</button>
        </div>
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

  const cancelBtn = widgetEl.querySelector('#ewCancelBtn');
  if (cancelBtn) {
    cancelBtn.addEventListener('click', (e) => {
      e.stopPropagation();
      cancelRecording();
    });
  }
}

function hideWidget() {
  stopDurationTimer();
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

// ============================================================
// 樂觀打字 (Optimistic Typing)
//
// 只在標準 <input>/<textarea> 上啟用：這類元素的值是單純字串，
// 「整段替換草稿區間」是無歧義、可逆的操作。像 Notion / Slack 這類
// contenteditable 富文本編輯器內部維護複雜的節點樹與框架狀態
// （React 受控元件等），若在使用者仍在說話時就不斷插入/替換文字，
// 很容易破壞其內部狀態或觸發非預期的重新渲染，因此故意不在
// contenteditable 上啟用，維持「說完才一次性插入」的原行為。
// ============================================================
// input[type] 只有這幾種支援 selectionStart/setSelectionRange；email/number/date 等
// 呼叫這些 API 會直接拋出 InvalidStateError，因此明確排除，退回懸浮視窗顯示即可。
const DRAFT_COMPATIBLE_INPUT_TYPES = new Set(['text', 'search', 'tel', 'url', 'password', '']);

function isDraftTarget() {
  const el = activeElement;
  if (!el || !document.contains(el)) return false;
  if (el.tagName === 'TEXTAREA') return true;
  if (el.tagName === 'INPUT') return DRAFT_COMPATIBLE_INPUT_TYPES.has((el.type || '').toLowerCase());
  return false;
}

function beginOptimisticDraft() {
  draftStart = -1;
  draftLength = 0;
  if (!isDraftTarget()) return;
  const el = activeElement;
  const pos = typeof el.selectionStart === 'number' ? el.selectionStart : el.value.length;
  draftStart = pos;
  draftLength = 0;
}

function endOptimisticDraft() {
  draftStart = -1;
  draftLength = 0;
}

// 將草稿區間（[draftStart, draftStart + draftLength)）整段替換為最新文字。
function applyDraftText(text) {
  if (!isDraftTarget() || draftStart < 0) return;
  const el = activeElement;
  const newText = text || "";

  try {
    el.focus();
    const rangeEnd = Math.min(draftStart + draftLength, el.value.length);
    el.setSelectionRange(draftStart, rangeEnd);

    const success = document.execCommand('insertText', false, newText);
    if (success) {
      draftLength = newText.length;
      el.setSelectionRange(draftStart + draftLength, draftStart + draftLength);
      return;
    }

    // Fallback：手動替換並觸發事件，確保框架能感知到變化。
    const val = el.value;
    el.value = val.substring(0, draftStart) + newText + val.substring(rangeEnd);
    draftLength = newText.length;
    el.selectionStart = el.selectionEnd = draftStart + draftLength;
    el.dispatchEvent(new InputEvent('input', { bubbles: true, data: newText, inputType: 'insertText' }));
  } catch (err) {
    // 某些元件（唯讀欄位等）可能拒絕程式化選取/插入，靜默略過，僅懸浮視窗仍會顯示進度
    console.warn('EchoWrite: optimistic draft update skipped:', err);
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
