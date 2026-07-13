// EchoWrite Popup logic (popup.js)

document.addEventListener('DOMContentLoaded', () => {
  const styleCards = document.querySelectorAll('.style-card');
  const historyList = document.getElementById('historyList');

  // 1. 載入並還原已選定的風格偏好
  chrome.storage.local.get(['selectedStyle', 'history'], (data) => {
    if (data.selectedStyle) {
      styleCards.forEach(card => {
        if (card.dataset.style === data.selectedStyle) {
          setActiveCard(card);
        }
      });
    }

    // 2. 載入歷史記錄列表
    if (data.history && data.history.length > 0) {
      renderHistory(data.history);
    }
  });

  // 3. 風格卡片切換點擊事件
  styleCards.forEach(card => {
    card.addEventListener('click', () => {
      setActiveCard(card);
      const style = card.dataset.style;
      chrome.storage.local.set({ selectedStyle: style }, () => {
        console.log('EchoWrite:風格偏好已更新為 ' + style);
      });
    });
  });

  function setActiveCard(activeCard) {
    styleCards.forEach(card => card.classList.remove('active'));
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
