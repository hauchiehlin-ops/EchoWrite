// EchoWrite Popup logic (popup.js)

document.addEventListener('DOMContentLoaded', () => {
  const modelCards = document.querySelectorAll('.model-section .style-card');
  const styleCards = document.querySelectorAll('.style-section .style-card');
  const historyList = document.getElementById('historyList');

  // 1. 載入並還原已選定的風格與模型
  chrome.storage.local.get(['selectedStyle', 'selectedModel', 'history'], (data) => {
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
