namespace Toastrack {
    /* A sidebar row: all notifications, or one app's */
    public class AppRow : Gtk.ListBoxRow {
        /* null for all apps */
        public string? app_key { get; construct; }
        public string title { get; construct; }

        private Gtk.Label count_label;

        public AppRow (string? app_key, string title, Icon icon) {
            Object (app_key: app_key, title: title);
            var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12);
            box.append (new Gtk.Image.from_gicon (icon) {
                pixel_size = app_key == null ? 16 : 24,
                accessible_role = Gtk.AccessibleRole.PRESENTATION,
            });
            box.append (new Gtk.Label (title) {
                xalign = 0,
                hexpand = true,
                ellipsize = Pango.EllipsizeMode.END,
            });
            count_label = new Gtk.Label (null) {
                css_classes = { "dim-label", "caption", "numeric" },
            };
            box.append (count_label);
            child = box;
        }

        public void set_count (int count) {
            count_label.label = count.to_string ();
            tooltip_text = ngettext ("%d notification", "%d notifications", count).printf (count);
        }
    }
}
