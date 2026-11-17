int main (string[] args) {
    Intl.bindtextdomain (Config.GETTEXT_PACKAGE, Config.LOCALEDIR);
    Intl.bind_textdomain_codeset (Config.GETTEXT_PACKAGE, "UTF-8");
    Intl.textdomain (Config.GETTEXT_PACKAGE);

    // Wayland only
    Gdk.set_allowed_backends ("wayland");

    var app = new Toastrack.Application ();
    return app.run (args);
}
