use whisper_rs::{WhisperContext, FullParams, SamplingStrategy};
use std::path::Path;

/// 讀取 WAV 音訊檔並使用本地 Whisper 模型進行語音轉寫。
/// `custom_vocabulary` 會拼接為 Whisper 的 initial prompt，引導 ASR 將發音相近的
/// 詞彙精確辨識為使用者自訂的專有名詞（人名、產品名等），降低 WER。
pub fn transcribe(audio_path: String, model_path: &str, custom_vocabulary: &[String]) -> Result<String, String> {
    // 1. 讀取音訊檔並轉化為 f32 PCM 數據
    let mut reader = hound::WavReader::open(Path::new(&audio_path))
        .map_err(|e| format!("無法開啟音訊檔: {}", e))?;
    
    let spec = reader.spec();
    // 驗證格式是否為 16kHz, 單聲道, 16bit PCM
    if spec.channels != 1 || spec.sample_rate != 16000 || spec.bits_per_sample != 16 {
        return Err("音訊格式必須為 16kHz, 單聲道, 16-bit PCM WAV".to_string());
    }
    
    let samples: Vec<f32> = reader
        .samples::<i16>()
        .map(|s| {
            let sample = s.unwrap_or(0);
            sample as f32 / 32768.0 // 正規化到 [-1.0, 1.0]
        })
        .collect();

    // 2. 載入本地 Whisper 模型
    let ctx = WhisperContext::new_with_params(model_path, whisper_rs::WhisperContextParameters::default())
        .map_err(|e| format!("無法載入 Whisper 模型: {:?}", e))?;
    
    let mut state = ctx.create_state()
        .map_err(|e| format!("無法建立推理狀態: {:?}", e))?;

    // 3. 設定 ASR 參數
    let mut params = FullParams::new(SamplingStrategy::Greedy { best_of: 1 });
    params.set_language(Some("zh")); // 設定為中文辨識
    params.set_print_special(false);
    params.set_print_progress(false);
    params.set_print_realtime(false);
    params.set_print_timestamps(false);

    if !custom_vocabulary.is_empty() {
        params.set_initial_prompt(&custom_vocabulary.join("、"));
    }

    // 4. 執行 ASR 推理
    state.full(params, &samples[..])
        .map_err(|e| format!("ASR 推理失敗: {:?}", e))?;

    // 5. 擷取並拼接識別的文本段落
    let num_segments = state.full_n_segments();
        
    let mut result = String::new();
    for i in 0..num_segments {
        let segment = state.get_segment(i)
            .ok_or_else(|| "無法取得段落".to_string())?;
        let segment_text = segment.to_str()
            .map_err(|e| format!("UTF-8 轉換失敗: {:?}", e))?;
        result.push_str(segment_text);
    }

    Ok(result)
}
