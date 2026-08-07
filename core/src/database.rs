use rusqlite::{Connection, Result};
use std::fs;
use std::path::PathBuf;
use std::sync::Mutex;
use lazy_static::lazy_static;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct HistoryRecord {
    pub id: i64,
    pub timestamp: String,
    pub text: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SyncDataPayload {
    pub version: u32,
    pub vocabulary: Vec<String>,
    pub tone_samples: Vec<String>,
}

lazy_static! {
    static ref OVERRIDE_DB_PATH: Mutex<Option<PathBuf>> = Mutex::new(None);
}

pub fn set_override_db_path(path: Option<PathBuf>) {
    if let Ok(mut lock) = OVERRIDE_DB_PATH.lock() {
        *lock = path;
    }
}

pub fn get_db_path() -> PathBuf {
    if let Ok(lock) = OVERRIDE_DB_PATH.lock() {
        if let Some(ref path) = *lock {
            if let Some(parent) = path.parent() {
                let _ = fs::create_dir_all(parent);
            }
            return path.clone();
        }
    }

    if let Ok(dir) = std::env::var("ECHOWRITE_MODEL_DIR") {
        let trimmed = dir.trim();
        if !trimmed.is_empty() {
            let path = PathBuf::from(trimmed);
            let _ = fs::create_dir_all(&path);
            return path.join("echowrite.db");
        }
    }

    let mdir = crate::models::model_dir();
    if mdir.is_dir() {
        if let Some(parent) = mdir.parent() {
            return parent.join("echowrite.db");
        }
        return mdir.join("echowrite.db");
    }

    // 取得使用者主目錄下的 .echowrite 目錄，若無權限建立則退回 temp_dir 或當前目錄
    let base_dir = dirs_next::home_dir().unwrap_or_else(|| PathBuf::from("."));
    let path = base_dir.join(".echowrite");
    if fs::create_dir_all(&path).is_err() {
        let temp_path = std::env::temp_dir().join(".echowrite");
        let _ = fs::create_dir_all(&temp_path);
        return temp_path.join("echowrite.db");
    }
    path.join("echowrite.db")
}

pub fn get_connection() -> Result<Connection> {
    let db_path = get_db_path();
    if let Some(parent) = db_path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    let conn = Connection::open(db_path)?;

    // 自動確保資料表結構存在
    conn.execute(
        "CREATE TABLE IF NOT EXISTS history (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
            text TEXT NOT NULL
        )",
        [],
    )?;

    conn.execute(
        "CREATE TABLE IF NOT EXISTS custom_vocabulary (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            phrase TEXT NOT NULL UNIQUE,
            added_at DATETIME DEFAULT CURRENT_TIMESTAMP
        )",
        [],
    )?;

    conn.execute(
        "CREATE TABLE IF NOT EXISTS personal_tone_samples (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            sample_text TEXT NOT NULL,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        )",
        [],
    )?;

    Ok(conn)
}

pub fn init_db() -> Result<()> {
    let _ = get_connection()?;
    Ok(())
}

pub fn save_history(text: &str) -> Result<()> {
    let conn = get_connection()?;
    conn.execute(
        "INSERT INTO history (text) VALUES (?1)",
        [text],
    )?;
    Ok(())
}

pub fn get_history(limit: u32) -> Result<Vec<HistoryRecord>> {
    let conn = get_connection()?;
    let mut stmt = conn.prepare("SELECT id, timestamp, text FROM history ORDER BY id DESC LIMIT ?1")?;
    let rows = stmt.query_map([limit], |row| {
        Ok(HistoryRecord {
            id: row.get(0)?,
            timestamp: row.get(1)?,
            text: row.get(2)?,
        })
    })?;

    let mut records = Vec::new();
    for r in rows {
        records.push(r?);
    }
    Ok(records)
}

pub fn delete_history_item(id: i64) -> Result<()> {
    let conn = get_connection()?;
    conn.execute("DELETE FROM history WHERE id = ?1", [id])?;
    Ok(())
}

pub fn clear_history() -> Result<()> {
    let conn = get_connection()?;
    conn.execute("DELETE FROM history", [])?;
    Ok(())
}

pub fn add_custom_phrase(phrase: &str) -> Result<()> {
    let conn = get_connection()?;
    conn.execute(
        "INSERT OR IGNORE INTO custom_vocabulary (phrase) VALUES (?1)",
        [phrase],
    )?;
    Ok(())
}

pub fn delete_custom_phrase(phrase: &str) -> Result<()> {
    let conn = get_connection()?;
    conn.execute(
        "DELETE FROM custom_vocabulary WHERE phrase = ?1",
        [phrase],
    )?;
    Ok(())
}

pub fn get_custom_phrases() -> Result<Vec<String>> {
    let conn = get_connection()?;
    let mut stmt = conn.prepare("SELECT phrase FROM custom_vocabulary ORDER BY phrase ASC")?;
    let rows = stmt.query_map([], |row| row.get(0))?;
    
    let mut phrases = Vec::new();
    for phrase in rows {
        phrases.push(phrase?);
    }
    Ok(phrases)
}

// MARK: - 個人口吻風格範例 (Personal Tone Samples)
pub fn add_personal_tone_sample(sample_text: &str) -> Result<()> {
    let conn = get_connection()?;
    conn.execute(
        "INSERT INTO personal_tone_samples (sample_text) VALUES (?1)",
        [sample_text],
    )?;
    Ok(())
}

pub fn get_personal_tone_samples() -> Result<Vec<String>> {
    let conn = get_connection()?;
    let mut stmt = conn.prepare("SELECT sample_text FROM personal_tone_samples ORDER BY id DESC LIMIT 5")?;
    let rows = stmt.query_map([], |row| row.get(0))?;
    
    let mut samples = Vec::new();
    for s in rows {
        samples.push(s?);
    }
    Ok(samples)
}

pub fn clear_personal_tone_samples() -> Result<()> {
    let conn = get_connection()?;
    conn.execute("DELETE FROM personal_tone_samples", [])?;
    Ok(())
}

// MARK: - 零雲端跨裝置詞庫同步 (Local P2P / Encrypted QR & JSON Sync)
pub fn export_sync_data() -> Result<String> {
    let vocab = get_custom_phrases()?;
    let tones = get_personal_tone_samples()?;
    let payload = SyncDataPayload {
        version: 1,
        vocabulary: vocab,
        tone_samples: tones,
    };
    serde_json::to_string(&payload).map_err(|e| rusqlite::Error::ToSqlConversionFailure(Box::new(e)))
}

pub fn import_sync_data(json_str: &str) -> Result<usize> {
    let payload: SyncDataPayload = serde_json::from_str(json_str)
        .map_err(|e| rusqlite::Error::ToSqlConversionFailure(Box::new(e)))?;
    
    let mut count = 0;
    for v in payload.vocabulary {
        if add_custom_phrase(&v).is_ok() {
            count += 1;
        }
    }
    for t in payload.tone_samples {
        if add_personal_tone_sample(&t).is_ok() {
            count += 1;
        }
    }
    Ok(count)
}

#[cfg(test)]
mod tests {
    use super::*;

    static TEST_MUTEX: Mutex<()> = Mutex::new(());

    #[test]
    fn test_custom_phrases_crud() {
        let _guard = TEST_MUTEX.lock().unwrap_or_else(|e| e.into_inner());
        let db_file = std::env::temp_dir().join("echowrite_test_db_vocab").join("echowrite.db");
        set_override_db_path(Some(db_file));

        let _ = init_db();
        let test_phrase = "EchoWrite專案詞庫測試";
        let _ = add_custom_phrase(test_phrase);
        let list = get_custom_phrases().unwrap();
        assert!(list.contains(&test_phrase.to_string()));

        let _ = delete_custom_phrase(test_phrase);
        let list_after = get_custom_phrases().unwrap();
        assert!(!list_after.contains(&test_phrase.to_string()));

        set_override_db_path(None);
    }

    #[test]
    fn test_history_crud() {
        let _guard = TEST_MUTEX.lock().unwrap_or_else(|e| e.into_inner());
        let db_file = std::env::temp_dir().join("echowrite_test_db_history").join("echowrite.db");
        set_override_db_path(Some(db_file));

        let _ = init_db();
        let test_text = "這是一段測試歷史紀錄。";
        save_history(test_text).unwrap();
        let history = get_history(10).unwrap();
        assert!(!history.is_empty());
        assert_eq!(history[0].text, test_text);

        let item_id = history[0].id;
        delete_history_item(item_id).unwrap();
        let history_after = get_history(10).unwrap();
        assert!(history_after.iter().all(|h| h.id != item_id));

        set_override_db_path(None);
    }

    #[test]
    fn test_personal_tone_and_sync_export_import() {
        let _guard = TEST_MUTEX.lock().unwrap_or_else(|e| e.into_inner());
        let db_file = std::env::temp_dir().join("echowrite_test_db_sync").join("echowrite.db");
        set_override_db_path(Some(db_file));

        let _ = init_db();
        let _ = add_custom_phrase("SyncPhrase1");
        let _ = add_personal_tone_sample("嗨大家，這是我平常習慣的打字口氣！");

        let exported = export_sync_data().unwrap();
        assert!(exported.contains("SyncPhrase1"));
        assert!(exported.contains("這是我平常習慣的打字口氣"));

        let imported_count = import_sync_data(&exported).unwrap();
        assert!(imported_count >= 2);

        set_override_db_path(None);
    }
}
