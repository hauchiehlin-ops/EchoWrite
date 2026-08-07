// EchoWrite Popup logic (popup.js)

document.addEventListener('DOMContentLoaded', () => {
  const modelCards = document.querySelectorAll('.model-section .style-card');
  const styleCards = document.querySelectorAll('.style-section .style-card');
  const historyList = document.getElementById('historyList');

  detectWebGPUStatus();

  // 1. 載入並還原已選定的風格與模型
  chrome.storage.local.get(['selectedStyle', 'selectedModel', 'history', 'modelLoadState', 'modelLoadModel', 'modelLoadError'], (data) => {
    if (data.selectedStyle) {
      styleCards.forEach(card => {
        if (card.dataset.style === data.selectedStyle) {
          setActiveCard(card, styleCards);
        }
      });
    }

    if (data.selectedModel) {
      modelCards.forEach(card => {
        if (card.dataset.model === data.selectedModel) {
          setActiveCard(card, modelCards);
        }
      });
    }

    // 2. 載入歷史記錄列表
    if (data.history && data.history.length > 0) {
      renderHistory(data.history);
    }

    renderModelLoadState(data.modelLoadState, data.modelLoadModel, data.modelLoadError);
  });

  chrome.storage.onChanged.addListener((changes, areaName) => {
    if (areaName !== 'local') return;
    if (changes.modelLoadState || changes.modelLoadModel || changes.modelLoadError) {
      chrome.storage.local.get(['modelLoadState', 'modelLoadModel', 'modelLoadError'], (data) => {
        renderModelLoadState(data.modelLoadState, data.modelLoadModel, data.modelLoadError);
      });
    }
  });

  // 3. 模型卡片切換事件
  modelCards.forEach(card => {
    card.addEventListener('click', () => {
      setActiveCard(card, modelCards);
      const model = card.dataset.model;
      chrome.storage.local.set({ selectedModel: model }, () => {
        console.log('EchoWrite: 模型已更新為 ' + model);
        // 通知 background -> offscreen 重新加載新模型
        chrome.runtime.sendMessage({ target: 'background', type: 'model-changed', model: model });
      });
    });
  });

  // 4. 風格卡片切換點擊事件
  styleCards.forEach(card => {
    card.addEventListener('click', () => {
      setActiveCard(card, styleCards);
      const style = card.dataset.style;
      chrome.storage.local.set({ selectedStyle: style }, () => {
        console.log('EchoWrite:風格偏好已更新為 ' + style);
      });
    });
  });

  function setActiveCard(activeCard, group) {
    group.forEach(card => card.classList.remove('active'));
    activeCard.classList.add('active');
  }

  function renderHistory(items) {
    historyList.innerHTML = '';
    // 只顯示最新的 5 筆
    items.slice(0, 5).forEach(text => {
      const div = document.createElement('div');
      div.className = 'history-item';
      div.textContent = text;
      div.title = '點擊複製此紀錄';
      div.addEventListener('click', () => {
        navigator.clipboard.writeText(text).then(() => {
          // 臨時改變文字表示複製成功
          const originalText = div.textContent;
          div.textContent = '✨ 已複製到剪貼簿！';
          div.style.color = '#10b981';
          setTimeout(() => {
            div.textContent = originalText;
            div.style.color = '';
          }, 1000);
        });
      });
      historyList.appendChild(div);
    });
  }
});

function renderModelLoadState(state, model, error) {
  const statusText = document.getElementById('statusText');
  const statusDot = document.getElementById('statusDot');
  const badge = document.getElementById('gpuBadge');

  if (!statusText || !statusDot || !badge) return;

  if (!state) return;

  if (state === 'loading') {
    statusDot.className = 'status-dot yellow';
    badge.textContent = '模型載入中';
    statusText.textContent = model ? `正在載入 ${model}...` : '正在載入本地模型...';
    return;
  }

  if (state === 'ready') {
    statusDot.className = 'status-dot green';
    badge.textContent = 'WebGPU Local';
    statusText.textContent = model ? `模型已就緒：${model}` : '本地模型已就緒';
    return;
  }

  if (state === 'failed') {
    statusDot.className = 'status-dot red';
    badge.textContent = '模型失敗';
    statusText.textContent = error ? `模型載入失敗：${error}` : '模型載入失敗，請重試';
    return;
  }

  if (state === 'fallback') {
    statusDot.className = 'status-dot yellow';
    badge.textContent = '規則排版模式';
    statusText.textContent = '此裝置不支援 WebGPU，將使用規則排版降級';
  }
}

// 偵測真實的 WebGPU 可用性與 GPU 資訊，取代原本寫死的「WebGPU 引擎就緒」文字
// （無論瀏覽器是否真的支援 WebGPU 都顯示同樣的字樣是誤導使用者的）。
async function detectWebGPUStatus() {
  const badge = document.getElementById('gpuBadge');
  const statusDot = document.getElementById('statusDot');
  const statusText = document.getElementById('statusText');

  if (!badge || !statusDot || !statusText) return;

  if (!navigator.gpu) {
    badge.textContent = '規則排版模式';
    statusDot.className = 'status-dot yellow';
    statusText.textContent = '此瀏覽器不支援 WebGPU，將使用規則排版降級';
    return;
  }

  try {
    const adapter = await navigator.gpu.requestAdapter();
    if (!adapter) {
      badge.textContent = '規則排版模式';
      statusDot.className = 'status-dot yellow';
      statusText.textContent = '找不到可用的 GPU，將使用規則排版降級';
      return;
    }

    badge.textContent = 'WebGPU Local';
    statusDot.className = 'status-dot green';

    let gpuLabel = 'WebGPU 引擎就緒';
    try {
      const info = adapter.info || (await adapter.requestAdapterInfo?.());
      if (info?.description || info?.vendor) {
        gpuLabel = `WebGPU 就緒（${info.description || info.vendor}）`;
      }
    } catch (e) {
      // requestAdapterInfo 在部分瀏覽器版本受限，忽略即可，不影響主要狀態顯示
    }
    statusText.textContent = gpuLabel;
  } catch (err) {
    badge.textContent = '規則排版模式';
    statusDot.className = 'status-dot red';
    statusText.textContent = 'WebGPU 偵測失敗，將使用規則排版降級';
    console.warn('EchoWrite: WebGPU detection failed:', err);
  }
}
