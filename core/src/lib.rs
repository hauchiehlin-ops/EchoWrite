uniffi::setup_scaffolding!();

pub mod audio;
pub mod asr;
pub mod llm;
pub mod formatter;
pub mod database;

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

#[uniffi::export]
pub fn initialize(whisper_path: String, llm_path: String) -> Result<(), EchoWriteError> {
    let mut state = STATE.lock().map_err(|e| EchoWriteError::InitError { message: e.to_string() })?;
    state.whisper_model_path = Some(whisper_path);
    state.llm_model_path = Some(llm_path);
    
    // 初始化 SQLite 資料庫
    database::init_db().map_err(|e| EchoWriteError::InitError { message: e.to_string() })?;
    Ok(())
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
    let mut state = STATE.lock().map_err(|e| EchoWriteError::ProcessError { message: e.to_string() })?;
    if !state.is_recording {
        return Err(EchoWriteError::ProcessError { message: "Not recording".to_string() });
    }
    state.is_recording = false;
    
    // 1. 取得錄音音訊檔案路徑
    let audio_path = audio::stop_audio_capture()
        .map_err(|e| EchoWriteError::ProcessError { message: e })?;
    
    // 2. 呼叫本地 ASR 進行語音轉文字
    let whisper_model = state.whisper_model_path.as_ref()
        .ok_or_else(|| EchoWriteError::ProcessError { message: "Whisper model not initialized".to_string() })?;
    let raw_text = asr::transcribe(audio_path, whisper_model)
        .map_err(|e| EchoWriteError::ProcessError { message: e })?;
    
    if raw_text.trim().is_empty() {
        return Ok(String::new());
    }
    
    // 3. 呼叫本地 SLM (Qwen-2.5) 進行句式潤飾與重組
    let llm_model = state.llm_model_path.as_ref()
        .ok_or_else(|| EchoWriteError::ProcessError { message: "LLM model not initialized".to_string() })?;
    let polished_text = llm::polish_text(raw_text, style, llm_model)
        .map_err(|e| EchoWriteError::ProcessError { message: e })?;
    
    // 4. 套用台灣繁體中文排版規範
    let formatted_text = formatter::format_text(polished_text);
    
    // 5. 存入本地歷史紀錄
    database::save_history(&formatted_text)
        .map_err(|e| EchoWriteError::ProcessError { message: e.to_string() })?;
    
    Ok(formatted_text)
}

#[uniffi::export]
pub fn format_only(text: String) -> String {
    formatter::format_text(text)
}
