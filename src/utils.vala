namespace Toastrack.Utils {
    /* The local day of @dt as YYYYMMDD, for grouping */
    public int day_key (DateTime dt) {
        return dt.get_year () * 10000 + dt.get_month () * 100 + dt.get_day_of_month ();
    }

    public DateTime start_of_day (DateTime dt) {
        return new DateTime.local (dt.get_year (), dt.get_month (), dt.get_day_of_month (), 0, 0, 0);
    }

    /* "Today", "Yesterday", "Monday", "Monday, March 3" or "Monday, March 3, 2025" */
    public string format_day (DateTime dt) {
        var today = start_of_day (new DateTime.now_local ());
        var day = start_of_day (dt);
        var days_ago = (int) (today.difference (day) / TimeSpan.DAY);
        if (days_ago == 0) {
            return _("Today");
        }
        if (days_ago == 1) {
            return _("Yesterday");
        }
        if (days_ago > 1 && days_ago < 7) {
            return dt.format ("%A");
        }
        if (dt.get_year () == today.get_year ()) {
            // Translators: date format, see https://docs.gtk.org/glib/method.DateTime.format.html
            // xgettext:no-c-format
            return dt.format (_("%A, %B %-d"));
        }
        // Translators: date format, see https://docs.gtk.org/glib/method.DateTime.format.html
        // xgettext:no-c-format
        return dt.format (_("%A, %B %-d, %Y"));
    }

    public string format_time (DateTime dt) {
        // Translators: time format, see https://docs.gtk.org/glib/method.DateTime.format.html
        // xgettext:no-c-format
        return dt.format (_("%H:%M"));
    }

    public string format_date_time (DateTime dt) {
        // Translators: date and time format, see https://docs.gtk.org/glib/method.DateTime.format.html
        // xgettext:no-c-format
        return dt.format (_("%B %-d, %Y, %H:%M:%S"));
    }

    /* An icon from a notification's icon or image: a themed name, a path or a file:// URI */
    public Icon? icon_from_string (string? value) {
        if (value == null || value == "") {
            return null;
        }
        File? file = null;
        if (value.has_prefix ("file://")) {
            file = File.new_for_uri (value);
        } else if (value.has_prefix ("/")) {
            file = File.new_for_path (value);
        }
        if (file != null) {
            return file.query_exists () ? new FileIcon (file) : null;
        }
        var display = Gdk.Display.get_default ();
        if (display == null || !Gtk.IconTheme.get_for_display (display).has_icon (value)) {
            return null;
        }
        return new ThemedIcon (value);
    }

    /* Tags notification bodies may have that Pango supports too */
    private const string[] ALLOWED_TAGS = { "b", "i", "u" };

    /**
     * Pango markup for a notification body: its bold, italic and underline kept and other
     * tags dropped, or @plain escaped when it isn't valid markup.
     */
    public string sanitize_markup (string body, string plain) {
        string markup;
        try {
            var tags = new Regex ("<(/?)([a-zA-Z][a-zA-Z0-9]*)[^>]*>");
            markup = tags.replace_eval (body, -1, 0, 0, (info, result) => {
                var name = info.fetch (2).down ();
                if (name in ALLOWED_TAGS) {
                    result.append ("<%s%s>".printf (info.fetch (1), name));
                } else if (name == "br" || name == "p" && info.fetch (1) == "" && result.len > 0) {
                    result.append ("\n");
                }
                return false;
            });
        } catch (RegexError e) {
            return Markup.escape_text (plain);
        }
        try {
            Pango.parse_markup (markup, -1, 0, null, null, null);
            return markup.strip ();
        } catch (Error e) {
            return Markup.escape_text (plain);
        }
    }
}
