// EchoWrite Microphone Request Logic (request_mic.js)

document.getElementById('grantBtn').addEventListener('click', async () => {
  try {
    // 請求麥克風權限
    const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    
    // 取得成功，釋放串流
    stream.getTracks().forEach(track => track.stop());
    
    // 顯示成功並在 1.5 秒後自動關閉分頁
    document.querySelector('h2').textContent = '✨ 授權成功！';
    document.querySelector('p').textContent = '麥克風已成功啟用。此分頁將自動關閉，請重新按下 Alt + S 開始使用 EchoWrite。';
    document.getElementById('grantBtn').style.display = 'none';
    
    setTimeout(() => {
      window.close();
    }, 1500);
  } catch (err) {
    console.error('Failed to get mic permission:', err);
    document.querySelector('p').textContent = '授權失敗：' + err.message + '。請確保您已核准瀏覽器左上角的麥克風存取提示。';
  }
});
