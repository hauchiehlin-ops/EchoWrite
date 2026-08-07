use crate::models::ModelKind;
use crate::{
    add_custom_vocabulary, get_custom_vocabulary, get_model_download_progress, initialize, is_model_ready,
    process_audio_file, start_model_download, start_recording, stop_recording_and_process,
};
use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int};

fn str_from_ptr(ptr: *const c_char) -> Result<String, c_int> {
    if ptr.is_null() {
        return Err(1);
    }
    let cstr = unsafe { CStr::from_ptr(ptr) };
    cstr.to_str().map(|s| s.to_string()).map_err(|_| 2)
}

fn into_raw_c_string(text: String) -> *mut c_char {
    CString::new(text).unwrap_or_else(|_| CString::new("").unwrap()).into_raw()
}

// 0 = 有效路徑字串傳入即視為指定路徑；空字串或 null 視為「自動解析本地模型目錄」。
fn opt_str_from_ptr(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    match str_from_ptr(ptr) {
        Ok(s) if !s.is_empty() => Some(s),
        _ => None,
    }
}

#[no_mangle]
pub extern "C" fn echowrite_initialize(whisper_path: *const c_char, llm_path: *const c_char) -> c_int {
    let whisper_path = opt_str_from_ptr(whisper_path);
    let llm_path = opt_str_from_ptr(llm_path);

    match initialize(whisper_path, llm_path) {
        Ok(_) => 0,
        Err(_) => 3,
    }
}

fn model_kind_from_c_int(kind: c_int) -> ModelKind {
    if kind == 1 {
        ModelKind::Llm
    } else {
        ModelKind::Whisper
    }
}

/// 檢查模型是否已存在本地（0 = Whisper, 1 = Llm）。回傳 1 = 就緒, 0 = 未就緒。
#[no_mangle]
pub extern "C" fn echowrite_is_model_ready(kind: c_int) -> c_int {
    if is_model_ready(model_kind_from_c_int(kind)) {
        1
    } else {
        0
    }
}

/// 啟動背景下載（非同步，立即返回）。
#[no_mangle]
pub extern "C" fn echowrite_start_model_download(kind: c_int) {
    start_model_download(model_kind_from_c_int(kind));
}

/// 取得下載進度。透過輸出參數回傳，避免跨語言結構體 ABI 對齊問題。
/// `state_out`: 0=NotStarted 1=Downloading 2=Verifying 3=Ready 4=Failed
#[no_mangle]
pub extern "C" fn echowrite_get_model_download_progress(
    kind: c_int,
    downloaded_out: *mut u64,
    total_out: *mut u64,
    state_out: *mut c_int,
) {
    let progress = get_model_download_progress(model_kind_from_c_int(kind));
    let state_code = match progress.state {
        crate::ModelDownloadState::NotStarted => 0,
        crate::ModelDownloadState::Downloading => 1,
        crate::ModelDownloadState::Verifying => 2,
        crate::ModelDownloadState::Ready => 3,
        crate::ModelDownloadState::Failed => 4,
    };
    unsafe {
        if !downloaded_out.is_null() {
            *downloaded_out = progress.downloaded_bytes;
        }
        if !total_out.is_null() {
            *total_out = progress.total_bytes;
        }
        if !state_out.is_null() {
            *state_out = state_code;
        }
    }
}

#[no_mangle]
pub extern "C" fn echowrite_start_recording() -> c_int {
    match start_recording() {
        Ok(_) => 0,
        Err(_) => 1,
    }
}

#[no_mangle]
pub extern "C" fn echowrite_stop_recording_and_process(style: *const c_char) -> *mut c_char {
    let style = match str_from_ptr(style) {
        Ok(v) => v,
        Err(_) => return into_raw_c_string(String::new()),
    };

    match stop_recording_and_process(style) {
        Ok(text) => into_raw_c_string(text),
        Err(_) => into_raw_c_string(String::new()),
    }
}

#[no_mangle]
pub extern "C" fn echowrite_process_audio_file(audio_path: *const c_char, style: *const c_char) -> *mut c_char {
    let audio_path = match str_from_ptr(audio_path) {
        Ok(v) => v,
        Err(_) => return into_raw_c_string(String::new()),
    };
    let style = match str_from_ptr(style) {
        Ok(v) => v,
        Err(_) => return into_raw_c_string(String::new()),
    };

    match process_audio_file(audio_path, style) {
        Ok(text) => into_raw_c_string(text),
        Err(_) => into_raw_c_string(String::new()),
    }
}

/// 新增一個自訂詞彙（人名/產品名等）。回傳 0 = 成功。
#[no_mangle]
pub extern "C" fn echowrite_add_custom_vocabulary(phrase: *const c_char) -> c_int {
    let phrase = match str_from_ptr(phrase) {
        Ok(v) => v,
        Err(code) => return code,
    };
    match add_custom_vocabulary(phrase) {
        Ok(_) => 0,
        Err(_) => 3,
    }
}

/// 刪除自訂詞彙。回傳 0 = 成功。
#[no_mangle]
pub extern "C" fn echowrite_delete_custom_vocabulary(phrase: *const c_char) -> c_int {
    let phrase = match str_from_ptr(phrase) {
        Ok(v) => v,
        Err(code) => return code,
    };
    match crate::delete_custom_vocabulary(phrase) {
        Ok(_) => 0,
        Err(_) => 3,
    }
}

/// 取得所有自訂詞彙，以換行字元（\n）分隔回傳。
#[no_mangle]
pub extern "C" fn echowrite_get_custom_vocabulary() -> *mut c_char {
    match get_custom_vocabulary() {
        Ok(phrases) => into_raw_c_string(phrases.join("\n")),
        Err(_) => into_raw_c_string(String::new()),
    }
}

/// 取得歷史紀錄（JSON 字串陣列格式）。
#[no_mangle]
pub extern "C" fn echowrite_get_transcription_history_json(limit: c_int) -> *mut c_char {
    let limit_u32 = if limit <= 0 { 50 } else { limit as u32 };
    match crate::get_transcription_history(limit_u32) {
        Ok(history) => {
            let json = serde_json::to_string(&history.into_iter().map(|h| {
                serde_json::json!({
                    "id": h.id,
                    "timestamp": h.timestamp,
                    "text": h.text
                })
            }).collect::<Vec<_>>()).unwrap_or_else(|_| "[]".to_string());
            into_raw_c_string(json)
        }
        Err(_) => into_raw_c_string("[]".to_string()),
    }
}

/// 刪除單筆歷史紀錄。
#[no_mangle]
pub extern "C" fn echowrite_delete_history_item(id: i64) -> c_int {
    match crate::delete_history_item(id) {
        Ok(_) => 0,
        Err(_) => 1,
    }
}

/// 清空歷史紀錄。
#[no_mangle]
pub extern "C" fn echowrite_clear_transcription_history() -> c_int {
    match crate::clear_transcription_history() {
        Ok(_) => 0,
        Err(_) => 1,
    }
}

#[no_mangle]
pub extern "C" fn echowrite_process_audio_file_with_context(
    audio_path: *const c_char,
    style: *const c_char,
    context_before: *const c_char,
) -> *mut c_char {
    let audio_path = match str_from_ptr(audio_path) {
        Ok(v) => v,
        Err(_) => return into_raw_c_string(String::new()),
    };
    let style = match str_from_ptr(style) {
        Ok(v) => v,
        Err(_) => return into_raw_c_string(String::new()),
    };
    let context_before = opt_str_from_ptr(context_before);

    match crate::process_audio_file_with_context(audio_path, style, context_before) {
        Ok(text) => into_raw_c_string(text),
        Err(_) => into_raw_c_string(String::new()),
    }
}

#[no_mangle]
pub extern "C" fn echowrite_format_only(text: *const c_char) -> *mut c_char {
    let text = match str_from_ptr(text) {
        Ok(v) => v,
        Err(_) => return into_raw_c_string(String::new()),
    };
    into_raw_c_string(crate::format_only(text))
}

#[no_mangle]
pub extern "C" fn echowrite_set_model_profile(profile_id: c_int) {
    let profile = if profile_id == 1 {
        crate::ModelProfile::Pro
    } else {
        crate::ModelProfile::Turbo
    };
    crate::set_model_profile(profile);
}

#[no_mangle]
pub extern "C" fn echowrite_get_model_profile() -> c_int {
    match crate::get_model_profile() {
        crate::ModelProfile::Turbo => 0,
        crate::ModelProfile::Pro => 1,
    }
}

#[no_mangle]
pub extern "C" fn echowrite_add_personal_tone_sample(sample_text: *const c_char) -> c_int {
    let sample = match str_from_ptr(sample_text) {
        Ok(v) => v,
        Err(code) => return code,
    };
    match crate::add_personal_tone_sample(sample) {
        Ok(_) => 0,
        Err(_) => 1,
    }
}

#[no_mangle]
pub extern "C" fn echowrite_get_personal_tone_samples() -> *mut c_char {
    match crate::get_personal_tone_samples() {
        Ok(samples) => {
            let json = serde_json::to_string(&samples).unwrap_or_else(|_| "[]".to_string());
            into_raw_c_string(json)
        }
        Err(_) => into_raw_c_string("[]".to_string()),
    }
}

#[no_mangle]
pub extern "C" fn echowrite_clear_personal_tone_samples() -> c_int {
    match crate::clear_personal_tone_samples() {
        Ok(_) => 0,
        Err(_) => 1,
    }
}

#[no_mangle]
pub extern "C" fn echowrite_export_sync_data() -> *mut c_char {
    match crate::export_sync_data() {
        Ok(json) => into_raw_c_string(json),
        Err(_) => into_raw_c_string("{}".to_string()),
    }
}

#[no_mangle]
pub extern "C" fn echowrite_import_sync_data(json_str: *const c_char) -> c_int {
    let json = match str_from_ptr(json_str) {
        Ok(v) => v,
        Err(code) => return code,
    };
    match crate::import_sync_data(json) {
        Ok(count) => count as c_int,
        Err(_) => -1,
    }
}

#[no_mangle]
pub extern "C" fn echowrite_free_string(ptr: *mut c_char) {
    if ptr.is_null() {
        return;
    }
    unsafe {
        let _ = CString::from_raw(ptr);
    }
}
