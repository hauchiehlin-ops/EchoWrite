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
    console.log('EchoWrite: chrome.runtime.getContexts not supported, falling back.');
  }

  if (hasExisting) {
    console.log('EchoWrite: Offscreen document already exists, marking as ready.');
    offscreenReady = true; // 已存在的 offscreen 一定已完成載入
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

// 監聽全域快捷鍵 Alt + S
chrome.commands.onCommand.addListener(async (command) => {
  console.log('EchoWrite: Command received:', command);
  if (command === 'toggle-recording') {
    const success = await setupOffscreen();
    console.log('EchoWrite: setupOffscreen result:', success, 'offscreenReady:', offscreenReady);
    if (success) {
      sendToOffscreen({ target: 'offscreen', type: 'toggle-recording' });
    }
  }
});

// 監聽來自 content.js 或 offscreen.js 的訊息並進行轉發
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  // ====== 來自 offscreen.js 的就緒信號 ======
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
    } else if (message.type === 'save-history') {
      chrome.storage.local.get(['history'], (data) => {
        const history = data.history || [];
        history.unshift(message.text);
        chrome.storage.local.set({ history: history.slice(0, 50) });
      });
    }
  } else if (message.target === 'content') {
    // 轉發來自 offscreen.js 的成果到當前 content tab
    console.log('EchoWrite: Forwarding to content tab:', message.type);
    chrome.tabs.query({ active: true, lastFocusedWindow: true }, (tabs) => {
      if (tabs[0]) {
        console.log('EchoWrite: Sending to tab', tabs[0].id);
        chrome.tabs.sendMessage(tabs[0].id, message).catch((e) => {
          console.warn('EchoWrite: Failed to send to tab:', e.message);
        });
      } else {
        console.warn('EchoWrite: No active tab found!');
      }
    });
  }
  return true;
});

console.log('EchoWrite: background.js loaded.');
