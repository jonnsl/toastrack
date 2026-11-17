namespace Toastrack {
    /* The installed app behind notifications, as far as it can be told, for names and icons */
    public class AppIdentity : Object {
        private static HashTable<string, AppIdentity>? cache;
        /* Installed apps by casefolded name, for senders that only give a name */
        private static HashTable<string, DesktopAppInfo>? by_name;

        public string key { get; construct; }
        public string name { get; private set; }
        public Icon icon { get; private set; }
        public DesktopAppInfo? info { get; private set; }

        private AppIdentity (string key) {
            Object (key: key);
        }

        public static AppIdentity lookup (Notification n) {
            return lookup_for (n.app_key, n.app_name, n.desktop_entry, n.sender_app_id, n.process_name);
        }

        public static AppIdentity lookup_for (string key, string app_name, string? desktop_entry,
                                              string? sender_app_id, string? process_name) {
            if (cache == null) {
                cache = new HashTable<string, AppIdentity> (str_hash, str_equal);
            }
            var app = cache[key];
            if (app != null) {
                return app;
            }
            app = new AppIdentity (key);
            app.info = find_info (key, app_name, desktop_entry, sender_app_id);
            if (app.info != null) {
                app.name = app.info.get_name ();
            } else if (app_name != "") {
                app.name = app_name;
            } else {
                app.name = process_name ?? _("Unknown App");
            }
            app.icon = app.info?.get_icon () ?? new ThemedIcon ("application-x-executable");
            cache[key] = app;
            return app;
        }

        private static DesktopAppInfo? find_info (string key, string app_name, string? desktop_entry,
                                                  string? sender_app_id) {
            foreach (var id in new string?[] { desktop_entry, key, app_name.down (),
                                               app_name.down ().replace (" ", "-") }) {
                var info = try_id (id);
                if (info != null) {
                    return info;
                }
            }
            if (app_name != "") {
                var info = by_name_lookup (app_name);
                if (info != null) {
                    return info;
                }
                // A sender's unit is a guess, e.g. notify-send in a terminal runs in the terminal's
                return null;
            }
            return try_id (sender_app_id);
        }

        private static DesktopAppInfo? try_id (string? id) {
            if (id == null || id == "" || id.contains ("/")) {
                return null;
            }
            return new DesktopAppInfo (id.has_suffix (".desktop") ? id : id + ".desktop");
        }

        private static DesktopAppInfo? by_name_lookup (string name) {
            if (by_name == null) {
                by_name = new HashTable<string, DesktopAppInfo> (str_hash, str_equal);
                foreach (var info in AppInfo.get_all ()) {
                    var desktop = info as DesktopAppInfo;
                    if (desktop != null && !by_name.contains (info.get_name ().casefold ())) {
                        by_name[info.get_name ().casefold ()] = desktop;
                    }
                }
            }
            return by_name[name.casefold ()];
        }
    }
}
