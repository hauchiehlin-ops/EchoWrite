package com.echowrite.app

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject

enum class EchoWriteStyle(val id: String, val title: String, val subtitle: String) {
    CASUAL("casual", "⚡ 極簡口語", "去贅字、保留自然口氣、全形標點"),
    FORMAL("formal", "🏛️ 專業公文", "轉換為嚴謹公務敬語與行政書面報告"),
    EMAIL("email", "✉️ 商務 Email", "自動產生主旨、問候語與完整信件結構"),
    BILINGUAL("bilingual", "🌐 中英雙語", "中文潤飾段落 + 地道專業英文對照"),
    BULLET("bullet", "📋 條列重點", "Markdown 條列式精簡重點清單");

    companion object {
        fun fromId(id: String): EchoWriteStyle {
            return entries.find { it.id == id } ?: CASUAL
        }
    }
}

enum class ModelProfile(val id: Int, val title: String, val desc: String) {
    TURBO(0, "⚡ Turbo 極速 (200ms)", "Whisper Tiny + Qwen 0.5B，超低延遲即時反饋"),
    PRO(1, "🏆 Pro 旗艦高精度", "Whisper Base + Qwen 1.5B，頂級長文與邏輯潤飾");

    companion object {
        fun fromId(id: Int): ModelProfile {
            return entries.find { it.id == id } ?: TURBO
        }
    }
}

data class HistoryItem(val id: Long, val timestamp: String, val text: String)

object EchoWriteCore {
    private const val TAG = "EchoWriteCore"

    const val MODEL_KIND_WHISPER = 0
    const val MODEL_KIND_LLM = 1
    const val MODEL_STATE_NOT_STARTED = 0
    const val MODEL_STATE_DOWNLOADING = 1
    const val MODEL_STATE_VERIFYING = 2
    const val MODEL_STATE_READY = 3
    const val MODEL_STATE_FAILED = 4

    private const val PREFS_NAME = "echowrite_prefs"
    private const val KEY_SELECTED_STYLE = "selected_style"
    private const val KEY_MODEL_PROFILE = "model_profile"

    var isLibraryLoaded = false
        private set

    init {
        try {
            // 先嘗試載入 C++ 標準運行庫
            try {
                System.loadLibrary("c++_shared")
            } catch (e: Throwable) {
                Log.w(TAG, "c++_shared load: ${e.message}")
            }
            System.loadLibrary("echowrite_core")
            isLibraryLoaded = true
            Log.i(TAG, "Successfully loaded libechowrite_core.so")
        } catch (e: Throwable) {
            Log.e(TAG, "Failed to load native library: ${e.message}", e)
            isLibraryLoaded = false
        }
    }

    // 原生 JNI 宣告
    @JvmStatic external fun setModelDir(dirPath: String): Boolean
    @JvmStatic external fun initialize(whisperPath: String, llmPath: String): Boolean
    @JvmStatic external fun isModelReady(kind: Int): Boolean
    @JvmStatic external fun startModelDownload(kind: Int)
    /** 回傳格式：`"state:downloaded:total"` */
    @JvmStatic external fun getModelDownloadProgress(kind: Int): String
    @JvmStatic external fun processAudioFile(audioPath: String, style: String): String
    @JvmStatic external fun processAudioFileWithContext(audioPath: String, style: String, contextBefore: String): String
    @JvmStatic external fun formatOnly(text: String): String
    @JvmStatic external fun addCustomVocabulary(phrase: String): Boolean
    @JvmStatic external fun deleteCustomVocabulary(phrase: String): Boolean
    @JvmStatic external fun getCustomVocabulary(): String
    @JvmStatic external fun getTranscriptionHistory(limit: Int): String
    @JvmStatic external fun deleteHistoryItem(id: Long): Boolean
    @JvmStatic external fun clearTranscriptionHistory(): Boolean

    // 維度二／三／四高階原生接口
    @JvmStatic external fun setModelProfile(profileId: Int)
    @JvmStatic external fun getModelProfile(): Int
    @JvmStatic external fun addPersonalToneSample(sampleText: String): Boolean
    @JvmStatic external fun getPersonalToneSamples(): String
    @JvmStatic external fun clearPersonalToneSamples(): Boolean
    @JvmStatic external fun exportSyncData(): String
    @JvmStatic external fun importSyncData(jsonStr: String): Int

    fun getSelectedStyle(context: Context): EchoWriteStyle {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val raw = prefs.getString(KEY_SELECTED_STYLE, EchoWriteStyle.CASUAL.id) ?: EchoWriteStyle.CASUAL.id
        return EchoWriteStyle.fromId(raw)
    }

    fun setSelectedStyle(context: Context, style: EchoWriteStyle) {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        prefs.edit().putString(KEY_SELECTED_STYLE, style.id).apply()
    }

    fun getSavedModelProfile(context: Context): ModelProfile {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val id = prefs.getInt(KEY_MODEL_PROFILE, ModelProfile.TURBO.id)
        return ModelProfile.fromId(id)
    }

    fun setSavedModelProfile(context: Context, profile: ModelProfile) {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        prefs.edit().putInt(KEY_MODEL_PROFILE, profile.id).apply()
        try {
            if (isLibraryLoaded) {
                setModelProfile(profile.id)
            }
        } catch (e: Throwable) {
            e.printStackTrace()
        }
    }

    fun parseHistoryList(jsonString: String): List<HistoryItem> {
        val list = mutableListOf<HistoryItem>()
        try {
            val array = JSONArray(jsonString)
            for (i in 0 until array.length()) {
                val obj = array.getJSONObject(i)
                list.add(
                    HistoryItem(
                        id = obj.optLong("id"),
                        timestamp = obj.optString("timestamp"),
                        text = obj.optString("text")
                    )
                )
            }
        } catch (e: Throwable) {
            e.printStackTrace()
        }
        return list
    }

    fun parseToneSamplesList(jsonString: String): List<String> {
        val list = mutableListOf<String>()
        try {
            val array = JSONArray(jsonString)
            for (i in 0 until array.length()) {
                list.add(array.getString(i))
            }
        } catch (e: Throwable) {
            e.printStackTrace()
        }
        return list
    }
}
