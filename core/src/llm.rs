use llama_cpp_2::llama_backend::LlamaBackend;
use llama_cpp_2::model::LlamaModel;
use llama_cpp_2::context::params::LlamaContextParams;
use llama_cpp_2::model::params::LlamaModelParams;
use std::path::Path;

pub fn get_system_prompt_for_style(style: &str) -> &'static str {
    match style.trim().to_lowercase().as_str() {
        "formal" | "official" => {
            "你是一個專業的公務與行政報告秘書。你的唯一任務是將口語逐字稿重塑為用詞嚴謹、客觀專業、符合台灣公務公文標準的書面中文。\n\
             ## 核心規則\n\
             1. 同音字與語音錯字修正（最高優先），依上下文校正。\n\
             2. 公務風格轉化：將口語轉換為正式、嚴謹的公務用語，使用客觀第三人稱或公務敬語，消除口語俚語。\n\
             3. 自動斷行與編號排版：\n\
                - 若口述包含多個步驟、事項或決議（如「第一...第二...」、「首先...最後...」），必須自動換行並以正式編號（一、二、或 1. 2.）清晰條列。\n\
                - 不同主題或段落之間自動換行分段，使用全形標點（，。！？「」），條理分明。\n\
             4. 移除所有冗詞贅句（呃、嗯、那個、然後）。\n\
             5. 遵守台灣在地化繁體中文規範與術語。\n\
             6. 語音編輯指令模式：若使用者發出編輯指令（如『把上一句改成...』、『刪除最後一行』），請輸出指令或直接對前文執行改寫。\n\
             7. 直接輸出重組後的結果文本，絕不包含任何解釋、旁白或客套話。"
        }
        "email" | "business" => {
            "你是一個頂級商務通訊助理。你的唯一任務是將口述內容整理為格式完整、得體專業的繁體中文商務電子郵件（Email）。\n\
             ## 核心規則\n\
             1. 同音字與錯字自動修正。\n\
             2. 信件架構與自動斷行編號：\n\
                - 自動生成【主旨：】。\n\
                - 自動換行加入合適的收信人稱謂問候語。\n\
                - 正文若提及多項討論事項或待辦任務，自動換行並以數字編號（1. 2. 3.）條列呈現。\n\
                - 結尾自動換行加入祝詞與署名。\n\
             3. 語氣得體：保持專業、親切且具執行力的商務口吻。\n\
             4. 標點規範：使用台灣全形標點符號。\n\
             5. 直接輸出完整的 Email 文本，絕不包含任何其他說明或引言。"
        }
        "bilingual" | "translation" => {
            "你是一個精通中英雙語的專業口譯與文案助理。你的唯一任務是將口述中文整理後，同時輸出繁體中文潤飾段落與地道專業的英文翻譯。\n\
             ## 核心規則\n\
             1. 修正口語錯字與同音字。\n\
             2. 輸出格式與自動排版：\n\
                【中文】：重塑後的優雅繁體中文段落（全形標點、自動斷行分段、編號清晰條列）。\n\
                \n\
                【English】：自然、道地且文法精準的英文翻譯（對應編號與換行結構）。\n\
             3. 絕不輸出任何其他引言、說明或多餘問候。"
        }
        "bullet" | "summary" => {
            "你是一個高效率的要點提煉助理。你的唯一任務是將口述內容提煉為結構清晰的 Markdown 條列式重點清單。\n\
             ## 核心規則\n\
             1. 錯字與同音字修正。\n\
             2. 自動斷行與編號清單：\n\
                - 必須將每項核心論點、代辦步驟或會議決策分行獨立，使用 Markdown 數字編號（1. 2. 3.）或符號（- ）。\n\
                - 遇到「第一、第二」、「首先、其次、最後」或轉折詞，一律自動換行並建立新編號項目。\n\
             3. 語句精練：去除所有廢話與重複內容，每點簡明扼要、直指重點。\n\
             4. 採用台灣繁體中文與全形標點。\n\
             5. 直接輸出條列清單，不加任何前言或結尾閒聊。"
        }
        _ => {
            // 預設 casual / smart 極簡口語潤飾模式
            "你是一個極致精準的台灣繁體中文語音轉文字助理。你的唯一任務是將語音辨識產出的零碎口語逐字稿，重塑為正確、流暢、段落分明的書面中文。\n\
             \n\
             ## 核心規則\n\
             1. 同音字與語音錯字修正（最高優先）：\n\
                - 語音辨識經常混淆同音字，請依上下文自動修正。\n\
                - 範例：的/得/地、在/再、做/作、那/哪、他/她/它、已/以、會/回、是/式/視/試、因為/因位、所以/所已、可以/可已、這個/者個、那個/拿個、什麼/甚麼、怎麼/真麼。\n\
                - 專有名詞修正：iPhone/愛瘋、YouTube/優兔、Google/估狗、LINE/賴。\n\
             2. 自動斷行與自動編號排版（重要）：\n\
                - 當說話者口述提及多個事項、步驟、論點或清單時（例如「第一...第二...」、「首先...再來...最後...」、「有三件事...」），必須自動換行並標上清晰編號（如 1. 2. 3. 或 第一、第二、）。\n\
                - 超過 60 至 80 個中文字，或主題轉換、因果結論轉換時，必須主動插入換行分段，絕不輸出一大塊未分段長文字。\n\
             3. 標點符號與規範：\n\
                - 不可輸出沒有標點的長句。每 1 到 2 個語意單位必須加入逗號（，）、句號（。）、問號（？）或驚嘆號（！）。\n\
                - 說話引用使用「」與『』，列舉使用頓號（、）。\n\
             4. 贅詞橋接與意圖自動判斷：自動移除思考停頓（呃、嗯、那個、然後然後）。將改口修正為最終意圖（如『明天...不對後天』→『後天』）。\n\
             5. 語音編輯指令模式：若使用者在說話中下達編輯指令（如『把上一句改成...』、『改成英文』），請直接對前文執行改寫。\n\
             6. 在地化規範：中英文/數字夾雜時自動加空格。轉換大陸用語（如：屏幕->螢幕、內存->記憶體、軟件->軟體、網絡->網路）。\n\
             7. 輸出限制：直接輸出重組後的結果文本，絕對不可包含任何你自己的說明、旁白、引言或客套語。"
        }
    }
}

/// 讀取 raw_text，結合游標前文脈絡 (context_before) 與個人風格範例 (tone_samples) 進行 AI 潤飾與重組
pub fn polish_text_with_context(
    raw_text: String,
    style: String,
    model_path: &str,
    context_before: Option<String>,
    tone_samples: &[String],
) -> Result<String, String> {
    let backend = LlamaBackend::init()
        .map_err(|e| format!("無法初始化 Llama 後端: {:?}", e))?;

    #[cfg(any(target_os = "macos", target_os = "ios"))]
    let model_params = LlamaModelParams::default().with_n_gpu_layers(u32::MAX);
    #[cfg(not(any(target_os = "macos", target_os = "ios")))]
    let model_params = LlamaModelParams::default();

    let model = LlamaModel::load_from_file(&backend, Path::new(model_path), &model_params)
        .map_err(|e| format!("無法載入 GGUF 模型 (路徑: {}): {:?}", model_path, e))?;

    let ctx_params = LlamaContextParams::default()
        .with_n_ctx(Some(std::num::NonZeroU32::new(2048).unwrap()));
    let mut ctx = model.new_context(&backend, ctx_params)
        .map_err(|e| format!("無法建立模型上下文: {:?}", e))?;

    let system_prompt = get_system_prompt_for_style(&style);

    // 構建帶有 Context 與 Few-Shot 範例的 User 提示詞
    let mut user_content = String::new();
    if let Some(ctx_str) = context_before {
        let trimmed_ctx = ctx_str.trim();
        if !trimmed_ctx.is_empty() {
            let sample_len = trimmed_ctx.chars().count();
            let start_idx = sample_len.saturating_sub(150);
            let recent_ctx: String = trimmed_ctx.chars().skip(start_idx).collect();
            user_content.push_str(&format!("【前文脈絡/上下文】:\n{}\n\n", recent_ctx));
        }
    }

    if !tone_samples.is_empty() {
        user_content.push_str("【個人喜好風格範例】:\n");
        for s in tone_samples.iter().take(3) {
            user_content.push_str(&format!("- {}\n", s));
        }
        user_content.push('\n');
    }

    user_content.push_str(&format!("【當前口述內容】:\n{}", raw_text));

    let prompt = format!(
        "<|im_start|>system\n{}<|im_end|>\n<|im_start|>user\n{}<|im_end|>\n<|im_start|>assistant\n",
        system_prompt, user_content
    );

    let tokens = model.str_to_token(&prompt, llama_cpp_2::model::AddBos::Always)
        .map_err(|e| format!("Tokenize 失敗: {:?}", e))?;

    let mut batch = llama_cpp_2::llama_batch::LlamaBatch::new(2048, 1);
    for (i, token) in tokens.iter().enumerate() {
        let is_last = i == tokens.len() - 1;
        let _ = batch.add(*token, i as i32, &[0], is_last);
    }

    ctx.decode(&mut batch)
        .map_err(|e| format!("模型解碼失敗: {:?}", e))?;

    let mut decoder = encoding_rs::UTF_8.new_decoder();
    let mut generated_text = String::new();
    let mut sampler = llama_cpp_2::sampling::LlamaSampler::greedy();
    
    let mut next_token = sampler.sample(&ctx, (tokens.len() - 1) as i32);
    let eos_token = model.token_eos();
    
    let max_tokens = 512;
    let mut token_count = 0;
    
    while next_token != eos_token && token_count < max_tokens {
        if let Ok(piece) = model.token_to_piece(next_token, &mut decoder, false, None) {
            generated_text.push_str(&piece);
        }
        
        batch.clear();
        let _ = batch.add(next_token, (tokens.len() + token_count) as i32, &[0], true);
        
        ctx.decode(&mut batch)
            .map_err(|e| format!("推理生成失敗: {:?}", e))?;
        
        next_token = sampler.sample(&ctx, 0);
        token_count += 1;
    }

    Ok(clean_model_output(generated_text))
}

pub fn polish_text(raw_text: String, style: String, model_path: &str) -> Result<String, String> {
    polish_text_with_context(raw_text, style, model_path, None, &[])
}

fn clean_model_output(text: String) -> String {
    text.replace("<|im_end|>", "")
        .replace("<|im_start|>", "")
        .replace("assistant", "")
        .trim()
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_style_prompts_differentiation() {
        let formal = get_system_prompt_for_style("formal");
        assert!(formal.contains("公務與行政報告秘書"));
        assert!(formal.contains("自動斷行與編號排版"));

        let email = get_system_prompt_for_style("email");
        assert!(email.contains("商務電子郵件"));
        assert!(email.contains("信件架構與自動斷行編號"));

        let bilingual = get_system_prompt_for_style("bilingual");
        assert!(bilingual.contains("【English】"));

        let bullet = get_system_prompt_for_style("bullet");
        assert!(bullet.contains("Markdown 條列式"));
        assert!(bullet.contains("自動斷行與編號清單"));

        let casual = get_system_prompt_for_style("casual");
        assert!(casual.contains("台灣繁體中文語音轉文字助理"));
        assert!(casual.contains("自動斷行與自動編號排版"));
    }
}
