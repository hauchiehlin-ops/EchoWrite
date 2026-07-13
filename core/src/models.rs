// 模型下載與管理模組
//
// 解決「初次執行沒有模型檔案」的問題：定義模型存放位置、檢查是否已就緒，
// 並提供背景執行緒下載 + 進度輪詢（供 UniFFI 各平台呼叫），避免在
// Keyboard Extension / Service Worker 等短生命週期環境中阻塞主執行緒。

use lazy_static::lazy_static;
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::fs::{self, File};
use std::io::{Read, Write};
use std::path::PathBuf;
use std::sync::Mutex;
use std::thread;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum ModelKind {
    Whisper,
    Llm,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum ModelDownloadState {
    NotStarted,
    Downloading,
    Verifying,
    Ready,
    Failed,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct ModelProgress {
    pub downloaded_bytes: u64,
    pub total_bytes: u64,
    pub state: ModelDownloadState,
    pub error: Option<String>,
}

struct ModelSpec {
    filename: &'static str,
    url: &'static str,
    // 若提供，下載完成後會校驗 sha256；留空則略過校驗。
    sha256: Option<&'static str>,
}

fn spec_for(kind: ModelKind) -> ModelSpec {
    match kind {
        ModelKind::Whisper => ModelSpec {
            filename: "ggml-base-q5_1.bin",
            url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base-q5_1.bin",
            sha256: None,
        },
        ModelKind::Llm => ModelSpec {
            filename: "qwen2.5-0.5b-instruct-q5_k_m.gguf",
            url: "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q5_k_m.gguf",
            sha256: None,
        },
    }
}

/// 模型存放目錄。可用 `ECHOWRITE_MODEL_DIR` 環境變數覆寫（測試 / 平台自訂共享容器路徑用）。
pub fn model_dir() -> PathBuf {
    if let Ok(override_dir) = std::env::var("ECHOWRITE_MODEL_DIR") {
        let path = PathBuf::from(override_dir);
        let _ = fs::create_dir_all(&path);
        return path;
    }
    let mut dir = dirs_next::home_dir().unwrap_or_else(|| PathBuf::from("."));
    dir.push(".echowrite");
    dir.push("models");
    let _ = fs::create_dir_all(&dir);
    dir
}

pub fn model_path(kind: ModelKind) -> PathBuf {
    let mut path = model_dir();
    path.push(spec_for(kind).filename);
    path
}

pub fn is_model_ready(kind: ModelKind) -> bool {
    model_path(kind).is_file()
}

/// 若模型檔案已存在於本地，回傳其絕對路徑；否則回傳 None。
pub fn default_model_path(kind: ModelKind) -> Option<String> {
    let path = model_path(kind);
    if path.is_file() {
        Some(path.to_string_lossy().to_string())
    } else {
        None
    }
}

lazy_static! {
    static ref PROGRESS: Mutex<HashMap<ModelKind, ModelProgress>> = Mutex::new(HashMap::new());
}

fn set_progress(kind: ModelKind, progress: ModelProgress) {
    if let Ok(mut map) = PROGRESS.lock() {
        map.insert(kind, progress);
    }
}

pub fn get_progress(kind: ModelKind) -> ModelProgress {
    if let Ok(map) = PROGRESS.lock() {
        if let Some(p) = map.get(&kind) {
            return p.clone();
        }
    }
    ModelProgress {
        downloaded_bytes: 0,
        total_bytes: 0,
        state: if is_model_ready(kind) {
            ModelDownloadState::Ready
        } else {
            ModelDownloadState::NotStarted
        },
        error: None,
    }
}

/// 啟動背景下載執行緒（若已就緒或已在下載中則直接返回）。
/// 呼叫端（各平台）應輪詢 `get_progress` 更新 UI。
pub fn start_download(kind: ModelKind) {
    if is_model_ready(kind) {
        set_progress(
            kind,
            ModelProgress {
                downloaded_bytes: 0,
                total_bytes: 0,
                state: ModelDownloadState::Ready,
                error: None,
            },
        );
        return;
    }
    if get_progress(kind).state == ModelDownloadState::Downloading {
        return;
    }

    set_progress(
        kind,
        ModelProgress {
            downloaded_bytes: 0,
            total_bytes: 0,
            state: ModelDownloadState::Downloading,
            error: None,
        },
    );

    thread::spawn(move || {
        if let Err(e) = download_blocking(kind) {
            set_progress(
                kind,
                ModelProgress {
                    downloaded_bytes: 0,
                    total_bytes: 0,
                    state: ModelDownloadState::Failed,
                    error: Some(e),
                },
            );
        }
    });
}

fn download_blocking(kind: ModelKind) -> Result<(), String> {
    let spec = spec_for(kind);
    let dest = model_path(kind);
    let tmp_dest = dest.with_extension("part");

    let response = reqwest::blocking::get(spec.url).map_err(|e| e.to_string())?;
    if !response.status().is_success() {
        return Err(format!("Download failed: HTTP {}", response.status()));
    }
    let total = response.content_length().unwrap_or(0);

    let mut file = File::create(&tmp_dest).map_err(|e| e.to_string())?;
    let mut reader = response;
    let mut buffer = [0u8; 65536];
    let mut downloaded: u64 = 0;

    loop {
        let n = reader.read(&mut buffer).map_err(|e| e.to_string())?;
        if n == 0 {
            break;
        }
        file.write_all(&buffer[..n]).map_err(|e| e.to_string())?;
        downloaded += n as u64;
        set_progress(
            kind,
            ModelProgress {
                downloaded_bytes: downloaded,
                total_bytes: total,
                state: ModelDownloadState::Downloading,
                error: None,
            },
        );
    }
    drop(file);

    if let Some(expected) = spec.sha256 {
        set_progress(
            kind,
            ModelProgress {
                downloaded_bytes: downloaded,
                total_bytes: total,
                state: ModelDownloadState::Verifying,
                error: None,
            },
        );
        let actual = sha256_of_file(&tmp_dest)?;
        if actual != expected {
            let _ = fs::remove_file(&tmp_dest);
            return Err(format!(
                "Checksum mismatch: expected {}, got {}",
                expected, actual
            ));
        }
    }

    fs::rename(&tmp_dest, &dest).map_err(|e| e.to_string())?;
    set_progress(
        kind,
        ModelProgress {
            downloaded_bytes: downloaded,
            total_bytes: total,
            state: ModelDownloadState::Ready,
            error: None,
        },
    );
    Ok(())
}

fn sha256_of_file(path: &PathBuf) -> Result<String, String> {
    let mut file = File::open(path).map_err(|e| e.to_string())?;
    let mut hasher = Sha256::new();
    let mut buffer = [0u8; 65536];
    loop {
        let n = file.read(&mut buffer).map_err(|e| e.to_string())?;
        if n == 0 {
            break;
        }
        hasher.update(&buffer[..n]);
    }
    Ok(format!("{:x}", hasher.finalize()))
}
