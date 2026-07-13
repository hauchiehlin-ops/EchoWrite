use rusqlite::{Connection, Result};
use std::fs;
use std::path::PathBuf;

fn get_db_path() -> PathBuf {
    // 取得使用者主目錄下的 .typeless 目錄
    let mut path = dirs_next::home_dir().unwrap_or_else(|| PathBuf::from("."));
    path.push(".typeless");
    let _ = fs::create_dir_all(&path);
    path.push("typeless.db");
    path
}

pub fn init_db() -> Result<()> {
    let db_path = get_db_path();
    let conn = Connection::open(db_path)?;

    // 建立歷史紀錄表
    conn.execute(
        "CREATE TABLE IF NOT EXISTS history (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
            text TEXT NOT NULL
        )",
        [],
    )?;

    // 建立自訂詞彙表
    conn.execute(
        "CREATE TABLE IF NOT EXISTS custom_vocabulary (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            phrase TEXT NOT NULL UNIQUE,
            added_at DATETIME DEFAULT CURRENT_TIMESTAMP
        )",
        [],
    )?;

    Ok(())
}

pub fn save_history(text: &str) -> Result<()> {
    let db_path = get_db_path();
    let conn = Connection::open(db_path)?;
    conn.execute(
        "INSERT INTO history (text) VALUES (?1)",
        [text],
    )?;
    Ok(())
}

pub fn add_custom_phrase(phrase: &str) -> Result<()> {
    let db_path = get_db_path();
    let conn = Connection::open(db_path)?;
    conn.execute(
        "INSERT OR IGNORE INTO custom_vocabulary (phrase) VALUES (?1)",
        [phrase],
    )?;
    Ok(())
}

pub fn get_custom_phrases() -> Result<Vec<String>> {
    let db_path = get_db_path();
    let conn = Connection::open(db_path)?;
    let mut stmt = conn.prepare("SELECT phrase FROM custom_vocabulary")?;
    let rows = stmt.query_map([], |row| row.get(0))?;
    
    let mut phrases = Vec::new();
    for phrase in rows {
        phrases.push(phrase?);
    }
    Ok(phrases)
}
