using Toastrack; // vala-lint=using-directive

/* Queries against a database built from the daemon's schema (see tests/meson.build) */

const int64 DAY = TimeSpan.DAY;
/* 2026-03-10 12:00 local */
int64 noon;

History setup_history () {
    var dir = Path.build_filename (Environment.get_user_data_dir (), "toastrack");
    var path = Path.build_filename (dir, "history.db");
    FileUtils.remove (path);
    DirUtils.create_with_parents (dir, 0700);

    string schema;
    try {
        FileUtils.get_contents (Environment.get_variable ("TOASTRACK_SCHEMA"), out schema);
    } catch (Error e) {
        error (e.message);
    }
    Sqlite.Database db;
    assert (Sqlite.Database.open (path, out db) == Sqlite.OK);
    exec (db, schema);
    exec (db, "PRAGMA user_version = 1");

    noon = new DateTime.local (2026, 3, 10, 12, 0, 0).to_unix () * TimeSpan.SECOND;
    insert (db, noon - 2 * DAY, "org.gnome.Fractal", "Fractal", "Alice", "Café at <b>noon</b>?", 1);
    insert (db, noon - DAY, "org.gnome.Fractal", "Fractal", "Bob", "Running late", 1);
    insert (db, noon, "firefox", "Firefox", "Download complete", "report.pdf", 1);
    insert (db, noon + 60, "org.gnome.Settings", "Settings", "Battery low", "5% left", 2);

    var history = new History (path);
    assert (history.open ());
    return history;
}

void exec (Sqlite.Database db, string sql) {
    string errmsg;
    if (db.exec (sql, null, out errmsg) != Sqlite.OK) {
        error (errmsg);
    }
}

void insert (Sqlite.Database db, int64 at, string key, string app, string summary, string body, int urgency) {
    Sqlite.Statement stmt;
    db.prepare_v2 ("""
        INSERT INTO notifications
            (received_at, source, app_key, app_name, desktop_entry, summary, body, body_text, urgency)
        VALUES (?, 'fdo', ?, ?, ?, ?, ?, ?, ?)
    """, -1, out stmt);
    stmt.bind_int64 (1, at);
    stmt.bind_text (2, key);
    stmt.bind_text (3, app);
    stmt.bind_text (4, key);
    stmt.bind_text (5, summary);
    stmt.bind_text (6, body);
    stmt.bind_text (7, body.replace ("<b>", "").replace ("</b>", ""));
    stmt.bind_int (8, urgency);
    assert (stmt.step () == Sqlite.DONE);
}

string summaries (GenericArray<Toastrack.Notification> items) {
    string[] s = {};
    foreach (var n in items) {
        s += n.summary;
    }
    return string.joinv (",", s);
}

void test_filters () {
    var history = setup_history ();
    var f = new Filter ();
    assert_cmpstr (summaries (history.query (f, null, 10)), EQ, "Battery low,Download complete,Bob,Alice");
    assert_cmpint (history.count (f), EQ, 4);

    f.newest_first = false;
    assert_cmpstr (summaries (history.query (f, null, 10)), EQ, "Alice,Bob,Download complete,Battery low");

    f = new Filter ();
    f.app_key = "org.gnome.Fractal";
    assert_cmpstr (summaries (history.query (f, null, 10)), EQ, "Bob,Alice");

    f = new Filter ();
    f.since = noon - DAY;
    f.until = noon;
    assert_cmpstr (summaries (history.query (f, null, 10)), EQ, "Bob");

    f = new Filter ();
    f.critical_only = true;
    assert_cmpstr (summaries (history.query (f, null, 10)), EQ, "Battery low");
}

void test_search () {
    var history = setup_history ();
    var f = new Filter ();
    // Prefixes, without diacritics, across summary, body and app name
    f.search = "cafe";
    assert_cmpstr (summaries (history.query (f, null, 10)), EQ, "Alice");
    f.search = "rep";
    assert_cmpstr (summaries (history.query (f, null, 10)), EQ, "Download complete");
    f.search = "fractal late";
    assert_cmpstr (summaries (history.query (f, null, 10)), EQ, "Bob");
    // Query syntax is taken literally
    f.search = "\"AND OR*";
    assert_cmpint (history.query (f, null, 10).length, EQ, 0);
    assert_null (History.fts_query ("   "));
}

void test_paging_and_changes () {
    var history = setup_history ();
    var f = new Filter ();
    var first = history.query (f, null, 2);
    assert_cmpstr (summaries (first), EQ, "Battery low,Download complete");
    var rest = history.query (f, first[1], 2);
    assert_cmpstr (summaries (rest), EQ, "Bob,Alice");

    var battery = first[0];
    assert_nonnull (history.get_notification (battery.id, f));
    f.app_key = "firefox";
    assert_null (history.get_notification (battery.id, f));

    try {
        history.delete_notification (battery.id);
        f = new Filter ();
        f.app_key = "org.gnome.Fractal";
        assert_cmpint (history.delete_matching (f), EQ, 2);
    } catch (Error e) {
        error (e.message);
    }
    assert_cmpint (history.count (new Filter ()), EQ, 1);
    assert_cmpint (history.apps ().length, EQ, 1);
}

void test_retention () {
    var history = setup_history ();
    assert_cmpint (history.get_retention_days (), EQ, 0);
    try {
        history.set_retention_days (7);
    } catch (Error e) {
        error (e.message);
    }
    assert_cmpint (history.get_retention_days (), EQ, 7);
    // Everything is from March 2026, long before "now"
    assert_cmpint (history.count (new Filter ()), EQ, 0);
}

void test_sections () {
    var history = setup_history ();
    var list = new NotificationList ();
    list.replace_all (history.query (new Filter (), null, 10));
    uint start, end;
    // Battery low and Download complete are the same day
    list.get_section (1, out start, out end);
    assert_cmpuint (start, EQ, 0);
    assert_cmpuint (end, EQ, 2);
    list.get_section (3, out start, out end);
    assert_cmpuint (start, EQ, 3);
    assert_cmpuint (end, EQ, 4);

    var n = new Toastrack.Notification (99);
    n.received_at = noon - DAY / 2;
    assert_cmpuint (list.position_for (n), EQ, 2);
}

void test_markup () {
    assert_cmpstr (Utils.sanitize_markup ("<b>Hi</b> <a href='x'>there</a>", "Hi there"), EQ, "<b>Hi</b> there");
    assert_cmpstr (Utils.sanitize_markup ("1 < 2 & 3", "1 < 2 & 3"), EQ, "1 &lt; 2 &amp; 3");
    assert_cmpstr (Utils.sanitize_markup ("<b>unclosed", "unclosed"), EQ, "unclosed");
    assert_cmpstr (Utils.sanitize_markup ("a<br>b", "a\nb"), EQ, "a\nb");
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/history/filters", test_filters);
    Test.add_func ("/history/search", test_search);
    Test.add_func ("/history/paging-and-changes", test_paging_and_changes);
    Test.add_func ("/history/retention", test_retention);
    Test.add_func ("/history/sections", test_sections);
    Test.add_func ("/utils/markup", test_markup);
    return Test.run ();
}
