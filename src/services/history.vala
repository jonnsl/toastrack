namespace Toastrack {
    public errordomain HistoryError {
        FAILED,
    }

    /* Which notifications to list */
    public class Filter {
        /* Only of this app; null for all */
        public string? app_key;
        /* Received at or after, in microseconds; 0 for no bound */
        public int64 since;
        /* Received before, in microseconds; 0 for no bound */
        public int64 until;
        public string search = "";
        public bool critical_only;
        public bool newest_first = true;

        public Filter copy () {
            var f = new Filter ();
            f.app_key = app_key;
            f.since = since;
            f.until = until;
            f.search = search;
            f.critical_only = critical_only;
            f.newest_first = newest_first;
            return f;
        }
    }

    /* An app in the history, for the sidebar */
    public class AppSummary : Object {
        public AppIdentity identity { get; set; }
        public int count { get; set; }
        public int64 last_received_at { get; set; }
    }

    /**
     * The notification history recorded by the daemon.
     *
     * The daemon creates the database and owns its schema; the app only reads, deletes and
     * stores settings in it. The daemon's Added and Changed signals come in through changed.
     */
    public class History : Object {
        /* The schema the app understands, see daemon/src/schema.sql */
        public const int SCHEMA_VERSION = 1;

        private const string COLUMNS = """
            id, received_at, source, app_key, app_name, desktop_entry, sender_app_id, process_name,
            summary, body, body_text, app_icon, image_path, image IS NOT NULL, urgency, category,
            actions, updates, closed_at, close_reason, action_invoked
        """;

        private static History? instance;

        private Sqlite.Database? db;

        public string path { get; construct; }
        /* Whether there's a history to read */
        public bool available { get; private set; }
        /* Why it isn't available, beyond not having been created yet */
        public string? error_message { get; private set; }

        /* @id changed, was added or was deleted; 0 for changes to any number of notifications */
        public signal void changed (int64 id);

        public History (string path) {
            Object (path: path);
        }

        public static unowned History get_default () {
            if (instance == null) {
                var dir = Path.build_filename (Environment.get_user_data_dir (), "toastrack");
                instance = new History (Path.build_filename (dir, "history.db"));
            }
            return instance;
        }

        /* Opens the history if it exists by now; returns whether it's available */
        public bool open () {
            if (available) {
                return true;
            }
            if (!FileUtils.test (path, FileTest.EXISTS)) {
                return false;
            }
            Sqlite.Database handle;
            if (Sqlite.Database.open_v2 (path, out handle, Sqlite.OPEN_READWRITE) != Sqlite.OK) {
                error_message = handle.errmsg ();
                warning ("Can't open %s: %s", path, error_message);
                return false;
            }
            handle.busy_timeout (3000);
            db = (owned) handle;
            try {
                var stmt = prepare ("PRAGMA user_version");
                stmt.step ();
                var version = stmt.column_int (0);
                if (version == 0) {
                    // Created but not set up yet
                    db = null;
                    return false;
                }
                if (version > SCHEMA_VERSION) {
                    error_message = _("The history was recorded by a newer version of Toastrack");
                    db = null;
                    return false;
                }
            } catch (Error e) {
                error_message = e.message;
                db = null;
                return false;
            }
            error_message = null;
            available = true;
            changed (0);
            return true;
        }

        private Sqlite.Statement prepare (string sql) throws Error {
            Sqlite.Statement stmt;
            if (db.prepare_v2 (sql, -1, out stmt) != Sqlite.OK) {
                throw new HistoryError.FAILED ("%s", db.errmsg ());
            }
            return stmt;
        }

        private void run (Sqlite.Statement stmt) throws Error {
            if (stmt.step () != Sqlite.DONE) {
                throw new HistoryError.FAILED ("%s", db.errmsg ());
            }
        }

        /* An FTS5 query matching every word of @text as a prefix, or null if there are none */
        public static string? fts_query (string text) {
            string[] terms = {};
            foreach (var word in Regex.split_simple ("\\s+", text.strip ())) {
                if (word != "") {
                    terms += "\"%s\"*".printf (word.replace ("\"", "\"\""));
                }
            }
            return terms.length == 0 ? null : string.joinv (" ", terms);
        }

        private static string where (Filter f, string[] extra = {}) {
            string[] parts = {};
            if (f.app_key != null) {
                parts += "app_key = :app";
            }
            if (f.since > 0) {
                parts += "received_at >= :since";
            }
            if (f.until > 0) {
                parts += "received_at < :until";
            }
            if (f.critical_only) {
                parts += "urgency = 2";
            }
            if (fts_query (f.search) != null) {
                parts += "id IN (SELECT rowid FROM notifications_fts WHERE notifications_fts MATCH :match)";
            }
            foreach (var part in extra) {
                parts += part;
            }
            return parts.length == 0 ? "" : " WHERE " + string.joinv (" AND ", parts);
        }

        private static void bind (Sqlite.Statement stmt, Filter f) {
            int index;
            if ((index = stmt.bind_parameter_index (":app")) > 0) {
                stmt.bind_text (index, f.app_key);
            }
            if ((index = stmt.bind_parameter_index (":since")) > 0) {
                stmt.bind_int64 (index, f.since);
            }
            if ((index = stmt.bind_parameter_index (":until")) > 0) {
                stmt.bind_int64 (index, f.until);
            }
            if ((index = stmt.bind_parameter_index (":match")) > 0) {
                stmt.bind_text (index, fts_query (f.search));
            }
        }

        private static string? column_str (Sqlite.Statement stmt, int col) {
            return stmt.column_type (col) == Sqlite.NULL ? null : stmt.column_text (col);
        }

        private static Notification read_row (Sqlite.Statement stmt) {
            var n = new Notification (stmt.column_int64 (0));
            n.received_at = stmt.column_int64 (1);
            n.source = stmt.column_text (2);
            n.app_key = stmt.column_text (3);
            n.app_name = stmt.column_text (4);
            n.desktop_entry = column_str (stmt, 5);
            n.sender_app_id = column_str (stmt, 6);
            n.process_name = column_str (stmt, 7);
            n.summary = stmt.column_text (8);
            n.body = stmt.column_text (9);
            n.body_text = stmt.column_text (10);
            n.app_icon = column_str (stmt, 11);
            n.image_path = column_str (stmt, 12);
            n.has_image = stmt.column_int (13) != 0;
            n.urgency = (Urgency) stmt.column_int (14).clamp (0, 2);
            n.category = column_str (stmt, 15);
            n.actions = stmt.column_text (16);
            n.updates = stmt.column_int (17);
            n.closed_at = stmt.column_int64 (18);
            n.close_reason = stmt.column_int (19);
            n.action_invoked = column_str (stmt, 20);
            return n;
        }

        /* Up to @limit notifications matching @f, in its order, that come after @after */
        public GenericArray<Notification> query (Filter f, Notification? after, int limit) {
            var result = new GenericArray<Notification> ();
            if (!available) {
                return result;
            }
            string[] extra = {};
            if (after != null) {
                extra += f.newest_first ? "(received_at, id) < (:after_time, :after_id)"
                                        : "(received_at, id) > (:after_time, :after_id)";
            }
            var order = f.newest_first ? "DESC" : "ASC";
            try {
                var stmt = prepare ("SELECT %s FROM notifications%s ORDER BY received_at %s, id %s LIMIT :limit"
                                    .printf (COLUMNS, where (f, extra), order, order));
                bind (stmt, f);
                if (after != null) {
                    stmt.bind_int64 (stmt.bind_parameter_index (":after_time"), after.received_at);
                    stmt.bind_int64 (stmt.bind_parameter_index (":after_id"), after.id);
                }
                stmt.bind_int (stmt.bind_parameter_index (":limit"), limit);
                while (stmt.step () == Sqlite.ROW) {
                    result.add (read_row (stmt));
                }
            } catch (Error e) {
                warning ("Can't list notifications: %s", e.message);
            }
            return result;
        }

        /* Notification @id if it matches @f */
        public Notification? get_notification (int64 id, Filter f) {
            if (!available) {
                return null;
            }
            try {
                var stmt = prepare ("SELECT %s FROM notifications%s".printf (COLUMNS, where (f, { "id = :id" })));
                bind (stmt, f);
                stmt.bind_int64 (stmt.bind_parameter_index (":id"), id);
                if (stmt.step () == Sqlite.ROW) {
                    return read_row (stmt);
                }
            } catch (Error e) {
                warning ("Can't read notification %lld: %s", id, e.message);
            }
            return null;
        }

        public int count (Filter f) {
            if (!available) {
                return 0;
            }
            try {
                var stmt = prepare ("SELECT COUNT(*) FROM notifications" + where (f));
                bind (stmt, f);
                stmt.step ();
                return stmt.column_int (0);
            } catch (Error e) {
                warning ("Can't count notifications: %s", e.message);
                return 0;
            }
        }

        public Bytes? load_image (int64 id) {
            if (!available) {
                return null;
            }
            try {
                var stmt = prepare ("SELECT image FROM notifications WHERE id = ?");
                stmt.bind_int64 (1, id);
                if (stmt.step () == Sqlite.ROW && stmt.column_type (0) == Sqlite.BLOB) {
                    unowned uint8[] data = (uint8[]) stmt.column_blob (0);
                    data.length = stmt.column_bytes (0);
                    return new Bytes (data);
                }
            } catch (Error e) {
                warning ("Can't load image of %lld: %s", id, e.message);
            }
            return null;
        }

        /* Apps with notifications, most recent first */
        public GenericArray<AppSummary> apps () {
            var result = new GenericArray<AppSummary> ();
            if (!available) {
                return result;
            }
            try {
                var stmt = prepare ("""
                    SELECT app_key, MAX(app_name), MAX(desktop_entry), MAX(sender_app_id), MAX(process_name),
                           COUNT(*), MAX(received_at)
                    FROM notifications GROUP BY app_key ORDER BY MAX(received_at) DESC
                """);
                while (stmt.step () == Sqlite.ROW) {
                    var app = new AppSummary () {
                        identity = AppIdentity.lookup_for (stmt.column_text (0), stmt.column_text (1) ?? "",
                                                           column_str (stmt, 2), column_str (stmt, 3),
                                                           column_str (stmt, 4)),
                        count = stmt.column_int (5),
                        last_received_at = stmt.column_int64 (6),
                    };
                    result.add (app);
                }
            } catch (Error e) {
                warning ("Can't list apps: %s", e.message);
            }
            return result;
        }

        public void delete_notification (int64 id) throws Error {
            var stmt = prepare ("DELETE FROM notifications WHERE id = ?");
            stmt.bind_int64 (1, id);
            run (stmt);
            changed (id);
        }

        /* Deletes what matches @f; returns how many were deleted */
        public int delete_matching (Filter f) throws Error {
            var stmt = prepare ("DELETE FROM notifications" + where (f));
            bind (stmt, f);
            run (stmt);
            var deleted = db.changes ();
            changed (0);
            return deleted;
        }

        /* Days notifications are kept for; 0 for forever */
        public int get_retention_days () {
            if (!available) {
                return 0;
            }
            try {
                var stmt = prepare ("SELECT value FROM meta WHERE key = 'retention-days'");
                if (stmt.step () == Sqlite.ROW) {
                    return int.parse (stmt.column_text (0));
                }
            } catch (Error e) {
                warning ("Can't read the retention period: %s", e.message);
            }
            return 0;
        }

        /* The daemon deletes older notifications hourly; they're deleted right away too */
        public void set_retention_days (int days) throws Error {
            var stmt = prepare ("INSERT OR REPLACE INTO meta (key, value) VALUES ('retention-days', ?)");
            stmt.bind_text (1, days.to_string ());
            run (stmt);
            if (days > 0) {
                var cutoff = get_real_time () - (int64) days * TimeSpan.DAY;
                var stmt_delete = prepare ("DELETE FROM notifications WHERE received_at < ?");
                stmt_delete.bind_int64 (1, cutoff);
                run (stmt_delete);
                if (db.changes () > 0) {
                    changed (0);
                }
            }
        }
    }
}
