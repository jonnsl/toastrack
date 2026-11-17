namespace Toastrack {
    [GtkTemplate (ui = "/io/github/jonnsl/Toastrack/widgets/notification-row.ui")]
    public class NotificationRow : Gtk.Box {
        [GtkChild] private unowned Gtk.Image icon;
        [GtkChild] private unowned Gtk.Label app_label;
        [GtkChild] private unowned Gtk.Image critical_icon;
        [GtkChild] private unowned Gtk.Label time_label;
        [GtkChild] private unowned Gtk.Label summary_label;
        [GtkChild] private unowned Gtk.Label body_label;

        public Notification? notification { get; private set; }

        public void bind (Notification n) {
            notification = n;
            icon.gicon = n.get_icon ();
            app_label.label = n.app.name;
            time_label.label = Utils.format_time (n.received);
            critical_icon.visible = n.urgency == Urgency.CRITICAL;
            summary_label.label = n.summary;
            summary_label.visible = n.summary != "";
            body_label.label = n.body_markup;
            body_label.visible = n.body_text != "";
            if (n.urgency == Urgency.CRITICAL) {
                add_css_class ("critical");
            } else {
                remove_css_class ("critical");
            }
        }

        public void unbind () {
            notification = null;
            icon.gicon = null;
        }
    }
}
