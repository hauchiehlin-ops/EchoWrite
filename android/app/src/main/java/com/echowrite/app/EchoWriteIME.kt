package com.echowrite.app

import android.content.Context
import android.graphics.Color
import android.inputmethodservice.InputMethodService
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import android.util.Log
import android.view.MotionEvent
import android.view.View
import android.widget.Button
import android.widget.TextView
import androidx.core.content.ContextCompat
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.concurrent.thread
import kotlin.math.sqrt

/**
 * EchoWrite Android 高辨識度 AI 輸入法
 * 特色：
 * 1. 頂部狀態列（AI 雙引擎狀態、即時秒數計時、NPU 離線加速標誌）。
 * 2. 5 大語意風格一鍵膠囊切換（極簡、公文、Email、雙語、重點）。
 * 3. 即時聲波波形動態視覺化 (Waveform Visualizer)。
 * 4. 樂觀串流排版 (Optimistic Streaming Typing - setComposingText -> commitText)。
 * 5. 滑動取消手勢與防呆捨棄。
 */
class EchoWriteIME : InputMethodService() {
    private val tag = "EchoWriteIME"
    private var isRecording = false
    private var recordButton: Button? = null
    private var statusText: TextView? = null
    private var previewText: TextView? = null
    private var timerText: TextView? = null
    private var swipeHintText: TextView? = null
    private var waveformView: WaveformVisualizerView? = null

    private val styleButtons = mutableMapOf<EchoWriteStyle, TextView>()
    private var currentStyle = EchoWriteStyle.CASUAL

    private var audioRecord: AudioRecord? = null
    private var tempAudioFile: File? = null
    private var modelsReady = false
    private val mainHandler = Handler(Looper.getMainLooper())
    private var progressPoller: Runnable? = null
    private var timerRunnable: Runnable? = null
    private var recordingSeconds = 0

    // 滑動取消手勢
    private var swipeStartX = 0f
    private var isDraggingToCancel = false

    override fun onCreateInputView(): View {
        val keyboardView = layoutInflater.inflate(R.layout.keyboard_layout, null)
        
        recordButton = keyboardView.findViewById(R.id.btn_record)
        statusText = keyboardView.findViewById(R.id.txt_status)
        previewText = keyboardView.findViewById(R.id.txt_preview)
        timerText = keyboardView.findViewById(R.id.txt_timer)
        swipeHintText = keyboardView.findViewById(R.id.txt_swipe_hint)
        waveformView = keyboardView.findViewById(R.id.waveform_view)

        // 設定模型存放路徑環境變數
        val modelsDir = File(filesDir, "models")
        if (!modelsDir.exists()) modelsDir.mkdirs()

        EchoWriteCore.setModelDir(modelsDir.absolutePath)
        EchoWriteCore.initialize("", "")
        EchoWriteCore.setSavedModelProfile(this, EchoWriteCore.getSavedModelProfile(this))
        tempAudioFile = File(cacheDir, "temp_input.wav")
        currentStyle = EchoWriteCore.getSelectedStyle(this)

        bindStyleButtons(keyboardView)
        updateStyleUI()
        ensureModelsReady()

        recordButton?.setOnClickListener {
            toggleRecording()
        }
        setupSwipeToCancel()

        return keyboardView
    }

    private fun bindStyleButtons(root: View) {
        val styleViews = mapOf(
            EchoWriteStyle.CASUAL to root.findViewById<TextView>(R.id.style_casual),
            EchoWriteStyle.FORMAL to root.findViewById<TextView>(R.id.style_formal),
            EchoWriteStyle.EMAIL to root.findViewById<TextView>(R.id.style_email),
            EchoWriteStyle.BILINGUAL to root.findViewById<TextView>(R.id.style_bilingual),
            EchoWriteStyle.BULLET to root.findViewById<TextView>(R.id.style_bullet)
        )

        for ((style, view) in styleViews) {
            if (view != null) {
                styleButtons[style] = view
                view.setOnClickListener {
                    currentStyle = style
                    EchoWriteCore.setSelectedStyle(this, style)
                    updateStyleUI()
                }
            }
        }
    }

    private fun updateStyleUI() {
        for ((style, view) in styleButtons) {
            if (style == currentStyle) {
                view.setBackgroundResource(R.drawable.capsule_selected_bg)
                view.setTextColor(Color.parseColor("#00E5FF"))
            } else {
                view.setBackgroundResource(R.drawable.capsule_unselected_bg)
                view.setTextColor(Color.parseColor("#9AA7BD"))
            }
        }
    }

    private fun setupSwipeToCancel() {
        val thresholdPx = 70 * resources.displayMetrics.density
        val maxTranslationPx = 250 * resources.displayMetrics.density

        recordButton?.setOnTouchListener { view, event ->
            when (event.action) {
                MotionEvent.ACTION_DOWN -> {
                    swipeStartX = event.rawX
                    isDraggingToCancel = false
                    false
                }
                MotionEvent.ACTION_MOVE -> {
                    if (isRecording) {
                        val dx = (event.rawX - swipeStartX).coerceAtMost(0f)
                        view.translationX = dx.coerceAtLeast(-maxTranslationPx)
                        view.alpha = 1f - (-dx / maxTranslationPx).coerceIn(0f, 0.5f)
                        isDraggingToCancel = -dx > thresholdPx

                        if (isDraggingToCancel) {
                            swipeHintText?.text = "⚠️ 放開以立即捨棄"
                            swipeHintText?.setTextColor(Color.parseColor("#FF5E62"))
                        } else {
                            swipeHintText?.text = "◀ 錄音中向左滑動取消"
                            swipeHintText?.setTextColor(Color.parseColor("#7384A6"))
                        }
                    }
                    false
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    view.animate().translationX(0f).alpha(1f).setDuration(150).start()
                    if (isDraggingToCancel && isRecording) {
                        isDraggingToCancel = false
                        cancelRecording()
                        true
                    } else {
                        isDraggingToCancel = false
                        false
                    }
                }
                else -> false
            }
        }
    }

    private fun ensureModelsReady() {
        val whisperReady = EchoWriteCore.isModelReady(EchoWriteCore.MODEL_KIND_WHISPER)
        val llmReady = EchoWriteCore.isModelReady(EchoWriteCore.MODEL_KIND_LLM)

        if (whisperReady && llmReady) {
            modelsReady = true
            setIdleState()
            return
        }

        modelsReady = false
        recordButton?.text = "⬇️ EchoWrite 本地雙引擎下載中"
        statusText?.text = "請保持連線，模型完成後即可完全離線辨識"
        if (!whisperReady) EchoWriteCore.startModelDownload(EchoWriteCore.MODEL_KIND_WHISPER)
        if (!llmReady) EchoWriteCore.startModelDownload(EchoWriteCore.MODEL_KIND_LLM)

        val poller = object : Runnable {
            override fun run() {
                val w = EchoWriteCore.getModelDownloadProgress(EchoWriteCore.MODEL_KIND_WHISPER).split(":", limit = 4)
                val l = EchoWriteCore.getModelDownloadProgress(EchoWriteCore.MODEL_KIND_LLM).split(":", limit = 4)
                val wState = w.getOrNull(0)?.toIntOrNull() ?: 0
                val lState = l.getOrNull(0)?.toIntOrNull() ?: 0
                val wError = w.getOrNull(3)?.takeIf { it.isNotBlank() }.orEmpty()
                val lError = l.getOrNull(3)?.takeIf { it.isNotBlank() }.orEmpty()

                when {
                    wState == EchoWriteCore.MODEL_STATE_FAILED || lState == EchoWriteCore.MODEL_STATE_FAILED -> {
                        val errorText = listOf(wError, lError).firstOrNull { it.isNotBlank() }.orEmpty()
                        recordButton?.text = "❌ 模型下載失敗"
                        statusText?.text = if (errorText.isNotBlank()) {
                            "請檢查網路連線：${errorText.take(28)}"
                        } else {
                            "請檢查網路連線或開啟主 App 重新下載"
                        }
                        Log.e(tag, "Model download failed. whisper=$wError llm=$lError")
                        return
                    }
                    wState == EchoWriteCore.MODEL_STATE_READY && lState == EchoWriteCore.MODEL_STATE_READY -> {
                        modelsReady = true
                        setIdleState()
                        return
                    }
                    else -> {
                        val downloaded = (w.getOrNull(1)?.toLongOrNull() ?: 0L) + (l.getOrNull(1)?.toLongOrNull() ?: 0L)
                        val total = (w.getOrNull(2)?.toLongOrNull() ?: 0L) + (l.getOrNull(2)?.toLongOrNull() ?: 0L)
                        val hasKnownTotal = total > 0
                        val percent = if (hasKnownTotal) (downloaded * 100 / total).toInt().coerceIn(0, 100) else 0
                        recordButton?.text = if (hasKnownTotal) "⬇️ 下載模型中 $percent%" else "⬇️ 續傳中..."
                        if (wError.isNotBlank() || lError.isNotBlank()) {
                            Log.w(tag, "Model download progress note. whisper=$wError llm=$lError")
                        }
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
        timerRunnable?.let { mainHandler.removeCallbacks(it) }
    }

    private fun toggleRecording() {
        if (isRecording) {
            stopRecordingAndProcessAI()
        } else {
            startRecording()
        }
    }

    private var lastRecordedContextBefore: String = ""

    private fun triggerHaptic(durationMs: Long) {
        try {
            val vibrator = getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                vibrator?.vibrate(VibrationEffect.createOneShot(durationMs, VibrationEffect.DEFAULT_AMPLITUDE))
            } else {
                @Suppress("DEPRECATION")
                vibrator?.vibrate(durationMs)
            }
        } catch (e: Exception) {
            // 忽略無震動權限或裝置無震動馬達之例外
        }
    }

    private fun startRecording() {
        if (!modelsReady) {
            recordButton?.text = "⬇️ 模型下載中，請稍候..."
            return
        }

        if (ContextCompat.checkSelfPermission(this, android.Manifest.permission.RECORD_AUDIO) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
            recordButton?.text = "❌ 請至 EchoWrite App 開啟麥克風權限"
            return
        }

        val audioFile = tempAudioFile ?: return
        if (audioFile.exists()) audioFile.delete()

        // 提取游標前文情境 Context
        lastRecordedContextBefore = currentInputConnection?.getTextBeforeCursor(150, 0)?.toString() ?: ""

        val sampleRate = 16000
        val channelConfig = AudioFormat.CHANNEL_IN_MONO
        val audioFormat = AudioFormat.ENCODING_PCM_16BIT
        val bufferSize = AudioRecord.getMinBufferSize(sampleRate, channelConfig, audioFormat)
        if (bufferSize <= 0) {
            Log.e(tag, "AudioRecord buffer init failed: bufferSize=$bufferSize")
            previewText?.text = "⚠️ 無法初始化麥克風緩衝區"
            previewText?.setTextColor(Color.parseColor("#FF9500"))
            cleanupRecordingResources()
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
        } catch (e: Exception) {
            e.printStackTrace()
            Log.e(tag, "AudioRecord start failed", e)
            previewText?.text = "⚠️ 麥克風啟動失敗：${e.message ?: "未知錯誤"}"
            previewText?.setTextColor(Color.parseColor("#FF9500"))
            cleanupRecordingResources()
            return
        }

        triggerHaptic(40)

        isRecording = true
        recordingSeconds = 0
        timerText?.text = "⏱ 00:00"
        recordButton?.text = "🔴 正在聆聽...（點擊完成）"
        recordButton?.setBackgroundResource(R.drawable.record_btn_recording_bg)
        swipeHintText?.visibility = View.VISIBLE
        previewText?.text = "🎙️ 「正在即時辨識說話內容...」"
        previewText?.setTextColor(Color.parseColor("#00E5FF"))

        // 樂觀串流草稿排版提示
        currentInputConnection?.setComposingText("📝 [語音輸入辨識中...]", 1)

        startTimer()

        thread {
            val audioData = ShortArray(bufferSize)
            FileOutputStream(audioFile).use { fos ->
                fos.write(ByteArray(44))
                var totalBytesWritten = 0

                while (isRecording) {
                    val readSize = audioRecord?.read(audioData, 0, audioData.size) ?: 0
                    if (readSize > 0) {
                        var sum = 0.0
                        for (i in 0 until readSize) {
                            val sample = audioData[i]
                            fos.write(sample.toInt() and 0xFF)
                            fos.write((sample.toInt() shr 8) and 0xFF)
                            totalBytesWritten += 2
                            val normalized = sample.toDouble() / 32768.0
                            sum += normalized * normalized
                        }
                        val rms = sqrt(sum / readSize.toDouble()).toFloat()
                        mainHandler.post {
                            waveformView?.updateAmplitude(rms * 4.0f)
                        }
                    }
                }
                writeWavHeader(audioFile, totalBytesWritten)
            }
        }
    }

    private fun cleanupRecordingResources() {
        timerRunnable?.let { mainHandler.removeCallbacks(it) }
        waveformView?.reset()

        try {
            audioRecord?.stop()
        } catch (_: Exception) {
        }
        try {
            audioRecord?.release()
        } catch (_: Exception) {
        }
        audioRecord = null

        isRecording = false
        currentInputConnection?.setComposingText("", 0)
        currentInputConnection?.finishComposingText()
        setIdleState()
    }

    private fun startTimer() {
        timerRunnable = object : Runnable {
            override fun run() {
                if (!isRecording) return
                recordingSeconds++
                val mins = recordingSeconds / 60
                val secs = recordingSeconds % 60
                timerText?.text = String.format("⏱ %02d:%02d", mins, secs)

                // 樂觀串流動態打字反饋
                val sampleDrafts = listOf("正在辨識中...", "AI 語意重塑中...", "即時處理中...")
                val currentDraft = sampleDrafts[(recordingSeconds / 2) % sampleDrafts.size]
                previewText?.text = "📝 「$currentDraft」"

                mainHandler.postDelayed(this, 1000)
            }
        }
        mainHandler.postDelayed(timerRunnable!!, 1000)
    }

    private fun cancelRecording() {
        isRecording = false
        timerRunnable?.let { mainHandler.removeCallbacks(it) }
        waveformView?.reset()

        triggerHaptic(60)

        audioRecord?.stop()
        audioRecord?.release()
        audioRecord = null

        // 樂觀排版：立即清除輸入框內的暫存 Composing 草稿
        currentInputConnection?.setComposingText("", 0)
        currentInputConnection?.finishComposingText()

        mainHandler.postDelayed({
            tempAudioFile?.let { if (it.exists()) it.delete() }
        }, 150)

        previewText?.text = "❌ 已取消本次錄音"
        previewText?.setTextColor(Color.parseColor("#9AA7BD"))
        setIdleState()
    }

    private fun stopRecordingAndProcessAI() {
        isRecording = false
        timerRunnable?.let { mainHandler.removeCallbacks(it) }
        waveformView?.reset()

        recordButton?.text = "⚡ LLM 語意重塑中..."
        recordButton?.setBackgroundResource(R.drawable.record_btn_processing_bg)
        recordButton?.isEnabled = false
        swipeHintText?.visibility = View.INVISIBLE
        previewText?.text = "⚙️ 正在套用【${currentStyle.title}】潤飾繁體中文..."

        audioRecord?.stop()
        audioRecord?.release()
        audioRecord = null

        val contextBefore = lastRecordedContextBefore

        thread {
            try {
                val audioPath = tempAudioFile?.absolutePath ?: return@thread
                val resultText = EchoWriteCore.processAudioFileWithContext(audioPath, currentStyle.id, contextBefore)

                mainHandler.post {
                    val ic = currentInputConnection
                    if (ic != null && resultText.isNotEmpty()) {
                        triggerHaptic(30)
                        // 樂觀排版原子替換：commitText 會替換 setComposingText 的草稿！
                        ic.commitText(resultText, 1)
                        previewText?.text = "✅ 已完成：${resultText.take(24)}..."
                        previewText?.setTextColor(Color.parseColor("#4CD964"))
                    } else {
                        ic?.finishComposingText()
                        previewText?.text = "💬 錄音無內容或音量過小"
                    }
                    setIdleState()
                    recordButton?.isEnabled = true
                }
            } catch (e: Exception) {
                mainHandler.post {
                    currentInputConnection?.finishComposingText()
                    recordButton?.text = "❌ 處理失敗，請重試"
                    previewText?.text = "⚠️ 本地運算錯誤：${e.message}"
                    setIdleState()
                    recordButton?.isEnabled = true
                }
            }
        }
    }

    private fun setIdleState() {
        recordButton?.text = "🎙️ 點擊開始 EchoWrite 語音重塑"
        recordButton?.setBackgroundResource(R.drawable.record_btn_bg)
        recordButton?.isEnabled = true
        swipeHintText?.visibility = View.INVISIBLE
        timerText?.text = "⏱ 00:00"
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
