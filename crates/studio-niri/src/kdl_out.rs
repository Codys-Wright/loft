//! A tiny KDL v1 writer.
//!
//! niri parses its config with knuffel (KDL v1); the `kdl` crate writes v2,
//! so the fragment we generate is emitted by hand. Nodes copied from the
//! user's config are converted from `kdl::KdlNode` into [`Node`].

use std::fmt::Write as _;

#[derive(Debug, Clone, PartialEq)]
pub enum Val {
    Str(String),
    Int(i64),
    /// Always written with a decimal point (knuffel won't decode `1` as f64).
    Float(f64),
    /// Written as an integer when integral (niri's `FloatOrInt` fields).
    Number(f64),
    Bool(bool),
    Null,
}

impl Val {
    fn write(&self, out: &mut String) {
        match self {
            Val::Str(s) => write_str(out, s),
            Val::Int(i) => {
                let _ = write!(out, "{i}");
            }
            Val::Float(f) => {
                let _ = write!(out, "{f:?}");
            }
            Val::Number(f) => {
                if f.fract() == 0.0 && f.abs() < 1e15 {
                    let _ = write!(out, "{}", *f as i64);
                } else {
                    let _ = write!(out, "{f:?}");
                }
            }
            Val::Bool(b) => {
                let _ = write!(out, "{b}");
            }
            Val::Null => out.push_str("null"),
        }
    }

    pub fn from_kdl(v: &kdl::KdlValue) -> Val {
        match v {
            kdl::KdlValue::String(s) => Val::Str(s.clone()),
            kdl::KdlValue::Integer(i) => Val::Int(*i as i64),
            kdl::KdlValue::Float(f) => Val::Float(*f),
            kdl::KdlValue::Bool(b) => Val::Bool(*b),
            kdl::KdlValue::Null => Val::Null,
        }
    }
}

fn write_str(out: &mut String, s: &str) {
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c => out.push(c),
        }
    }
    out.push('"');
}

fn is_bare_ident(s: &str) -> bool {
    !s.is_empty()
        && !s.starts_with(|c: char| c.is_ascii_digit())
        && !matches!(s, "true" | "false" | "null")
        && s.chars().all(|c| {
            !c.is_whitespace()
                && !matches!(
                    c,
                    '"' | '\\'
                        | '{'
                        | '}'
                        | '('
                        | ')'
                        | ';'
                        | '='
                        | '['
                        | ']'
                        | '/'
                        | '<'
                        | '>'
                        | ','
                )
        })
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct Node {
    pub name: String,
    pub args: Vec<Val>,
    pub props: Vec<(String, Val)>,
    pub children: Vec<Node>,
}

impl Node {
    pub fn new(name: impl Into<String>) -> Self {
        Node {
            name: name.into(),
            ..Default::default()
        }
    }

    pub fn arg(mut self, v: Val) -> Self {
        self.args.push(v);
        self
    }

    pub fn prop(mut self, k: impl Into<String>, v: Val) -> Self {
        self.props.push((k.into(), v));
        self
    }

    pub fn child(mut self, n: Node) -> Self {
        self.children.push(n);
        self
    }

    /// The child with this name, created (appended) when missing.
    pub fn child_mut(&mut self, name: &str) -> &mut Node {
        if let Some(i) = self.children.iter().position(|c| c.name == name) {
            &mut self.children[i]
        } else {
            self.children.push(Node::new(name));
            self.children.last_mut().unwrap()
        }
    }

    pub fn remove_children(&mut self, name: &str) {
        self.children.retain(|c| c.name != name);
    }

    pub fn from_kdl(n: &kdl::KdlNode) -> Node {
        let mut out = Node::new(n.name().value());
        for e in n.entries() {
            let v = Val::from_kdl(e.value());
            match e.name() {
                Some(k) => out.props.push((k.value().to_string(), v)),
                None => out.args.push(v),
            }
        }
        out.children = n.iter_children().map(Node::from_kdl).collect();
        out
    }

    pub fn write(&self, out: &mut String, indent: usize) {
        out.push_str(&"    ".repeat(indent));
        if is_bare_ident(&self.name) {
            out.push_str(&self.name);
        } else {
            write_str(out, &self.name);
        }
        for a in &self.args {
            out.push(' ');
            a.write(out);
        }
        for (k, v) in &self.props {
            out.push(' ');
            if is_bare_ident(k) {
                out.push_str(k);
            } else {
                write_str(out, k);
            }
            out.push('=');
            v.write(out);
        }
        if self.children.is_empty() {
            out.push('\n');
            return;
        }
        out.push_str(" {\n");
        for c in &self.children {
            c.write(out, indent + 1);
        }
        out.push_str(&"    ".repeat(indent));
        out.push_str("}\n");
    }
}

pub fn write_doc(nodes: &[Node]) -> String {
    let mut out = String::new();
    for (i, n) in nodes.iter().enumerate() {
        if i > 0 {
            out.push('\n');
        }
        n.write(&mut out, 0);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn writes_nested_nodes() {
        let n = Node::new("output")
            .arg(Val::Str("Dell Inc. DELL \"U\" 1".into()))
            .child(Node::new("scale").arg(Val::Number(1.0)))
            .child(
                Node::new("position")
                    .prop("x", Val::Int(0))
                    .prop("y", Val::Int(-1440)),
            )
            .child(Node::new("off"));
        let mut s = String::new();
        n.write(&mut s, 0);
        assert_eq!(
            s,
            "output \"Dell Inc. DELL \\\"U\\\" 1\" {\n    scale 1\n    position x=0 y=-1440\n    off\n}\n"
        );
    }

    #[test]
    fn floats_keep_a_decimal_point() {
        let mut s = String::new();
        Node::new("proportion")
            .arg(Val::Float(1.0))
            .write(&mut s, 0);
        Node::new("gaps").arg(Val::Number(12.5)).write(&mut s, 0);
        Node::new("Mod+T").write(&mut s, 0);
        Node::new("odd name").write(&mut s, 0);
        assert_eq!(s, "proportion 1.0\ngaps 12.5\nMod+T\n\"odd name\"\n");
    }
}
