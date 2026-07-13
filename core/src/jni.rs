#![cfg(target_os = "android")]

use crate::models::ModelKind;
use crate::{get_model_download_progress, initialize, is_model_ready, process_audio_file, start_model_download};
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

fn model_kind_from_jint(kind: jint) -> ModelKind {
    if kind == 1 {
        ModelKind::Llm
    } else {
        ModelKind::Whisper
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

/// 回傳格式：`state:downloaded:total`（state 同 ffi.rs 的整數碼），
/// 避免額外定義 JNI 結構體轉換。
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
    let result = format!("{}:{}:{}", state_code, downloaded, total);

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

    let result = match process_audio_file(audio_path, style) {
        Ok(text) => text,
        Err(_) => String::new(),
    };

    match env.new_string(result) {
        Ok(output) => output.into_raw(),
        Err(_) => ptr::null_mut(),
    }
}
