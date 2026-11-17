namespace Toastrack {
    public enum Urgency {
        LOW,
        NORMAL,
        CRITICAL,
    }

    /* A recorded notification, see daemon/src/schema.sql */
    public class Notification : Object {
        public int64 id { get; construct; }
        /* Unix time in microseconds */
        public int64 received_at { get; set; }
        public string source { get; set; default = "fdo"; }
        public string app_key { get; set; default = ""; }
        public string app_name { get; set; default = ""; }
        public string? desktop_entry { get; set; }
        public string? sender_app_id { get; set; }
        public string? process_name { get; set; }
        public string summary { get; set; default = ""; }
        /* As sent, possibly with markup */
        public string body { get; set; default = ""; }
        public string body_text { get; set; default = ""; }
        public string? app_icon { get; set; }
        public string? image_path { get; set; }
        public bool has_image { get; set; }
        public Urgency urgency { get; set; default = Urgency.NORMAL; }
        public string? category { get; set; }
        /* Buttons as "key\tlabel", one per line */
        public string actions { get; set; default = ""; }
        public int updates { get; set; }
        public int64 closed_at { get; set; }
        public int close_reason { get; set; }
        public string? action_invoked { get; set; }

        private Gdk.Texture? image_texture;
        private bool image_loaded;

        public Notification (int64 id) {
            Object (id: id);
        }

        public DateTime received {
            owned get {
                return new DateTime.from_unix_local (received_at / 1000000)
                .add (received_at % 1000000);
            }
        }

        public AppIdentity app {
            owned get {
                return AppIdentity.lookup (this);
            }
        }

        /* The image the sender attached, loaded from the history on first use */
        public Gdk.Texture? get_image () {
            if (!image_loaded) {
                image_loaded = true;
                var bytes = has_image ? History.get_default ().load_image (id) : null;
                if (bytes != null) {
                    try {
                        image_texture = Gdk.Texture.from_bytes (bytes);
                    } catch (Error e) {
                        debug ("Can't decode the image of %lld: %s", id, e.message);
                    }
                }
            }
            return image_texture;
        }

        /* What represents the notification: its image, else its icon, else its app's */
        public Icon get_icon () {
            Icon? image = get_image ();
            return image ?? Utils.icon_from_string (image_path) ?? Utils.icon_from_string (app_icon) ?? app.icon;
        }

        /* Body as Pango markup; senders often send text that isn't valid markup */
        public string body_markup {
            owned get {
                return Utils.sanitize_markup (body, body_text);
            }
        }

        /* (key, label) of each button, without the default action */
        public string[] get_action_labels () {
            string[] labels = {};
            foreach (var line in actions.split ("\n")) {
                var parts = line.split ("\t", 2);
                if (parts.length == 2 && parts[0] != "default" && parts[1] != "") {
                    labels += parts[1];
                }
            }
            return labels;
        }

        /* The label of the action the user picked, if any */
        public string? get_invoked_label () {
            if (action_invoked == null) {
                return null;
            }
            if (action_invoked == "default") {
                return _("Opened");
            }
            foreach (var line in actions.split ("\n")) {
                var parts = line.split ("\t", 2);
                if (parts.length == 2 && parts[0] == action_invoked) {
                    return parts[1] != "" ? parts[1] : _("Opened");
                }
            }
            return action_invoked;
        }

        public string? get_close_label () {
            if (closed_at == 0) {
                return null;
            }
            switch (close_reason) {
            case 1:
                return _("Expired");
            case 2:
                return _("Dismissed");
            case 3:
                return _("Closed by the app");
            case 5:
                return _("Replaced by a newer notification");
            default:
                return _("Closed");
            }
        }

        /* Summary and body as plain text, e.g. for the clipboard */
        public string to_text () {
            if (body_text == "") {
                return summary;
            }
            return summary == "" ? body_text : "%s\n%s".printf (summary, body_text);
        }
    }
}
