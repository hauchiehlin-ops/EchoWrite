// EchoWrite Background Service Worker (background.js)

let offscreenReady = false;

// ============================================================
// 擴充套件安裝/更新時，自動將 content script 注入所有已開啟的分頁
// （解決重新載入擴充套件後，舊分頁無 content script 的問題）
// ============================================================
chrome.runtime.onInstalled.addListener(async () => {
  console.log('EchoWrite: Extension installed/updated, injecting content scripts into existing tabs...');
  try {
    const tabs = await chrome.tabs.query({});
    for (const tab of tabs) {
      // 跳過 chrome:// 和 edge:// 等受保護的頁面
      if (!tab.url || tab.url.startsWith('chrome://') || tab.url.startsWith('edge://') || tab.url.startsWith('chrome-extension://') || tab.url.startsWith('about:')) {
        continue;
      }
      try {
        await chrome.scripting.executeScript({
          target: { tabId: tab.id },
          files: ['content.js']
        });
        await chrome.scripting.insertCSS({
          target: { tabId: tab.id },
          files: ['content.css']
        });
        console.log('EchoWrite: Injected content script into tab', tab.id, tab.url?.substring(0, 50));
      } catch (e) {
        // 某些受限頁面無法注入，靜默忽略
      }
    }
  } catch (e) {
    console.warn('EchoWrite: Failed to inject into existing tabs:', e);
  }
});

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
    console.log('EchoWrite: chrome.runtime.getContexts not supported, falling back.');
  }

  if (hasExisting) {
    console.log('EchoWrite: Offscreen document already exists, marking as ready.');
    offscreenReady = true;
    return true;
  }

  try {
    offscreenReady = false;
    await chrome.offscreen.createDocument({
      url: 'offscreen.html',
      reasons: ['AUDIO_PLAYBACK', 'USER_MEDIA'],
      justification: 'EchoWrite needs microphone access and DOM APIs for speech recognition.'
    });
    console.log('EchoWrite: Offscreen document created, waiting for ready signal...');

    // 等待 offscreen-ready 信號，最多等 3 秒
    await new Promise((resolve) => {
      const check = setInterval(() => {
        if (offscreenReady) {
          clearInterval(check);
          resolve();
        }
      }, 50);
      setTimeout(() => {
        clearInterval(check);
        if (!offscreenReady) {
          console.warn('EchoWrite: Offscreen ready timeout, proceeding anyway.');
          offscreenReady = true;
        }
        resolve();
      }, 3000);
    });

    return true;
  } catch (err) {
    const errMsg = err?.message || String(err);
    if (errMsg.includes('Only a single offscreen document')) {
      console.log('EchoWrite: Offscreen document already exists (from catch).');
      offscreenReady = true;
      return true;
    } else {
      console.error('EchoWrite: Failed to create offscreen document:', err);
      return false;
    }
  }
}

// 傳送訊息給 Offscreen Document
function sendToOffscreen(message) {
  console.log('EchoWrite: sendToOffscreen:', message.type, 'ready=' + offscreenReady);
  chrome.runtime.sendMessage(message).catch((err) => {
    console.warn('EchoWrite: Message to offscreen failed:', err.message);
  });
}

// 記住使用者觸發錄音時的真實分頁 ID
let lastActiveTabId = null;

// 找到使用者正在使用的「真實網頁」分頁（跳過 chrome:// 等系統頁面）
async function findUserTab() {
  // 優先使用已記錄的分頁
  if (lastActiveTabId) {
    try {
      const tab = await chrome.tabs.get(lastActiveTabId);
      if (tab && tab.url && !tab.url.startsWith('chrome://') && !tab.url.startsWith('chrome-extension://')) {
        return tab;
      }
    } catch (e) {
      // 分頁可能已關閉
    }
  }

  // 否則搜尋最近使用的一般網頁分頁
  const tabs = await chrome.tabs.query({ lastFocusedWindow: true });
  for (const tab of tabs) {
    if (tab.url && !tab.url.startsWith('chrome://') && !tab.url.startsWith('chrome-extension://') && !tab.url.startsWith('about:') && !tab.url.startsWith('edge://')) {
      return tab;
    }
  }
  return null;
}

// 嘗試將訊息送達 content script，若失敗則動態注入後重試
async function sendToContentTab(message) {
  const tab = await findUserTab();
  if (!tab) {
    console.warn('EchoWrite: No suitable tab found (all tabs are chrome:// or system pages).');
    return;
  }

  const tabId = tab.id;
  console.log('EchoWrite: Forwarding to content tab:', message.type, 'tabId=' + tabId, 'url=' + (tab.url || '').substring(0, 60));

  try {
    await chrome.tabs.sendMessage(tabId, message);
  } catch (e) {
    // content script 不存在，動態注入後重試
    console.log('EchoWrite: Content script not found, injecting dynamically...');
    try {
      await chrome.scripting.executeScript({
        target: { tabId: tabId },
        files: ['content.js']
      });
      await chrome.scripting.insertCSS({
        target: { tabId: tabId },
        files: ['content.css']
      });
      // 注入完成，重試發送
      await chrome.tabs.sendMessage(tabId, message);
      console.log('EchoWrite: Retry after injection succeeded.');
    } catch (e2) {
      console.warn('EchoWrite: Failed to inject and send:', e2.message);
    }
  }
}

// 監聽全域快捷鍵 Alt + S
chrome.commands.onCommand.addListener(async (command) => {
  console.log('EchoWrite: Command received:', command);
  if (command === 'toggle-recording') {
    // 記住使用者觸發時的活動分頁（可能是普通網頁）
    try {
      const tabs = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
      if (tabs[0] && tabs[0].url && !tabs[0].url.startsWith('chrome://')) {
        lastActiveTabId = tabs[0].id;
        console.log('EchoWrite: Stored active tab:', lastActiveTabId, tabs[0].url?.substring(0, 60));
      }
    } catch (e) {}

    const success = await setupOffscreen();
    console.log('EchoWrite: setupOffscreen result:', success);
    if (success) {
      sendToOffscreen({ target: 'offscreen', type: 'toggle-recording' });
    }
  }
});

// 監聽來自 content.js 或 offscreen.js 的訊息並進行轉發
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  // 來自 offscreen.js 的就緒信號
  if (message.target === 'background' && message.type === 'offscreen-ready') {
    console.log('EchoWrite: Offscreen ready signal received!');
    offscreenReady = true;
    return;
  }

  if (message.target === 'background') {
    if (message.type === 'toggle-recording') {
      console.log('EchoWrite: toggle-recording from content.js');
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
    } else if (message.type === 'get-model') {
      chrome.storage.local.get(['selectedModel'], (data) => {
        sendResponse({ model: data.selectedModel || 'Qwen2.5-1.5B-Instruct-q4f16_1-MLC' });
      });
      return true; // 異步回應
    } else if (message.type === 'model-changed') {
      console.log('EchoWrite: model-changed received, forwarding to offscreen');
      sendToOffscreen({ target: 'offscreen', type: 'model-changed', model: message.model });
    } else if (message.type === 'save-history') {
      chrome.storage.local.get(['history'], (data) => {
        const history = data.history || [];
        history.unshift(message.text);
        chrome.storage.local.set({ history: history.slice(0, 50) });
      });
    }
  } else if (message.target === 'content') {
    // 轉發來自 offscreen.js 的成果到當前 content tab（自動注入 fallback）
    sendToContentTab(message);
  }
  return true;
});

console.log('EchoWrite: background.js loaded.');
