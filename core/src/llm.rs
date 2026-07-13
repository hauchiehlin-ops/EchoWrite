use llama_cpp_2::llama_backend::LlamaBackend;
use llama_cpp_2::model::LlamaModel;
use llama_cpp_2::context::params::LlamaContextParams;
use llama_cpp_2::model::params::LlamaModelParams;
use std::path::Path;

/// 讀取 raw_text，使用指定的本地端 GGUF 模型進行 AI 潤飾與重組，支援語音意圖自動偵測
pub fn polish_text(raw_text: String, _style: String, model_path: &str) -> Result<String, String> {
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

    // 4. 定義「語音意圖自動識別」的全能型 System Prompt
    // 讓模型自動辨識使用者的口語內容是否含有指令（例如：「幫我寫信」、「條列整理」），並直接套用對應的格式。
    let system_prompt = 
        "你是一個極致智慧的台灣語音助理。請將以下使用者的口語進行重組與潤飾，遵守以下規範：\n\
         1. 贅字與贅語過濾：徹底刪除口語中的「嗯、啊、然後、就是、那個」等冗詞，並校正口吃與錯字。\n\
         2. 意圖自動路由：\n\
            - 若語音中含有格式指令（如「幫我寫信給...」、「用清單/列表整理」、「大綱如下...」、「翻譯成英文...」），請自動將內容重組並輸出為該特定格式（如 Email 格式、Markdown 清單、英文）。\n\
            - 若無特定格式指令，請將其自動重組為通順、用詞專業、符合台灣繁體中文文書習慣的書面語段落。\n\
         3. 在地化規範：中英文/數字夾雜時自動加空格。使用台灣繁體標點（，。！？「」『』）。轉換大陸用語（如：文件->檔案、網絡->網路）。\n\
         4. 輸出限制：直接輸出重組後的結果文本，絕對不可包含任何你自己的說明、旁白、引言或客套回應。";

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
