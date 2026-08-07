package com.echowrite.app

import android.Manifest
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.Typeface
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.InputMethodManager
import android.widget.*
import androidx.appcompat.app.AppCompatActivity
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.google.android.material.tabs.TabLayout
import java.io.File

/**
 * EchoWrite Android 主 App 全功能現代化儀表板
 * 包含：
 * 1. 本地雙引擎模型管理中心（Whisper ASR / Qwen LLM）與 Turbo/Pro 效能切換。
 * 2. 5 大語意風格偏好設定。
 * 3. 專屬客製詞庫管理與個人說話口吻學習 (Few-Shot Tone Adaptation)。
 * 4. 零雲端加密 P2P / 剪貼簿跨裝置同步 (Zero-Cloud Sync)。
 * 5. 轉寫歷史紀錄剪貼簿。
 * 6. 鍵盤啟用診斷與權限引導。
 */
class MainActivity : AppCompatActivity() {
    private val tag = "EchoWriteMainActivity"
    private val micRequestCode = 201
    private lateinit var tabLayout: TabLayout
    private lateinit var container: FrameLayout
    private val mainHandler = Handler(Looper.getMainLooper())
    private var downloadPoller: Runnable? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        val modelsDir = File(filesDir, "models")
        if (!modelsDir.exists()) modelsDir.mkdirs()

        try {
            if (EchoWriteCore.isLibraryLoaded) {
                EchoWriteCore.setModelDir(modelsDir.absolutePath)
                EchoWriteCore.initialize("", "")
                EchoWriteCore.setSavedModelProfile(this, EchoWriteCore.getSavedModelProfile(this))
            } else {
                Toast.makeText(this, "EchoWrite 核心庫初始化中，請稍候...", Toast.LENGTH_SHORT).show()
            }
        } catch (e: Throwable) {
            e.printStackTrace()
        }

        tabLayout = findViewById(R.id.tab_layout)
        container = findViewById(R.id.fragment_container)

        tabLayout.addOnTabSelectedListener(object : TabLayout.OnTabSelectedListener {
            override fun onTabSelected(tab: TabLayout.Tab?) {
                switchTab(tab?.position ?: 0)
            }
            override fun onTabUnselected(tab: TabLayout.Tab?) {}
            override fun onTabReselected(tab: TabLayout.Tab?) {}
        })

        switchTab(0)
        checkAutoOnboarding()
    }

    override fun onDestroy() {
        super.onDestroy()
        stopPolling()
    }

    private fun stopPolling() {
        downloadPoller?.let { mainHandler.removeCallbacks(it) }
        downloadPoller = null
    }

    private fun switchTab(position: Int) {
        stopPolling()
        container.removeAllViews()
        when (position) {
            0 -> renderModelHub()
            1 -> renderStylePreferences()
            2 -> renderCustomVocabulary()
            3 -> renderTranscriptionHistory()
            4 -> renderDoctorView()
        }
    }

    // MARK: - 1. 模型中心 (Model Hub)
    private fun renderModelHub() {
        val scroll = ScrollView(this)
        val layout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, 0, 0, 32)
        }
        scroll.addView(layout)

        // 品牌標題卡片
        val headerCard = createCardLayout()
        val titleText = TextView(this).apply {
            text = "⚡ EchoWrite 本地神經雙引擎"
            textSize = 18f
            setTextColor(Color.WHITE)
            typeface = Typeface.DEFAULT_BOLD
        }
        val subtitleText = TextView(this).apply {
            text = "零雲端依賴，所有 ASR 語音辨識與 LLM 句式重塑均在裝置晶片端完成。"
            textSize = 12f
            setTextColor(Color.parseColor("#8F9FB8"))
            setPadding(0, 4, 0, 0)
        }
        headerCard.addView(titleText)
        headerCard.addView(subtitleText)
        layout.addView(headerCard)

        // AI 效能分級卡片 (Turbo vs Pro)
        val profileCard = createCardLayout()
        val profileTitle = TextView(this).apply {
            text = "🚀 AI 模型效能分級 (Dynamic Model Profiling)"
            textSize = 15f
            setTextColor(Color.WHITE)
            typeface = Typeface.DEFAULT_BOLD
        }
        val profileDesc = TextView(this).apply {
            text = "依據設備效能與即時性需求自由切換模型組合："
            textSize = 12f
            setTextColor(Color.parseColor("#8F9FB8"))
            setPadding(0, 4, 0, 12)
        }
        profileCard.addView(profileTitle)
        profileCard.addView(profileDesc)

        val currentProfile = EchoWriteCore.getSavedModelProfile(this)
        for (profile in ModelProfile.entries) {
            val isSelected = profile == currentProfile
            val item = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(20, 16, 20, 16)
                setBackgroundResource(if (isSelected) R.drawable.capsule_selected_bg else R.drawable.capsule_unselected_bg)
                layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
                    setMargins(0, 0, 0, 10)
                }
                setOnClickListener {
                    EchoWriteCore.setSavedModelProfile(this@MainActivity, profile)
                    renderModelHub()
                }
            }
            val t = TextView(this).apply {
                text = "${profile.title} ${if (isSelected) "✓" else ""}"
                textSize = 14f
                setTextColor(if (isSelected) Color.parseColor("#00E5FF") else Color.WHITE)
                typeface = Typeface.DEFAULT_BOLD
            }
            val s = TextView(this).apply {
                text = profile.desc
                textSize = 11f
                setTextColor(Color.parseColor("#8F9FB8"))
            }
            item.addView(t)
            item.addView(s)
            profileCard.addView(item)
        }
        layout.addView(profileCard)

        // 模型 1：Whisper ASR
        layout.addView(createModelCard(
            kind = EchoWriteCore.MODEL_KIND_WHISPER,
            title = "🎙️ 本地語音辨識引擎 (Whisper ASR)",
            description = "將語音訊號離線轉換為繁體中文草稿，具備台灣術語與俚語強化。",
            targetFile = "whisper-tiny-q8_0.bin",
            approxSize = "~75 MB"
        ))

        // 模型 2：Qwen SLM
        layout.addView(createModelCard(
            kind = EchoWriteCore.MODEL_KIND_LLM,
            title = "🧠 本地語意重塑引擎 (Qwen SLM)",
            description = "將粗糙辨識草稿自動去贅字、潤飾句構、套用個人口吻並自動排版。",
            targetFile = "qwen2.5-0.5b-instruct-q4_k_m.gguf",
            approxSize = "~350 MB"
        ))

        container.addView(scroll)
        startDownloadProgressPolling()
    }

    private fun createModelCard(kind: Int, title: String, description: String, targetFile: String, approxSize: String): View {
        val card = createCardLayout()
        val titleView = TextView(this).apply {
            text = title
            textSize = 16f
            setTextColor(Color.WHITE)
            typeface = Typeface.DEFAULT_BOLD
        }
        val descView = TextView(this).apply {
            text = description
            textSize = 12f
            setTextColor(Color.parseColor("#8F9FB8"))
            setPadding(0, 4, 0, 12)
        }
        card.addView(titleView)
        card.addView(descView)

        // 狀態與進度列
        val statusRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        val statusText = TextView(this).apply {
            text = "檢查中..."
            textSize = 13f
            setTextColor(Color.parseColor("#8F9FB8"))
            tag = "status_$kind"
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        }
        val bytesText = TextView(this).apply {
            text = approxSize
            textSize = 12f
            setTextColor(Color.parseColor("#64748B"))
            tag = "bytes_$kind"
        }
        statusRow.addView(statusText)
        statusRow.addView(bytesText)
        card.addView(statusRow)

        val progressBar = ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply {
            max = 100
            progress = 0
            tag = "progress_$kind"
            setPadding(0, 8, 0, 12)
        }
        card.addView(progressBar)

        val downloadBtn = Button(this).apply {
            text = "下載模型"
            setBackgroundResource(R.drawable.record_btn_bg)
            setTextColor(Color.WHITE)
            tag = "btn_$kind"
            setOnClickListener {
                isEnabled = false
                text = "⬇️ 下載啟動中..."
                EchoWriteCore.startModelDownload(kind)
                updateModelProgress(kind)
            }
        }
        card.addView(downloadBtn)

        return card
    }

    private fun startDownloadProgressPolling() {
        downloadPoller = object : Runnable {
            override fun run() {
                updateModelProgress(EchoWriteCore.MODEL_KIND_WHISPER)
                updateModelProgress(EchoWriteCore.MODEL_KIND_LLM)
                mainHandler.postDelayed(this, 300)
            }
        }
        mainHandler.post(downloadPoller!!)
    }

    private fun updateModelProgress(kind: Int) {
        val progressRaw = EchoWriteCore.getModelDownloadProgress(kind)
        val raw = progressRaw.split(":", limit = 4)
        val state = raw.getOrNull(0)?.toIntOrNull() ?: 0
        val downloaded = raw.getOrNull(1)?.toLongOrNull() ?: 0L
        val total = (raw.getOrNull(2)?.toLongOrNull() ?: 0L)
        val error = raw.getOrNull(3)?.takeIf { it.isNotBlank() }.orEmpty()
        val hasKnownTotal = total > 0
        val percent = if (hasKnownTotal) ((downloaded * 100) / total).toInt().coerceIn(0, 100) else 0

        val statusView = container.findViewWithTag<TextView>("status_$kind")
        val progressView = container.findViewWithTag<ProgressBar>("progress_$kind")
        val bytesView = container.findViewWithTag<TextView>("bytes_$kind")
        val btn = container.findViewWithTag<Button>("btn_$kind")

        val mbDownloaded = String.format("%.1f", downloaded.toDouble() / (1024 * 1024))
        val mbTotal = String.format("%.1f", total.toDouble() / (1024 * 1024))
        bytesView?.text = if (hasKnownTotal) "$mbDownloaded MB / $mbTotal MB" else "$mbDownloaded MB / ? MB"
        progressView?.isIndeterminate = !hasKnownTotal && state == EchoWriteCore.MODEL_STATE_DOWNLOADING
        progressView?.progress = if (hasKnownTotal) percent else 0

        if (error.isNotBlank() && state == EchoWriteCore.MODEL_STATE_FAILED) {
            Log.e(tag, "Model $kind download failed: $error")
        }

        when (state) {
            EchoWriteCore.MODEL_STATE_READY -> {
                statusView?.text = "● 已就緒"
                statusView?.setTextColor(Color.parseColor("#4CD964"))
                btn?.visibility = View.VISIBLE
                btn?.isEnabled = false
                btn?.text = "已下載"
                progressView?.progress = 100
                progressView?.isIndeterminate = false
            }
            EchoWriteCore.MODEL_STATE_DOWNLOADING -> {
                statusView?.text = if (hasKnownTotal) "⬇️ 下載中 $percent%" else "⬇️ 續傳中..."
                statusView?.setTextColor(Color.parseColor("#00E5FF"))
                btn?.visibility = View.VISIBLE
                btn?.isEnabled = false
                btn?.text = "下載中..."
                if (error.isNotBlank()) {
                    Log.w(tag, "Model $kind download progress note: $error")
                }
            }
            EchoWriteCore.MODEL_STATE_VERIFYING -> {
                statusView?.text = "校驗中..."
                statusView?.setTextColor(Color.parseColor("#FF9500"))
                btn?.visibility = View.VISIBLE
                btn?.isEnabled = false
                btn?.text = "校驗中..."
                progressView?.isIndeterminate = true
            }
            EchoWriteCore.MODEL_STATE_FAILED -> {
                statusView?.text = if (error.isNotBlank()) "❌ 失敗：${error.take(24)}" else "❌ 失敗"
                statusView?.setTextColor(Color.parseColor("#FF3B30"))
                btn?.visibility = View.VISIBLE
                btn?.isEnabled = true
                btn?.text = "重新下載"
                progressView?.isIndeterminate = false
            }
            else -> {
                statusView?.text = "未下載"
                statusView?.setTextColor(Color.parseColor("#8F9FB8"))
                btn?.visibility = View.VISIBLE
                btn?.isEnabled = true
                btn?.text = "下載模型"
                progressView?.isIndeterminate = false
            }
        }
    }

    // MARK: - 2. 語意風格偏好 (Style Preferences)
    private fun renderStylePreferences() {
        val scroll = ScrollView(this)
        val layout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
        }
        scroll.addView(layout)

        val current = EchoWriteCore.getSelectedStyle(this)

        val descCard = createCardLayout()
        val descTitle = TextView(this).apply {
            text = "預設語音重塑風格"
            textSize = 17f
            setTextColor(Color.WHITE)
            typeface = Typeface.DEFAULT_BOLD
        }
        val descSub = TextView(this).apply {
            text = "點選以下風格作為輸入法預設處理模式："
            textSize = 12f
            setTextColor(Color.parseColor("#8F9FB8"))
            setPadding(0, 4, 0, 12)
        }
        descCard.addView(descTitle)
        descCard.addView(descSub)

        for (style in EchoWriteStyle.entries) {
            val isSelected = style == current
            val item = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(24, 20, 24, 20)
                setBackgroundResource(if (isSelected) R.drawable.capsule_selected_bg else R.drawable.capsule_unselected_bg)
                layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
                    setMargins(0, 0, 0, 16)
                }
                setOnClickListener {
                    EchoWriteCore.setSelectedStyle(this@MainActivity, style)
                    renderStylePreferences()
                }
            }

            val t = TextView(this).apply {
                text = "${style.title} ${if (isSelected) "✓" else ""}"
                textSize = 15f
                setTextColor(if (isSelected) Color.parseColor("#00E5FF") else Color.WHITE)
                typeface = Typeface.DEFAULT_BOLD
            }
            val s = TextView(this).apply {
                text = style.subtitle
                textSize = 12f
                setTextColor(Color.parseColor("#8F9FB8"))
                setPadding(0, 2, 0, 0)
            }
            item.addView(t)
            item.addView(s)
            descCard.addView(item)
        }
        layout.addView(descCard)
        container.addView(scroll)
    }

    // MARK: - 3. 專屬詞庫與個人化 (Custom Vocabulary & Tone)
    private fun renderCustomVocabulary() {
        val scroll = ScrollView(this)
        val layout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, 0, 0, 32)
        }
        scroll.addView(layout)

        // 1. 專屬詞庫
        val vocabCard = createCardLayout()
        val vocabTitle = TextView(this).apply {
            text = "🏷️ 專屬詞庫 (Custom Vocabulary)"
            textSize = 16f
            setTextColor(Color.WHITE)
            typeface = Typeface.DEFAULT_BOLD
        }
        vocabCard.addView(vocabTitle)

        val inputRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, 12, 0, 12)
        }
        val editPhrase = EditText(this).apply {
            hint = "輸入專有名詞（如：EchoWrite）"
            setHintTextColor(Color.parseColor("#64748B"))
            setTextColor(Color.WHITE)
            textSize = 13f
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        }
        val addBtn = Button(this).apply {
            text = "新增詞彙"
            textSize = 12f
            setBackgroundResource(R.drawable.record_btn_bg)
            setTextColor(Color.WHITE)
            setOnClickListener {
                val phrase = editPhrase.text.toString().trim()
                if (phrase.isNotEmpty()) {
                    EchoWriteCore.addCustomVocabulary(phrase)
                    editPhrase.setText("")
                    renderCustomVocabulary()
                }
            }
        }
        inputRow.addView(editPhrase)
        inputRow.addView(addBtn)
        vocabCard.addView(inputRow)

        val rawVocab = EchoWriteCore.getCustomVocabulary()
        val phrases = if (rawVocab.isEmpty()) emptyList() else rawVocab.split("\n").filter { it.isNotBlank() }
        for (phrase in phrases) {
            val row = LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(16, 10, 16, 10)
                setBackgroundResource(R.drawable.preview_box_bg)
                layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
                    setMargins(0, 0, 0, 8)
                }
            }
            val label = TextView(this).apply {
                text = "• $phrase"
                textSize = 13f
                setTextColor(Color.WHITE)
                layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
            }
            val delBtn = Button(this).apply {
                text = "刪除"
                textSize = 11f
                setTextColor(Color.parseColor("#FF5E62"))
                setBackgroundColor(Color.TRANSPARENT)
                setOnClickListener {
                    EchoWriteCore.deleteCustomVocabulary(phrase)
                    renderCustomVocabulary()
                }
            }
            row.addView(label)
            row.addView(delBtn)
            vocabCard.addView(row)
        }
        layout.addView(vocabCard)

        // 2. 個人說話口吻微調學習 (Few-shot Tone Learning)
        val toneCard = createCardLayout()
        val toneTitle = TextView(this).apply {
            text = "🎭 個人口吻模仿 (Few-Shot Tone Adaptation)"
            textSize = 16f
            setTextColor(Color.WHITE)
            typeface = Typeface.DEFAULT_BOLD
        }
        val toneSub = TextView(this).apply {
            text = "輸入一段你平常習慣發送的文字範例，AI 將在潤飾時自動模擬你的說話語氣與慣用詞："
            textSize = 12f
            setTextColor(Color.parseColor("#8F9FB8"))
            setPadding(0, 4, 0, 10)
        }
        toneCard.addView(toneTitle)
        toneCard.addView(toneSub)

        val toneInputRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, 0, 0, 12)
        }
        val editTone = EditText(this).apply {
            hint = "貼上一段你的日常口吻範例..."
            setHintTextColor(Color.parseColor("#64748B"))
            setTextColor(Color.WHITE)
            textSize = 13f
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        }
        val addToneBtn = Button(this).apply {
            text = "學習口吻"
            textSize = 12f
            setBackgroundResource(R.drawable.record_btn_bg)
            setTextColor(Color.WHITE)
            setOnClickListener {
                val sample = editTone.text.toString().trim()
                if (sample.isNotEmpty()) {
                    EchoWriteCore.addPersonalToneSample(sample)
                    editTone.setText("")
                    renderCustomVocabulary()
                }
            }
        }
        toneInputRow.addView(editTone)
        toneInputRow.addView(addToneBtn)
        toneCard.addView(toneInputRow)

        val toneSamplesJson = EchoWriteCore.getPersonalToneSamples()
        val toneSamples = EchoWriteCore.parseToneSamplesList(toneSamplesJson)
        for (sample in toneSamples) {
            val sampleBox = TextView(this).apply {
                text = "💬 「$sample」"
                textSize = 12f
                setTextColor(Color.parseColor("#00E5FF"))
                setPadding(16, 12, 16, 12)
                setBackgroundResource(R.drawable.preview_box_bg)
                layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
                    setMargins(0, 0, 0, 8)
                }
            }
            toneCard.addView(sampleBox)
        }
        if (toneSamples.isNotEmpty()) {
            val clearToneBtn = Button(this).apply {
                text = "清空所有學習口吻"
                textSize = 12f
                setTextColor(Color.parseColor("#FF5E62"))
                setBackgroundColor(Color.TRANSPARENT)
                setOnClickListener {
                    EchoWriteCore.clearPersonalToneSamples()
                    renderCustomVocabulary()
                }
            }
            toneCard.addView(clearToneBtn)
        }
        layout.addView(toneCard)

        // 3. 零雲端跨裝置同步 (Zero-Cloud P2P Sync)
        val syncCard = createCardLayout()
        val syncTitle = TextView(this).apply {
            text = "🔄 零雲端跨裝置同步 (Encrypted Sync)"
            textSize = 16f
            setTextColor(Color.WHITE)
            typeface = Typeface.DEFAULT_BOLD
        }
        val syncSub = TextView(this).apply {
            text = "透過本地加密 JSON 封包在 macOS/iOS/Android 之間自由同步詞庫與口吻："
            textSize = 12f
            setTextColor(Color.parseColor("#8F9FB8"))
            setPadding(0, 4, 0, 12)
        }
        syncCard.addView(syncTitle)
        syncCard.addView(syncSub)

        val syncBtnRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(0, 0, 0, 8)
        }
        val exportBtn = Button(this).apply {
            text = "📤 匯出同步資料"
            textSize = 12f
            setBackgroundResource(R.drawable.record_btn_bg)
            setTextColor(Color.WHITE)
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f).apply {
                setMargins(0, 0, 8, 0)
            }
            setOnClickListener {
                val json = EchoWriteCore.exportSyncData()
                val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                clipboard.setPrimaryClip(ClipData.newPlainText("EchoWrite Sync Data", json))
                Toast.makeText(this@MainActivity, "✅ 同步資料已複製至剪貼簿！", Toast.LENGTH_LONG).show()
            }
        }
        val importBtn = Button(this).apply {
            text = "📥 自剪貼簿匯入"
            textSize = 12f
            setBackgroundResource(R.drawable.record_btn_bg)
            setTextColor(Color.WHITE)
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f).apply {
                setMargins(8, 0, 0, 0)
            }
            setOnClickListener {
                val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                val clipText = clipboard.primaryClip?.getItemAt(0)?.text?.toString() ?: ""
                if (clipText.isNotEmpty()) {
                    val count = EchoWriteCore.importSyncData(clipText)
                    if (count > 0) {
                        Toast.makeText(this@MainActivity, "✅ 成功匯入 $count 筆詞庫與口吻！", Toast.LENGTH_SHORT).show()
                        renderCustomVocabulary()
                    } else {
                        Toast.makeText(this@MainActivity, "❌ 匯入失敗，請確認剪貼簿格式", Toast.LENGTH_SHORT).show()
                    }
                }
            }
        }
        syncBtnRow.addView(exportBtn)
        syncBtnRow.addView(importBtn)
        syncCard.addView(syncBtnRow)
        layout.addView(syncCard)

        container.addView(scroll)
    }

    // MARK: - 4. 轉寫歷史紀錄 (Transcription History)
    private fun renderTranscriptionHistory() {
        val layout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
        }

        val topRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, 0, 0, 12)
        }
        val title = TextView(this).apply {
            text = "歷史紀錄"
            textSize = 16f
            setTextColor(Color.WHITE)
            typeface = Typeface.DEFAULT_BOLD
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        }
        val clearBtn = Button(this).apply {
            text = "清空全部"
            textSize = 12f
            setTextColor(Color.parseColor("#FF5E62"))
            setBackgroundColor(Color.TRANSPARENT)
            setOnClickListener {
                EchoWriteCore.clearTranscriptionHistory()
                renderTranscriptionHistory()
            }
        }
        topRow.addView(title)
        topRow.addView(clearBtn)
        layout.addView(topRow)

        val scroll = ScrollView(this)
        val listLayout = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        scroll.addView(listLayout)

        val json = EchoWriteCore.getTranscriptionHistory(50)
        val records = EchoWriteCore.parseHistoryList(json)

        if (records.isEmpty()) {
            val emptyText = TextView(this).apply {
                text = "尚無歷史紀錄。\n使用 EchoWrite 輸入法打字後，結果將自動備份於此。"
                textSize = 13f
                setTextColor(Color.parseColor("#8F9FB8"))
                gravity = Gravity.CENTER
                setPadding(0, 48, 0, 0)
            }
            listLayout.addView(emptyText)
        } else {
            for (rec in records) {
                val card = createCardLayout()
                val metaRow = LinearLayout(this).apply {
                    orientation = LinearLayout.HORIZONTAL
                    gravity = Gravity.CENTER_VERTICAL
                }
                val timeView = TextView(this).apply {
                    text = rec.timestamp
                    textSize = 11f
                    setTextColor(Color.parseColor("#8F9FB8"))
                    layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
                }
                val copyBtn = Button(this).apply {
                    text = "複製"
                    textSize = 11f
                    setTextColor(Color.parseColor("#00E5FF"))
                    setBackgroundColor(Color.TRANSPARENT)
                    setOnClickListener {
                        val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                        clipboard.setPrimaryClip(ClipData.newPlainText("EchoWrite", rec.text))
                        Toast.makeText(this@MainActivity, "已複製至剪貼簿", Toast.LENGTH_SHORT).show()
                    }
                }
                val delBtn = Button(this).apply {
                    text = "刪除"
                    textSize = 11f
                    setTextColor(Color.parseColor("#FF5E62"))
                    setBackgroundColor(Color.TRANSPARENT)
                    setOnClickListener {
                        EchoWriteCore.deleteHistoryItem(rec.id)
                        renderTranscriptionHistory()
                    }
                }
                metaRow.addView(timeView)
                metaRow.addView(copyBtn)
                metaRow.addView(delBtn)
                card.addView(metaRow)

                val bodyView = TextView(this).apply {
                    text = rec.text
                    textSize = 13f
                    setTextColor(Color.WHITE)
                    setPadding(0, 4, 0, 0)
                }
                card.addView(bodyView)
                listLayout.addView(card)
            }
        }
        layout.addView(scroll)
        container.addView(layout)
    }

    // MARK: - 5. 鍵盤啟用指南與診斷 (IME Doctor)
    private fun renderDoctorView() {
        val scroll = ScrollView(this)
        val layout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
        }
        scroll.addView(layout)

        val card = createCardLayout()
        val title = TextView(this).apply {
            text = "🛡️ 系統狀態與啟用引導"
            textSize = 17f
            setTextColor(Color.WHITE)
            typeface = Typeface.DEFAULT_BOLD
        }
        card.addView(title)

        val micGranted = ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
        val micStatusRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, 12, 0, 12)
        }
        val micText = TextView(this).apply {
            text = "麥克風權限狀態："
            textSize = 14f
            setTextColor(Color.parseColor("#8F9FB8"))
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        }
        val micBadge = TextView(this).apply {
            text = if (micGranted) "● 已授權" else "● 未啟用"
            textSize = 13f
            setTextColor(if (micGranted) Color.parseColor("#4CD964") else Color.parseColor("#FF9500"))
            typeface = Typeface.DEFAULT_BOLD
        }
        micStatusRow.addView(micText)
        micStatusRow.addView(micBadge)
        card.addView(micStatusRow)

        if (!micGranted) {
            val micBtn = Button(this).apply {
                text = "授權麥克風權限"
                setBackgroundResource(R.drawable.record_btn_bg)
                setTextColor(Color.WHITE)
                setOnClickListener {
                    ActivityCompat.requestPermissions(this@MainActivity, arrayOf(Manifest.permission.RECORD_AUDIO), micRequestCode)
                }
            }
            card.addView(micBtn)
        }

        val step1Btn = Button(this).apply {
            text = "1. 前往系統開啟 EchoWrite 輸入法"
            setOnClickListener { startActivity(Intent(Settings.ACTION_INPUT_METHOD_SETTINGS)) }
            layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
                setMargins(0, 12, 0, 0)
            }
        }
        val step2Btn = Button(this).apply {
            text = "2. 立即切換 EchoWrite 鍵盤"
            setOnClickListener {
                val imm = getSystemService(INPUT_METHOD_SERVICE) as InputMethodManager
                imm.showInputMethodPicker()
            }
            layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
                setMargins(0, 12, 0, 0)
            }
        }
        card.addView(step1Btn)
        card.addView(step2Btn)
        layout.addView(card)

        // 30 秒語音操作指南
        val guideCard = createCardLayout()
        val guideTitle = TextView(this).apply {
            text = "📖 30 秒語音操作指南"
            textSize = 16f
            setTextColor(Color.WHITE)
            typeface = Typeface.DEFAULT_BOLD
        }
        val guideText = TextView(this).apply {
            text = "• 換行排版：說「換行」或「下一行」自動跳行\n" +
                   "• 空行分段：說「空兩行」自動分段\n" +
                   "• 標點符號：說「加個問號」、「驚嘆號」立即插入\n" +
                   "• 滑動取消：錄音時向左滑動即可捨棄本次錄音"
            textSize = 13f
            setTextColor(Color.parseColor("#8F9FB8"))
            setPadding(0, 8, 0, 0)
            setLineSpacing(4f, 1.2f)
        }
        guideCard.addView(guideTitle)
        guideCard.addView(guideText)
        layout.addView(guideCard)

        // 零雲端隱私權政策
        val privacyCard = createCardLayout()
        val privacyTitle = TextView(this).apply {
            text = "🔒 零雲端隱私權政策 (Zero-Cloud Privacy)"
            textSize = 16f
            setTextColor(Color.WHITE)
            typeface = Typeface.DEFAULT_BOLD
        }
        val privacyText = TextView(this).apply {
            text = "🛡️ 100% 晶片端離線推論：\n" +
                   "所有 Whisper ASR 與 Qwen SLM 完全在您的裝置硬體離線運算，絕無任何音訊或文字上傳雲端。\n\n" +
                   "🔑 零按鍵記錄 (Zero Keylogging)：\n" +
                   "僅在您按下錄音期間使用麥克風，無任何背景側錄。\n\n" +
                   "💾 本地透明儲存：\n" +
                   "詞庫與歷史紀錄僅儲存於本機 SQLite 資料庫。"
            textSize = 12f
            setTextColor(Color.parseColor("#8F9FB8"))
            setPadding(0, 8, 0, 0)
            setLineSpacing(4f, 1.2f)
        }
        privacyCard.addView(privacyTitle)
        privacyCard.addView(privacyText)
        layout.addView(privacyCard)

        container.addView(scroll)
    }

    private fun createCardLayout(): LinearLayout {
        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(24, 24, 24, 24)
            setBackgroundResource(R.drawable.preview_box_bg)
            layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
                setMargins(0, 0, 0, 16)
            }
        }
    }

    private fun checkAutoOnboarding() {
        val micGranted = ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
        if (!micGranted) {
            ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.RECORD_AUDIO), micRequestCode)
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == micRequestCode) {
            renderDoctorView()
        }
    }
}
