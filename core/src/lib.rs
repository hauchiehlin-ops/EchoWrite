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

pub use models::{ModelDownloadState, ModelKind, ModelProgress};

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

    // 初始化 SQLite 資料庫
    database::init_db().map_err(|e| EchoWriteError::InitError { message: e.to_string() })?;
    Ok(())
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

    process_audio_file_internal(audio_path, style, whisper_model, llm_model)
}

#[uniffi::export]
pub fn process_audio_file(audio_path: String, style: String) -> Result<String, EchoWriteError> {
    let (whisper_model, llm_model) = {
        let state = STATE.lock().map_err(|e| EchoWriteError::ProcessError { message: e.to_string() })?;
        let whisper_model = resolve_model_path(state.whisper_model_path.clone(), models::ModelKind::Whisper)?;
        let llm_model = resolve_model_path(state.llm_model_path.clone(), models::ModelKind::Llm)?;
        (whisper_model, llm_model)
    };

    process_audio_file_internal(audio_path, style, whisper_model, llm_model)
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

fn process_audio_file_internal(
    audio_path: String,
    style: String,
    whisper_model: String,
    llm_model: String,
) -> Result<String, EchoWriteError> {
    // 2. 呼叫本地 ASR 進行語音轉文字 (在鎖外執行)
    let raw_text = asr::transcribe(audio_path, &whisper_model)
        .map_err(|e| EchoWriteError::ProcessError { message: e })?;

    if raw_text.trim().is_empty() {
        return Ok(String::new());
    }

    // 3. 呼叫本地 SLM 進行句式潤飾與重組 (在鎖外執行)
    let polished_text = llm::polish_text(raw_text, style, &llm_model)
        .map_err(|e| EchoWriteError::ProcessError { message: e })?;

    // 4. 套用台灣繁體中文排版規範
    let formatted_text = formatter::format_text(polished_text);

    // 5. 存入本地歷史紀錄
    database::save_history(&formatted_text)
        .map_err(|e| EchoWriteError::ProcessError { message: e.to_string() })?;

    Ok(formatted_text)
}
