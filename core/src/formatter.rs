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
}
