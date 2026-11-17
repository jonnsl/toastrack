namespace Toastrack {
    /* Picks a day to list the notifications of */
    public class DayDialog : Adw.Dialog {
        private Gtk.Calendar calendar;

        public DateTime date {
            owned get {
                return calendar.get_date ();
            }
            set {
                calendar.set_date (value);
            }
        }

        public signal void chosen (DateTime day);

        construct {
            title = _("Choose a Day");
            content_width = 360;

            calendar = new Gtk.Calendar () {
                margin_top = 6,
                margin_bottom = 12,
                margin_start = 12,
                margin_end = 12,
            };

            var show_button = new Gtk.Button.with_mnemonic (_("_Show")) {
                css_classes = { "suggested-action" },
            };
            show_button.clicked.connect (() => {
                chosen (calendar.get_date ());
                close ();
            });
            var header = new Adw.HeaderBar () {
                show_end_title_buttons = false,
                show_start_title_buttons = false,
            };
            var cancel_button = new Gtk.Button.with_mnemonic (_("_Cancel"));
            cancel_button.clicked.connect (() => close ());
            header.pack_start (cancel_button);
            header.pack_end (show_button);

            var toolbar = new Adw.ToolbarView () {
                content = calendar,
            };
            toolbar.add_top_bar (header);
            child = toolbar;
            default_widget = show_button;
        }
    }
}
