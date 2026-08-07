#![cfg(target_os = "android")]

use crate::models::{ModelKind, ModelProfile};
use crate::{
    add_custom_vocabulary, format_only, get_custom_vocabulary, get_model_download_progress, initialize, is_model_ready,
    process_audio_file_with_context, start_model_download, set_model_profile, get_model_profile,
    add_personal_tone_sample, get_personal_tone_samples, clear_personal_tone_samples,
    export_sync_data, import_sync_data, set_model_dir,
};
use jni::objects::{JObject, JString};
use jni::sys::{jboolean, jint, jlong, jstring, JNI_FALSE, JNI_TRUE};
use jni::JNIEnv;
use std::ptr;

fn get_java_string(env: &mut JNIEnv, value: JString) -> Result<String, String> {
    env.get_string(&value)
        .map(|s| s.to_string_lossy().into_owned())
        .map_err(|e| e.to_string())
}

// 空字串視為「未指定路徑，交由 Rust 端自動解析本地模型目錄」。
fn get_optional_java_string(env: &mut JNIEnv, value: JString) -> Option<String> {
    get_java_string(env, value).ok().filter(|s| !s.is_empty())
}

fn model_kind_from_jint(kind: jint) -> ModelKind {
    if kind == 1 {
        ModelKind::Llm
    } else {
        ModelKind::Whisper
    }
}

// -----------------------------------------------------------------------------
// JNI Exports for EchoWriteIME
// -----------------------------------------------------------------------------

#[no_mangle]
pub extern "system" fn Java_com_echowrite_app_EchoWriteIME_setModelDir(
    mut env: JNIEnv,
    _: JObject,
    dir: JString,
) -> jboolean {
    if let Ok(dir_str) = get_java_string(&mut env, dir) {
        if !dir_str.is_empty() {
            set_model_dir(dir_str);
            return JNI_TRUE;
        }
    }
    JNI_FALSE
}

#[no_mangle]
pub extern "system" fn Java_com_echowrite_app_EchoWriteIME_initialize(
    mut env: JNIEnv,
    _: JObject,
    whisper_path: JString,
    llm_path: JString,
) -> jboolean {
    let whisper_path = get_optional_java_string(&mut env, whisper_path);
    let llm_path = get_optional_java_string(&mut env, llm_path);

    match initialize(whisper_path, llm_path) {
        Ok(_) => JNI_TRUE,
        Err(_) => JNI_FALSE,
    }
}

#[no_mangle]
pub extern "system" fn Java_com_echowrite_app_EchoWriteIME_isModelReady(
    _env: JNIEnv,
    _: JObject,
    kind: jint,
) -> jboolean {
    if is_model_ready(model_kind_from_jint(kind)) {
        JNI_TRUE
    } else {
        JNI_FALSE
    }
}

#[no_mangle]
pub extern "system" fn Java_com_echowrite_app_EchoWriteIME_startModelDownload(
    _env: JNIEnv,
    _: JObject,
    kind: jint,
) {
    start_model_download(model_kind_from_jint(kind));
}

#[no_mangle]
pub extern "system" fn Java_com_echowrite_app_EchoWriteIME_getModelDownloadProgress(
    mut env: JNIEnv,
    _: JObject,
    kind: jint,
) -> jstring {
    let progress = get_model_download_progress(model_kind_from_jint(kind));
    let state_code: jint = match progress.state {
        crate::ModelDownloadState::NotStarted => 0,
        crate::ModelDownloadState::Downloading => 1,
        crate::ModelDownloadState::Verifying => 2,
        crate::ModelDownloadState::Ready => 3,
        crate::ModelDownloadState::Failed => 4,
    };
    let downloaded: jlong = progress.downloaded_bytes as jlong;
    let total: jlong = progress.total_bytes as jlong;
    let err_msg = progress.error.unwrap_or_default();
    let result = format!("{}:{}:{}:{}", state_code, downloaded, total, err_msg);

    match env.new_string(result) {
        Ok(output) => output.into_raw(),
        Err(_) => ptr::null_mut(),
    }
}

#[no_mangle]
pub extern "system" fn Java_com_echowrite_app_EchoWriteIME_processAudioFile(
    mut env: JNIEnv,
    _: JObject,
    audio_path: JString,
    style: JString,
) -> jstring {
    let audio_path = match get_java_string(&mut env, audio_path) {
        Ok(v) => v,
        Err(_) => return ptr::null_mut(),
    };
    let style = match get_java_string(&mut env, style) {
        Ok(v) => v,
        Err(_) => return ptr::null_mut(),
    };

    let result = match process_audio_file_with_context(audio_path, style, None) {
        Ok(text) => text,
        Err(_) => String::new(),
    };

    match env.new_string(result) {
        Ok(output) => output.into_raw(),
        Err(_) => ptr::null_mut(),
    }
}

#[no_mangle]
pub extern "system" fn Java_com_echowrite_app_EchoWriteIME_processAudioFileWithContext(
    mut env: JNIEnv,
    _: JObject,
    audio_path: JString,
    style: JString,
    context_before: JString,
) -> jstring {
    let audio_path = match get_java_string(&mut env, audio_path) {
        Ok(v) => v,
        Err(_) => return ptr::null_mut(),
    };
    let style = match get_java_string(&mut env, style) {
        Ok(v) => v,
        Err(_) => return ptr::null_mut(),
    };
    let context_before = get_optional_java_string(&mut env, context_before);

    let result = match process_audio_file_with_context(audio_path, style, context_before) {
        Ok(text) => text,
        Err(_) => String::new(),
    };

    match env.new_string(result) {
        Ok(output) => output.into_raw(),
        Err(_) => ptr::null_mut(),
    }
}

#[no_mangle]
pub extern "system" fn Java_com_echowrite_app_EchoWriteIME_formatOnly(
    mut env: JNIEnv,
    _: JObject,
    text: JString,
) -> jstring {
    let text = match get_java_string(&mut env, text) {
        Ok(v) => v,
        Err(_) => return ptr::null_mut(),
    };

    let result = format_only(text);
    match env.new_string(result) {
        Ok(output) => output.into_raw(),
        Err(_) => ptr::null_mut(),
    }
}

#[no_mangle]
pub extern "system" fn Java_com_echowrite_app_EchoWriteIME_addCustomVocabulary(
    mut env: JNIEnv,
    _: JObject,
    phrase: JString,
) -> jboolean {
    let phrase = match get_java_string(&mut env, phrase) {
        Ok(v) => v,
        Err(_) => return JNI_FALSE,
    };
    match add_custom_vocabulary(phrase) {
        Ok(_) => JNI_TRUE,
        Err(_) => JNI_FALSE,
    }
}

#[no_mangle]
pub extern "system" fn Java_com_echowrite_app_EchoWriteIME_deleteCustomVocabulary(
    mut env: JNIEnv,
    _: JObject,
    phrase: JString,
) -> jboolean {
    let phrase = match get_java_string(&mut env, phrase) {
        Ok(v) => v,
        Err(_) => return JNI_FALSE,
    };
    match crate::delete_custom_vocabulary(phrase) {
        Ok(_) => JNI_TRUE,
        Err(_) => JNI_FALSE,
    }
}

#[no_mangle]
pub extern "system" fn Java_com_echowrite_app_EchoWriteIME_getCustomVocabulary(
    mut env: JNIEnv,
    _: JObject,
) -> jstring {
    let joined = get_custom_vocabulary().unwrap_or_default().join("\n");
    match env.new_string(joined) {
        Ok(output) => output.into_raw(),
        Err(_) => ptr::null_mut(),
    }
}

#[no_mangle]
pub extern "system" fn Java_com_echowrite_app_EchoWriteIME_getTranscriptionHistory(
    mut env: JNIEnv,
    _: JObject,
    limit: jint,
) -> jstring {
    let limit_u32 = if limit <= 0 { 50 } else { limit as u32 };
    let json = match crate::get_transcription_history(limit_u32) {
        Ok(history) => {
            serde_json::to_string(&history.into_iter().map(|h| {
                serde_json::json!({
                    "id": h.id,
                    "timestamp": h.timestamp,
                    "text": h.text
                })
            }).collect::<Vec<_>>()).unwrap_or_else(|_| "[]".to_string())
        }
        Err(_) => "[]".to_string(),
    };

    match env.new_string(json) {
        Ok(output) => output.into_raw(),
        Err(_) => ptr::null_mut(),
    }
}

#[no_mangle]
pub extern "system" fn Java_com_echowrite_app_EchoWriteIME_deleteHistoryItem(
    _env: JNIEnv,
    _: JObject,
    id: jlong,
) -> jboolean {
    match crate::delete_history_item(id as i64) {
        Ok(_) => JNI_TRUE,
        Err(_) => JNI_FALSE,
    }
}

#[no_mangle]
pub extern "system" fn Java_com_echowrite_app_EchoWriteIME_clearTranscriptionHistory(
    _env: JNIEnv,
    _: JObject,
) -> jboolean {
    match crate::clear_transcription_history() {
        Ok(_) => JNI_TRUE,
        Err(_) => JNI_FALSE,
    }
}

// -----------------------------------------------------------------------------
// JNI Exports for EchoWriteCore
// -----------------------------------------------------------------------------

#[no_mangle]
pub extern "system" fn Java_com_echowrite_app_EchoWriteCore_setModelDir(
    env: JNIEnv,
    obj: JObject,
    dir: JString,
) -> jboolean {
    Java_com_echowrite_app_EchoWriteIME_setModelDir(env, obj, dir)
}

#[no_mangle]
pub extern "system" fn Java_com_echowrite_app_EchoWriteCore_initialize(
    env: JNIEnv,
    obj: JObject,
    whisper_path: JString,
    llm_path: JString,
) -> jboolean {
    Java_com_echowrite_app_EchoWriteIME_initialize(env, obj, whisper_path, llm_path)
}

#[no_mangle]
pub extern "system" fn Java_com_echowrite_app_EchoWriteCore_isModelReady(
    env: JNIEnv,
    obj: JObject,
    kind: jint,
) -> jboolean {
    Java_com_echowrite_app_EchoWriteIME_isModelReady(env, obj, kind)
}

#[no_mangle]
pub extern "system" fn Java_com_echowrite_app_EchoWriteCore_startModelDownload(
    env: JNIEnv,
    obj: JObject,
    kind: jint,
) {
    Java_com_echowrite_app_EchoWriteIME_startModelDownload(env, obj, kind)
}

#[no_mangle]
pub extern "system" fn Java_com_echowrite_app_EchoWriteCore_getModelDownloadProgress(
    env: JNIEnv,
    obj: JObject,
    kind: jint,
) -> jstring {
    Java_com_echowrite_app_EchoWriteIME_getModelDownloadProgress(env, obj, kind)
}

#[no_mangle]
pub extern "system" fn Java_com_echowrite_app_EchoWriteCore_processAudioFile(
    env: JNIEnv,
    obj: JObject,
    audio_path: JString,
    style: JString,
) -> jstring {
    Java_com_echowrite_app_EchoWriteIME_processAudioFile(env, obj, audio_path, style)
}

#[no_mangle]
pub extern "system" fn Java_com_echowrite_app_EchoWriteCore_processAudioFileWithContext(
    env: JNIEnv,
    obj: JObject,
    audio_path: JString,
    style: JString,
    context_before: JString,
) -> jstring {
    Java_com_echowrite_app_EchoWriteIME_processAudioFileWithContext(env, obj, audio_path, style, context_before)
}

#[no_mangle]
pub extern "system" fn Java_com_echowrite_app_EchoWriteCore_formatOnly(
    env: JNIEnv,
    obj: JObject,
    text: JString,
) -> jstring {
    Java_com_echowrite_app_EchoWriteIME_formatOnly(env, obj, text)
}

#[no_mangle]
pub extern "system" fn Java_com_echowrite_app_EchoWriteCore_addCustomVocabulary(
    env: JNIEnv,
    obj: JObject,
    phrase: JString,
) -> jboolean {
    Java_com_echowrite_app_EchoWriteIME_addCustomVocabulary(env, obj, phrase)
}

#[no_mangle]
pub extern "system" fn Java_com_echowrite_app_EchoWriteCore_deleteCustomVocabulary(
    env: JNIEnv,
    obj: JObject,
    phrase: JString,
) -> jboolean {
    Java_com_echowrite_app_EchoWriteIME_deleteCustomVocabulary(env, obj, phrase)
}

#[no_mangle]
pub extern "system" fn Java_com_echowrite_app_EchoWriteCore_getCustomVocabulary(
    env: JNIEnv,
    obj: JObject,
) -> jstring {
    Java_com_echowrite_app_EchoWriteIME_getCustomVocabulary(env, obj)
}

#[no_mangle]
pub extern "system" fn Java_com_echowrite_app_EchoWriteCore_getTranscriptionHistory(
    env: JNIEnv,
    obj: JObject,
    limit: jint,
) -> jstring {
    Java_com_echowrite_app_EchoWriteIME_getTranscriptionHistory(env, obj, limit)
}

#[no_mangle]
pub extern "system" fn Java_com_echowrite_app_EchoWriteCore_deleteHistoryItem(
    env: JNIEnv,
    obj: JObject,
    id: jlong,
) -> jboolean {
    Java_com_echowrite_app_EchoWriteIME_deleteHistoryItem(env, obj, id)
}

#[no_mangle]
pub extern "system" fn Java_com_echowrite_app_EchoWriteCore_clearTranscriptionHistory(
    env: JNIEnv,
    obj: JObject,
) -> jboolean {
    Java_com_echowrite_app_EchoWriteIME_clearTranscriptionHistory(env, obj)
}

#[no_mangle]
pub extern "system" fn Java_com_echowrite_app_EchoWriteCore_setModelProfile(
    _env: JNIEnv,
    _: JObject,
    profile_id: jint,
) {
    let profile = if profile_id == 1 {
        ModelProfile::Pro
    } else {
        ModelProfile::Turbo
    };
    set_model_profile(profile);
}

#[no_mangle]
pub extern "system" fn Java_com_echowrite_app_EchoWriteCore_getModelProfile(
    _env: JNIEnv,
    _: JObject,
) -> jint {
    match get_model_profile() {
        ModelProfile::Turbo => 0,
        ModelProfile::Pro => 1,
    }
}

#[no_mangle]
pub extern "system" fn Java_com_echowrite_app_EchoWriteCore_addPersonalToneSample(
    mut env: JNIEnv,
    _: JObject,
    sample: JString,
) -> jboolean {
    let sample = match get_java_string(&mut env, sample) {
        Ok(v) => v,
        Err(_) => return JNI_FALSE,
    };
    match add_personal_tone_sample(sample) {
        Ok(_) => JNI_TRUE,
        Err(_) => JNI_FALSE,
    }
}

#[no_mangle]
pub extern "system" fn Java_com_echowrite_app_EchoWriteCore_getPersonalToneSamples(
    mut env: JNIEnv,
    _: JObject,
) -> jstring {
    let samples = get_personal_tone_samples().unwrap_or_default();
    let json = serde_json::to_string(&samples).unwrap_or_else(|_| "[]".to_string());
    match env.new_string(json) {
        Ok(output) => output.into_raw(),
        Err(_) => ptr::null_mut(),
    }
}

#[no_mangle]
pub extern "system" fn Java_com_echowrite_app_EchoWriteCore_clearPersonalToneSamples(
    _env: JNIEnv,
    _: JObject,
) -> jboolean {
    match clear_personal_tone_samples() {
        Ok(_) => JNI_TRUE,
        Err(_) => JNI_FALSE,
    }
}

#[no_mangle]
pub extern "system" fn Java_com_echowrite_app_EchoWriteCore_exportSyncData(
    mut env: JNIEnv,
    _: JObject,
) -> jstring {
    let json = export_sync_data().unwrap_or_else(|_| "{}".to_string());
    match env.new_string(json) {
        Ok(output) => output.into_raw(),
        Err(_) => ptr::null_mut(),
    }
}

#[no_mangle]
pub extern "system" fn Java_com_echowrite_app_EchoWriteCore_importSyncData(
    mut env: JNIEnv,
    _: JObject,
    json: JString,
) -> jint {
    let json = match get_java_string(&mut env, json) {
        Ok(v) => v,
        Err(_) => return -1,
    };
    match import_sync_data(json) {
        Ok(count) => count as jint,
        Err(_) => -1,
    }
}
