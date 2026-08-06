// EchoWrite Microphone Request Logic (request_mic.js)

const grantBtn = document.getElementById('grantBtn');
const deviceList = document.getElementById('deviceList');

async function refreshDeviceList() {
  if (!navigator.mediaDevices?.enumerateDevices) {
    deviceList.textContent = '此瀏覽器無法列出麥克風裝置。';
    return;
  }

  try {
    const devices = await navigator.mediaDevices.enumerateDevices();
    const inputs = devices.filter((device) => device.kind === 'audioinput');
    if (inputs.length === 0) {
      deviceList.textContent = '目前沒有偵測到任何麥克風。請先接上 USB/藍牙麥克風或有麥克風的耳機，並到「系統設定 > 聲音 > 輸入」確認裝置。';
      return;
    }

    deviceList.textContent = '偵測到麥克風：' + inputs.map((device, index) => device.label || `麥克風 ${index + 1}`).join('、');
  } catch (err) {
    deviceList.textContent = '無法檢查麥克風裝置：' + (err?.message || String(err));
  }
}

function messageForGetUserMediaError(err) {
  if (err?.name === 'NotFoundError' || err?.name === 'DevicesNotFoundError') {
    return '找不到可用麥克風。請先接上 USB/藍牙麥克風或耳機麥克風，並到「系統設定 > 聲音 > 輸入」確認。';
  }
  if (err?.name === 'NotAllowedError' || err?.name === 'PermissionDeniedError') {
    return '麥克風權限被拒絕。請核准 Chrome 左上角的麥克風存取提示，或到「系統設定 > 隱私權與安全性 > 麥克風」允許 Chrome。';
  }
  if (err?.name === 'NotReadableError') {
    return '麥克風目前無法讀取，可能被其他應用程式占用。請關閉正在使用麥克風的 App 後再試。';
  }
  return '授權失敗：' + (err?.message || String(err));
}

refreshDeviceList();

navigator.mediaDevices?.addEventListener?.('devicechange', refreshDeviceList);

grantBtn.addEventListener('click', async () => {
  try {
    // 請求麥克風權限
    const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    
    // 取得成功，釋放串流
    stream.getTracks().forEach(track => track.stop());
    
    // 顯示成功並在 1.5 秒後自動關閉分頁
    document.querySelector('h2').textContent = '✨ 授權成功！';
    document.querySelector('p').textContent = '麥克風已成功啟用。此分頁將自動關閉，請回到原頁面點擊 EchoWrite 浮動圖標開始使用。';
    deviceList.textContent = '';
    grantBtn.style.display = 'none';
    
    setTimeout(() => {
      window.close();
    }, 1500);
  } catch (err) {
    console.error('Failed to get mic permission:', err);
    document.querySelector('p').textContent = messageForGetUserMediaError(err);
    refreshDeviceList();
  }
});
