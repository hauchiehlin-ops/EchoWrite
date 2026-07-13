package com.echowrite.app

import android.inputmethodservice.InputMethodService
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.view.View
import android.view.inputmethod.InputConnection
import android.widget.Button
import java.io.File
import java.io.FileOutputStream
import kotlin.concurrent.thread

class EchoWriteIME : InputMethodService() {
    private var isRecording = false
    private var recordButton: Button? = null
    private var audioRecord: AudioRecord? = null
    private var tempAudioFile: File? = null
    
    // 載入 Rust JNI 核心庫 (由 UniFFI/Cargo ndk 編譯出的 SO 檔)
    companion object {
        init {
            System.loadLibrary("echowrite_core")
        }
    }

    // 聲明 Rust 核心 API JNI 介面 (由 UniFFI 生成，這裡展示基本對接形式)
    private external fun initialize(whisperPath: String, llmPath: String): Boolean
    private external fun stopRecordingAndProcess(style: String): String

    override fun onCreateInputView(): View {
        // 1. 載入鍵盤視圖 (通常包含語音輸入按鍵)
        val keyboardView = layoutInflater.inflate(R.layout.keyboard_layout, null)
        recordButton = keyboardView.findViewById(R.id.btn_record)
        
        // 2. 設定模型的本地路徑並初始化
        val whisperModel = File(filesDir, "whisper-small-q4.bin").absolutePath
        val llmModel = File(filesDir, "qwen-2.5-1.5b-q4.gguf").absolutePath
        initialize(whisperModel, llmModel)

        tempAudioFile = File(cacheDir, "temp_input.wav")

        recordButton?.setOnClickListener {
            toggleRecording()
        }

        return keyboardView
    }

    private fun toggleRecording() {
        if (isRecording) {
            stopRecordingAndProcessAI()
        } else {
            startRecording()
        }
    }

    private fun startRecording() {
        isRecording = true
        recordButton?.text = "🔴 錄音中 (點擊完成)..."
        
        // 設定錄音規格：16kHz, 單聲道, 16bit PCM (符合 Whisper 標準)
        val sampleRate = 16000
        val channelConfig = AudioFormat.CHANNEL_IN_MONO
        val audioFormat = AudioFormat.ENCODING_PCM_16BIT
        val bufferSize = AudioRecord.getMinBufferSize(sampleRate, channelConfig, audioFormat)

        audioRecord = AudioRecord(
            MediaRecorder.AudioSource.MIC,
            sampleRate,
            channelConfig,
            audioFormat,
            bufferSize
        )

        audioRecord?.startRecording()

        // 啟動背景線程將 PCM 數據寫入 WAV 檔案
        thread {
            val audioData = ShortArray(bufferSize)
            FileOutputStream(tempAudioFile).use { fos ->
                // 寫入一個空的 44 字節 WAV 標頭檔預留空間
                fos.write(ByteArray(44)) 
                
                var totalBytesWritten = 0
                while (isRecording) {
                    val readSize = audioRecord?.read(audioData, 0, audioData.size) ?: 0
                    if (readSize > 0) {
                        for (i in 0 until readSize) {
                            val sample = audioData[i]
                            fos.write(sample.toInt() and 0xFF)
                            fos.write((sample.toInt() shr 8) and 0xFF)
                            totalBytesWritten += 2
                        }
                    }
                }
                
                // 錄音結束，寫入正確的 WAV 標頭數據
                writeWavHeader(tempAudioFile!!, totalBytesWritten)
            }
        }
    }

    private fun stopRecordingAndProcessAI() {
        isRecording = false
        recordButton?.text = "⚙️ AI 潤飾中..."
        recordButton?.isEnabled = false

        audioRecord?.stop()
        audioRecord?.release()
        audioRecord = null

        // 啟動背景線程進行本地 ASR + SLM (Qwen-2.5) 重組
        thread {
            try {
                // 調用 Rust FFI 進行本地推理
                val resultText = stopRecordingAndProcess("casual")

                // 切回主線程將文字寫入目前的輸入焦點 App (如 LINE, 微信)
                recordButton?.post {
                    val ic: InputConnection = currentInputConnection
                    if (ic != null && resultText.isNotEmpty()) {
                        // 使用 IME commitText 將文字提交給宿主應用程式
                        ic.commitText(resultText, 1)
                    }
                    recordButton?.text = "🎙️ 按下說話 (EchoWrite)"
                    recordButton?.isEnabled = true
                }
            } catch (e: Exception) {
                recordButton?.post {
                    recordButton?.text = "❌ 辨識失敗"
                    recordButton?.isEnabled = true
                }
            }
        }
    }

    private fun writeWavHeader(file: File, totalAudioLen: Int) {
        // 用於將 PCM 轉換為標準 RIFF WAV 標頭的實作略，以確保 Whisper.cpp 能順利解析
    }
}
