// EchoWrite Background Service Worker (background.js)

// 建立或取得 Offscreen Document
async function setupOffscreen() {
  let hasExisting = false;
  try {
    const existingContexts = await chrome.runtime.getContexts({
      contextTypes: ['OFFSCREEN_DOCUMENT']
    });
    hasExisting = existingContexts.length > 0;
  } catch (e) {
    // 降級處理：若 chrome.runtime.getContexts 不存在（例如舊版 Chrome），改用全域狀態捕獲
    console.log('EchoWrite: chrome.runtime.getContexts is not supported in this version. Falling back to create try-catch.');
  }

  if (hasExisting) {
    return;
  }

  try {
    // 建立 Offscreen 視窗以允許麥克風錄音與 WebGPU 本地推理
    await chrome.offscreen.createDocument({
      url: 'offscreen.html',
      reasons: ['AUDIO_PLAYBACK', 'USER_MEDIA'], // 用於音訊錄製與語音辨識
      justification: 'EchoWrite needs microphone access and DOM APIs to record audio and run local WebGPU LLM.'
    });
    console.log('EchoWrite: Offscreen document created.');
  } catch (err) {
    if (err.message && err.message.includes('Only a single offscreen document')) {
      console.log('EchoWrite: Offscreen document already exists.');
    } else {
      console.error('EchoWrite: Failed to create offscreen document:', err);
    }
  }
}

// 監聽全域快捷鍵 Alt + S
chrome.commands.onCommand.addListener(async (command) => {
  if (command === 'toggle-recording') {
    await setupOffscreen();
    // 傳送指令給 offscreen 開始錄音
    chrome.runtime.sendMessage({ target: 'offscreen', type: 'toggle-recording' });
  }
});

// 監聽來自 content.js 或 offscreen.js 的訊息並進行轉發
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message.target === 'background') {
    // 處理 content.js 發起的錄音事件
    if (message.type === 'start-recording-request') {
      setupOffscreen().then(() => {
        chrome.runtime.sendMessage({ target: 'offscreen', type: 'start-recording' });
      });
    } else if (message.type === 'stop-recording-request') {
      chrome.runtime.sendMessage({ target: 'offscreen', type: 'stop-recording' });
    }
  } else if (message.target === 'content') {
    // 轉發來自 offscreen.js 處理完畢的成果到當前的 content tab
    chrome.tabs.query({ active: true, currentWindow: true }, (tabs) => {
      if (tabs[0]) {
        chrome.tabs.sendMessage(tabs[0].id, message);
      }
    });
  }
  return true;
});
