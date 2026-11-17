-- Schema version 1. The daemon owns the schema and runs migrations; the app
-- only reads and deletes. The app's tests load this file to build a database.

CREATE TABLE notifications (
    id INTEGER PRIMARY KEY,
    -- Unix time in microseconds. Replacing a notification moves it to the time of the update
    received_at INTEGER NOT NULL,
    -- 'fdo' (org.freedesktop.Notifications) or 'gtk' (org.gtk.Notifications)
    source TEXT NOT NULL,
    -- What notifications are grouped by: the desktop entry, else the app name, else the process name
    app_key TEXT NOT NULL,
    app_name TEXT NOT NULL DEFAULT '',
    desktop_entry TEXT,
    -- Application id of the sender's systemd unit (app-*.scope/.service), when it has one
    sender_app_id TEXT,
    process_name TEXT,
    summary TEXT NOT NULL DEFAULT '',
    -- As sent, possibly with markup
    body TEXT NOT NULL DEFAULT '',
    -- Without markup, for display fallbacks and search
    body_text TEXT NOT NULL DEFAULT '',
    -- Icon name, file path or file:// URI
    app_icon TEXT,
    image_path TEXT,
    -- Encoded image (PNG, JPEG, ...) from image-data hints or GIcon bytes
    image BLOB,
    -- 0 low, 1 normal, 2 critical
    urgency INTEGER NOT NULL DEFAULT 1,
    category TEXT,
    -- Buttons as "key\tlabel", one per line
    actions TEXT NOT NULL DEFAULT '',
    -- How many times the sender replaced it
    updates INTEGER NOT NULL DEFAULT 0,
    -- Server-assigned id (fdo) or app-assigned id (gtk), for replacements and closing
    notification_id TEXT,
    sender TEXT,
    closed_at INTEGER,
    -- 1 expired, 2 dismissed, 3 closed by the app, 4 undefined (e.g. the server went away),
    -- 5 superseded by a newer version recorded as its own notification
    close_reason INTEGER,
    action_invoked TEXT
);

CREATE INDEX notifications_received ON notifications (received_at);
CREATE INDEX notifications_app ON notifications (app_key, received_at);
CREATE INDEX notifications_notification_id ON notifications (source, notification_id);

CREATE VIRTUAL TABLE notifications_fts USING fts5 (
    summary, body_text, app_name,
    content = 'notifications',
    content_rowid = 'id',
    tokenize = 'unicode61 remove_diacritics 2'
);

CREATE TRIGGER notifications_ai AFTER INSERT ON notifications BEGIN
    INSERT INTO notifications_fts (rowid, summary, body_text, app_name)
    VALUES (new.id, new.summary, new.body_text, new.app_name);
END;

CREATE TRIGGER notifications_ad AFTER DELETE ON notifications BEGIN
    INSERT INTO notifications_fts (notifications_fts, rowid, summary, body_text, app_name)
    VALUES ('delete', old.id, old.summary, old.body_text, old.app_name);
END;

CREATE TRIGGER notifications_au AFTER UPDATE OF summary, body_text, app_name ON notifications BEGIN
    INSERT INTO notifications_fts (notifications_fts, rowid, summary, body_text, app_name)
    VALUES ('delete', old.id, old.summary, old.body_text, old.app_name);
    INSERT INTO notifications_fts (rowid, summary, body_text, app_name)
    VALUES (new.id, new.summary, new.body_text, new.app_name);
END;

-- Settings shared by the app and the daemon, e.g. retention-days
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
