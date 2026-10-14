//! Finding menus by pid on the bus, without the registrar: every
//! connection a process owns, introspected for Qt's `/MenuBar/<n>` DBusMenu
//! objects and GtkApplication's `<app>/menus/menubar`.
//!
//! This is what makes the global menu work when another registrar (Plasma's
//! kded appmenu) owns the name, and the only way to see GTK menubars at all
//! (GTK publishes their paths through X11 properties / gtk-shell, which niri
//! doesn't have).

use std::collections::{HashMap, HashSet, VecDeque};

use zbus::Connection;
use zbus::fdo::DBusProxy;
use zbus::names::BusName;

#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct Node {
    pub interfaces: Vec<String>,
    pub children: Vec<String>,
}

/// The root node's interfaces and direct child node names.
pub fn parse_introspection(xml: &str) -> Node {
    let mut node = Node::default();
    let mut depth = 0usize;
    let mut rest = xml;
    while let Some(start) = rest.find('<') {
        rest = &rest[start + 1..];
        let Some(end) = rest.find('>') else { break };
        let tag = &rest[..end];
        rest = &rest[end + 1..];
        if tag.starts_with('!') || tag.starts_with('?') {
            continue;
        }
        if let Some(closing) = tag.strip_prefix('/') {
            if closing.trim() == "node" {
                depth = depth.saturating_sub(1);
            }
            continue;
        }
        let self_closing = tag.ends_with('/');
        let mut parts = tag.trim_end_matches('/').split_whitespace();
        let name = parts.next().unwrap_or("");
        match name {
            "node" => {
                if depth == 1
                    && let Some(n) = attr(tag, "name")
                {
                    node.children.push(n.to_string());
                }
                if !self_closing {
                    depth += 1;
                }
            }
            "interface" if depth == 1 => {
                if let Some(n) = attr(tag, "name") {
                    node.interfaces.push(n.to_string());
                }
            }
            _ => {}
        }
    }
    node
}

fn attr<'a>(tag: &'a str, key: &str) -> Option<&'a str> {
    for quote in ['"', '\''] {
        let pat = format!("{key}={quote}");
        if let Some(i) = tag.find(&pat) {
            let v = &tag[i + pat.len()..];
            return v.find(quote).map(|e| &v[..e]);
        }
    }
    None
}

pub fn join(path: &str, child: &str) -> String {
    if path == "/" {
        format!("/{child}")
    } else {
        format!("{path}/{child}")
    }
}

pub async fn introspect(conn: &Connection, dest: &str, path: &str) -> zbus::Result<Node> {
    let reply = conn
        .call_method(
            Some(dest),
            path,
            Some("org.freedesktop.DBus.Introspectable"),
            "Introspect",
            &(),
        )
        .await?;
    let xml: String = reply.body().deserialize()?;
    Ok(parse_introspection(&xml))
}

/// Unique bus name → pid, filled lazily and pruned on NameOwnerChanged.
#[derive(Debug, Default)]
pub struct PidCache {
    pids: HashMap<String, Option<u32>>,
}

impl PidCache {
    pub fn forget(&mut self, name: &str) {
        self.pids.remove(name);
    }

    pub async fn pid_of(&mut self, conn: &Connection, name: &str) -> Option<u32> {
        if let Some(p) = self.pids.get(name) {
            return *p;
        }
        let pid = pid_of(conn, name).await;
        self.pids.insert(name.to_string(), pid);
        pid
    }

    /// Unique names owned by any of `pids`, in the order of `pids`.
    pub async fn connections_of(&mut self, conn: &Connection, pids: &[u32]) -> Vec<(String, u32)> {
        let wanted: HashSet<u32> = pids.iter().copied().collect();
        let Ok(proxy) = DBusProxy::new(conn).await else {
            return Vec::new();
        };
        let Ok(names) = proxy.list_names().await else {
            return Vec::new();
        };
        let mut out = Vec::new();
        for name in names {
            let name = name.as_str();
            if !name.starts_with(':') || Some(name) == conn.unique_name().map(|u| u.as_str()) {
                continue;
            }
            if let Some(pid) = self.pid_of(conn, name).await
                && wanted.contains(&pid)
            {
                out.push((name.to_string(), pid));
            }
        }
        out.sort_by_key(|(name, pid)| (pids.iter().position(|p| p == pid), name_order(name)));
        out
    }
}

/// ":1.42" sorts numerically.
fn name_order(name: &str) -> (u64, u64) {
    let mut it = name
        .trim_start_matches(':')
        .split('.')
        .map(|p| p.parse().unwrap_or(0));
    (it.next().unwrap_or(0), it.next().unwrap_or(0))
}

pub async fn pid_of(conn: &Connection, name: &str) -> Option<u32> {
    let proxy = DBusProxy::new(conn).await.ok()?;
    let bus = BusName::try_from(name).ok()?;
    proxy.get_connection_unix_process_id(bus).await.ok()
}

/// Qt's menubars: `/MenuBar/<n>` (bare `/MenuBar` is a tray icon's menu),
/// in creation order.
pub async fn qt_menubars(conn: &Connection, dest: &str) -> Vec<String> {
    let Ok(root) = introspect(conn, dest, "/MenuBar").await else {
        return Vec::new();
    };
    let mut ids: Vec<u64> = root
        .children
        .iter()
        .filter_map(|c| c.parse().ok())
        .collect();
    ids.sort_unstable();
    let mut out = Vec::new();
    for id in ids {
        let path = format!("/MenuBar/{id}");
        if let Ok(n) = introspect(conn, dest, &path).await
            && n.interfaces.iter().any(|i| i == crate::dbusmenu::IFACE)
        {
            out.push(path);
        }
    }
    out
}

const GTK_MAX_NODES: usize = 400;
const GTK_MAX_DEPTH: usize = 9;

/// GtkApplication object paths that export a menubar (`<app>/menus/menubar`).
pub async fn gtk_apps(conn: &Connection, dest: &str) -> Vec<String> {
    let mut found = Vec::new();
    let mut queue: VecDeque<(String, usize)> = VecDeque::from([("/".to_string(), 0)]);
    let mut seen = 0;
    while let Some((path, depth)) = queue.pop_front() {
        seen += 1;
        if seen > GTK_MAX_NODES {
            break;
        }
        let Ok(node) = introspect(conn, dest, &path).await else {
            continue;
        };
        if path.ends_with("/menus/menubar")
            && node.interfaces.iter().any(|i| i == crate::gtkmenu::MENUS)
        {
            found.push(path.trim_end_matches("/menus/menubar").to_string());
            continue;
        }
        if depth < GTK_MAX_DEPTH {
            for c in node.children {
                queue.push_back((join(&path, &c), depth + 1));
            }
        }
    }
    found
}

/// The window action groups of a GtkApplication: `<app>/window/<n>`.
pub async fn gtk_windows(conn: &Connection, dest: &str, app_path: &str) -> Vec<String> {
    let Ok(node) = introspect(conn, dest, &format!("{app_path}/window")).await else {
        return Vec::new();
    };
    let mut ids: Vec<u64> = node
        .children
        .iter()
        .filter_map(|c| c.parse().ok())
        .collect();
    ids.sort_unstable();
    ids.into_iter()
        .map(|i| format!("{app_path}/window/{i}"))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_introspection_xml() {
        let xml = r#"<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
<node>
  <interface name="org.freedesktop.DBus.Introspectable">
    <method name="Introspect"><arg name="xml_data" type="s" direction="out"/></method>
  </interface>
  <interface name="com.canonical.dbusmenu">
    <signal name="LayoutUpdated"><arg type="u"/><arg type="i"/></signal>
  </interface>
  <node name="1"/>
  <node name='2'/>
  <node name="inline">
    <interface name="should.not.count"/>
    <node name="grandchild"/>
  </node>
</node>"#;
        let n = parse_introspection(xml);
        assert_eq!(
            n.interfaces,
            [
                "org.freedesktop.DBus.Introspectable",
                "com.canonical.dbusmenu"
            ]
        );
        assert_eq!(n.children, ["1", "2", "inline"]);
    }

    #[test]
    fn orders_names() {
        let mut v = vec![":1.10", ":1.9", ":1.100"];
        v.sort_by_key(|n| name_order(n));
        assert_eq!(v, [":1.9", ":1.10", ":1.100"]);
        assert_eq!(join("/", "org"), "/org");
        assert_eq!(join("/org", "gnome"), "/org/gnome");
    }
}
