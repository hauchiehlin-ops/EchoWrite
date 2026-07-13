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
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.concurrent.thread

class EchoWriteIME : InputMethodService() {
    private var isRecording = false
    private var recordButton: Button? = null
    private var audioRecord: AudioRecord? = null
    private var tempAudioFile: File? = null
    private var modelsReady = false
    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())
    private var progressPoller: Runnable? = null

    companion object {
        const val MODEL_KIND_WHISPER = 0
        const val MODEL_KIND_LLM = 1
        const val MODEL_STATE_READY = 3
        const val MODEL_STATE_FAILED = 4

        init {
            System.loadLibrary("echowrite_core")
        }
    }

    // 空字串代表「未指定路徑」，交由 Rust 端自動解析本地模型目錄下已下載的模型。
    private external fun initialize(whisperPath: String, llmPath: String): Boolean
    private external fun processAudioFile(audioPath: String, style: String): String
    private external fun isModelReady(kind: Int): Boolean
    private external fun startModelDownload(kind: Int)
    /** 回傳格式：`"state:downloaded:total"` */
    private external fun getModelDownloadProgress(kind: Int): String

    override fun onCreateInputView(): View {
        val keyboardView = layoutInflater.inflate(R.layout.keyboard_layout, null)
        recordButton = keyboardView.findViewById(R.id.btn_record)

        initialize("", "")
        tempAudioFile = File(cacheDir, "temp_input.wav")
        ensureModelsReady()

        recordButton?.setOnClickListener {
            toggleRecording()
        }

        return keyboardView
    }

    private fun ensureModelsReady() {
        val whisperReady = isModelReady(MODEL_KIND_WHISPER)
        val llmReady = isModelReady(MODEL_KIND_LLM)

        if (whisperReady && llmReady) {
            modelsReady = true
            recordButton?.text = "🎙️ 按下說話 (EchoWrite)"
            return
        }

        modelsReady = false
        recordButton?.text = "⬇️ 下載模型中..."
        if (!whisperReady) startModelDownload(MODEL_KIND_WHISPER)
        if (!llmReady) startModelDownload(MODEL_KIND_LLM)

        val poller = object : Runnable {
            override fun run() {
                val w = getModelDownloadProgress(MODEL_KIND_WHISPER).split(":")
                val l = getModelDownloadProgress(MODEL_KIND_LLM).split(":")
                val wState = w[0].toIntOrNull() ?: 0
                val lState = l[0].toIntOrNull() ?: 0

                when {
                    wState == MODEL_STATE_FAILED || lState == MODEL_STATE_FAILED -> {
                        recordButton?.text = "❌ 模型下載失敗，請檢查網路"
                        return
                    }
                    wState == MODEL_STATE_READY && lState == MODEL_STATE_READY -> {
                        modelsReady = true
                        recordButton?.text = "🎙️ 按下說話 (EchoWrite)"
                        return
                    }
                    else -> {
                        val downloaded = (w.getOrNull(1)?.toLongOrNull() ?: 0L) + (l.getOrNull(1)?.toLongOrNull() ?: 0L)
                        val total = ((w.getOrNull(2)?.toLongOrNull() ?: 0L) + (l.getOrNull(2)?.toLongOrNull() ?: 0L)).coerceAtLeast(1L)
                        val percent = (downloaded * 100 / total).toInt()
                        recordButton?.text = "⬇️ 下載模型中... $percent%"
                        mainHandler.postDelayed(this, 1000)
                    }
                }
            }
        }
        progressPoller = poller
        mainHandler.postDelayed(poller, 1000)
    }

    override fun onDestroy() {
        super.onDestroy()
        progressPoller?.let { mainHandler.removeCallbacks(it) }
    }

    private fun toggleRecording() {
        if (isRecording) {
            stopRecordingAndProcessAI()
        } else {
            startRecording()
        }
    }

    private fun startRecording() {
        if (!modelsReady) {
            recordButton?.text = "⬇️ 模型下載中，請稍候..."
            return
        }

        if (androidx.core.content.ContextCompat.checkSelfPermission(this, android.Manifest.permission.RECORD_AUDIO) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
            recordButton?.text = "❌ 請啟用麥克風權限"
            return
        }

        val audioFile = tempAudioFile ?: return
        if (audioFile.exists()) {
            audioFile.delete()
        }

        isRecording = true
        recordButton?.text = "🔴 錄音中 (點擊完成)..."

        val sampleRate = 16000
        val channelConfig = AudioFormat.CHANNEL_IN_MONO
        val audioFormat = AudioFormat.ENCODING_PCM_16BIT
        val bufferSize = AudioRecord.getMinBufferSize(sampleRate, channelConfig, audioFormat)
        if (bufferSize <= 0) {
            recordButton?.text = "❌ 無法初始化錄音"
            isRecording = false
            return
        }

        try {
            audioRecord = AudioRecord(
                MediaRecorder.AudioSource.MIC,
                sampleRate,
                channelConfig,
                audioFormat,
                bufferSize
            )
            audioRecord?.startRecording()
        } catch (e: SecurityException) {
            e.printStackTrace()
            recordButton?.text = "❌ 權限不足，請授權"
            isRecording = false
            return
        } catch (e: Exception) {
            e.printStackTrace()
            recordButton?.text = "❌ 錄音啟動失敗"
            isRecording = false
            return
        }

        thread {
            val audioData = ShortArray(bufferSize)
            FileOutputStream(audioFile).use { fos ->
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

                writeWavHeader(audioFile, totalBytesWritten)
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

        thread {
            try {
                val audioPath = tempAudioFile?.absolutePath ?: return@thread
                val resultText = processAudioFile(audioPath, "casual")

                recordButton?.post {
                    val ic = currentInputConnection
                    if (ic != null && resultText.isNotEmpty()) {
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
        val totalDataLen = totalAudioLen + 36
        val sampleRate = 16000
        val channels = 1
        val byteRate = sampleRate * channels * 16 / 8

        val header = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
        header.put("RIFF".toByteArray(Charsets.US_ASCII))
        header.putInt(totalDataLen)
        header.put("WAVE".toByteArray(Charsets.US_ASCII))
        header.put("fmt ".toByteArray(Charsets.US_ASCII))
        header.putInt(16)
        header.putShort(1)
        header.putShort(channels.toShort())
        header.putInt(sampleRate)
        header.putInt(byteRate)
        header.putShort((channels * 16 / 8).toShort())
        header.putShort(16)
        header.put("data".toByteArray(Charsets.US_ASCII))
        header.putInt(totalAudioLen)

        RandomAccessFileHelper.overwrite(file, header.array())
    }
}

private object RandomAccessFileHelper {
    fun overwrite(file: File, bytes: ByteArray) {
        java.io.RandomAccessFile(file, "rw").use { raf ->
            raf.seek(0)
            raf.write(bytes)
        }
    }
}
