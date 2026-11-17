//! SQLite history. The daemon owns the schema; the app reads it and may delete rows.

use std::path::{Path, PathBuf};
use std::time::Duration;

use anyhow::{Context, Result, bail};
use rusqlite::{Connection, OptionalExtension, params};

use crate::record::Record;

const SCHEMA_VERSION: i32 = 1;
const SCHEMA_V1: &str = include_str!("schema.sql");

pub const REASON_UNDEFINED: i32 = 4;
pub const REASON_SUPERSEDED: i32 = 5;

pub struct Store {
    conn: Connection,
}

/// A notification still on screen, as far as we know
pub struct Open {
    pub id: i64,
    pub received_at: i64,
}

/// $XDG_DATA_HOME/toastrack/history.db
pub fn default_path() -> Result<PathBuf> {
    let data = std::env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".local/share")))
        .context("Neither XDG_DATA_HOME nor HOME is set")?;
    Ok(data.join("toastrack").join("history.db"))
}

pub fn now() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_micros() as i64).unwrap_or(0)
}

impl Store {
    pub fn open(path: &Path) -> Result<Self> {
        if let Some(dir) = path.parent() {
            use std::os::unix::fs::DirBuilderExt;
            std::fs::DirBuilder::new()
                .recursive(true)
                .mode(0o700)
                .create(dir)
                .with_context(|| format!("Can't create {}", dir.display()))?;
        }
        let conn = Connection::open(path).with_context(|| format!("Can't open {}", path.display()))?;
        Self::setup(conn)
    }

    #[cfg(test)]
    pub fn in_memory() -> Result<Self> {
        Self::setup(Connection::open_in_memory()?)
    }

    fn setup(conn: Connection) -> Result<Self> {
        // The app writes too, e.g. when deleting
        conn.busy_timeout(Duration::from_secs(5))?;
        conn.pragma_update(None, "journal_mode", "WAL")?;
        conn.pragma_update(None, "synchronous", "NORMAL")?;
        let mut store = Store { conn };
        store.migrate()?;
        Ok(store)
    }

    fn migrate(&mut self) -> Result<()> {
        let version: i32 = self.conn.pragma_query_value(None, "user_version", |r| r.get(0))?;
        if version > SCHEMA_VERSION {
            bail!("The history was written by a newer version (schema {version})");
        }
        if version == SCHEMA_VERSION {
            return Ok(());
        }
        let tx = self.conn.transaction()?;
        if version < 1 {
            tx.execute_batch(SCHEMA_V1)?;
        }
        tx.pragma_update(None, "user_version", SCHEMA_VERSION)?;
        tx.commit()?;
        Ok(())
    }

    pub fn insert(&self, r: &Record, now: i64) -> Result<i64> {
        self.conn.execute(
            "INSERT INTO notifications (received_at, source, app_key, app_name, desktop_entry, sender_app_id,
                process_name, summary, body, body_text, app_icon, image_path, image, urgency, category, actions,
                notification_id, sender)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18)",
            params![
                now,
                r.source,
                r.app_key(),
                r.app_name,
                r.desktop_entry,
                r.sender_app_id,
                r.process_name,
                r.summary,
                r.body,
                r.body_text,
                r.app_icon,
                r.image_path,
                r.image,
                r.urgency,
                r.category,
                r.actions_text(),
                r.notification_id,
                r.sender,
            ],
        )?;
        Ok(self.conn.last_insert_rowid())
    }

    /// Overwrites the content of @id with @r and moves it to @now
    pub fn update(&self, id: i64, r: &Record, now: i64) -> Result<()> {
        self.conn.execute(
            "UPDATE notifications SET received_at = ?2, summary = ?3, body = ?4, body_text = ?5, app_icon = ?6,
                image_path = ?7, image = ?8, urgency = ?9, category = ?10, actions = ?11, updates = updates + 1
             WHERE id = ?1",
            params![
                id,
                now,
                r.summary,
                r.body,
                r.body_text,
                r.app_icon,
                r.image_path,
                r.image,
                r.urgency,
                r.category,
                r.actions_text(),
            ],
        )?;
        Ok(())
    }

    /// The latest notification with @notification_id that hasn't been closed, optionally only
    /// of @desktop_entry. Ids aren't matched to senders since e.g. `notify-send -r` replaces
    /// from a new process; open notifications are closed whenever the server may have changed
    pub fn find_open(&self, source: &str, notification_id: &str, desktop_entry: Option<&str>) -> Result<Option<Open>> {
        Ok(self
            .conn
            .query_row(
                "SELECT id, received_at FROM notifications
                 WHERE source = ?1 AND notification_id = ?2 AND closed_at IS NULL
                   AND (?3 IS NULL OR desktop_entry = ?3)
                 ORDER BY id DESC LIMIT 1",
                params![source, notification_id, desktop_entry],
                |row| Ok(Open { id: row.get(0)?, received_at: row.get(1)? }),
            )
            .optional()?)
    }

    pub fn set_notification_id(&self, id: i64, notification_id: &str) -> Result<()> {
        self.conn
            .execute("UPDATE notifications SET notification_id = ?2 WHERE id = ?1", params![id, notification_id])?;
        Ok(())
    }

    pub fn close(&self, id: i64, reason: i32, now: i64) -> Result<()> {
        self.conn.execute(
            "UPDATE notifications SET closed_at = ?2, close_reason = ?3 WHERE id = ?1 AND closed_at IS NULL",
            params![id, now, reason],
        )?;
        Ok(())
    }

    pub fn set_action_invoked(&self, id: i64, action: &str) -> Result<()> {
        self.conn.execute("UPDATE notifications SET action_invoked = ?2 WHERE id = ?1", params![id, action])?;
        Ok(())
    }

    /// Closes every open notification of @source, e.g. when its server goes away
    pub fn close_all(&self, source: &str, now: i64) -> Result<()> {
        self.conn.execute(
            "UPDATE notifications SET closed_at = ?2, close_reason = ?3 WHERE source = ?1 AND closed_at IS NULL",
            params![source, now, REASON_UNDEFINED],
        )?;
        Ok(())
    }

    /// Deletes what's older than the retention-days the app set; returns how many were deleted
    pub fn prune(&self, now: i64) -> Result<usize> {
        let days: Option<String> =
            self.conn.query_row("SELECT value FROM meta WHERE key = 'retention-days'", [], |r| r.get(0)).optional()?;
        let days = days.and_then(|d| d.parse::<i64>().ok()).unwrap_or(0);
        if days <= 0 {
            return Ok(0);
        }
        let cutoff = now - days * 86_400 * 1_000_000;
        Ok(self.conn.execute("DELETE FROM notifications WHERE received_at < ?1", params![cutoff])?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::record::SOURCE_FDO;

    fn record(summary: &str) -> Record {
        Record {
            source: SOURCE_FDO,
            app_name: "Test".into(),
            summary: summary.into(),
            body_text: "some body".into(),
            sender: Some(":1.5".into()),
            ..Default::default()
        }
    }

    fn search(store: &Store, query: &str) -> Vec<String> {
        let mut stmt = store
            .conn
            .prepare(
                "SELECT summary FROM notifications WHERE id IN
                 (SELECT rowid FROM notifications_fts WHERE notifications_fts MATCH ?1) ORDER BY id",
            )
            .unwrap();
        stmt.query_map([query], |r| r.get(0)).unwrap().map(|r| r.unwrap()).collect()
    }

    #[test]
    fn insert_update_search() {
        let store = Store::in_memory().unwrap();
        let id = store.insert(&record("Café opening"), 1).unwrap();
        store.insert(&record("Other"), 2).unwrap();
        assert_eq!(search(&store, "cafe*"), vec!["Café opening"]);

        store.set_notification_id(id, "42").unwrap();
        let open = store.find_open(SOURCE_FDO, "42", None).unwrap().unwrap();
        assert_eq!(open.id, id);
        assert!(store.find_open(SOURCE_FDO, "42", Some("other.app")).unwrap().is_none());

        store.update(id, &record("Updated"), 3).unwrap();
        assert_eq!(search(&store, "cafe*"), Vec::<String>::new());
        assert_eq!(search(&store, "updated"), vec!["Updated"]);

        store.close(id, 2, 4).unwrap();
        assert!(store.find_open(SOURCE_FDO, "42", None).unwrap().is_none());

        store.conn.execute("DELETE FROM notifications WHERE id = ?1", [id]).unwrap();
        assert_eq!(search(&store, "updated"), Vec::<String>::new());
    }

    #[test]
    fn prune() {
        let store = Store::in_memory().unwrap();
        let day = 86_400 * 1_000_000;
        store.insert(&record("old"), 0).unwrap();
        store.insert(&record("new"), 10 * day).unwrap();
        assert_eq!(store.prune(10 * day).unwrap(), 0);
        store.conn.execute("INSERT INTO meta (key, value) VALUES ('retention-days', '7')", []).unwrap();
        assert_eq!(store.prune(10 * day).unwrap(), 1);
    }
}
