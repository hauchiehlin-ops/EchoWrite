use llama_cpp_2::llama_backend::LlamaBackend;
use llama_cpp_2::model::LlamaModel;
use llama_cpp_2::context::params::LlamaContextParams;
use llama_cpp_2::model::params::LlamaModelParams;
use std::path::Path;

/// 讀取 raw_text，使用指定的本地端 GGUF 模型進行 AI 潤飾與重組
pub fn polish_text(raw_text: String, style: String, model_path: &str) -> Result<String, String> {
    // 1. 初始化 Llama.cpp 後端 (LlamaBackend)
    let backend = LlamaBackend::init()
        .map_err(|e| format!("無法初始化 Llama 後端: {:?}", e))?;

    // 2. 設定載入參數並加載量化 GGUF 模型
    let model_params = LlamaModelParams::default();
    let model = LlamaModel::load_from_file(&backend, Path::new(model_path), &model_params)
        .map_err(|e| format!("無法載入 GGUF 模型 (路徑: {}): {:?}", model_path, e))?;

    // 3. 建立上下文 context
    let ctx_params = LlamaContextParams::default()
        .with_n_ctx(Some(std::num::NonZeroU32::new(2048).unwrap()));
    let mut ctx = model.new_context(&backend, ctx_params)
        .map_err(|e| format!("無法建立模型上下文: {:?}", e))?;

    // 4. 定義適合台灣習慣的 System Prompt
    let system_prompt = match style.as_str() {
        "professional" | "work" => {
            "你是一個專業的台灣秘書助理。請將以下口語重組，刪除所有的贅字（例如：嗯、啊、就是、然後、那個），校正錯字，並整理成結構清晰、用詞專業的公務繁體中文書面語。請維持原有語意，直接輸出潤飾後的文本，不要包含任何開場白或客套回覆。"
        }
        "casual" | "chat" => {
            "你是一個親切的台灣個人助手。請將以下口語轉換成語氣自然、通順流暢的繁體中文，消除口吃與重複，但保留口語隨和的感覺。請直接輸出轉換後的文本，不要有任何客套語。"
        }
        "outline" | "notes" => {
            "請將以下語音內容整理成條理分明的 Markdown 清單大綱（包含重點與待辦事項）。請使用台灣習慣詞彙與繁體中文，直接輸出 Markdown 內容，不要包含額外的說明。"
        }
        _ => {
            "請優化以下繁體中文文本，修復錯字與語句不通順處。請直接輸出結果。"
        }
    };

    // 5. 格式化 Prompt (採用 Qwen 格式)
    let prompt = format!(
        "<|im_start|>system\n{}<|im_end|>\n<|im_start|>user\n{}<|im_end|>\n<|im_start|>assistant\n",
        system_prompt, raw_text
    );

    // 6. Tokenize 將文字轉為 Token ID
    let tokens = model.str_to_token(&prompt, llama_cpp_2::model::AddBos::Always)
        .map_err(|e| format!("Tokenize 失敗: {:?}", e))?;

    // 7. 載入 Prompt tokens 到 batch 並解碼
    let mut batch = llama_cpp_2::llama_batch::LlamaBatch::new(2048, 1);
    for (i, token) in tokens.iter().enumerate() {
        let is_last = i == tokens.len() - 1;
        let _ = batch.add(*token, i as i32, &[0], is_last);
    }

    ctx.decode(&mut batch)
        .map_err(|e| format!("模型解碼失敗: {:?}", e))?;

    // 8. 文字生成與採樣迴圈 (真實解碼)
    let mut decoder = encoding_rs::UTF_8.new_decoder();
    let mut generated_text = String::new();
    let mut sampler = llama_cpp_2::sampling::LlamaSampler::greedy();
    
    // 採樣第一個輸出的 token
    let mut next_token = sampler.sample(&ctx, (tokens.len() - 1) as i32);
    let eos_token = model.token_eos();
    
    let max_tokens = 512;
    let mut token_count = 0;
    
    while next_token != eos_token && token_count < max_tokens {
        // 將 token 轉換為文字片段
        if let Ok(piece) = model.token_to_piece(next_token, &mut decoder, false, None) {
            generated_text.push_str(&piece);
        }
        
        // 準備下一個 token 的解碼批次
        batch.clear();
        let _ = batch.add(next_token, (tokens.len() + token_count) as i32, &[0], true);
        
        // 推理該單一 token
        ctx.decode(&mut batch)
            .map_err(|e| format!("推理生成失敗: {:?}", e))?;
        
        // 採樣下一個 token
        next_token = sampler.sample(&ctx, 0);
        token_count += 1;
    }

    Ok(generated_text)
}
