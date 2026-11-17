namespace Toastrack {
    [GtkTemplate (ui = "/io/github/jonnsl/Toastrack/window.ui")]
    public class Window : Adw.ApplicationWindow {
        [GtkChild] private unowned Adw.ToastOverlay toast_overlay;
        [GtkChild] private unowned Adw.NavigationSplitView split_view;
        [GtkChild] private unowned Gtk.ListBox sidebar_list;
        [GtkChild] private unowned Adw.NavigationPage content_page;
        [GtkChild] private unowned Adw.WindowTitle window_title;
        [GtkChild] private unowned Gtk.MenuButton date_button;
        [GtkChild] private unowned Gtk.SearchBar search_bar;
        [GtkChild] private unowned Gtk.SearchEntry search_entry;
        [GtkChild] private unowned Adw.Banner recorder_banner;
        [GtkChild] private unowned Gtk.Stack stack;
        [GtkChild] private unowned Gtk.ScrolledWindow scrolled_window;
        [GtkChild] private unowned Gtk.ListView list_view;
        [GtkChild] private unowned Adw.StatusPage empty_page;

        /* Notifications loaded at a time */
        private const int PAGE_SIZE = 100;

        private Settings settings;
        private History history;
        private Recorder recorder;
        private NotificationList list = new NotificationList ();
        private Filter filter = new Filter ();
        /* "any", "today", "yesterday", "week", "month" or "day:YYYY-MM-DD" */
        private string date_range = "any";
        private bool all_loaded;
        private uint reload_id;
        private uint sidebar_id;
        /* While the sidebar is rebuilt, selection changes aren't the user's */
        private bool updating_sidebar;

        public Window (Gtk.Application app) {
            Object (application: app);
        }

        construct {
            if (Config.PROFILE == "development") {
                add_css_class ("devel");
            }

            settings = new Settings (Config.APPLICATION_ID);
            settings.bind ("window-width", this, "default-width", SettingsBindFlags.DEFAULT);
            settings.bind ("window-height", this, "default-height", SettingsBindFlags.DEFAULT);
            settings.bind ("window-maximized", this, "maximized", SettingsBindFlags.DEFAULT);

            ActionEntry[] entries = {
                { "search", on_search },
                { "date-range", on_date_range, "s", "'any'" },
                { "choose-day", on_choose_day },
                { "critical-only", null, null, "false", on_critical_only },
                { "delete-shown", on_delete_shown },
                { "start-recording", on_start_recording },
                { "show-all", on_show_all },
            };
            add_action_entries (entries, this);
            add_action (settings.create_action ("sort-order"));
            settings.changed["sort-order"].connect (reload);

            var factory = new Gtk.SignalListItemFactory ();
            factory.setup.connect ((obj) => ((Gtk.ListItem) obj).child = new NotificationRow ());
            factory.bind.connect ((obj) => {
                var item = (Gtk.ListItem) obj;
                ((NotificationRow) item.child).bind ((Notification) item.item);
            });
            factory.unbind.connect ((obj) => ((NotificationRow) ((Gtk.ListItem) obj).child).unbind ());
            list_view.factory = factory;

            var header_factory = new Gtk.SignalListItemFactory ();
            header_factory.setup.connect ((obj) => {
                ((Gtk.ListHeader) obj).child = new Gtk.Label (null) {
                    xalign = 0,
                    css_classes = { "heading", "day-header" },
                };
            });
            header_factory.bind.connect ((obj) => {
                var header = (Gtk.ListHeader) obj;
                ((Gtk.Label) header.child).label = Utils.format_day (((Notification) header.item).received);
            });
            list_view.header_factory = header_factory;
            list_view.model = new Gtk.NoSelection (list);
            list_view.activate.connect ((position) => {
                var n = (Notification) list.get_item (position);
                if (n != null) {
                    new NotificationDialog (n).present (this);
                }
            });
            scrolled_window.edge_reached.connect ((pos) => {
                if (pos == Gtk.PositionType.BOTTOM) {
                    load_more ();
                }
            });

            sidebar_list.set_header_func (sidebar_header);
            sidebar_list.row_selected.connect (on_sidebar_row_selected);
            sidebar_list.row_activated.connect (() => split_view.show_content = true);

            search_bar.connect_entry (search_entry);
            search_bar.key_capture_widget = this;
            search_entry.search_changed.connect (() => {
                filter.search = search_entry.text;
                reload ();
            });
            search_bar.notify["search-mode-enabled"].connect (() => {
                if (!search_bar.search_mode_enabled) {
                    search_entry.text = "";
                }
            });

            history = History.get_default ();
            history.changed.connect (on_history_changed);
            recorder = Recorder.get_default ();
            recorder.notify["running"].connect (update_state);
            recorder.notify["known"].connect (update_state);
            history.notify["available"].connect (() => {
                reload ();
                refresh_sidebar ();
            });

            update_date_label ();
            refresh_sidebar ();
            reload ();
        }

        public override void dispose () {
            if (reload_id != 0) {
                Source.remove (reload_id);
                reload_id = 0;
            }
            if (sidebar_id != 0) {
                Source.remove (sidebar_id);
                sidebar_id = 0;
            }
            history.changed.disconnect (on_history_changed);
            base.dispose ();
        }

        public void add_toast (Adw.Toast toast) {
            toast_overlay.add_toast (toast);
        }

        /* The filter with the date range resolved against the current day */
        private Filter current_filter () {
            var f = filter.copy ();
            f.newest_first = settings.get_string ("sort-order") != "oldest";
            var today = Utils.start_of_day (new DateTime.now_local ());
            DateTime? since = null, until = null;
            switch (date_range) {
            case "today":
                since = today;
                break;
            case "yesterday":
                since = today.add_days (-1);
                until = today;
                break;
            case "week":
                since = today.add_days (-6);
                break;
            case "month":
                since = today.add_days (-29);
                break;
            default:
                if (date_range.has_prefix ("day:")) {
                    since = parse_day (date_range.substring (4));
                    until = since?.add_days (1);
                }
                break;
            }
            f.since = since != null ? since.to_unix () * TimeSpan.SECOND : 0;
            f.until = until != null ? until.to_unix () * TimeSpan.SECOND : 0;
            return f;
        }

        private static DateTime? parse_day (string day) {
            var parts = day.split ("-");
            if (parts.length != 3) {
                return null;
            }
            return new DateTime.local (int.parse (parts[0]), int.parse (parts[1]), int.parse (parts[2]), 0, 0, 0);
        }

        private void reload () {
            if (reload_id != 0) {
                Source.remove (reload_id);
                reload_id = 0;
            }
            var f = current_filter ();
            list.newest_first = f.newest_first;
            var items = history.query (f, null, PAGE_SIZE);
            all_loaded = items.length < PAGE_SIZE;
            list.replace_all (items);
            update_state ();
            scroll_to_top ();
        }

        /* To the first day's header, which scrolling to the first item would leave hidden */
        private void scroll_to_top () {
            Idle.add (() => {
                scrolled_window.vadjustment.value = 0;
                return Source.REMOVE;
            });
        }

        /* Reloads once a burst of changes is over */
        private void schedule_reload () {
            if (reload_id != 0) {
                Source.remove (reload_id);
            }
            reload_id = Timeout.add (300, () => {
                reload_id = 0;
                reload ();
                return Source.REMOVE;
            });
        }

        private void load_more () {
            if (all_loaded) {
                return;
            }
            var more = history.query (current_filter (), list.last (), PAGE_SIZE);
            all_loaded = more.length < PAGE_SIZE;
            list.append_all (more);
        }

        private void on_history_changed (int64 id) {
            schedule_sidebar_refresh ();
            if (id == 0) {
                schedule_reload ();
                return;
            }
            var position = list.find (id);
            if (position >= 0) {
                list.remove (position);
            }
            var n = history.get_notification (id, current_filter ());
            if (n != null) {
                var at = list.position_for (n);
                // Past the end, it'll come with the next page
                if (at < list.get_n_items () || all_loaded) {
                    var at_top = scrolled_window.vadjustment.value <= 0;
                    list.insert (at, n);
                    // Otherwise the view stays on what was first and the new one is hidden above
                    if (at == 0 && at_top) {
                        scroll_to_top ();
                    }
                }
            }
            update_state ();
        }

        private void update_state () {
            var f = current_filter ();
            var count = history.count (f);
            window_title.subtitle = history.available
                                    ? ngettext ("%d notification", "%d notifications", count).printf (count)
                                    : "";
            recorder_banner.revealed = recorder.known && !recorder.running && history.available;
            action_set_enabled ("win.delete-shown", count > 0);

            if (list.get_n_items () > 0) {
                stack.visible_child_name = "list";
                return;
            }
            stack.visible_child_name = "empty";
            empty_page.child = null;
            if (!history.available) {
                if (history.error_message != null) {
                    empty_page.icon_name = "dialog-error-symbolic";
                    empty_page.title = _("Can’t Read the History");
                    empty_page.description = history.error_message;
                } else if (recorder.known && !recorder.running) {
                    empty_page.icon_name = "media-record-symbolic";
                    empty_page.title = _("Not Recording Yet");
                    empty_page.description = _("Start recording to keep a history of your notifications. They’re recorded in the background, even when Toastrack is closed."); // vala-lint=line-length
                    empty_page.child = new Gtk.Button.with_mnemonic (_("_Start Recording")) {
                        action_name = "win.start-recording",
                        halign = Gtk.Align.CENTER,
                        css_classes = { "pill", "suggested-action" },
                    };
                } else {
                    empty_page.icon_name = "toastrack-symbolic";
                    empty_page.title = _("No Notifications Yet");
                    empty_page.description = _("Notifications you get from now on show up here");
                }
            } else if (f.search.strip () != "" || f.since > 0 || f.critical_only) {
                empty_page.icon_name = "system-search-symbolic";
                empty_page.title = _("No Results Found");
                empty_page.description = _("Try a different search or filter");
            } else {
                empty_page.icon_name = "toastrack-symbolic";
                empty_page.title = _("No Notifications Yet");
                empty_page.description = _("Notifications you get from now on show up here");
            }
        }

        private void schedule_sidebar_refresh () {
            if (sidebar_id != 0) {
                return;
            }
            sidebar_id = Timeout.add (500, () => {
                sidebar_id = 0;
                refresh_sidebar ();
                return Source.REMOVE;
            });
        }

        private void refresh_sidebar () {
            updating_sidebar = true;
            sidebar_list.remove_all ();
            var all = new AppRow (null, _("All Notifications"), new ThemedIcon ("toastrack-symbolic"));
            sidebar_list.append (all);
            var total = 0;
            AppRow? selected = filter.app_key == null ? all : null;

            var apps = history.apps ();
            apps.sort ((a, b) => a.identity.name.collate (b.identity.name));
            foreach (var app in apps) {
                var row = new AppRow (app.identity.key, app.identity.name, app.identity.icon);
                row.set_count (app.count);
                sidebar_list.append (row);
                total += app.count;
                if (app.identity.key == filter.app_key) {
                    selected = row;
                }
            }
            all.set_count (total);
            // The app is gone, e.g. its notifications were deleted
            if (selected == null) {
                selected = all;
                filter.app_key = null;
                update_title ();
                reload ();
            }
            sidebar_list.select_row (selected);
            updating_sidebar = false;
        }

        private void sidebar_header (Gtk.ListBoxRow row, Gtk.ListBoxRow? before) {
            if (row.get_index () == 1) {
                row.set_header (new Gtk.Label (_("Apps")) {
                    xalign = 0,
                    css_classes = { "heading", "dim-label", "sidebar-heading" },
                });
            } else {
                row.set_header (null);
            }
        }

        private void on_sidebar_row_selected (Gtk.ListBoxRow? row) {
            if (updating_sidebar || row == null) {
                return;
            }
            var app_row = (AppRow) row;
            if (app_row.app_key == filter.app_key) {
                return;
            }
            filter.app_key = app_row.app_key;
            update_title ();
            reload ();
        }

        private void update_title () {
            var row = sidebar_list.get_selected_row () as AppRow;
            var title = filter.app_key != null && row != null ? row.title : _("All Notifications");
            window_title.title = title;
            content_page.title = title;
        }

        private void update_date_label () {
            switch (date_range) {
            case "today":
                date_button.label = _("Today");
                break;
            case "yesterday":
                date_button.label = _("Yesterday");
                break;
            case "week":
                date_button.label = _("Past 7 Days");
                break;
            case "month":
                date_button.label = _("Past 30 Days");
                break;
            case "any":
                date_button.label = _("Any Time");
                break;
            default:
                var day = parse_day (date_range.substring (4));
                date_button.label = day != null ? Utils.format_day (day) : date_range;
                break;
            }
        }

        private void set_date_range (string range) {
            date_range = range;
            ((SimpleAction) lookup_action ("date-range")).set_state (new Variant.string (range));
            update_date_label ();
            reload ();
        }

        private void on_date_range (SimpleAction action, Variant? param) {
            set_date_range (param.get_string ());
        }

        private void on_choose_day () {
            var dialog = new DayDialog ();
            var since = current_filter ().since;
            if (since > 0) {
                dialog.date = new DateTime.from_unix_local (since / TimeSpan.SECOND);
            }
            dialog.chosen.connect ((day) => set_date_range ("day:" + day.format ("%F")));
            dialog.present (this);
        }

        private void on_critical_only (SimpleAction action, Variant value) {
            action.set_state (value);
            filter.critical_only = value.get_boolean ();
            reload ();
        }

        private void on_search () {
            search_bar.search_mode_enabled = true;
            search_entry.grab_focus ();
        }

        private void on_show_all () {
            sidebar_list.select_row (sidebar_list.get_row_at_index (0));
            if (date_range != "any") {
                set_date_range ("any");
            }
        }

        private void on_delete_shown () {
            var f = current_filter ();
            var count = history.count (f);
            var dialog = new Adw.AlertDialog (
                _("Delete Notifications?"),
                ngettext ("The notification shown will be permanently deleted",
                          "The %d notifications shown will be permanently deleted", count).printf (count)
            );
            dialog.add_response ("cancel", _("_Cancel"));
            dialog.add_response ("delete", _("_Delete"));
            dialog.set_response_appearance ("delete", Adw.ResponseAppearance.DESTRUCTIVE);
            dialog.default_response = "cancel";
            dialog.close_response = "cancel";
            dialog.response.connect ((response) => {
                if (response != "delete") {
                    return;
                }
                try {
                    history.delete_matching (f);
                } catch (Error e) {
                    add_toast (new Adw.Toast (_("Can’t delete notifications: %s").printf (e.message)));
                }
            });
            dialog.present (this);
        }

        private void on_start_recording () {
            start_recording.begin ();
        }

        private async void start_recording () {
            try {
                yield recorder.enable ();
            } catch (Error e) {
                warning ("Can't start %s: %s", Recorder.UNIT, e.message);
                add_toast (new Adw.Toast (_("Can’t start recording: %s").printf (e.message)));
            }
        }
    }
}
