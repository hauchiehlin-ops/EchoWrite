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
    // 僅 Whisper 使用：Apple 平台的 CoreML (ANE) 編碼器模型下載位址（*.mlmodelc.zip）。
    // 解壓後會改名為 `{filename 去除副檔名}-encoder.mlmodelc`，符合 whisper.cpp 的查找慣例
    // （見 whisper_get_coreml_path_encoder：把 .bin 換成 -encoder.mlmodelc）。下載/解壓失敗
    // 屬於盡力而為 (best-effort)：whisper.cpp 編譯時已定義 WHISPER_COREML_ALLOW_FALLBACK，
    // 找不到就自動退回 Metal/CPU，不影響 ASR 主流程。
    coreml_encoder_url: Option<&'static str>,
}

fn spec_for(kind: ModelKind) -> ModelSpec {
    match kind {
        ModelKind::Whisper => ModelSpec {
            filename: "ggml-base-q5_1.bin",
            url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base-q5_1.bin",
            sha256: None,
            coreml_encoder_url: Some(
                "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base-encoder.mlmodelc.zip",
            ),
        },
        ModelKind::Llm => ModelSpec {
            filename: "qwen2.5-0.5b-instruct-q5_k_m.gguf",
            url: "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q5_k_m.gguf",
            coreml_encoder_url: None,
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

    #[cfg(any(target_os = "macos", target_os = "ios"))]
    if let Some(coreml_url) = spec.coreml_encoder_url {
        // 盡力而為：CoreML 加速模型下載/解壓失敗不影響主流程，僅記錄警告。
        if let Err(e) = try_setup_coreml_encoder(coreml_url, &dest) {
            eprintln!("EchoWrite: CoreML encoder setup skipped ({e}); ASR 將使用 Metal/CPU。");
        }
    }

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

/// 下載並解壓 CoreML 編碼器模型（*.mlmodelc.zip），放置到
/// `{whisper_model_path 去除副檔名}-encoder.mlmodelc`，讓 whisper.cpp 的
/// `WHISPER_USE_COREML` 查找邏輯能自動找到它並啟用 Apple Neural Engine 加速。
#[cfg(any(target_os = "macos", target_os = "ios"))]
fn try_setup_coreml_encoder(url: &str, whisper_model_path: &PathBuf) -> Result<(), String> {
    let final_dir = {
        let mut stem = whisper_model_path.clone();
        stem.set_extension("");
        let mut name = stem
            .file_name()
            .ok_or("invalid model filename")?
            .to_os_string();
        name.push("-encoder.mlmodelc");
        let mut path = whisper_model_path.clone();
        path.set_file_name(name);
        path
    };

    if final_dir.is_dir() {
        return Ok(()); // 已經設置過。
    }

    let response = reqwest::blocking::get(url).map_err(|e| e.to_string())?;
    if !response.status().is_success() {
        return Err(format!("HTTP {}", response.status()));
    }
    let bytes = response.bytes().map_err(|e| e.to_string())?;

    let zip_path = whisper_model_path.with_extension("mlmodelc.zip.part");
    fs::write(&zip_path, &bytes).map_err(|e| e.to_string())?;

    let extract_dir = whisper_model_path.with_extension("mlmodelc.extract.tmp");
    let _ = fs::remove_dir_all(&extract_dir);
    fs::create_dir_all(&extract_dir).map_err(|e| e.to_string())?;

    let zip_file = File::open(&zip_path).map_err(|e| e.to_string())?;
    let mut archive = zip::ZipArchive::new(zip_file).map_err(|e| e.to_string())?;
    archive
        .extract(&extract_dir)
        .map_err(|e| e.to_string())?;
    let _ = fs::remove_file(&zip_path);

    // 壓縮檔內通常會有一層 *.mlmodelc 目錄（可能巢狀一層資料夾），找出它。
    let mlmodelc_dir = find_mlmodelc_dir(&extract_dir)
        .ok_or_else(|| "no .mlmodelc directory found in archive".to_string())?;

    fs::rename(&mlmodelc_dir, &final_dir).map_err(|e| e.to_string())?;
    let _ = fs::remove_dir_all(&extract_dir);

    Ok(())
}

#[cfg(any(target_os = "macos", target_os = "ios"))]
fn find_mlmodelc_dir(root: &std::path::Path) -> Option<PathBuf> {
    let entries = fs::read_dir(root).ok()?;
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            if path.extension().map(|e| e == "mlmodelc").unwrap_or(false) {
                return Some(path);
            }
            if let Some(found) = find_mlmodelc_dir(&path) {
                return Some(found);
            }
        }
    }
    None
}
