//! Reading the active niri config tree: the entry config plus everything it
//! `include`s, in niri's order and with niri's path rules.
//!
//! - an include path is relative to the including file; `~/…` is the home dir
//! - `include optional=true "…"` may be missing; a plain include may not
//! - includes are positional: the included file's nodes take the place of the
//!   `include` line, so later definitions win (or, for `output`, the first
//!   matching block wins — see `render`)

use std::collections::HashSet;
use std::path::{Component, Path, PathBuf};

use anyhow::{Context, Result};
use kdl::{KdlDocument, KdlNode};

/// niri's include depth limit.
const RECURSION_LIMIT: usize = 10;

#[derive(Debug)]
pub struct ConfigFile {
    pub path: PathBuf,
    pub text: String,
    pub doc: KdlDocument,
}

impl ConfigFile {
    pub fn line_of(&self, node: &KdlNode) -> usize {
        let off = node.span().offset().min(self.text.len());
        self.text[..off].bytes().filter(|&b| b == b'\n').count() + 1
    }
}

/// A top-level (non-include) node of the flattened config.
#[derive(Debug, Clone, Copy)]
pub struct TopNode {
    pub file: usize,
    pub index: usize,
}

#[derive(Debug, Clone, Copy)]
pub struct NodeRef<'a> {
    pub file: &'a ConfigFile,
    pub node: &'a KdlNode,
}

impl NodeRef<'_> {
    pub fn line(&self) -> usize {
        self.file.line_of(self.node)
    }

    pub fn location(&self) -> String {
        format!("{}:{}", self.file.path.display(), self.line())
    }
}

#[derive(Debug, Default)]
pub struct ConfigTree {
    pub entry: PathBuf,
    pub files: Vec<ConfigFile>,
    pub nodes: Vec<TopNode>,
    /// Problems found while loading (missing required includes, parse errors).
    pub errors: Vec<String>,
}

/// niri's `~` expansion and relative-to-the-including-file resolution.
pub fn resolve_include(base_dir: &Path, path: &str) -> PathBuf {
    let p = Path::new(path);
    if let Ok(rest) = p.strip_prefix("~")
        && let Some(home) = std::env::home_dir()
    {
        return home.join(rest);
    }
    base_dir.join(p)
}

/// Lexically normalized absolute path (`.`/`..` folded, no symlink lookups),
/// with the parent canonicalized when it exists — good enough to recognize
/// the same file reached through different spellings.
pub fn normalize(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for c in path.components() {
        match c {
            Component::ParentDir => {
                out.pop();
            }
            Component::CurDir => {}
            c => out.push(c),
        }
    }
    if let (Some(parent), Some(name)) = (out.parent(), out.file_name())
        && let Ok(p) = parent.canonicalize()
    {
        return p.join(name);
    }
    out
}

pub fn parse_kdl(text: &str) -> Result<KdlDocument, String> {
    KdlDocument::parse_v1(text)
        .or_else(|_| KdlDocument::parse(text))
        .map_err(|e| {
            let msg = e
                .diagnostics
                .first()
                .and_then(|d| d.message.clone())
                .unwrap_or_else(|| e.to_string());
            match e.diagnostics.first().map(|d| d.span.offset()) {
                Some(off) => {
                    let line = text[..off.min(text.len())].matches('\n').count() + 1;
                    format!("line {line}: {msg}")
                }
                None => msg,
            }
        })
}

/// The include node's path argument and `optional=` flag.
pub fn include_args(node: &KdlNode) -> Option<(String, bool)> {
    let path = node
        .entries()
        .iter()
        .find(|e| e.name().is_none())
        .and_then(|e| e.value().as_string())?
        .to_string();
    let optional = node
        .entries()
        .iter()
        .find(|e| e.name().map(|n| n.value()) == Some("optional"))
        .and_then(|e| e.value().as_bool())
        .unwrap_or(false);
    Some((path, optional))
}

impl ConfigTree {
    /// Load `entry` and its includes. Files for which `skip` returns true are
    /// treated as if they were empty (used to read "the config without our
    /// own overrides fragment").
    pub fn load(entry: &Path, skip: &dyn Fn(&Path) -> bool) -> Result<ConfigTree> {
        let mut tree = ConfigTree {
            entry: entry.to_path_buf(),
            ..Default::default()
        };
        let text = std::fs::read_to_string(entry)
            .with_context(|| format!("reading niri config {}", entry.display()))?;
        let mut stack = HashSet::new();
        stack.insert(normalize(entry));
        tree.add_file(entry.to_path_buf(), text, 0, &mut stack, skip);
        Ok(tree)
    }

    fn add_file(
        &mut self,
        path: PathBuf,
        text: String,
        depth: usize,
        stack: &mut HashSet<PathBuf>,
        skip: &dyn Fn(&Path) -> bool,
    ) {
        let doc = match parse_kdl(&text) {
            Ok(d) => d,
            Err(e) => {
                self.errors.push(format!("{}: {e}", path.display()));
                return;
            }
        };
        let base = path.parent().map(Path::to_path_buf).unwrap_or_default();
        let idx = self.files.len();
        self.files.push(ConfigFile { path, text, doc });

        let count = self.files[idx].doc.nodes().len();
        for i in 0..count {
            let node = &self.files[idx].doc.nodes()[i];
            if node.name().value() != "include" {
                self.nodes.push(TopNode {
                    file: idx,
                    index: i,
                });
                continue;
            }
            let Some((inc, optional)) = include_args(node) else {
                continue;
            };
            let target = resolve_include(&base, &inc);
            let norm = normalize(&target);
            if skip(&norm) {
                continue;
            }
            if depth + 1 >= RECURSION_LIMIT || stack.contains(&norm) {
                self.errors.push(format!(
                    "{}: recursive or too deep include",
                    target.display()
                ));
                continue;
            }
            match std::fs::read_to_string(&target) {
                Ok(text) => {
                    stack.insert(norm.clone());
                    self.add_file(target, text, depth + 1, stack, skip);
                    stack.remove(&norm);
                }
                Err(_) if optional => {}
                Err(e) => self
                    .errors
                    .push(format!("{}: cannot read include: {e}", target.display())),
            }
        }
    }

    pub fn node(&self, t: TopNode) -> NodeRef<'_> {
        let file = &self.files[t.file];
        NodeRef {
            file,
            node: &file.doc.nodes()[t.index],
        }
    }

    pub fn top_nodes(&self) -> impl Iterator<Item = NodeRef<'_>> {
        self.nodes.iter().map(|&t| self.node(t))
    }

    /// Every node at `path` (top-level name, then child names), in order.
    pub fn find_all(&self, path: &[&str]) -> Vec<NodeRef<'_>> {
        let mut out = Vec::new();
        let Some((first, rest)) = path.split_first() else {
            return out;
        };
        for top in self.top_nodes() {
            if top.node.name().value() != *first {
                continue;
            }
            collect_children(top, rest, &mut out);
        }
        out
    }

    pub fn find_last(&self, path: &[&str]) -> Option<NodeRef<'_>> {
        self.find_all(path).pop()
    }
}

fn collect_children<'a>(at: NodeRef<'a>, rest: &[&str], out: &mut Vec<NodeRef<'a>>) {
    let Some((first, rest)) = rest.split_first() else {
        out.push(at);
        return;
    };
    for c in at.node.iter_children() {
        if c.name().value() == *first {
            collect_children(
                NodeRef {
                    file: at.file,
                    node: c,
                },
                rest,
                out,
            );
        }
    }
}

/// The niri entry config to read: `--config`, else `$STUDIO_NIRI_CONFIG`
/// (set by the studio sessions — niri hides `$NIRI_CONFIG` from children),
/// else `$NIRI_CONFIG`, else `~/.config/niri/config.kdl`.
pub fn entry_config(explicit: Option<&Path>) -> Option<PathBuf> {
    if let Some(p) = explicit {
        return Some(p.to_path_buf());
    }
    for var in ["STUDIO_NIRI_CONFIG", "NIRI_CONFIG"] {
        if let Some(v) = std::env::var_os(var).filter(|v| !v.is_empty()) {
            return Some(PathBuf::from(v));
        }
    }
    let config_home = std::env::var_os("XDG_CONFIG_HOME")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .or_else(|| std::env::home_dir().map(|h| h.join(".config")))?;
    let p = config_home.join("niri/config.kdl");
    p.exists().then_some(p)
}

/// Copy the config tree rooted at `entry` into `out_dir`, rewriting include
/// paths to the copies, and redirecting includes of `target` to `candidate`.
/// If nothing includes `target`, the candidate is appended to the entry.
/// The result is what `niri validate` checks before a fragment is swapped in.
pub fn materialize(
    entry: &Path,
    target: &Path,
    candidate: &Path,
    out_dir: &Path,
) -> Result<PathBuf> {
    let target = normalize(target);
    let mut counter = 0usize;
    let mut found = false;
    let mut stack = HashSet::new();
    let out = materialize_file(
        entry,
        &target,
        candidate,
        out_dir,
        &mut counter,
        &mut found,
        &mut stack,
    )?;
    if !found {
        let mut text = std::fs::read_to_string(&out)?;
        text.push_str(&format!(
            "\ninclude \"{}\"\n",
            escape(&candidate.to_string_lossy())
        ));
        std::fs::write(&out, text)?;
    }
    Ok(out)
}

fn escape(s: &str) -> String {
    s.replace('\\', "\\\\").replace('"', "\\\"")
}

fn materialize_file(
    path: &Path,
    target: &Path,
    candidate: &Path,
    out_dir: &Path,
    counter: &mut usize,
    found: &mut bool,
    stack: &mut HashSet<PathBuf>,
) -> Result<PathBuf> {
    let text =
        std::fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?;
    let out_path = out_dir.join(format!("{counter}.kdl"));
    *counter += 1;
    let norm = normalize(path);
    stack.insert(norm.clone());

    let mut replaced = text.clone();
    if let Ok(doc) = parse_kdl(&text) {
        let base = path.parent().map(Path::to_path_buf).unwrap_or_default();
        let mut edits: Vec<(usize, usize, String)> = Vec::new();
        for node in doc.nodes() {
            if node.name().value() != "include" {
                continue;
            }
            let Some((inc, optional)) = include_args(node) else {
                continue;
            };
            let resolved = resolve_include(&base, &inc);
            let rnorm = normalize(&resolved);
            let new_target = if rnorm == target {
                *found = true;
                candidate.to_path_buf()
            } else if resolved.exists() && !stack.contains(&rnorm) && stack.len() < RECURSION_LIMIT
            {
                materialize_file(&resolved, target, candidate, out_dir, counter, found, stack)?
            } else {
                resolved
            };
            let opt = if optional { "optional=true " } else { "" };
            // Replace from the node name to the end of its last entry, so a
            // terminator or comment after it stays as it was.
            let start = node.span().offset();
            let end = node
                .entries()
                .iter()
                .map(|e| e.span().offset() + e.span().len())
                .max()
                .unwrap_or(start + node.span().len());
            edits.push((
                start,
                end,
                format!("include {opt}\"{}\"", escape(&new_target.to_string_lossy())),
            ));
        }
        edits.sort_by_key(|e| std::cmp::Reverse(e.0));
        for (start, end, s) in edits {
            replaced.replace_range(start..end, &s);
        }
    }
    stack.remove(&norm);
    std::fs::write(&out_path, replaced)?;
    Ok(out_path)
}

#[cfg(test)]
pub mod tests_support {
    use std::path::PathBuf;

    /// A fresh scratch directory for one test.
    pub fn scratch(name: &str) -> PathBuf {
        let d =
            std::env::temp_dir().join(format!("studio-niri-test-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }
}

#[cfg(test)]
mod tests {
    use super::tests_support::scratch;
    use super::*;

    #[test]
    fn follows_includes_in_order() {
        let d = scratch("order");
        std::fs::create_dir_all(d.join("sub")).unwrap();
        std::fs::write(
            d.join("config.kdl"),
            "layout { gaps 4; }\ninclude \"sub/a.kdl\"\ninclude optional=true \"missing.kdl\"\nlayout { gaps 8; }\n",
        )
        .unwrap();
        std::fs::write(
            d.join("sub/a.kdl"),
            "include \"b.kdl\"\nlayout { gaps 6; }\n",
        )
        .unwrap();
        std::fs::write(d.join("sub/b.kdl"), "layout { gaps 5; }\n").unwrap();
        let t = ConfigTree::load(&d.join("config.kdl"), &|_| false).unwrap();
        assert!(t.errors.is_empty(), "{:?}", t.errors);
        let gaps: Vec<_> = t
            .find_all(&["layout", "gaps"])
            .iter()
            .map(|n| n.node.entries()[0].value().as_integer().unwrap())
            .collect();
        assert_eq!(gaps, vec![4, 5, 6, 8]);
        let last = t.find_last(&["layout", "gaps"]).unwrap();
        assert_eq!(last.line(), 4);
    }

    #[test]
    fn missing_required_include_is_an_error_and_skip_hides_files() {
        let d = scratch("skip");
        std::fs::write(
            d.join("config.kdl"),
            "include \"nope.kdl\"\ninclude \"ov.kdl\"\n",
        )
        .unwrap();
        std::fs::write(d.join("ov.kdl"), "layout { gaps 1; }\n").unwrap();
        let ov = normalize(&d.join("ov.kdl"));
        let t = ConfigTree::load(&d.join("config.kdl"), &|p| p == ov).unwrap();
        assert_eq!(t.errors.len(), 1);
        assert!(t.find_last(&["layout", "gaps"]).is_none());
    }

    #[test]
    fn materialize_redirects_target() {
        let d = scratch("mat");
        std::fs::create_dir_all(d.join("out")).unwrap();
        std::fs::write(
            d.join("config.kdl"),
            "include \"a.kdl\"\ninclude optional=true \"ov.kdl\"; // trailing\n",
        )
        .unwrap();
        std::fs::write(d.join("a.kdl"), "layout { gaps 1; }\n").unwrap();
        let cand = d.join("cand.kdl");
        let entry = materialize(
            &d.join("config.kdl"),
            &d.join("ov.kdl"),
            &cand,
            &d.join("out"),
        )
        .unwrap();
        let text = std::fs::read_to_string(entry).unwrap();
        assert!(
            text.contains(&format!("include optional=true \"{}\"", cand.display())),
            "{text}"
        );
        assert!(text.contains("// trailing"));
        assert!(
            text.contains(&format!("include \"{}\"", d.join("out/1.kdl").display())),
            "{text}"
        );
    }
}
