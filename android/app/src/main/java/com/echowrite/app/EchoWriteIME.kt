package com.echowrite.app

import android.content.Context
import android.graphics.Color
import android.inputmethodservice.InputMethodService
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.content.Intent
import android.os.Bundle
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.os.VibrationEffect
import android.os.Vibrator
import android.util.Log
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import android.widget.Button
import android.widget.FrameLayout
import android.widget.HorizontalScrollView
import android.widget.LinearLayout
import android.widget.TextView
import android.speech.SpeechRecognizer
import androidx.core.content.ContextCompat
import java.io.File
import java.io.FileOutputStream
import java.io.RandomAccessFile
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

    // Native SpeechRecognizer State
    private var speechRecognizer: android.speech.SpeechRecognizer? = null
    private var isAudioRecording = false
    
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
        EchoWriteCore.initialize("")
        EchoWriteCore.setSavedModelProfile(this, EchoWriteCore.getSavedModelProfile(this))

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
        deleteBtn?.setOnTouchListener { _, event ->
            when (event.action) {
                MotionEvent.ACTION_DOWN -> {
                    currentInputConnection?.deleteSurroundingText(1, 0)
                    triggerHaptic(18)
                    isDeleteRepeating = true
                    startDeleteRepeat()
                    true
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    stopDeleteRepeat()
                    true
                }
                else -> false
            }
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
        val llmReady = EchoWriteCore.isModelReady(EchoWriteCore.MODEL_KIND_LLM)

        if (llmReady) {
            modelsReady = true
            setIdleState()
            return
        }

        modelsReady = false
        recordButton?.text = "⬇️ EchoWrite 本地 LLM 下載中"
        statusText?.text = "請保持連線，模型完成後即可完全離線辨識"
        if (!llmReady) EchoWriteCore.startModelDownload(EchoWriteCore.MODEL_KIND_LLM)

        val poller = object : Runnable {
            override fun run() {
                val l = EchoWriteCore.getModelDownloadProgress(EchoWriteCore.MODEL_KIND_LLM).split(":", limit = 4)
                val lState = l.getOrNull(0)?.toIntOrNull() ?: 0
                val lError = l.getOrNull(3)?.takeIf { it.isNotBlank() }.orEmpty()

                when {
                    lState == EchoWriteCore.MODEL_STATE_FAILED -> {
                        val errorText = lError
                        recordButton?.text = "❌ 模型下載失敗"
                        statusText?.text = if (errorText.isNotBlank()) {
                            "請檢查網路連線：${errorText.take(28)}"
                        } else {
                            "請檢查網路連線或開啟主 App 重新下載"
                        }
                        Log.e(tag, "Model download failed. llm=$lError")
                        return
                    }
                    lState == EchoWriteCore.MODEL_STATE_READY -> {
                        modelsReady = true
                        setIdleState()
                        return
                    }
                    else -> {
                        val downloaded = (l.getOrNull(1)?.toLongOrNull() ?: 0L)
                        val total = (l.getOrNull(2)?.toLongOrNull() ?: 0L)
                        val hasKnownTotal = total > 0
                        val percent = if (hasKnownTotal) (downloaded * 100 / total).toInt().coerceIn(0, 100) else 0
                        recordButton?.text = if (hasKnownTotal) "⬇️ 下載模型中 $percent%" else "⬇️ 續傳中..."
                        if (lError.isNotBlank()) {
                            Log.w(tag, "Model download progress note. llm=$lError")
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


    private fun startRecording() {
        if (!modelsReady) {
            previewText?.text = "⚠️ LLM 模型尚未下載完成"
            previewText?.setTextColor(Color.parseColor("#FF9500"))
            return
        }

        if (ContextCompat.checkSelfPermission(this, android.Manifest.permission.RECORD_AUDIO) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
            recordButton?.text = "❌ 請至 EchoWrite App 開啟麥克風權限"
            return
        }

        if (!SpeechRecognizer.isRecognitionAvailable(this)) {
            previewText?.text = "⚠️ 語音辨識啟動失敗：服務不可用"
            previewText?.setTextColor(Color.parseColor("#FF9500"))
            recordButton?.text = "❌ 語音引擎不可用"
            return
        }

        lastRecordedContextBefore = currentInputConnection?.getTextBeforeCursor(150, 0)?.toString() ?: ""
        lastPartialText = ""

        try {
            speechRecognizer?.destroy()
            speechRecognizer = SpeechRecognizer.createSpeechRecognizer(this)
            val intent = Intent(android.speech.RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                putExtra(android.speech.RecognizerIntent.EXTRA_LANGUAGE_MODEL, android.speech.RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                putExtra(android.speech.RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
                putExtra(android.speech.RecognizerIntent.EXTRA_MAX_RESULTS, 1)
            }
            speechRecognizer?.setRecognitionListener(object : android.speech.RecognitionListener {
                override fun onReadyForSpeech(params: Bundle?) {}
                override fun onBeginningOfSpeech() {}
                override fun onRmsChanged(rmsdB: Float) {
                    val normalized = ((rmsdB + 2) / 12f).coerceIn(0.1f, 1.0f)
                    waveformView?.updateAmplitude(normalized)
                }
                override fun onBufferReceived(buffer: ByteArray?) {}
                override fun onEndOfSpeech() {}
                override fun onError(error: Int) {
                    mainHandler.post { handleSpeechRecognitionError(error) }
                }
                override fun onResults(results: Bundle?) {
                    val matches = results?.getStringArrayList(android.speech.SpeechRecognizer.RESULTS_RECOGNITION)
                    val text = matches?.firstOrNull() ?: ""
                    if (isRecording || isStoppingToProcess) {
                        isRecording = false
                        processAI(text)
                    }
                }
                override fun onPartialResults(partialResults: Bundle?) {
                    val matches = partialResults?.getStringArrayList(android.speech.SpeechRecognizer.RESULTS_RECOGNITION)
                    val text = matches?.firstOrNull() ?: ""
                    if (text.isNotEmpty() && isRecording) {
                        previewText?.text = text
                    }
                }
                override fun onEvent(eventType: Int, params: Bundle?) {}
            })
            speechRecognizer?.startListening(intent)
        } catch (e: SecurityException) {
            previewText?.text = "⚠️ 語音辨識啟動失敗：權限不足（${e.localizedMessage}）"
            recordButton?.text = "❌ 權限不足"
            return
        } catch (e: IllegalStateException) {
            previewText?.text = "⚠️ 語音辨識啟動失敗：辨識器狀態異常（${e.localizedMessage}）"
            recordButton?.text = "❌ 辨識器忙碌"
            return
        } catch (e: RuntimeException) {
            previewText?.text = "⚠️ 語音辨識啟動失敗：${e.localizedMessage}"
            recordButton?.text = "❌ 啟動失敗"
            return
        }

        isRecording = true
        isAudioRecording = true
        triggerHaptic(40)
        recordingStartMs = SystemClock.elapsedRealtime()
        timerText?.text = "⏱ 00:00"
        recordButton?.text = "⏹️ 說完即點擊完成"
        recordButton?.setBackgroundResource(R.drawable.record_btn_recording_bg)
        swipeHintText?.visibility = View.VISIBLE
        previewText?.text = "🎙️ 錄音中，即時語音辨識..."
        previewText?.setTextColor(Color.parseColor("#00E5FF"))

        startTimer()
    }

    private fun handleSpeechRecognitionError(errorCode: Int) {
        val message = describeSpeechRecognitionError(errorCode)
        Log.e(tag, "SpeechRecognizer error: $message")

        isRecording = false
        isAudioRecording = false
        isStoppingToProcess = false
        timerRunnable?.let { mainHandler.removeCallbacks(it) }
        waveformView?.reset()

        try { speechRecognizer?.cancel() } catch (_: Exception) {}

        previewText?.text = "⚠️ 語音辨識失敗：$message"
        previewText?.setTextColor(Color.parseColor("#FF9500"))
        recordButton?.isEnabled = true
        setIdleState()
    }

    private fun describeSpeechRecognitionError(errorCode: Int): String {
        return when (errorCode) {
            SpeechRecognizer.ERROR_AUDIO -> "音訊擷取失敗"
            SpeechRecognizer.ERROR_CLIENT -> "客戶端錯誤"
            SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "麥克風或辨識權限不足"
            SpeechRecognizer.ERROR_NETWORK -> "網路錯誤"
            SpeechRecognizer.ERROR_NETWORK_TIMEOUT -> "網路逾時"
            SpeechRecognizer.ERROR_NO_MATCH -> "沒有辨識結果"
            SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> "辨識器忙碌中"
            SpeechRecognizer.ERROR_SERVER -> "辨識服務回傳錯誤"
            SpeechRecognizer.ERROR_SERVER_DISCONNECTED -> "辨識服務中斷"
            SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "偵測不到語音輸入"
            SpeechRecognizer.ERROR_TOO_MANY_REQUESTS -> "請求過多，稍後再試"
            SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED -> "語言不支援"
            SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE -> "語言資源不可用"
            SpeechRecognizer.ERROR_CANNOT_CHECK_SUPPORT -> "無法檢查語音支援"
            SpeechRecognizer.ERROR_CANNOT_LISTEN_TO_DOWNLOAD_EVENTS -> "無法監聽語言模型下載事件"
            else -> "未知錯誤（$errorCode）"
        }
    }

    private fun cleanupRecordingResources() {
        timerRunnable?.let { mainHandler.removeCallbacks(it) }
        waveformView?.reset()

        isAudioRecording = false
        try { speechRecognizer?.destroy() } catch (e: Exception) {}
        speechRecognizer = null

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

    private var isStoppingToProcess = false

    private fun cancelRecording() {
        isRecording = false
        isAudioRecording = false
        isStoppingToProcess = false
        timerRunnable?.let { mainHandler.removeCallbacks(it) }
        waveformView?.reset()
        try { speechRecognizer?.cancel() } catch (e: Exception) {}

        triggerHaptic(60)

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
        isAudioRecording = false
        isStoppingToProcess = true
        
        timerRunnable?.let { mainHandler.removeCallbacks(it) }
        waveformView?.reset()
        
        try { speechRecognizer?.stopListening() } catch (e: Exception) {}

        // 清除可能殘留的草稿
        currentInputConnection?.setComposingText("", 0)
        currentInputConnection?.finishComposingText()

        previewText?.text = "⚙️ LLM 語意精修串流中..."
        previewText?.setTextColor(Color.parseColor("#C4B5FD"))
        recordButton?.isEnabled = false
        recordButton?.text = "⚙️ 引擎處理中..."
        recordButton?.setBackgroundResource(R.drawable.record_btn_processing_bg)
        swipeHintText?.visibility = View.INVISIBLE
    }
    
    private fun processAI(rawText: String) {
        if (rawText.isBlank()) {
            mainHandler.post {
                previewText?.text = "⚠️ 未聽清楚內容，或轉寫失敗"
                previewText?.setTextColor(Color.parseColor("#FF9500"))
                isStoppingToProcess = false
                setIdleState()
                recordButton?.isEnabled = true
            }
            return
        }

        thread {
            val styleStr = currentStyle.id
            val contextBefore = lastRecordedContextBefore
            try {
                EchoWriteCore.polishTextStream(rawText, styleStr, contextBefore, object : EchoWriteCore.LlmStreamCallback {
                    override fun onTextUpdate(text: String) {
                        mainHandler.post {
                            if (isStoppingToProcess) {
                                currentInputConnection?.setComposingText(text, 1)
                                previewText?.text = text
                            }
                        }
                    }
                    override fun onError(error: String) {
                        Log.e(tag, "LLM Stream error: $error")
                    }
                })
            } catch (e: Exception) {
                Log.e(tag, "processAI error", e)
            }

            mainHandler.post {
                if (isStoppingToProcess) {
                    triggerHaptic(30)
                    currentInputConnection?.finishComposingText()
                    previewText?.text = "✅ 處理完成"
                    previewText?.setTextColor(Color.parseColor("#4CD964"))
                }
                isStoppingToProcess = false
                setIdleState()
                recordButton?.isEnabled = true
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
