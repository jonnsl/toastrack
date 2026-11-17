namespace Toastrack {
    /**
     * The daemon that records notifications, a systemd user service.
     *
     * Tracks whether it's running, turns its signals into History.changed, and enables or
     * disables it through systemd.
     */
    public class Recorder : Object {
        public const string BUS_NAME = "io.github.jonnsl.Toastrack.Daemon";
        public const string UNIT = "toastrack.service";
        private const string SIGNAL_PATH = "/io/github/jonnsl/Toastrack";
        private const string SIGNAL_INTERFACE = "io.github.jonnsl.Toastrack1";

        private static Recorder? instance;

        private DBusConnection? bus;
        private uint watch_id;
        private uint signal_id;

        public bool running { get; private set; }
        /* Until the bus has said whether the daemon is running */
        public bool known { get; private set; }

        public static unowned Recorder get_default () {
            if (instance == null) {
                instance = new Recorder ();
            }
            return instance;
        }

        public void start_watching () {
            if (watch_id != 0) {
                return;
            }
            try {
                bus = Bus.get_sync (BusType.SESSION);
            } catch (Error e) {
                warning ("Can't connect to the session bus: %s", e.message);
                known = true;
                return;
            }
            signal_id = bus.signal_subscribe (null, SIGNAL_INTERFACE, null, SIGNAL_PATH, null,
                                              DBusSignalFlags.NONE, on_signal);
            watch_id = Bus.watch_name_on_connection (bus, BUS_NAME, BusNameWatcherFlags.NONE,
                                                     () => update_running (true),
                                                     () => update_running (false));
        }

        private void update_running (bool value) {
            running = value;
            known = true;
            if (value) {
                // The daemon creates the history on its first run
                History.get_default ().open ();
            }
        }

        private void on_signal (DBusConnection conn, string? sender, string path, string iface, string name,
                                Variant parameters) {
            if (!parameters.is_of_type (new VariantType ("(x)"))) {
                return;
            }
            var history = History.get_default ();
            if (!history.available) {
                history.open ();
                return;
            }
            history.changed (parameters.get_child_value (0).get_int64 ());
        }

        private async Variant call_systemd (string method, Variant? parameters) throws Error {
            return yield bus.call ("org.freedesktop.systemd1", "/org/freedesktop/systemd1",
                                   "org.freedesktop.systemd1.Manager", method, parameters, null,
                                   DBusCallFlags.NONE, -1, null);
        }

        /* Enables the service so it starts at login, and starts it */
        public async void enable () throws Error {
            yield call_systemd ("EnableUnitFiles", new Variant ("(^asbb)", new string[] { UNIT }, false, true));
            yield call_systemd ("Reload", null);
            yield call_systemd ("StartUnit", new Variant ("(ss)", UNIT, "replace"));
        }

        /* Stops the service and keeps it from starting at login */
        public async void disable () throws Error {
            yield call_systemd ("DisableUnitFiles", new Variant ("(^asb)", new string[] { UNIT }, false));
            yield call_systemd ("Reload", null);
            yield call_systemd ("StopUnit", new Variant ("(ss)", UNIT, "replace"));
        }
    }
}
