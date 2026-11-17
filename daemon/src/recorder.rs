//! Turns monitored bus messages into history.

use std::collections::{HashMap, VecDeque};
use std::time::{Duration, Instant};

use anyhow::Result;
use zbus::fdo::DBusProxy;
use zbus::message::Type;
use zbus::names::BusName;
use zbus::{Connection, Message};

use crate::procinfo::{self, ProcessInfo};
use crate::record::{self, Record, SOURCE_FDO, SOURCE_GTK};
use crate::store::{self, Store};

pub const FDO_INTERFACE: &str = "org.freedesktop.Notifications";
pub const GTK_INTERFACE: &str = "org.gtk.Notifications";
pub const SIGNAL_PATH: &str = "/io/github/jonnsl/Toastrack";
pub const SIGNAL_INTERFACE: &str = "io.github.jonnsl.Toastrack1";

/// Replacements within this many microseconds of the previous version overwrite it; later
/// ones are recorded as new notifications so e.g. chat messages aren't lost
const REPLACE_WINDOW: i64 = 30 * 1_000_000;
/// How long to wait for the server's reply to Notify, which carries the notification's id
const PENDING_TTL: Duration = Duration::from_secs(60);
const SENDER_CACHE_SIZE: usize = 256;
const SEEN_SIZE: usize = 64;

/// fdo close reasons; 3 is "closed by a call to CloseNotification"
const REASON_CLOSED_BY_APP: i32 = 3;

pub struct Recorder {
    store: Store,
    bus: Connection,
    dbus: DBusProxy<'static>,
    /// Notify calls whose reply hasn't been seen: (caller, serial) → (row, when)
    pending: HashMap<(String, u32), (i64, Instant)>,
    /// Process info by unique name
    senders: HashMap<String, (Option<String>, Option<String>)>,
    /// The last messages handled, since a message may arrive on two monitors while one is replaced
    seen: VecDeque<(String, u32)>,
    /// Unique name of the org.freedesktop.Notifications owner
    server: Option<String>,
}

impl Recorder {
    pub fn new(store: Store, bus: Connection, dbus: DBusProxy<'static>, server: Option<String>) -> Self {
        Recorder { store, bus, dbus, pending: HashMap::new(), senders: HashMap::new(), seen: VecDeque::new(), server }
    }

    pub async fn handle(&mut self, msg: &Message) {
        let header = msg.header();
        let Some(sender) = header.sender().map(|s| s.to_string()) else {
            return;
        };
        let key = (sender.clone(), header.primary().serial_num().get());
        if self.seen.contains(&key) {
            return;
        }
        if self.seen.len() >= SEEN_SIZE {
            self.seen.pop_front();
        }
        self.seen.push_back(key.clone());

        let interface = header.interface().map(|i| i.as_str());
        let member = header.member().map(|m| m.as_str());
        let destination = header.destination().map(|d| d.to_string());
        let reply_serial = header.reply_serial().map(|s| s.get());
        // Servers may pass calls on, e.g. GNOME's forwards each one to gnome-shell, and re-emit
        // the signals they get back; only what's between apps and the server is recorded
        let to_fdo = addressed_to(destination.as_deref(), FDO_INTERFACE, self.server.as_deref());
        let to_gtk = addressed_to(destination.as_deref(), GTK_INTERFACE, None);
        let from_server = self.server.as_deref() == Some(sender.as_str());
        let result = match (msg.message_type(), interface, member) {
            (Type::MethodCall, Some(FDO_INTERFACE), Some("Notify")) if to_fdo => self.on_notify(msg, key).await,
            (Type::MethodCall, Some(GTK_INTERFACE), Some("AddNotification")) if to_gtk => {
                self.on_gtk_add(msg, sender).await
            }
            (Type::MethodCall, Some(GTK_INTERFACE), Some("RemoveNotification")) if to_gtk => {
                self.on_gtk_remove(msg).await
            }
            (Type::MethodReturn, _, _) => match (destination, reply_serial) {
                (Some(destination), Some(serial)) => self.on_reply(msg, destination, serial),
                _ => Ok(()),
            },
            (Type::Signal, Some(FDO_INTERFACE), Some("NotificationClosed")) if from_server => self.on_closed(msg).await,
            (Type::Signal, Some(FDO_INTERFACE), Some("ActionInvoked")) if from_server => self.on_action(msg).await,
            _ => Ok(()),
        };
        if let Err(e) = result {
            log::warn!("Can't record {}.{}: {e:#}", interface.unwrap_or("?"), member.unwrap_or("?"));
        }
    }

    /// The notification server went away, taking its notifications with it
    pub async fn server_changed(&mut self, server: Option<String>) {
        self.server = server;
        self.pending.clear();
        if let Err(e) = self.store.close_all(SOURCE_FDO, store::now()) {
            log::warn!("Can't close notifications: {e:#}");
        }
        self.emit("Changed", 0).await;
    }

    pub async fn prune(&mut self) {
        match self.store.prune(store::now()) {
            Ok(0) => {}
            Ok(n) => {
                log::info!("Deleted {n} notifications past the retention period");
                self.emit("Changed", 0).await;
            }
            Err(e) => log::warn!("Can't delete old notifications: {e:#}"),
        }
    }

    async fn on_notify(&mut self, msg: &Message, (sender, serial): (String, u32)) -> Result<()> {
        let (mut r, replaces_id) = record::from_notify(msg.body().deserialize()?);
        r.sender = Some(sender.clone());
        self.fill_process_info(&mut r, &sender).await;
        let replaces = (replaces_id != 0).then(|| replaces_id.to_string());
        r.notification_id = replaces.clone();
        let row = self.save(r, replaces.as_deref(), None).await?;

        let now = Instant::now();
        self.pending.retain(|_, (_, at)| now.duration_since(*at) < PENDING_TTL);
        self.pending.insert((sender, serial), (row, now));
        Ok(())
    }

    fn on_reply(&mut self, msg: &Message, destination: String, serial: u32) -> Result<()> {
        if let Some((row, _)) = self.pending.remove(&(destination, serial)) {
            let (id,): (u32,) = msg.body().deserialize()?;
            self.store.set_notification_id(row, &id.to_string())?;
        }
        Ok(())
    }

    async fn on_closed(&mut self, msg: &Message) -> Result<()> {
        let (id, reason): (u32, u32) = msg.body().deserialize()?;
        if let Some(open) = self.store.find_open(SOURCE_FDO, &id.to_string(), None)? {
            self.store.close(open.id, reason as i32, store::now())?;
            self.emit("Changed", open.id).await;
        }
        Ok(())
    }

    async fn on_action(&mut self, msg: &Message) -> Result<()> {
        let (id, action): (u32, String) = msg.body().deserialize()?;
        if let Some(open) = self.store.find_open(SOURCE_FDO, &id.to_string(), None)? {
            self.store.set_action_invoked(open.id, &action)?;
            self.emit("Changed", open.id).await;
        }
        Ok(())
    }

    async fn on_gtk_add(&mut self, msg: &Message, sender: String) -> Result<()> {
        let mut r = record::from_add_notification(msg.body().deserialize()?);
        r.sender = Some(sender.clone());
        self.fill_process_info(&mut r, &sender).await;
        let replaces = r.notification_id.clone();
        let desktop_entry = r.desktop_entry.clone();
        self.save(r, replaces.as_deref(), desktop_entry.as_deref()).await?;
        Ok(())
    }

    async fn on_gtk_remove(&mut self, msg: &Message) -> Result<()> {
        let (app_id, id): (String, String) = msg.body().deserialize()?;
        if let Some(open) = self.store.find_open(SOURCE_GTK, &id, Some(&app_id))? {
            self.store.close(open.id, REASON_CLOSED_BY_APP, store::now())?;
            self.emit("Changed", open.id).await;
        }
        Ok(())
    }

    /// Inserts @r, or updates the notification it replaces; returns its row
    async fn save(&mut self, r: Record, replaces: Option<&str>, desktop_entry: Option<&str>) -> Result<i64> {
        let now = store::now();
        if let Some(replaces) = replaces
            && let Some(open) = self.store.find_open(r.source, replaces, desktop_entry)?
        {
            if r.ephemeral || now - open.received_at < REPLACE_WINDOW {
                self.store.update(open.id, &r, now)?;
                self.emit("Changed", open.id).await;
                return Ok(open.id);
            }
            self.store.close(open.id, store::REASON_SUPERSEDED, now)?;
            self.emit("Changed", open.id).await;
        }
        let id = self.store.insert(&r, now)?;
        log::debug!("Recorded {id} from {}", r.app_key());
        self.emit("Added", id).await;
        Ok(id)
    }

    async fn fill_process_info(&mut self, r: &mut Record, sender: &str) {
        if !self.senders.contains_key(sender) {
            let info = self.lookup_process(sender).await;
            if self.senders.len() >= SENDER_CACHE_SIZE {
                self.senders.clear();
            }
            self.senders.insert(sender.to_string(), (info.name, info.app_id));
        }
        let (name, app_id) = &self.senders[sender];
        r.process_name = name.clone();
        r.sender_app_id = app_id.clone();
    }

    async fn lookup_process(&self, sender: &str) -> ProcessInfo {
        let none = ProcessInfo { name: None, app_id: None };
        let Ok(name) = BusName::try_from(sender) else {
            return none;
        };
        // Senders like notify-send may already be gone
        let credentials =
            tokio::time::timeout(Duration::from_millis(500), self.dbus.get_connection_credentials(name)).await;
        match credentials {
            Ok(Ok(c)) => c.process_id().map(procinfo::lookup).unwrap_or(none),
            _ => none,
        }
    }

    /// Tells the app the history changed; 0 for changes to many notifications
    async fn emit(&self, signal: &str, id: i64) {
        if let Err(e) = self.bus.emit_signal(None::<&str>, SIGNAL_PATH, SIGNAL_INTERFACE, signal, &(id,)).await {
            log::warn!("Can't emit {signal}: {e}");
        }
    }
}

/// Whether a call with @destination is meant for the service with @well_known name, owned by @owner
fn addressed_to(destination: Option<&str>, well_known: &str, owner: Option<&str>) -> bool {
    destination.is_some_and(|d| d == well_known || Some(d) == owner)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_calls_to_the_server() {
        assert!(addressed_to(Some(FDO_INTERFACE), FDO_INTERFACE, Some(":1.19")));
        assert!(addressed_to(Some(":1.19"), FDO_INTERFACE, Some(":1.19")));
        // GNOME's server forwarding to gnome-shell
        assert!(!addressed_to(Some("org.gnome.Shell"), FDO_INTERFACE, Some(":1.19")));
        assert!(!addressed_to(Some(":1.7"), FDO_INTERFACE, Some(":1.19")));
        assert!(!addressed_to(None, FDO_INTERFACE, None));
    }
}
