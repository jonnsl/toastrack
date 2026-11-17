//! What can be learned about a sender from its process.

pub struct ProcessInfo {
    pub name: Option<String>,
    /// Application id from the process's systemd unit, see
    /// https://systemd.io/DESKTOP_ENVIRONMENTS/
    pub app_id: Option<String>,
}

pub fn lookup(pid: u32) -> ProcessInfo {
    let read = |file: &str| std::fs::read_to_string(format!("/proc/{pid}/{file}")).ok();
    ProcessInfo {
        name: read("comm").map(|s| s.trim().to_string()).filter(|s| !s.is_empty()),
        app_id: read("cgroup").as_deref().and_then(app_id_from_cgroup),
    }
}

/// The application id in "app[-<launcher>]-<id>-<random>.scope" or
/// "app[-<launcher>]-<id>[@<random>].service", where dashes in parts are escaped as \x2d
pub fn app_id_from_cgroup(cgroup: &str) -> Option<String> {
    // The unified hierarchy line is "0::/path"
    let path = cgroup.lines().find_map(|l| l.strip_prefix("0::"))?;
    let unit = path.rsplit('/').next()?;
    let parts: Vec<&str> = if let Some(scope) = unit.strip_suffix(".scope") {
        let mut parts: Vec<&str> = scope.split('-').collect();
        parts.pop();
        parts
    } else {
        let service = unit.strip_suffix(".service")?;
        service.split('@').next()?.split('-').collect()
    };
    if parts.len() < 2 || parts[0] != "app" {
        return None;
    }
    let id = parts.last()?.replace("\\x2d", "-");
    Some(id).filter(|s| !s.is_empty())
}

#[cfg(test)]
mod tests {
    use super::app_id_from_cgroup;

    #[test]
    fn units() {
        let base = "0::/user.slice/user-1000.slice/user@1000.service/app.slice/";
        let id = |unit: &str| app_id_from_cgroup(&format!("{base}{unit}\n"));
        assert_eq!(id("app-gnome-org.gnome.Nautilus-1234.scope").as_deref(), Some("org.gnome.Nautilus"));
        assert_eq!(id("app-flatpak-com.discordapp.Discord-55.scope").as_deref(), Some("com.discordapp.Discord"));
        assert_eq!(id("app-google\\x2dchrome-9.scope").as_deref(), Some("google-chrome"));
        assert_eq!(id("app-niri-firefox@abc.service").as_deref(), Some("firefox"));
        assert_eq!(id("app-foot.service").as_deref(), Some("foot"));
        assert_eq!(id("dbus-broker.service"), None);
        assert_eq!(id("session-2.scope"), None);
    }
}
