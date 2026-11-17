namespace Toastrack {
    [GtkTemplate (ui = "/io/github/jonnsl/Toastrack/dialogs/preferences-dialog.ui")]
    public class PreferencesDialog : Adw.PreferencesDialog {
        [GtkChild] private unowned Adw.SwitchRow recording_row;
        [GtkChild] private unowned Adw.ComboRow retention_row;
        [GtkChild] private unowned Adw.ActionRow location_row;

        /* Days for each retention_row choice; 0 for forever */
        private const int[] RETENTION_DAYS = { 0, 365, 182, 91, 30, 7 };

        private Recorder recorder;
        private History history;
        /* While the switch follows the recorder rather than the user */
        private bool syncing;

        construct {
            recorder = Recorder.get_default ();
            history = History.get_default ();

            sync_recording ();
            recorder.notify["running"].connect (sync_recording);
            recording_row.notify["active"].connect (on_recording_toggled);

            var days = history.get_retention_days ();
            var selected = 0;
            for (var i = 0; i < RETENTION_DAYS.length; i++) {
                if (RETENTION_DAYS[i] == days) {
                    selected = i;
                }
            }
            retention_row.selected = selected;
            retention_row.sensitive = history.available;
            retention_row.notify["selected"].connect (on_retention_changed);

            location_row.subtitle = history.path;
        }

        public override void dispose () {
            recorder.notify["running"].disconnect (sync_recording);
            base.dispose ();
        }

        private void sync_recording () {
            syncing = true;
            recording_row.active = recorder.running;
            syncing = false;
        }

        private void on_recording_toggled () {
            if (syncing || recording_row.active == recorder.running) {
                return;
            }
            set_recording.begin (recording_row.active);
        }

        private async void set_recording (bool enabled) {
            recording_row.sensitive = false;
            try {
                if (enabled) {
                    yield recorder.enable ();
                } else {
                    yield recorder.disable ();
                }
            } catch (Error e) {
                warning ("Can't change %s: %s", Recorder.UNIT, e.message);
                add_toast (new Adw.Toast (enabled ? _("Can’t start recording: %s").printf (e.message)
                                                  : _("Can’t stop recording: %s").printf (e.message)));
                sync_recording ();
            }
            recording_row.sensitive = true;
        }

        private void on_retention_changed () {
            var days = RETENTION_DAYS[retention_row.selected];
            try {
                history.set_retention_days (days);
            } catch (Error e) {
                add_toast (new Adw.Toast (_("Can’t change how long notifications are kept: %s").printf (e.message)));
            }
        }
    }
}
