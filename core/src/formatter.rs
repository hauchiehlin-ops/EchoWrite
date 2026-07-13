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
        m.insert("文件", "檔案"); // 在電腦術語中，大陸的「文件」為台灣的「檔案」
        m.insert("硬盤", "硬碟");
        m.insert("光盤", "光碟");
        m.insert("數據庫", "資料庫");
        m.insert("算法", "演算法");
        m.insert("程序", "程式"); // 台灣稱「程式」，大陸稱「程序」
        m.insert("服務器", "伺服器");
        m.insert("用戶", "使用者");
        m.insert("菜單", "選單");
        m.insert("支持", "支援"); // 大陸「支持」某功能 -> 台灣「支援」
        m.insert("激活", "啟用"); // 啟用/開通
        m.insert("信箱", "電子信箱");
        m.insert("網絡", "網路");
        m.insert("項目", "專案"); // 專案 (Project)
        m.insert("信息", "訊息"); // 訊息 (Message/Information)
        m.insert("視頻", "影片"); // 影片 (Video)
        m.insert("音頻", "音訊"); // 音訊 (Audio)
        m.insert("高興", "開心");
        m
    };

    // 用於中英文間隔的正規表示式
    // 1. 中文字元後面緊跟英文字母或數字，插入空格
    static ref RE_ZH_EN: Regex = Regex::new(r"([\u4e00-\u9fa5]+)([a-zA-Z0-9]+)").unwrap();
    // 2. 英文字母或數字後面緊跟中文字元，插入空格
    static ref RE_EN_ZH: Regex = Regex::new(r"([a-zA-Z0-9]+)([\u4e00-\u9fa5]+)").unwrap();
}

/// 格式化語句，使其符合台灣繁體中文排版習慣
pub fn format_text(mut text: String) -> String {
    // 1. 進行兩岸詞彙轉換
    for (mainland, taiwan) in TERMINOLOGY_MAP.iter() {
        text = text.replace(mainland, taiwan);
    }

    // 2. 將英文半形標點符號轉換為繁體中文全形標點符號
    // 考慮到語音轉寫可能輸出半形標點
    text = text.replace(",", "，")
               .replace(".", "。")
               .replace("?", "？")
               .replace("!", "！")
               .replace(":", "：")
               .replace(";", "；")
               .replace("\"", "”")
               .replace("'", "’");

    // 3. 處理中英文/數字夾雜時的半形空格
    // 中文+英文 -> 中文 + 空格 + 英文
    let text = RE_ZH_EN.replace_all(&text, "$1 $2").into_owned();
    // 英文+中文 -> 英文 + 空格 + 中文
    let text = RE_EN_ZH.replace_all(&text, "$1 $2").into_owned();

    // 4. 去除首尾空白字元並返回
    text.trim().to_string()
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
    fn test_empty_input() {
        assert_eq!(format_text(String::new()), "");
    }

    #[test]
    fn test_trims_surrounding_whitespace() {
        assert_eq!(format_text("  你好  ".to_string()), "你好");
    }

    #[test]
    fn test_multiple_terminology_replacements() {
        let input = "服務器上的數據庫算法需要用戶激活菜單才能支持新功能".to_string();
        let output = format_text(input);
        assert!(output.contains("伺服器"));
        assert!(output.contains("資料庫"));
        assert!(output.contains("演算法"));
        assert!(output.contains("使用者"));
        assert!(output.contains("啟用"));
        assert!(output.contains("選單"));
        assert!(output.contains("支援"));
        // 確認簡中詞彙已完全被取代，不殘留原詞
        assert!(!output.contains("服務器上"));
        assert!(!output.contains("數據庫"));
    }

    #[test]
    fn test_halfwidth_punctuation_converted_to_fullwidth() {
        let input = "你好,世界.真的嗎?太好了!等等:對;\"是的\"'沒錯'".to_string();
        let output = format_text(input);
        assert!(output.contains('，'));
        assert!(output.contains('。'));
        assert!(output.contains('？'));
        assert!(output.contains('！'));
        assert!(output.contains('：'));
        assert!(output.contains('；'));
        // 半形標點應該已經完全消失
        assert!(!output.contains(','));
        assert!(!output.contains('.'));
        assert!(!output.contains('?'));
        assert!(!output.contains('!'));
    }

    #[test]
    fn test_spacing_between_chinese_and_english() {
        assert_eq!(format_text("我愛swift語言".to_string()), "我愛 swift 語言");
        assert_eq!(format_text("iPhone很好用".to_string()), "iPhone 很好用");
    }

    #[test]
    fn test_pure_english_text_untouched_by_terminology_map() {
        let input = "Hello World 123".to_string();
        assert_eq!(format_text(input), "Hello World 123");
    }

    #[test]
    fn test_idempotent_on_already_formatted_text() {
        let once = format_text("我的螢幕壞了，所以買了新的軟體。".to_string());
        let twice = format_text(once.clone());
        assert_eq!(once, twice);
    }
}
