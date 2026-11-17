//! Records desktop notifications into a SQLite history.
//!
//! Becomes a D-Bus monitor of the session bus, so it only ever sees copies of the calls apps make
//! to the notification server and never stands between them.

mod image;
mod markup;
mod procinfo;
mod record;
mod recorder;
mod store;

use std::time::Duration;

use anyhow::{Context, Result, bail};
use futures_util::StreamExt;
use tokio::signal::unix::{SignalKind, signal};
use zbus::fdo::{DBusProxy, MonitoringProxy, RequestNameFlags, RequestNameReply};
use zbus::message::Type;
use zbus::names::BusName;
use zbus::{Connection, MatchRule, MessageStream, connection};

use recorder::{FDO_INTERFACE, GTK_INTERFACE, Recorder};

const DAEMON_NAME: &str = "io.github.jonnsl.Toastrack.Daemon";
const PRUNE_INTERVAL: Duration = Duration::from_secs(60 * 60);

struct Monitor {
    // Kept alive for the stream
    _conn: Connection,
    stream: MessageStream,
}

/// A connection that receives copies of notification calls and signals, and of the replies of
/// @server, the notification server, which carry the ids it assigns
async fn start_monitor(server: Option<&str>) -> Result<Monitor> {
    let conn = connection::Builder::session()?.build().await?;
    let stream = MessageStream::from(&conn);
    let mut rules = vec![
        MatchRule::builder().msg_type(Type::MethodCall).interface(FDO_INTERFACE)?.member("Notify")?.build(),
        MatchRule::builder().msg_type(Type::Signal).interface(FDO_INTERFACE)?.build(),
        MatchRule::builder().msg_type(Type::MethodCall).interface(GTK_INTERFACE)?.build(),
    ];
    if let Some(server) = server {
        rules.push(MatchRule::builder().msg_type(Type::MethodReturn).sender(server)?.build());
    }
    MonitoringProxy::new(&conn).await?.become_monitor(&rules, 0).await.context("Can't monitor the session bus")?;
    Ok(Monitor { _conn: conn, stream })
}

async fn server_owner(dbus: &DBusProxy<'_>) -> Option<String> {
    let name = BusName::try_from(FDO_INTERFACE).ok()?;
    dbus.get_name_owner(name).await.ok().map(|o| o.to_string())
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<()> {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).format_timestamp(None).init();

    let path = store::default_path()?;
    let store = store::Store::open(&path)?;
    // Whatever was open when we last ran may be gone, and its ids reused
    for source in [record::SOURCE_FDO, record::SOURCE_GTK] {
        store.close_all(source, store::now())?;
    }
    log::info!("Recording to {}", path.display());

    let bus = Connection::session().await?;
    let dbus = DBusProxy::new(&bus).await?;
    let mut owner_changes = dbus.receive_name_owner_changed_with_args(&[(0, FDO_INTERFACE)]).await?;
    let server = server_owner(&dbus).await;
    let mut monitor = start_monitor(server.as_deref()).await?;

    // Owned only once recording, so systemd and the app know we're ready
    let reply = bus.request_name_with_flags(DAEMON_NAME, RequestNameFlags::DoNotQueue.into()).await?;
    if reply != RequestNameReply::PrimaryOwner {
        bail!("Another instance is already running");
    }

    let mut recorder = Recorder::new(store, bus.clone(), dbus.clone(), server);
    let mut prune = tokio::time::interval(PRUNE_INTERVAL);
    let mut sigterm = signal(SignalKind::terminate())?;
    let mut sigint = signal(SignalKind::interrupt())?;

    loop {
        tokio::select! {
            msg = monitor.stream.next() => match msg {
                Some(Ok(msg)) => recorder.handle(&msg).await,
                Some(Err(e)) => log::warn!("Bad message: {e}"),
                None => bail!("Lost the session bus"),
            },
            Some(change) = owner_changes.next() => {
                let owner = change.args()?.new_owner().as_ref().map(|o| o.to_string());
                log::info!("Notification server is now {}", owner.as_deref().unwrap_or("gone"));
                // Started before the old one is dropped so nothing is missed in between
                monitor = start_monitor(owner.as_deref()).await?;
                recorder.server_changed(owner).await;
            },
            _ = prune.tick() => recorder.prune().await,
            _ = sigterm.recv() => break,
            _ = sigint.recv() => break,
        }
    }
    Ok(())
}
