use crate::{initialize, process_audio_file, start_recording, stop_recording_and_process};
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

#[no_mangle]
pub extern "C" fn echowrite_initialize(whisper_path: *const c_char, llm_path: *const c_char) -> c_int {
    let whisper_path = match str_from_ptr(whisper_path) {
        Ok(v) => v,
        Err(code) => return code,
    };
    let llm_path = match str_from_ptr(llm_path) {
        Ok(v) => v,
        Err(code) => return code,
    };

    match initialize(whisper_path, llm_path) {
        Ok(_) => 0,
        Err(_) => 3,
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

#[no_mangle]
pub extern "C" fn echowrite_free_string(ptr: *mut c_char) {
    if ptr.is_null() {
        return;
    }
    unsafe {
        let _ = CString::from_raw(ptr);
    }
}
