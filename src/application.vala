namespace Toastrack {
    public class Application : Adw.Application {
        public Application () {
            Object (
                application_id: Config.APPLICATION_ID,
                resource_base_path: Config.RESOURCE_PATH,
                flags: ApplicationFlags.DEFAULT_FLAGS
            );
        }

        construct {
            ActionEntry[] action_entries = {
                { "about", on_about_action },
                { "preferences", on_preferences_action },
                { "quit", quit },
            };
            add_action_entries (action_entries, this);
            set_accels_for_action ("app.quit", { "<primary>q" });
            set_accels_for_action ("app.preferences", { "<primary>comma" });
            set_accels_for_action ("win.search", { "<primary>f" });
            set_accels_for_action ("win.show-all", { "<primary>1" });
        }

        public override void startup () {
            base.startup ();
            History.get_default ().open ();
            Recorder.get_default ().start_watching ();
        }

        public override void activate () {
            base.activate ();
            if (active_window == null) {
                new Toastrack.Window (this);
            }
            active_window.present ();
        }

        private void on_about_action () {
            var about = new Adw.AboutDialog () {
                application_name = _("Toastrack"),
                application_icon = Config.APPLICATION_ID,
                developer_name = "Jonnathan Soares",
                version = Config.VERSION,
                developers = { "Jonnathan Soares" },
                // Translators: Replace "translator-credits" with your name/username, and optionally an email or URL.
                translator_credits = _("translator-credits"),
                copyright = "© 2026 Jonnathan Soares",
                license_type = Gtk.License.GPL_3_0,
                website = "https://github.com/jonnsl/toastrack",
                issue_url = "https://github.com/jonnsl/toastrack/issues",
            };
            about.present (active_window);
        }

        private void on_preferences_action () {
            new PreferencesDialog ().present (active_window);
        }
    }
}
