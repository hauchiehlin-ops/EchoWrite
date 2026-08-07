use lazy_static::lazy_static;
use regex::Regex;
use std::collections::HashMap;

lazy_static! {
    // 台灣常用術語對照表
    static ref TERMINOLOGY_MAP: HashMap<&'static str, &'static str> = {
        let mut m = HashMap::new();
        m.insert("屏幕", "螢幕");
        m.insert("內存", "記憶體");
        m.insert("軟件", "軟體");
        m.insert("硬件", "硬體");
        m.insert("文件", "檔案");
        m.insert("硬盤", "硬碟");
        m.insert("光盤", "光碟");
        m.insert("數據庫", "資料庫");
        m.insert("算法", "演算法");
        m.insert("程序", "程式");
        m.insert("服務器", "伺服器");
        m.insert("用戶", "使用者");
        m.insert("菜單", "選單");
        m.insert("支持", "支援");
        m.insert("激活", "啟用");
        m.insert("信箱", "電子信箱");
        m.insert("網絡", "網路");
        m.insert("項目", "專案");
        m.insert("信息", "訊息");
        m.insert("視頻", "影片");
        m.insert("音頻", "音訊");
        m.insert("高興", "開心");
        m
    };

    // 台灣日常台語音譯與俚語校正表
    static ref DIALECT_MAP: HashMap<&'static str, &'static str> = {
        let mut m = HashMap::new();
        m.insert("動胃條", "凍未條");
        m.insert("棟未條", "凍未條");
        m.insert("棟胃條", "凍未條");
        m.insert("帶智大條", "代誌大條");
        m.insert("帶志大條", "代誌大條");
        m.insert("拍謝", "歹勢");
        m.insert("拍寫", "歹勢");
        m.insert("派謝", "歹勢");
        m.insert("動蒜", "凍蒜");
        m.insert("棟蒜", "凍蒜");
        m.insert("假白", "假掰");
        m.insert("嘎掰", "假掰");
        m.insert("好家在", "好佳在");
        m.insert("黑白講", "烏白講");
        m
    };

    // 科技與商務常用中英混說縮寫標準大小寫映射
    static ref CODE_SWITCHING_CASING: Vec<(&'static str, &'static str, Regex)> = {
        let raw_list = vec![
            ("pr", "PR"),
            ("api", "API"),
            ("ui", "UI"),
            ("ux", "UX"),
            ("pm", "PM"),
            ("qa", "QA"),
            ("ci/cd", "CI/CD"),
            ("cicd", "CI/CD"),
            ("kpi", "KPI"),
            ("okr", "OKR"),
            ("llm", "LLM"),
            ("asr", "ASR"),
            ("gpu", "GPU"),
            ("npu", "NPU"),
            ("cpu", "CPU"),
            ("app", "App"),
        ];

        raw_list.into_iter().map(|(raw, std)| {
            let pattern = if raw.contains('/') {
                format!(r"(?i){}", regex::escape(raw))
            } else {
                format!(r"(?i)\b{}\b", regex::escape(raw))
            };
            let re = Regex::new(&pattern).unwrap();
            (raw, std, re)
        }).collect()
    };

    // 用於中英文間隔的正規表示式
    static ref RE_ZH_EN: Regex = Regex::new(r"([\u4e00-\u9fa5]+)([a-zA-Z0-9]+)").unwrap();
    static ref RE_EN_ZH: Regex = Regex::new(r"([a-zA-Z0-9]+)([\u4e00-\u9fa5]+)").unwrap();

    // 換行符號周圍的多餘空白與重複換行清理
    static ref RE_CONSECUTIVE_NEWLINES: Regex = Regex::new(r"\n{3,}").unwrap();
    static ref RE_LINE_SPACES: Regex = Regex::new(r"[ \t]+\n").unwrap();
    static ref RE_SPACES_AFTER_LINE: Regex = Regex::new(r"\n[ \t]+").unwrap();
}

/// 格式化語句：包含兩岸詞彙轉換、台語校正、科技縮寫標準化、全形標點、中英空格、自動編號換行與分段排版
pub fn format_text(mut text: String) -> String {
    if text.trim().is_empty() {
        return String::new();
    }

    // 1. 進行兩岸詞彙轉換
    for (mainland, taiwan) in TERMINOLOGY_MAP.iter() {
        text = text.replace(mainland, taiwan);
    }

    // 2. 進行台語日常音譯校正
    for (misheard, correct) in DIALECT_MAP.iter() {
        text = text.replace(misheard, correct);
    }

    // 3. 科技商務縮寫大小寫標準化（在全形標點轉換前先進行正規匹配）
    for (_raw, standardized, re) in CODE_SWITCHING_CASING.iter() {
        text = re.replace_all(&text, *standardized).into_owned();
    }

    // 4. 將英文半形標點符號轉換為繁體中文全形標點符號
    text = text.replace(",", "，")
               .replace(".", "。")
               .replace("?", "？")
               .replace("!", "！")
               .replace(":", "：")
               .replace(";", "；")
               .replace("\"", "”")
               .replace("'", "’");

    // 5. 處理中英文/數字夾雜時的半形空格
    let text = RE_ZH_EN.replace_all(&text, "$1 $2").into_owned();
    let text = RE_EN_ZH.replace_all(&text, "$1 $2").into_owned();

    // 6. 自動編號與條列斷行排版
    let text = auto_format_list_and_paragraphs(text);

    // 7. 去除多餘空行與首尾空白
    let text = RE_CONSECUTIVE_NEWLINES.replace_all(&text, "\n\n").into_owned();
    let text = RE_LINE_SPACES.replace_all(&text, "\n").into_owned();
    let text = RE_SPACES_AFTER_LINE.replace_all(&text, "\n").into_owned();

    text.trim().to_string()
}

/// 自動偵測口述中的編號（第一、第二、1.、2.、第一個、第二個、首先、最後等）並自動換行條列與分段
fn auto_format_list_and_paragraphs(text: String) -> String {
    let mut result = String::new();
    let chars: Vec<char> = text.chars().collect();
    let len = chars.len();
    let mut i = 0;

    let triggers = [
        "第一個", "第二個", "第三個", "第四個", "第五個", "第六個", "第七個", "第八個", "第九個", "第十個",
        "第一點", "第二點", "第三點", "第四點", "第五點", "第六點", "第七點", "第八點", "第九點", "第十點",
        "第一項", "第二項", "第三項", "第四項", "第五項", "第六項", "第七項", "第八項", "第九項", "第十項",
        "第一步", "第二步", "第三步", "第四步", "第五步",
        "第一件事", "第二件事", "第三件事",
        "第一、", "第二、", "第三、", "第四、", "第五、", "第六、", "第七、", "第八、", "第九、", "第十、",
        "第一，", "第二，", "第三，", "第四，", "第五，", "第六，", "第七，", "第八，", "第九，", "第十，",
        "首先，", "其次，", "再來，", "接著，", "最後，",
        "首先、", "其次、", "再來、", "接著、", "最後、",
        "其一，", "其二，", "其三，", "其四，",
        "其一、", "其二、", "其三、", "其四、",
        "一方面，", "另一方面，",
        "一、", "二、", "三、", "四、", "五、", "六、", "七、", "八、", "九、", "十、",
        "1. ", "2. ", "3. ", "4. ", "5. ", "6. ", "7. ", "8. ", "9. ", "10. ",
        "1.", "2.", "3.", "4.", "5.", "6.", "7.", "8.", "9.", "10.",
        "1、", "2、", "3、", "4、", "5、", "6、", "7、", "8、", "9、", "10、",
        "（一）", "（二）", "（三）", "（四）", "（五）",
        "(一)", "(二)", "(三)", "(四)", "(五)",
        "（1）", "（2）", "（3）", "（4）", "（5）",
        "(1)", "(2)", "(3)", "(4)", "(5)",
        "A. ", "B. ", "C. ", "D. ", "E. ",
    ];

    while i < len {
        let remaining: String = chars[i..].iter().collect();
        let mut matched_trigger = false;

        for trigger in &triggers {
            if remaining.starts_with(trigger) {
                if !result.is_empty() && !result.ends_with('\n') {
                    while result.ends_with('，') || result.ends_with('、') || result.ends_with(' ') || result.ends_with('：') {
                        result.pop();
                    }
                    if !result.ends_with('。') && !result.ends_with('！') && !result.ends_with('？') && !result.ends_with('\n') {
                        result.push('。');
                    }
                    result.push('\n');
                }
                result.push_str(trigger);
                i += trigger.chars().count();
                matched_trigger = true;
                break;
            }
        }

        if !matched_trigger {
            result.push(chars[i]);
            i += 1;
        }
    }

    // 若結尾沒有標點且非空，補上句號
    let mut final_text = result.trim().to_string();
    if !final_text.is_empty() && !final_text.ends_with('。') && !final_text.ends_with('！') && !final_text.ends_with('？') && !final_text.ends_with('”') && !final_text.ends_with('’') {
        final_text.push('。');
    }

    final_text
}

/// 快速處理獨立語音編輯與標點指令（免經 LLM 即時極速生效）
pub fn handle_voice_editing_command(raw_text: &str) -> Option<String> {
    let trimmed = raw_text.trim().trim_matches(|c: char| c.is_ascii_punctuation() || c == '。' || c == '，');
    match trimmed {
        "換行" | "下一行" | "換下一行" | "另起一行" => Some("\n".to_string()),
        "空行" | "空一行" | "空兩行" => Some("\n\n".to_string()),
        "逗號" | "加個逗號" => Some("，".to_string()),
        "句號" | "加個句號" | "句點" => Some("。".to_string()),
        "問號" | "加個問號" => Some("？".to_string()),
        "驚嘆號" | "感嘆號" | "加個驚嘆號" => Some("！".to_string()),
        "冒號" => Some("：".to_string()),
        "分號" => Some("；".to_string()),
        "頓號" => Some("、".to_string()),
        "刪除" | "刪掉" | "清除" => Some("".to_string()),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_formatting() {
        let input = "我的屏幕壞了,所以我買了個新的硬件。這是我最近開發的軟件project。".to_string();
        let expected = "我的螢幕壞了，所以我買了個新的硬體。這是我最近開發的軟體 project。".to_string();
        assert_eq!(format_text(input), expected);
    }

    #[test]
    fn test_dialect_corrections() {
        let input = "這件事情真的動胃條，代誌大條了，真拍謝。".to_string();
        let output = format_text(input);
        assert!(output.contains("凍未條"));
        assert!(output.contains("代誌大條"));
        assert!(output.contains("歹勢"));
    }

    #[test]
    fn test_code_switching_capitalization() {
        let input = "請幫我 review 這個 pr，然後確認 api 和 ui 設計。".to_string();
        let output = format_text(input);
        assert!(output.contains("PR"));
        assert!(output.contains("API"));
        assert!(output.contains("UI"));
    }

    #[test]
    fn test_auto_line_breaks_and_numbering() {
        let input = "今天會議有三個重點第一、確認上線時間第二、分配後端任務第三、完成文檔測試".to_string();
        let output = format_text(input);
        assert!(output.contains("今天會議有三個重點。\n第一、確認上線時間"));
        assert!(output.contains("\n第二、分配後端任務"));
        assert!(output.contains("\n第三、完成文檔測試"));
    }

    #[test]
    fn test_user_speech_item_segmentation() {
        let input = "我現在要開始進行測試，如果說可以的話請幫我做好分段準備第一個我要去超商買咖啡，第二個我要進辦公室上班，第三個準備參加晨會".to_string();
        let output = format_text(input);
        assert!(output.contains("我現在要開始進行測試，如果說可以的話請幫我做好分段準備。\n第一個我要去超商買咖啡。"));
        assert!(output.contains("\n第二個我要進辦公室上班。"));
        assert!(output.contains("\n第三個準備參加晨會。"));
    }

    #[test]
    fn test_voice_editing_commands() {
        assert_eq!(handle_voice_editing_command("換行"), Some("\n".to_string()));
        assert_eq!(handle_voice_editing_command("下一行。"), Some("\n".to_string()));
        assert_eq!(handle_voice_editing_command("加個問號"), Some("？".to_string()));
        assert_eq!(handle_voice_editing_command("空兩行"), Some("\n\n".to_string()));
        assert_eq!(handle_voice_editing_command("今天天氣很好"), None);
    }
}
