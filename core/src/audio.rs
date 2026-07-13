use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use std::fs::File;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use lazy_static::lazy_static;

#[allow(dead_code)]
struct StreamWrapper(cpal::Stream);
unsafe impl Send for StreamWrapper {}
unsafe impl Sync for StreamWrapper {}

lazy_static! {
    // 儲存錄音串流，保持 active 狀態
    static ref ACTIVE_STREAM: Mutex<Option<StreamWrapper>> = Mutex::new(None);
    // 在記憶體中暫存錄音的原始 f32 samples
    static ref RECORDED_SAMPLES: Arc<Mutex<Vec<f32>>> = Arc::new(Mutex::new(Vec::new()));
    // 錄音時的硬體音訊規格
    static ref RECORD_CONFIG: Mutex<Option<(u16, u32)>> = Mutex::new(None);
}

pub fn start_audio_capture() -> Result<(), String> {
    // 1. 重設快取
    {
        let mut samples = RECORDED_SAMPLES.lock().map_err(|e| e.to_string())?;
        samples.clear();
    }

    // 2. 獲取預設的輸入音訊裝置 (麥克風)
    let host = cpal::default_host();
    let device = host.default_input_device()
        .ok_or_else(|| "找不到預設輸入音訊裝置 (麥克風)".to_string())?;
    
    let config = device.default_input_config()
        .map_err(|e| format!("無法讀取麥克風配置: {}", e))?;
    
    let channels = config.channels();
    let sample_rate = config.sample_rate().0;
    
    // 快取目前的硬體錄音參數
    {
        let mut cached_config = RECORD_CONFIG.lock().map_err(|e| e.to_string())?;
        *cached_config = Some((channels, sample_rate));
    }

    let samples_clone = RECORDED_SAMPLES.clone();
    
    // 3. 建立並啟動 CPAL 輸入音訊串流
    let err_cb = |err| println!("CPAL 錄音發生錯誤: {}", err);
    
    let stream = match config.sample_format() {
        cpal::SampleFormat::F32 => device.build_input_stream(
            &config.into(),
            move |data: &[f32], _: &_| {
                if let Ok(mut samples) = samples_clone.lock() {
                    samples.extend_from_slice(data);
                }
            },
            err_cb,
            None
        ),
        cpal::SampleFormat::I16 => device.build_input_stream(
            &config.into(),
            move |data: &[i16], _: &_| {
                if let Ok(mut samples) = samples_clone.lock() {
                    let f32_data: Vec<f32> = data.iter().map(|&s| s as f32 / 32768.0).collect();
                    samples.extend_from_slice(&f32_data);
                }
            },
            err_cb,
            None
        ),
        cpal::SampleFormat::U16 => device.build_input_stream(
            &config.into(),
            move |data: &[u16], _: &_| {
                if let Ok(mut samples) = samples_clone.lock() {
                    let f32_data: Vec<f32> = data.iter().map(|&s| (s as f32 - 32768.0) / 32768.0).collect();
                    samples.extend_from_slice(&f32_data);
                }
            },
            err_cb,
            None
        ),
        _ => return Err("不支援的麥克風採樣格式".to_string()),
    }.map_err(|e| format!("無法建立錄音串流: {}", e))?;

    stream.play().map_err(|e| format!("無法啟動錄音串流: {}", e))?;
    
    // 將串流存入全域，防止被 drop 釋放
    let mut active_stream = ACTIVE_STREAM.lock().map_err(|e| e.to_string())?;
    *active_stream = Some(StreamWrapper(stream));

    println!("Rust: Started recording audio at {}Hz ({} channels)", sample_rate, channels);
    Ok(())
}

pub fn stop_audio_capture() -> Result<String, String> {
    // 1. 停止並釋放錄音串流
    {
        let mut active_stream = ACTIVE_STREAM.lock().map_err(|e| e.to_string())?;
        if active_stream.is_none() {
            return Err("目前沒有進行中的錄音串流".to_string());
        }
        *active_stream = None; // 丟棄 stream 會自動關閉錄音
    }

    // 2. 獲取錄音參數與採樣資料
    let (channels, sample_rate) = {
        let cached_config = RECORD_CONFIG.lock().map_err(|e| e.to_string())?;
        cached_config.ok_or_else(|| "找不到錄音規格記錄".to_string())?
    };
    
    let raw_samples = {
        let samples = RECORDED_SAMPLES.lock().map_err(|e| e.to_string())?;
        samples.clone()
    };

    if raw_samples.is_empty() {
        return Err("未錄製到任何音訊數據".to_string());
    }

    // 3. 重塑音訊：將多聲道與任意採樣率，重塑為 16kHz 單聲道
    let processed_samples = resample_and_mono(&raw_samples, channels, sample_rate);

    // 4. 寫入本地 Temp WAV 檔案
    let mut path = dirs_next::home_dir().ok_or("無法獲取 Home 目錄")?;
    path.push(".typeless");
    let _ = std::fs::create_dir_all(&path);
    path.push("temp_recording.wav");

    write_wav_file(&path, &processed_samples).map_err(|e| e.to_string())?;

    Ok(path.to_str().ok_or("音訊路徑轉換失敗")?.to_string())
}

/// 將任意聲道與採樣率的 f32 音訊，降採樣並轉換為 16kHz 單聲道 i16 PCM
fn resample_and_mono(input: &[f32], from_channels: u16, from_sample_rate: u32) -> Vec<i16> {
    // A. 轉為單聲道 (平均所有聲道)
    let mut mono = Vec::new();
    let chunk_size = from_channels as usize;
    for chunk in input.chunks_exact(chunk_size) {
        let sum: f32 = chunk.iter().sum();
        mono.push(sum / (from_channels as f32));
    }
    
    // B. 線性插值重塑採樣率至 16000Hz
    let target_sample_rate = 16000.0;
    let ratio = (from_sample_rate as f32) / target_sample_rate;
    let target_length = ((mono.len() as f32) / ratio).floor() as usize;
    
    let mut output = Vec::with_capacity(target_length);
    for i in 0..target_length {
        let src_index = (i as f32) * ratio;
        let index_floor = src_index.floor() as usize;
        let index_ceil = (index_floor + 1).min(mono.len() - 1);
        let weight = src_index - (index_floor as f32);
        
        let sample = (1.0 - weight) * mono[index_floor] + weight * mono[index_ceil];
        
        // 將 f32 [-1.0, 1.0] 轉換為 i16
        let sample_i16 = (sample.clamp(-1.0, 1.0) * 32767.0) as i16;
        output.push(sample_i16);
    }
    output
}

fn write_wav_file(path: &PathBuf, samples: &[i16]) -> Result<(), hound::Error> {
    let file = File::create(path).map_err(hound::Error::IoError)?;
    let spec = hound::WavSpec {
        channels: 1,
        sample_rate: 16000,
        bits_per_sample: 16,
        sample_format: hound::SampleFormat::Int,
    };
    let mut writer = hound::WavWriter::new(file, spec)?;
    for &sample in samples {
        writer.write_sample(sample)?;
    }
    writer.finalize()?;
    Ok(())
}
