#![cfg(target_os = "android")]

use crate::{initialize, process_audio_file};
use jni::objects::{JObject, JString};
use jni::sys::{jboolean, jstring, JNI_FALSE, JNI_TRUE};
use jni::JNIEnv;
use std::ptr;

fn get_java_string(env: &mut JNIEnv, value: JString) -> Result<String, String> {
    env.get_string(&value)
        .map(|s| s.to_string_lossy().into_owned())
        .map_err(|e| e.to_string())
}

#[no_mangle]
pub extern "system" fn Java_com_echowrite_app_EchoWriteIME_initialize(
    mut env: JNIEnv,
    _: JObject,
    whisper_path: JString,
    llm_path: JString,
) -> jboolean {
    let whisper_path = match get_java_string(&mut env, whisper_path) {
        Ok(v) => v,
        Err(_) => return JNI_FALSE,
    };
    let llm_path = match get_java_string(&mut env, llm_path) {
        Ok(v) => v,
        Err(_) => return JNI_FALSE,
    };

    match initialize(whisper_path, llm_path) {
        Ok(_) => JNI_TRUE,
        Err(_) => JNI_FALSE,
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
