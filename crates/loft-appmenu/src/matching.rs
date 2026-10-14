//! Window pid → the process whose menu to show.
//!
//! niri reports the pid of the window's Wayland client. Usually that is the
//! process exporting the menu, but not always: launch wrappers, sandboxes
//! (bwrap → child) and multi-process apps export from a child or parent.
//! Candidates are tried in order: the pid itself, its descendants (breadth
//! first), then up to two ancestors — never a process that owns another
//! window (a Qt app started from a terminal is not the terminal's menu), nor
//! one of our own ancestors (the compositor / session).

use std::collections::{HashMap, HashSet, VecDeque};

#[derive(Debug, Default, Clone)]
pub struct ProcTable {
    parent: HashMap<u32, u32>,
}

const MAX_DESCENDANT_DEPTH: usize = 4;
const MAX_ANCESTORS: usize = 2;

impl ProcTable {
    pub fn from_pairs(pairs: impl IntoIterator<Item = (u32, u32)>) -> Self {
        ProcTable {
            parent: pairs.into_iter().collect(),
        }
    }

    /// Every process in /proc with its parent.
    pub fn read() -> Self {
        let mut parent = HashMap::new();
        if let Ok(dir) = std::fs::read_dir("/proc") {
            for entry in dir.flatten() {
                let Some(pid) = entry
                    .file_name()
                    .to_str()
                    .and_then(|s| s.parse::<u32>().ok())
                else {
                    continue;
                };
                if let Some(ppid) = read_ppid(pid) {
                    parent.insert(pid, ppid);
                }
            }
        }
        ProcTable { parent }
    }

    pub fn parent_of(&self, pid: u32) -> Option<u32> {
        self.parent.get(&pid).copied()
    }

    pub fn children_of(&self, pid: u32) -> Vec<u32> {
        let mut c: Vec<u32> = self
            .parent
            .iter()
            .filter(|&(_, &pp)| pp == pid)
            .map(|(&p, _)| p)
            .collect();
        c.sort_unstable();
        c
    }

    pub fn ancestors_of(&self, pid: u32) -> Vec<u32> {
        let mut out = Vec::new();
        let mut cur = pid;
        while let Some(p) = self.parent_of(cur) {
            if p <= 1 || out.contains(&p) {
                break;
            }
            out.push(p);
            cur = p;
        }
        out
    }
}

/// /proc/<pid>/stat field 4. The comm field (2) may contain spaces and
/// parens, so parse after the last ')'.
pub fn parse_ppid(stat: &str) -> Option<u32> {
    let rest = &stat[stat.rfind(')')? + 1..];
    rest.split_whitespace().nth(1)?.parse().ok()
}

fn read_ppid(pid: u32) -> Option<u32> {
    parse_ppid(&std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?)
}

/// Pids to look for a menu in, best first.
pub fn candidates(table: &ProcTable, pid: u32, exclude: &[u32], protected: &[u32]) -> Vec<u32> {
    let skip: HashSet<u32> = exclude
        .iter()
        .chain(protected)
        .copied()
        .filter(|&p| p != pid)
        .collect();
    let mut out = vec![pid];

    let mut queue: VecDeque<(u32, usize)> = VecDeque::from([(pid, 0)]);
    while let Some((p, depth)) = queue.pop_front() {
        if depth >= MAX_DESCENDANT_DEPTH {
            continue;
        }
        for child in table.children_of(p) {
            // A child owning its own window is another app (and so is its subtree).
            if skip.contains(&child) || out.contains(&child) {
                continue;
            }
            out.push(child);
            queue.push_back((child, depth + 1));
        }
    }

    for ancestor in table.ancestors_of(pid).into_iter().take(MAX_ANCESTORS) {
        if skip.contains(&ancestor) {
            break;
        }
        out.push(ancestor);
    }
    out
}

/// Several menubars in one process (one per main window): when there are as
/// many menubars as windows, the focused window's position among the
/// process's windows (by niri id = creation order) picks the menubar in
/// registration order; otherwise the newest one.
pub fn pick<T>(menus: &[T], index: Option<usize>, count: Option<usize>) -> Option<&T> {
    match (index, count) {
        (Some(i), Some(n)) if n == menus.len() && i < n => menus.get(i),
        _ => menus.last(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // 1 ─ 100 (niri) ─┬ 200 (foot) ── 210 (zsh) ── 220 (kate, own window)
    //                 ├ 300 (wrapper) ── 310 (app) ── 320 (helper)
    //                 └ 400 (quickshell) ── 410 (loft-appmenu)
    fn table() -> ProcTable {
        ProcTable::from_pairs([
            (100, 1),
            (200, 100),
            (210, 200),
            (220, 210),
            (300, 100),
            (310, 300),
            (320, 310),
            (400, 100),
            (410, 400),
        ])
    }

    #[test]
    fn parses_stat() {
        assert_eq!(
            parse_ppid("1234 (my (weird) app) S 99 1234 1234 0 -1"),
            Some(99)
        );
        assert_eq!(parse_ppid("1 (systemd) S 0 1 1"), Some(0));
        assert_eq!(parse_ppid("garbage"), None);
    }

    #[test]
    fn walks_descendants_then_ancestors() {
        let t = table();
        let protected = t.ancestors_of(410);
        assert_eq!(protected, vec![400, 100]);
        // The wrapper's window: its child exports the menu.
        assert_eq!(candidates(&t, 300, &[], &protected), vec![300, 310, 320]);
        // The app's window: itself, its helper, then up to the wrapper (niri is protected).
        assert_eq!(candidates(&t, 310, &[], &protected), vec![310, 320, 300]);
    }

    #[test]
    fn skips_other_windows() {
        let t = table();
        let protected = t.ancestors_of(410);
        // foot's window must not show kate's menu (kate owns a window).
        assert_eq!(candidates(&t, 200, &[200, 220], &protected), vec![200, 210]);
        // and kate doesn't climb into the terminal.
        assert_eq!(candidates(&t, 220, &[200, 220], &protected), vec![220, 210]);
    }

    #[test]
    fn picks_by_window_position() {
        let menus = ["/MenuBar/1", "/MenuBar/2", "/MenuBar/3"];
        assert_eq!(pick(&menus, Some(0), Some(3)), Some(&"/MenuBar/1"));
        assert_eq!(pick(&menus, Some(2), Some(3)), Some(&"/MenuBar/3"));
        // A dialog is open too (4 windows, 3 menubars): newest.
        assert_eq!(pick(&menus, Some(0), Some(4)), Some(&"/MenuBar/3"));
        assert_eq!(pick(&menus, None, None), Some(&"/MenuBar/3"));
        assert_eq!(pick::<&str>(&[], Some(0), Some(0)), None);
    }
}
