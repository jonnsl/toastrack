//! Notifications as recorded, parsed from org.freedesktop.Notifications.Notify and
//! org.gtk.Notifications.AddNotification calls.

use std::collections::HashMap;

use zbus::zvariant::{OwnedValue, Value};

use crate::{image, markup};

pub const SOURCE_FDO: &str = "fdo";
pub const SOURCE_GTK: &str = "gtk";

#[derive(Debug, Default, Clone, PartialEq)]
pub struct Record {
    pub source: &'static str,
    pub app_name: String,
    pub desktop_entry: Option<String>,
    pub sender_app_id: Option<String>,
    pub process_name: Option<String>,
    pub summary: String,
    pub body: String,
    pub body_text: String,
    pub app_icon: Option<String>,
    pub image_path: Option<String>,
    pub image: Option<Vec<u8>>,
    pub urgency: u8,
    pub category: Option<String>,
    /// (key, label) of each button
    pub actions: Vec<(String, String)>,
    pub notification_id: Option<String>,
    pub sender: Option<String>,
    /// Progress and OSD-style notifications that are always updated in place
    pub ephemeral: bool,
}

impl Record {
    /// What notifications are grouped by in the app
    pub fn app_key(&self) -> String {
        [&self.desktop_entry, &Some(self.app_name.clone()), &self.process_name]
            .into_iter()
            .flatten()
            .map(|s| s.trim())
            .find(|s| !s.is_empty())
            .unwrap_or("unknown")
            .to_string()
    }

    pub fn actions_text(&self) -> String {
        self.actions
            .iter()
            .map(|(key, label)| format!("{}\t{}", one_line(key), one_line(label)))
            .collect::<Vec<_>>()
            .join("\n")
    }
}

fn one_line(s: &str) -> String {
    s.replace(['\t', '\n', '\r'], " ")
}

/// The arguments of org.freedesktop.Notifications.Notify
pub type NotifyArgs = (String, u32, String, String, String, Vec<String>, HashMap<String, OwnedValue>, i32);

/// Parses a Notify call; returns the record and the id it replaces (0 for none)
pub fn from_notify(args: NotifyArgs) -> (Record, u32) {
    let (app_name, replaces_id, app_icon, summary, body, actions, hints, _timeout) = args;
    let hint = |name: &str| hints.get(name).map(|v| unwrap(v));
    let hint_str = |name: &str| hint(name).and_then(as_str).filter(|s| !s.is_empty()).map(String::from);

    let image =
        ["image-data", "image_data", "icon_data"].into_iter().find_map(|name| hint(name).and_then(image_from_raw));
    let image_path = hint_str("image-path").or_else(|| hint_str("image_path"));
    let urgency = hint("urgency").and_then(as_u8).unwrap_or(1).min(2);
    let ephemeral = hint("value").is_some()
        || hints.contains_key("x-canonical-private-synchronous")
        || hints.contains_key("synchronous")
        || hints.contains_key("x-dunst-stack-tag");

    // Actions come as a flat list of key, label pairs
    let actions = actions.as_chunks::<2>().0.iter().map(|pair| (pair[0].clone(), pair[1].clone())).collect();

    let record = Record {
        source: SOURCE_FDO,
        app_name: app_name.trim().to_string(),
        desktop_entry: hint_str("desktop-entry").map(|s| s.trim_end_matches(".desktop").to_string()),
        body_text: markup::strip(&body),
        summary,
        body,
        app_icon: Some(app_icon).filter(|s| !s.is_empty()),
        image_path,
        image,
        urgency,
        category: hint_str("category"),
        actions,
        ephemeral,
        ..Default::default()
    };
    (record, replaces_id)
}

/// The arguments of org.gtk.Notifications.AddNotification
pub type AddNotificationArgs = (String, String, HashMap<String, OwnedValue>);

pub fn from_add_notification(args: AddNotificationArgs) -> Record {
    let (app_id, id, props) = args;
    let prop = |name: &str| props.get(name).map(|v| unwrap(v));
    let prop_str = |name: &str| prop(name).and_then(as_str).filter(|s| !s.is_empty()).map(String::from);

    let mut record = Record {
        source: SOURCE_GTK,
        desktop_entry: Some(app_id.clone()).filter(|s| !s.is_empty()),
        app_name: String::new(),
        summary: prop_str("title").unwrap_or_default(),
        body: prop_str("body").unwrap_or_default(),
        urgency: match prop_str("priority").as_deref() {
            Some("low") => 0,
            Some("high") | Some("urgent") => 2,
            _ => 1,
        },
        category: prop_str("category"),
        notification_id: Some(id),
        ..Default::default()
    };
    // GLib 2.82+ sends a separate markup-body
    if let Some(markup_body) = prop_str("markup-body") {
        record.body = markup_body;
    }
    record.body_text = markup::strip(&record.body);

    if let Some(icon) = prop("icon") {
        apply_gicon(&mut record, icon);
    }
    if let Some(default) = prop_str("default-action") {
        record.actions.push((default, String::new()));
    }
    if let Some(Value::Array(buttons)) = prop("buttons") {
        for button in buttons.inner() {
            if let Value::Dict(dict) = unwrap(button) {
                let mut label = None;
                let mut action = None;
                for (key, value) in dict.iter() {
                    match as_str(unwrap(key)) {
                        Some("label") => label = as_str(unwrap(value)).map(String::from),
                        Some("action") => action = as_str(unwrap(value)).map(String::from),
                        _ => {}
                    }
                }
                if let Some(label) = label {
                    record.actions.push((action.unwrap_or_default(), label));
                }
            }
        }
    }
    record
}

/// A serialized GIcon: ('themed', <['name', ...]>), ('file', <'path'>), ('bytes', <ay>),
/// or a bare string for a themed icon or path
fn apply_gicon(record: &mut Record, icon: &Value) {
    match icon {
        Value::Str(s) => record.app_icon = Some(s.to_string()),
        Value::Structure(s) => {
            let fields = s.fields();
            let (Some(kind), Some(data)) = (fields.first().and_then(as_str), fields.get(1)) else {
                return;
            };
            let data = unwrap(data);
            match kind {
                "themed" => {
                    if let Value::Array(names) = data {
                        record.app_icon = names.inner().iter().filter_map(as_str).next().map(String::from);
                    }
                }
                "file" => record.image_path = as_str(data).map(String::from),
                "bytes" => record.image = as_bytes(data),
                _ => {}
            }
        }
        _ => {}
    }
}

/// image-data is (iiibiiay): width, height, rowstride, has alpha, bits per sample, channels, data
fn image_from_raw(value: &Value) -> Option<Vec<u8>> {
    let Value::Structure(s) = value else {
        return None;
    };
    let f = s.fields();
    if f.len() != 7 {
        return None;
    }
    let raw = image::Raw {
        width: as_i32(&f[0])?,
        height: as_i32(&f[1])?,
        rowstride: as_i32(&f[2])?,
        has_alpha: matches!(f[3], Value::Bool(true)),
        bits_per_sample: as_i32(&f[4])?,
        channels: as_i32(&f[5])?,
        data: as_bytes(unwrap(&f[6]))?,
    };
    image::to_png(&raw)
}

fn unwrap<'a>(value: &'a Value<'a>) -> &'a Value<'a> {
    match value {
        Value::Value(inner) => unwrap(inner),
        v => v,
    }
}

fn as_str<'a>(value: &'a Value<'a>) -> Option<&'a str> {
    match value {
        Value::Str(s) => Some(s.as_str()),
        Value::ObjectPath(p) => Some(p.as_str()),
        _ => None,
    }
}

fn as_i32(value: &Value) -> Option<i32> {
    match value {
        Value::I32(n) => Some(*n),
        Value::U32(n) => i32::try_from(*n).ok(),
        Value::I16(n) => Some(*n as i32),
        Value::U16(n) => Some(*n as i32),
        Value::U8(n) => Some(*n as i32),
        _ => None,
    }
}

fn as_u8(value: &Value) -> Option<u8> {
    as_i32(value).and_then(|n| u8::try_from(n).ok())
}

fn as_bytes(value: &Value) -> Option<Vec<u8>> {
    let Value::Array(array) = value else {
        return None;
    };
    array.inner().iter().map(|v| if let Value::U8(b) = v { Some(*b) } else { None }).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use zbus::zvariant::{Array, StructureBuilder};

    fn owned(v: Value) -> OwnedValue {
        v.try_into_owned().unwrap()
    }

    #[test]
    fn notify_with_hints() {
        let mut hints = HashMap::new();
        hints.insert("desktop-entry".to_string(), owned(Value::from("org.gnome.Fractal.desktop")));
        hints.insert("urgency".to_string(), owned(Value::U8(2)));
        hints.insert("category".to_string(), owned(Value::from("im.received")));
        let args = (
            "Fractal".to_string(),
            7,
            "chat-symbolic".to_string(),
            "Alice".to_string(),
            "<b>hi</b> &amp; bye".to_string(),
            vec!["default".into(), "Open".into(), "reply".into(), "Reply".into()],
            hints,
            -1,
        );
        let (r, replaces) = from_notify(args);
        assert_eq!(replaces, 7);
        assert_eq!(r.desktop_entry.as_deref(), Some("org.gnome.Fractal"));
        assert_eq!(r.app_key(), "org.gnome.Fractal");
        assert_eq!(r.urgency, 2);
        assert_eq!(r.body_text, "hi & bye");
        assert_eq!(r.actions_text(), "default\tOpen\nreply\tReply");
        assert!(!r.ephemeral);
    }

    #[test]
    fn notify_image_data() {
        let pixels: Vec<u8> = vec![255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 9, 9, 9, 0];
        let image = StructureBuilder::new()
            .add_field(2i32)
            .add_field(2i32)
            .add_field(8i32)
            .add_field(true)
            .add_field(8i32)
            .add_field(4i32)
            .append_field(Value::Array(Array::from(pixels)))
            .build()
            .unwrap();
        let mut hints = HashMap::new();
        hints.insert("image-data".to_string(), owned(Value::Structure(image)));
        hints.insert("value".to_string(), owned(Value::I32(40)));
        let (r, _) = from_notify((String::new(), 0, String::new(), "s".into(), String::new(), vec![], hints, 0));
        let png = r.image.as_ref().expect("image");
        assert_eq!(&png[1..4], b"PNG");
        assert!(r.ephemeral);
        assert_eq!(r.app_key(), "unknown");
    }

    #[test]
    fn gtk_notification() {
        let mut props = HashMap::new();
        props.insert("title".to_string(), owned(Value::from("Download complete")));
        props.insert("body".to_string(), owned(Value::from("file.iso")));
        props.insert("priority".to_string(), owned(Value::from("urgent")));
        let icon = StructureBuilder::new()
            .add_field("themed")
            .append_field(Value::Value(Box::new(Value::Array(Array::from(vec!["folder-download", "folder"])))))
            .build()
            .unwrap();
        props.insert("icon".to_string(), owned(Value::Structure(icon)));
        let r = from_add_notification(("org.gnome.Epiphany".into(), "dl-1".into(), props));
        assert_eq!(r.source, SOURCE_GTK);
        assert_eq!(r.app_key(), "org.gnome.Epiphany");
        assert_eq!(r.summary, "Download complete");
        assert_eq!(r.urgency, 2);
        assert_eq!(r.app_icon.as_deref(), Some("folder-download"));
        assert_eq!(r.notification_id.as_deref(), Some("dl-1"));
    }
}
