// EchoWrite Background Service Worker (background.js)

let offscreenReady = false;
let pendingMessages = [];

// 建立或取得 Offscreen Document
async function setupOffscreen() {
  if (!chrome.offscreen) {
    console.warn('EchoWrite: chrome.offscreen is not supported in this browser.');
    return false;
  }
  let hasExisting = false;
  try {
    const existingContexts = await chrome.runtime.getContexts({
      contextTypes: ['OFFSCREEN_DOCUMENT']
    });
    hasExisting = existingContexts.length > 0;
  } catch (e) {
    console.log('EchoWrite: chrome.runtime.getContexts is not supported in this version. Falling back to create try-catch.');
  }

  if (hasExisting) {
    return true;
  }

  try {
    offscreenReady = false;
    await chrome.offscreen.createDocument({
      url: 'offscreen.html',
      reasons: ['AUDIO_PLAYBACK', 'USER_MEDIA'],
      justification: 'EchoWrite needs microphone access and DOM APIs to record audio and run local WebGPU LLM.'
    });
    console.log('EchoWrite: Offscreen document created, waiting for ready signal...');
    return true;
  } catch (err) {
    const errMsg = err?.message || String(err);
    if (errMsg.includes('Only a single offscreen document')) {
      console.log('EchoWrite: Offscreen document already exists.');
      return true;
    } else {
      console.error('EchoWrite: Failed to create offscreen document:', err);
      return false;
    }
  }
}

// 傳送訊息給 Offscreen Document，若尚未就緒則排入佇列
function sendToOffscreen(message) {
  if (offscreenReady) {
    chrome.runtime.sendMessage(message).catch((err) => {
      console.warn("EchoWrite: Message to offscreen failed:", err.message);
    });
  } else {
    console.log("EchoWrite: Offscreen not ready yet, queuing message:", message.type);
    pendingMessages.push(message);
  }
}

// 清空排隊的訊息
function flushPendingMessages() {
  console.log("EchoWrite: Flushing " + pendingMessages.length + " pending messages.");
  const msgs = pendingMessages.slice();
  pendingMessages = [];
  for (const msg of msgs) {
    chrome.runtime.sendMessage(msg).catch((err) => {
      console.warn("EchoWrite: Flushed message failed:", err.message);
    });
  }
}

// 監聽全域快捷鍵 Alt + S
chrome.commands.onCommand.addListener(async (command) => {
  if (command === 'toggle-recording') {
    const success = await setupOffscreen();
    if (success) {
      sendToOffscreen({ target: 'offscreen', type: 'toggle-recording' });
    }
  }
});

// 監聽來自 content.js 或 offscreen.js 的訊息並進行轉發
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  // ====== 來自 offscreen.js 的就緒信號 ======
  if (message.target === 'background' && message.type === 'offscreen-ready') {
    console.log("EchoWrite: Offscreen document is ready!");
    offscreenReady = true;
    flushPendingMessages();
    return;
  }

  if (message.target === 'background') {
    // 處理 content.js 發起的錄音與切換事件
    if (message.type === 'toggle-recording') {
      setupOffscreen().then((success) => {
        if (success) sendToOffscreen({ target: 'offscreen', type: 'toggle-recording' });
      });
    } else if (message.type === 'start-recording-request') {
      setupOffscreen().then((success) => {
        if (success) sendToOffscreen({ target: 'offscreen', type: 'start-recording' });
      });
    } else if (message.type === 'stop-recording-request') {
      sendToOffscreen({ target: 'offscreen', type: 'stop-recording' });
    } else if (message.type === 'request-mic-permission') {
      chrome.tabs.create({ url: 'request_mic.html' });
    } else if (message.type === 'get-style') {
      chrome.storage.local.get(['selectedStyle'], (data) => {
        sendResponse({ style: data.selectedStyle || 'smart' });
      });
      return true; // 異步回應
    } else if (message.type === 'save-history') {
      chrome.storage.local.get(['history'], (data) => {
        const history = data.history || [];
        history.unshift(message.text);
        chrome.storage.local.set({ history: history.slice(0, 50) });
      });
    }
  } else if (message.target === 'content') {
    // 轉發來自 offscreen.js 處理完畢的成果到當前的 content tab
    chrome.tabs.query({ active: true, lastFocusedWindow: true }, (tabs) => {
      if (tabs[0]) {
        chrome.tabs.sendMessage(tabs[0].id, message).catch((e) => {
          // 靜默捕獲分頁關閉等異常
        });
      }
    });
  }
  return true;
});
