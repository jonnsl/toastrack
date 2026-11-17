namespace Toastrack {
    [GtkTemplate (ui = "/io/github/jonnsl/Toastrack/dialogs/notification-dialog.ui")]
    public class NotificationDialog : Adw.Dialog {
        [GtkChild] private unowned Gtk.Image icon;
        [GtkChild] private unowned Gtk.Label summary_label;
        [GtkChild] private unowned Gtk.Label app_label;
        [GtkChild] private unowned Gtk.Label body_label;
        [GtkChild] private unowned Adw.WrapBox actions_box;
        [GtkChild] private unowned Adw.ActionRow received_row;
        [GtkChild] private unowned Adw.ActionRow status_row;
        [GtkChild] private unowned Adw.ActionRow urgency_row;
        [GtkChild] private unowned Adw.ActionRow category_row;
        [GtkChild] private unowned Adw.ActionRow sender_row;
        [GtkChild] private unowned Gtk.Button open_button;

        public Notification notification { get; construct; }

        public NotificationDialog (Notification notification) {
            Object (notification: notification);
        }

        construct {
            var n = notification;
            var app = n.app;
            title = app.name;
            icon.gicon = n.get_icon ();
            summary_label.label = n.summary;
            summary_label.visible = n.summary != "";
            app_label.label = app.name;
            body_label.label = n.body_markup;
            body_label.visible = n.body_text != "";

            var labels = n.get_action_labels ();
            foreach (var label in labels) {
                actions_box.append (new Gtk.Label (label) {
                    css_classes = { "action-chip" },
                });
            }
            actions_box.visible = labels.length > 0;

            received_row.subtitle = Utils.format_date_time (n.received);
            if (n.updates > 0) {
                received_row.subtitle += "\n" + ngettext ("Updated once", "Updated %d times", n.updates)
                                         .printf (n.updates);
            }

            string[] status = {};
            var invoked = n.get_invoked_label ();
            if (invoked != null) {
                status += _("Clicked “%s”").printf (invoked);
            }
            var closed = n.get_close_label ();
            if (closed != null) {
                var closed_at = new DateTime.from_unix_local (n.closed_at / TimeSpan.SECOND);
                status += "%s · %s".printf (closed, Utils.format_date_time (closed_at));
            }
            status_row.subtitle = string.joinv ("\n", status);
            status_row.visible = status.length > 0;

            switch (n.urgency) {
            case Urgency.LOW:
                urgency_row.subtitle = _("Low");
                break;
            case Urgency.CRITICAL:
                urgency_row.subtitle = _("Critical");
                break;
            default:
                urgency_row.subtitle = _("Normal");
                break;
            }

            category_row.subtitle = n.category ?? "";
            category_row.visible = n.category != null;

            string[] sender = {};
            if (n.app_name != "" && n.app_name != app.name) {
                sender += n.app_name;
            }
            if (n.desktop_entry != null) {
                sender += n.desktop_entry;
            }
            if (n.process_name != null && n.process_name != n.app_name) {
                sender += _("Process “%s”").printf (n.process_name);
            }
            sender_row.subtitle = string.joinv ("\n", sender);
            sender_row.visible = sender.length > 0;

            open_button.visible = app.info != null;
        }

        [GtkCallback]
        private void on_copy () {
            get_clipboard ().set_text (notification.to_text ());
            var window = get_root () as Window;
            close ();
            window?.add_toast (new Adw.Toast (_("Copied to clipboard")));
        }

        [GtkCallback]
        private void on_open_app () {
            var info = notification.app.info;
            if (info == null) {
                return;
            }
            try {
                info.launch (null, get_display ().get_app_launch_context ());
                close ();
            } catch (Error e) {
                var window = get_root () as Window;
                window?.add_toast (new Adw.Toast (_("Can’t open %s").printf (info.get_name ())));
            }
        }

        [GtkCallback]
        private void on_delete () {
            var window = get_root () as Window;
            try {
                History.get_default ().delete_notification (notification.id);
                close ();
            } catch (Error e) {
                window?.add_toast (new Adw.Toast (_("Can’t delete the notification: %s").printf (e.message)));
            }
        }
    }
}
