uniffi::setup_scaffolding!();

pub mod audio;
pub mod asr;
pub mod llm;
pub mod formatter;
pub mod database;
pub mod models;
pub mod ffi;
#[cfg(target_os = "android")]
pub mod jni;

pub use models::{ModelDownloadState, ModelKind, ModelProgress, ModelProfile};
pub use database::HistoryRecord;

use std::sync::Mutex;
use lazy_static::lazy_static;

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum EchoWriteError {
    #[error("Initialization error: {message}")]
    InitError { message: String },
    #[error("Recording error: {message}")]
    RecordError { message: String },
    #[error("Processing error: {message}")]
    ProcessError { message: String },
}

// 全域狀態管理，便於原生端簡單呼叫
struct AppState {
    whisper_model_path: Option<String>,
    llm_model_path: Option<String>,
    is_recording: bool,
}

lazy_static! {
    static ref STATE: Mutex<AppState> = Mutex::new(AppState {
        whisper_model_path: None,
        llm_model_path: None,
        is_recording: false,
    });
}

/// 初始化核心。`whisper_path` / `llm_path` 可省略（傳 `None`）：
/// 省略時會自動嘗試解析本地模型目錄（`~/.echowrite/models`，或
/// `ECHOWRITE_MODEL_DIR` 指定的共享容器路徑）下是否已有模型檔案。
/// 若模型尚未下載，初始化仍會成功，但呼叫端須先透過
/// `start_model_download` 下載完成，否則後續的轉寫/潤飾呼叫會回傳
/// `ProcessError`（訊息含 "not ready"）提示尚未就緒。
#[uniffi::export]
pub fn initialize(whisper_path: Option<String>, llm_path: Option<String>) -> Result<(), EchoWriteError> {
    let mut state = STATE.lock().map_err(|e| EchoWriteError::InitError { message: e.to_string() })?;
    state.whisper_model_path = whisper_path.or_else(|| models::default_model_path(models::ModelKind::Whisper));
    state.llm_model_path = llm_path.or_else(|| models::default_model_path(models::ModelKind::Llm));
    models::sync_model_profile_from_disk();

    // 初始化 SQLite 資料庫
    database::init_db().map_err(|e| EchoWriteError::InitError { message: e.to_string() })?;
    Ok(())
}

/// 設定模型存放目錄（供行動端/沙盒指定 App 專屬資料夾使用）
#[uniffi::export]
pub fn set_model_dir(dir_path: String) {
    if !dir_path.is_empty() {
        models::set_model_dir(std::path::PathBuf::from(dir_path));
    }
}

/// 設定模型效能分級（Turbo: 200ms 極速 / Pro: 旗艦高精度）
#[uniffi::export]
pub fn set_model_profile(profile: models::ModelProfile) {
    models::set_model_profile(profile);
}

/// 取得目前的模型效能分級
#[uniffi::export]
pub fn get_model_profile() -> models::ModelProfile {
    models::get_model_profile()
}

/// 檢查指定模型是否已存在於本地（不觸發下載）。
#[uniffi::export]
pub fn is_model_ready(kind: models::ModelKind) -> bool {
    models::is_model_ready(kind)
}

/// 啟動背景執行緒下載指定模型。非同步、立即返回；
/// 呼叫端應以 `get_model_download_progress` 輪詢進度（例如每 200ms）。
#[uniffi::export]
pub fn start_model_download(kind: models::ModelKind) {
    models::start_download(kind);
}

/// 取得指定模型目前的下載進度／狀態。
#[uniffi::export]
pub fn get_model_download_progress(kind: models::ModelKind) -> models::ModelProgress {
    models::get_progress(kind)
}

#[uniffi::export]
pub fn start_recording() -> Result<(), EchoWriteError> {
    let mut state = STATE.lock().map_err(|e| EchoWriteError::RecordError { message: e.to_string() })?;
    if state.is_recording {
        return Err(EchoWriteError::RecordError { message: "Already recording".to_string() });
    }
    state.is_recording = true;
    audio::start_audio_capture().map_err(|e| EchoWriteError::RecordError { message: e })?;
    Ok(())
}

#[uniffi::export]
pub fn stop_recording_and_process(style: String) -> Result<String, EchoWriteError> {
    stop_recording_and_process_with_context(style, None)
}

#[uniffi::export]
pub fn stop_recording_and_process_with_context(style: String, context_before: Option<String>) -> Result<String, EchoWriteError> {
    let (audio_path, whisper_model, llm_model) = {
        let mut state = STATE.lock().map_err(|e| EchoWriteError::ProcessError { message: e.to_string() })?;
        if !state.is_recording {
            return Err(EchoWriteError::ProcessError { message: "Not recording".to_string() });
        }
        state.is_recording = false;
        
        // 1. 取得錄音音訊檔案路徑
        let audio_path = audio::stop_audio_capture()
            .map_err(|e| EchoWriteError::ProcessError { message: e })?;
        
        let whisper_model = resolve_model_path(state.whisper_model_path.clone(), models::ModelKind::Whisper)?;
        let llm_model = resolve_model_path(state.llm_model_path.clone(), models::ModelKind::Llm)?;

        (audio_path, whisper_model, llm_model)
    }; // 此處 Mutex 鎖自動釋放！

    process_audio_file_internal(audio_path, style, whisper_model, llm_model, context_before)
}

#[uniffi::export]
pub fn process_audio_file(audio_path: String, style: String) -> Result<String, EchoWriteError> {
    process_audio_file_with_context(audio_path, style, None)
}

#[uniffi::export]
pub fn process_audio_file_with_context(audio_path: String, style: String, context_before: Option<String>) -> Result<String, EchoWriteError> {
    let (whisper_model, llm_model) = {
        let state = STATE.lock().map_err(|e| EchoWriteError::ProcessError { message: e.to_string() })?;
        let whisper_model = resolve_model_path(state.whisper_model_path.clone(), models::ModelKind::Whisper)?;
        let llm_model = resolve_model_path(state.llm_model_path.clone(), models::ModelKind::Llm)?;
        (whisper_model, llm_model)
    };

    process_audio_file_internal(audio_path, style, whisper_model, llm_model, context_before)
}

/// 優先使用初始化時已解析的路徑；若當時尚未就緒，重新檢查一次
/// （處理「initialize 時模型還沒下載完，但現在下載完成了」的情況）。
fn resolve_model_path(cached: Option<String>, kind: models::ModelKind) -> Result<String, EchoWriteError> {
    if let Some(path) = cached {
        return Ok(path);
    }
    models::default_model_path(kind).ok_or_else(|| EchoWriteError::ProcessError {
        message: format!("Model not ready: {:?}. Call start_model_download first.", kind),
    })
}

#[uniffi::export]
pub fn format_only(text: String) -> String {
    formatter::format_text(text)
}

/// 新增一個自訂詞彙（人名、產品名、公司名等），之後的語音辨識會優先套用
#[uniffi::export]
pub fn add_custom_vocabulary(phrase: String) -> Result<(), EchoWriteError> {
    database::add_custom_phrase(&phrase).map_err(|e| EchoWriteError::ProcessError { message: e.to_string() })
}

/// 刪除指定的自訂詞彙。
#[uniffi::export]
pub fn delete_custom_vocabulary(phrase: String) -> Result<(), EchoWriteError> {
    database::delete_custom_phrase(&phrase).map_err(|e| EchoWriteError::ProcessError { message: e.to_string() })
}

/// 取得目前所有自訂詞彙，供設定畫面顯示/管理。
#[uniffi::export]
pub fn get_custom_vocabulary() -> Result<Vec<String>, EchoWriteError> {
    database::get_custom_phrases().map_err(|e| EchoWriteError::ProcessError { message: e.to_string() })
}

/// 新增個人口吻風格範例
#[uniffi::export]
pub fn add_personal_tone_sample(sample_text: String) -> Result<(), EchoWriteError> {
    database::add_personal_tone_sample(&sample_text).map_err(|e| EchoWriteError::ProcessError { message: e.to_string() })
}

/// 取得個人口吻風格範例
#[uniffi::export]
pub fn get_personal_tone_samples() -> Result<Vec<String>, EchoWriteError> {
    database::get_personal_tone_samples().map_err(|e| EchoWriteError::ProcessError { message: e.to_string() })
}

/// 清空個人口吻風格範例
#[uniffi::export]
pub fn clear_personal_tone_samples() -> Result<(), EchoWriteError> {
    database::clear_personal_tone_samples().map_err(|e| EchoWriteError::ProcessError { message: e.to_string() })
}

/// 零雲端詞庫與風格同步資料匯出（JSON 字串）
#[uniffi::export]
pub fn export_sync_data() -> Result<String, EchoWriteError> {
    database::export_sync_data().map_err(|e| EchoWriteError::ProcessError { message: e.to_string() })
}

/// 零雲端詞庫與風格同步資料匯入（傳入 JSON 字串，回傳匯入成功的筆數）
#[uniffi::export]
pub fn import_sync_data(json_str: String) -> Result<u32, EchoWriteError> {
    database::import_sync_data(&json_str)
        .map(|count| count as u32)
        .map_err(|e| EchoWriteError::ProcessError { message: e.to_string() })
}

/// 取得最近的轉寫歷史紀錄。
#[uniffi::export]
pub fn get_transcription_history(limit: u32) -> Result<Vec<HistoryRecord>, EchoWriteError> {
    database::get_history(limit).map_err(|e| EchoWriteError::ProcessError { message: e.to_string() })
}

/// 刪除單筆歷史紀錄。
#[uniffi::export]
pub fn delete_history_item(id: i64) -> Result<(), EchoWriteError> {
    database::delete_history_item(id).map_err(|e| EchoWriteError::ProcessError { message: e.to_string() })
}

/// 清空所有歷史紀錄。
#[uniffi::export]
pub fn clear_transcription_history() -> Result<(), EchoWriteError> {
    database::clear_history().map_err(|e| EchoWriteError::ProcessError { message: e.to_string() })
}

/// 取得指定風格的 Prompt 內容說明。
#[uniffi::export]
pub fn get_style_prompt_preview(style: String) -> String {
    llm::get_system_prompt_for_style(&style).to_string()
}

fn process_audio_file_internal(
    audio_path: String,
    style: String,
    whisper_model: String,
    llm_model: String,
    context_before: Option<String>,
) -> Result<String, EchoWriteError> {
    // 2. 呼叫本地 ASR 進行語音轉文字 (在鎖外執行)
    // 自訂詞彙查詢失敗不應阻斷整個轉寫流程，僅降級為不使用引導詞。
    let custom_vocabulary = database::get_custom_phrases().unwrap_or_default();
    let raw_text = asr::transcribe(audio_path, &whisper_model, &custom_vocabulary)
        .map_err(|e| EchoWriteError::ProcessError { message: e })?;

    if raw_text.trim().is_empty() {
        return Ok(String::new());
    }

    // 2.5 語音快速編輯指令判斷 (Voice Command Editing Fast-Path)
    if let Some(cmd_text) = formatter::handle_voice_editing_command(&raw_text) {
        return Ok(cmd_text);
    }

    let tone_samples = database::get_personal_tone_samples().unwrap_or_default();
    let is_casual = style.is_empty() || style == "casual" || style == "smart";
    let has_no_context = context_before.as_ref().map(|s| s.trim().is_empty()).unwrap_or(true);
    let is_short_phrase = raw_text.chars().count() <= 14;

    // 2.8 智能極速通道 (Smart Ultra-Fast Path < 1ms)
    // 針對簡短日常口述（如「好的收到」、「明天下午三點開會」），規則引擎即可達成 100% 同音字校正、在地標點與中英空格，實現零延遲瞬間反饋！
    let polished_text = if is_casual && has_no_context && tone_samples.is_empty() && is_short_phrase {
        raw_text
    } else {
        // 3. 呼叫本地常駐 SLM 進行句式潤飾與重組 (結合 Context 與個人風格範例，常駐 RAM/顯存 0ms 重載)
        match llm::polish_text_with_context(raw_text.clone(), style, &llm_model, context_before, &tone_samples) {
            Ok(text) => text,
            Err(e) => {
                // LLM 發生任何異常時平滑降級為原始文字排版，絕不阻塞使用者輸入
                eprintln!("[EchoWrite Core] LLM 處理警告，平滑降級為規則排版: {}", e);
                raw_text
            }
        }
    };

    // 4. 套用台灣繁體中文排版規範
    let formatted_text = formatter::format_text(polished_text);

    // 5. 存入本地歷史紀錄
    database::save_history(&formatted_text)
        .map_err(|e| EchoWriteError::ProcessError { message: e.to_string() })?;

    Ok(formatted_text)
}
