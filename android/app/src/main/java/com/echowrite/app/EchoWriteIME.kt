package com.echowrite.app

import android.content.Context
import android.graphics.Color
import android.inputmethodservice.InputMethodService
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.content.Intent
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
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

    private var speechRecognizer: SpeechRecognizer? = null
    private var lastPartialText: String = ""
    private var lastRecordedContextBefore: String = ""
    private var modelsReady = false
    private val mainHandler = Handler(Looper.getMainLooper())
    private var progressPoller: Runnable? = null
    private var timerRunnable: Runnable? = null
    private var recordingStartMs: Long = 0L

    // 底部輔助列按鍵
    private var deleteRepeatRunnable: Runnable? = null
    private var isDeleteRepeating = false

    // 滑動取消手勢
    private var swipeStartX = 0f
    private var isDraggingToCancel = false

    override fun onCreateInputView(): View {
        stopDownloadProgressPolling()
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
        bindBottomBar(keyboardView)
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

    // MARK: - 底部輔助標點列接線
    private fun bindBottomBar(root: View) {
        val punctuations = mapOf(
            R.id.key_comma     to "，",
            R.id.key_period    to "。",
            R.id.key_exclamation to "！",
            R.id.key_question  to "？",
            R.id.key_pause     to "、"
        )
        for ((id, p) in punctuations) {
            root.findViewById<Button>(id)?.setOnClickListener {
                currentInputConnection?.commitText(p, 1)
                triggerHaptic(18)
            }
        }

        // 空白鍵
        root.findViewById<Button>(R.id.key_space)?.setOnClickListener {
            currentInputConnection?.commitText(" ", 1)
            triggerHaptic(18)
        }

        // 換行鍵
        root.findViewById<Button>(R.id.key_return)?.setOnClickListener {
            currentInputConnection?.commitText("\n", 1)
            triggerHaptic(18)
        }

        // 隱藏鍵盤鍵
        root.findViewById<Button>(R.id.key_hide)?.setOnClickListener {
            requestHideSelf(0)
            triggerHaptic(25)
        }

        // 地球儀切換輸入法
        root.findViewById<Button>(R.id.key_globe)?.setOnClickListener {
            switchToNextInputMethod(false)
            triggerHaptic(18)
        }

        // 刪除鍵：單按刪一字，長按連續刪除
        val deleteBtn = root.findViewById<Button>(R.id.key_delete)
        deleteBtn?.setOnClickListener {
            currentInputConnection?.deleteSurroundingText(1, 0)
            triggerHaptic(18)
        }
        deleteBtn?.setOnLongClickListener {
            isDeleteRepeating = true
            startDeleteRepeat()
            true
        }
        deleteBtn?.setOnTouchListener { _, event ->
            if (event.action == MotionEvent.ACTION_UP || event.action == MotionEvent.ACTION_CANCEL) {
                stopDeleteRepeat()
            }
            false
        }
    }

    private fun startDeleteRepeat() {
        stopDeleteRepeat()
        deleteRepeatRunnable = object : Runnable {
            override fun run() {
                if (!isDeleteRepeating) return
                currentInputConnection?.deleteSurroundingText(1, 0)
                triggerHaptic(12)
                mainHandler.postDelayed(this, 65)
            }
        }
        mainHandler.postDelayed(deleteRepeatRunnable!!, 350)
    }

    private fun stopDeleteRepeat() {
        isDeleteRepeating = false
        deleteRepeatRunnable?.let { mainHandler.removeCallbacks(it) }
        deleteRepeatRunnable = null
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

    private fun stopDownloadProgressPolling() {
        progressPoller?.let { mainHandler.removeCallbacks(it) }
        progressPoller = null
    }

    override fun onDestroy() {
        super.onDestroy()
        stopDownloadProgressPolling()
        timerRunnable?.let { mainHandler.removeCallbacks(it) }
        stopDeleteRepeat()
    }

    override fun onStartInputView(info: android.view.inputmethod.EditorInfo?, restarting: Boolean) {
        super.onStartInputView(info, restarting)
        EchoWriteCore.setSavedModelProfile(this, EchoWriteCore.getSavedModelProfile(this))
        currentStyle = EchoWriteCore.getSelectedStyle(this)
        updateStyleUI()
        ensureModelsReady()
    }

    override fun onFinishInputView(finishingInput: Boolean) {
        super.onFinishInputView(finishingInput)
        stopDownloadProgressPolling()
    }

    private fun toggleRecording() {
        if (isRecording) {
            stopRecordingAndProcessAI()
        } else {
            startRecording()
        }
    }

    private var lastRecordedContextBefore: String = ""

    private fun startRecording() {
        if (!modelsReady) {
            recordButton?.text = "⬇️ 模型下載中，請稍候..."
            return
        }

        if (ContextCompat.checkSelfPermission(this, android.Manifest.permission.RECORD_AUDIO) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
            recordButton?.text = "❌ 請至 EchoWrite App 開啟麥克風權限"
            return
        }

        // 提取游標前文情境 Context
        lastRecordedContextBefore = currentInputConnection?.getTextBeforeCursor(150, 0)?.toString() ?: ""
        lastPartialText = ""

        if (!SpeechRecognizer.isRecognitionAvailable(this)) {
            previewText?.text = "⚠️ 語音辨識器目前不可用，請確認系統設定"
            previewText?.setTextColor(Color.parseColor("#FF9500"))
            return
        }

        triggerHaptic(40)
        isRecording = true
        recordingStartMs = SystemClock.elapsedRealtime()
        timerText?.text = "⏱ 00:00"
        recordButton?.text = "⏹️ 說完即點擊完成"
        recordButton?.setBackgroundResource(R.drawable.record_btn_recording_bg)
        swipeHintText?.visibility = View.VISIBLE
        previewText?.text = "🎙️ 「正在即時辨識說話內容...」"
        previewText?.setTextColor(Color.parseColor("#00E5FF"))

        startTimer()

        mainHandler.post {
            val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                putExtra(RecognizerIntent.EXTRA_LANGUAGE, "zh-TW")
                putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            }

            speechRecognizer = SpeechRecognizer.createSpeechRecognizer(this).apply {
                setRecognitionListener(object : RecognitionListener {
                    override fun onReadyForSpeech(params: Bundle?) {}
                    override fun onBeginningOfSpeech() {}
                    override fun onRmsChanged(rmsdB: Float) {
                        // rmsdB 範圍大概是 -2.0 到 10.0，映射到 amplitude 0..1
                        val level = (rmsdB + 2f) / 12f
                        waveformView?.updateAmplitude(level.coerceIn(0.1f, 1.0f))
                    }
                    override fun onBufferReceived(buffer: ByteArray?) {}
                    override fun onEndOfSpeech() {}
                    override fun onError(error: Int) {
                        if (isRecording) {
                            Log.e(tag, "SpeechRecognizer error: $error")
                            // 錯誤代碼 7 代表沒有匹配到語音，不一定是壞事
                        }
                    }
                    override fun onResults(results: Bundle?) {
                        if (!isRecording) return
                        val matches = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                        if (!matches.isNullOrEmpty()) {
                            lastPartialText = matches[0]
                        }
                    }
                    override fun onPartialResults(partialResults: Bundle?) {
                        if (!isRecording) return
                        val matches = partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                        if (!matches.isNullOrEmpty()) {
                            val text = matches[0]
                            lastPartialText = text
                            // 邊說邊顯示辨識結果
                            currentInputConnection?.setComposingText(text, 1)
                            previewText?.text = "🎙️ $text"
                            previewText?.setTextColor(Color.parseColor("#E5E5EA"))
                        }
                    }
                    override fun onEvent(eventType: Int, params: Bundle?) {}
                })
                startListening(intent)
            }
        }
    }

    private fun cleanupRecordingResources() {
        timerRunnable?.let { mainHandler.removeCallbacks(it) }
        waveformView?.reset()

        mainHandler.post {
            speechRecognizer?.stopListening()
            speechRecognizer?.cancel()
            speechRecognizer?.destroy()
            speechRecognizer = null
        }

        isRecording = false
        currentInputConnection?.setComposingText("", 0)
        currentInputConnection?.finishComposingText()
        setIdleState()
    }

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

    private fun startTimer() {
        timerRunnable = object : Runnable {
            override fun run() {
                if (!isRecording) return
                val elapsedSecs = ((SystemClock.elapsedRealtime() - recordingStartMs) / 1000L).toInt()
                val mins = elapsedSecs / 60
                val secs = elapsedSecs % 60
                timerText?.text = String.format("⏱ %02d:%02d", mins, secs)
                mainHandler.postDelayed(this, 250)
            }
        }
        mainHandler.post(timerRunnable!!)
    }

    private fun cancelRecording() {
        isRecording = false
        timerRunnable?.let { mainHandler.removeCallbacks(it) }
        waveformView?.reset()

        triggerHaptic(60)

        mainHandler.post {
            speechRecognizer?.cancel()
            speechRecognizer?.destroy()
            speechRecognizer = null
        }

        // 樂觀排版：立即清除輸入框內的暫存 Composing 草稿
        currentInputConnection?.setComposingText("", 0)
        currentInputConnection?.finishComposingText()
        lastPartialText = ""

        previewText?.text = "❌ 已取消本次錄音"
        previewText?.setTextColor(Color.parseColor("#9AA7BD"))
        setIdleState()
    }

    private fun stopRecordingAndProcessAI() {
        isRecording = false
        timerRunnable?.let { mainHandler.removeCallbacks(it) }
        waveformView?.reset()

        mainHandler.post {
            speechRecognizer?.stopListening()
            speechRecognizer?.destroy()
            speechRecognizer = null
        }

        val rawText = lastPartialText.trim()
        lastPartialText = ""

        // 清除草稿
        currentInputConnection?.setComposingText("", 0)
        currentInputConnection?.finishComposingText()

        if (rawText.isEmpty()) {
            previewText?.text = "⚠️ 未偵測到語音，請靠近麥克風再試"
            previewText?.setTextColor(Color.parseColor("#FF9500"))
            setIdleState()
            return
        }

        val isCasual = currentStyle == EchoWriteStyle.CASUAL
        val contextBefore = lastRecordedContextBefore
        val styleStr = currentStyle.id

        if (isCasual) {
            // ⚡ 極速通道：純規則引擎，< 10ms，不呼叫 LLM
            val formatted = EchoWriteCore.formatOnly(rawText)
            currentInputConnection?.commitText(formatted, 1)
            previewText?.text = "✅ 已打入：${formatted.take(28)}"
            previewText?.setTextColor(Color.parseColor("#4CD964"))
            triggerHaptic(30)
            setIdleState()
        } else {
            // 🌊 非 casual：先立刻插入原始格式化文字，再非同步 LLM 精修替換
            val quickFormatted = EchoWriteCore.formatOnly(rawText)
            currentInputConnection?.commitText(quickFormatted, 1)
            
            previewText?.text = "⚙️ 精修中（${currentStyle.title}）..."
            previewText?.setTextColor(Color.parseColor("#C4B5FD"))
            recordButton?.isEnabled = false
            recordButton?.text = "⚙️ LLM 語意精修中..."
            recordButton?.setBackgroundResource(R.drawable.record_btn_processing_bg)
            swipeHintText?.visibility = View.INVISIBLE

            val insertedLen = quickFormatted.length

            thread {
                var resultText = ""
                try {
                    resultText = EchoWriteCore.polishRawTextWithContext(rawText, styleStr, contextBefore)
                } catch (e: Exception) {
                    Log.e(tag, "polishRawText error", e)
                }

                mainHandler.post {
                    val ic = currentInputConnection
                    if (ic != null && resultText.isNotEmpty() && resultText != quickFormatted) {
                        triggerHaptic(30)
                        ic.deleteSurroundingText(insertedLen, 0)
                        ic.commitText(resultText, 1)
                        previewText?.text = "✅ 已精修打入：${resultText.take(24)}..."
                        previewText?.setTextColor(Color.parseColor("#4CD964"))
                    } else {
                        previewText?.text = "✅ 已打入（快速模式）：${quickFormatted.take(20)}..."
                        previewText?.setTextColor(Color.parseColor("#4CD964"))
                    }
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
        swipeHintText?.visibility = View.GONE
        timerText?.text = "⏱ 00:00"
    }
}
