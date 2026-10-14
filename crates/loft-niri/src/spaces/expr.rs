//! `${…}` interpolation in space templates.
//!
//! A string that is exactly one `${expr}` becomes the expression's value
//! (any JSON type: `"match": "${previewMatch}"` can be an object or null);
//! otherwise each `${expr}` is replaced by its text.
//!
//! Expressions: identifiers (the params, `id`, `state`, `home`), string
//! literals ('…' or "…"), numbers, `true` / `false` / `null`, `==` / `!=`,
//! `!`, `&&` / `||` (JavaScript semantics: they return an operand),
//! parentheses, and the helpers `slug(s)`, `basename(path)`, `isUrl(s)` and
//! `re(s)` (s as a regex literal).

use anyhow::{Result, bail};
use serde_json::{Map, Value};

pub type Ctx = Map<String, Value>;

pub fn truthy(v: &Value) -> bool {
    match v {
        Value::Null => false,
        Value::Bool(b) => *b,
        Value::Number(n) => n.as_f64().is_some_and(|f| f != 0.0),
        Value::String(s) => !s.is_empty(),
        Value::Array(_) | Value::Object(_) => true,
    }
}

pub fn text(v: &Value) -> String {
    match v {
        Value::Null => String::new(),
        Value::String(s) => s.clone(),
        other => other.to_string(),
    }
}

/// `My Project!` → `my-project`.
pub fn slug(s: &str) -> String {
    let mut out = String::new();
    for c in s.chars() {
        if c.is_alphanumeric() {
            out.extend(c.to_lowercase());
        } else if !out.is_empty() && !out.ends_with('-') {
            out.push('-');
        }
    }
    out.trim_end_matches('-').to_string()
}

pub fn basename(s: &str) -> String {
    s.trim_end_matches('/')
        .rsplit('/')
        .next()
        .unwrap_or("")
        .to_string()
}

pub fn is_url(s: &str) -> bool {
    let l = s.trim_start().to_ascii_lowercase();
    l.starts_with("http://") || l.starts_with("https://")
}

/// Interpolate every string in `v` (recursively).
pub fn interpolate(v: &Value, ctx: &Ctx) -> Result<Value> {
    Ok(match v {
        Value::String(s) => interpolate_str(s, ctx)?,
        Value::Array(a) => Value::Array(
            a.iter()
                .map(|x| interpolate(x, ctx))
                .collect::<Result<_>>()?,
        ),
        Value::Object(m) => {
            let mut out = Map::new();
            for (k, x) in m {
                out.insert(k.clone(), interpolate(x, ctx)?);
            }
            Value::Object(out)
        }
        other => other.clone(),
    })
}

pub fn interpolate_str(s: &str, ctx: &Ctx) -> Result<Value> {
    let Some(first) = s.find("${") else {
        return Ok(Value::String(s.to_string()));
    };
    // Exactly one `${…}` spanning the whole string: keep the value's type.
    if first == 0
        && let Some(end) = closing(s, 2)
        && end == s.len() - 1
    {
        return eval(&s[2..end], ctx);
    }
    let mut out = String::new();
    let mut rest = s;
    while let Some(i) = rest.find("${") {
        out.push_str(&rest[..i]);
        let Some(end) = closing(rest, i + 2) else {
            bail!("unclosed `${{` in {s:?}");
        };
        out.push_str(&text(&eval(&rest[i + 2..end], ctx)?));
        rest = &rest[end + 1..];
    }
    out.push_str(rest);
    Ok(Value::String(out))
}

/// The `}` closing an interpolation starting at `from` (skips quoted strings).
fn closing(s: &str, from: usize) -> Option<usize> {
    let b = s.as_bytes();
    let mut quote = None;
    let mut i = from;
    while i < b.len() {
        match (quote, b[i]) {
            (Some(q), c) if c == q => quote = None,
            (Some(_), b'\\') => i += 1,
            (None, b'\'' | b'"') => quote = Some(b[i]),
            (None, b'}') => return Some(i),
            _ => {}
        }
        i += 1;
    }
    None
}

#[derive(Debug, Clone, PartialEq)]
enum Tok {
    Ident(String),
    Str(String),
    Num(f64),
    Op(&'static str),
}

fn lex(src: &str) -> Result<Vec<Tok>> {
    let mut toks = Vec::new();
    let cs: Vec<char> = src.chars().collect();
    let mut i = 0;
    while i < cs.len() {
        let c = cs[i];
        if c.is_whitespace() {
            i += 1;
        } else if c == '\'' || c == '"' {
            let mut s = String::new();
            i += 1;
            while i < cs.len() && cs[i] != c {
                if cs[i] == '\\' && i + 1 < cs.len() {
                    i += 1;
                }
                s.push(cs[i]);
                i += 1;
            }
            if i >= cs.len() {
                bail!("unterminated string in `{src}`");
            }
            i += 1;
            toks.push(Tok::Str(s));
        } else if c.is_ascii_digit() {
            let start = i;
            while i < cs.len() && (cs[i].is_ascii_digit() || cs[i] == '.') {
                i += 1;
            }
            let s: String = cs[start..i].iter().collect();
            toks.push(Tok::Num(s.parse()?));
        } else if c.is_alphabetic() || c == '_' {
            let start = i;
            while i < cs.len() && (cs[i].is_alphanumeric() || cs[i] == '_') {
                i += 1;
            }
            toks.push(Tok::Ident(cs[start..i].iter().collect()));
        } else {
            let two: String = cs[i..(i + 2).min(cs.len())].iter().collect();
            let op = match two.as_str() {
                "==" => Some("=="),
                "!=" => Some("!="),
                "&&" => Some("&&"),
                "||" => Some("||"),
                _ => None,
            };
            if let Some(op) = op {
                toks.push(Tok::Op(op));
                i += 2;
                continue;
            }
            toks.push(Tok::Op(match c {
                '!' => "!",
                '(' => "(",
                ')' => ")",
                ',' => ",",
                _ => bail!("unexpected `{c}` in `{src}`"),
            }));
            i += 1;
        }
    }
    Ok(toks)
}

struct Parser<'a> {
    toks: Vec<Tok>,
    pos: usize,
    ctx: &'a Ctx,
    src: &'a str,
}

impl Parser<'_> {
    fn peek_op(&self, op: &str) -> bool {
        matches!(self.toks.get(self.pos), Some(Tok::Op(o)) if *o == op)
    }

    fn expect_op(&mut self, op: &str) -> Result<()> {
        if !self.peek_op(op) {
            bail!("expected `{op}` in `{}`", self.src);
        }
        self.pos += 1;
        Ok(())
    }

    fn or(&mut self) -> Result<Value> {
        let mut v = self.and()?;
        while self.peek_op("||") {
            self.pos += 1;
            let r = self.and()?;
            if !truthy(&v) {
                v = r;
            }
        }
        Ok(v)
    }

    fn and(&mut self) -> Result<Value> {
        let mut v = self.unary()?;
        while self.peek_op("&&") {
            self.pos += 1;
            let r = self.unary()?;
            if truthy(&v) {
                v = r;
            }
        }
        Ok(v)
    }

    fn unary(&mut self) -> Result<Value> {
        if self.peek_op("!") {
            self.pos += 1;
            return Ok(Value::Bool(!truthy(&self.unary()?)));
        }
        self.cmp()
    }

    fn cmp(&mut self) -> Result<Value> {
        let l = self.primary()?;
        for (op, eq) in [("==", true), ("!=", false)] {
            if self.peek_op(op) {
                self.pos += 1;
                let r = self.primary()?;
                return Ok(Value::Bool((l == r) == eq));
            }
        }
        Ok(l)
    }

    fn primary(&mut self) -> Result<Value> {
        let Some(t) = self.toks.get(self.pos).cloned() else {
            bail!("unexpected end of `{}`", self.src);
        };
        self.pos += 1;
        match t {
            Tok::Str(s) => Ok(Value::String(s)),
            Tok::Num(n) => Ok(serde_json::Number::from_f64(n).map_or(Value::Null, Value::Number)),
            Tok::Op("(") => {
                let v = self.or()?;
                self.expect_op(")")?;
                Ok(v)
            }
            Tok::Ident(name) if self.peek_op("(") => {
                self.pos += 1;
                let mut args = Vec::new();
                if !self.peek_op(")") {
                    args.push(self.or()?);
                    while self.peek_op(",") {
                        self.pos += 1;
                        args.push(self.or()?);
                    }
                }
                self.expect_op(")")?;
                call(&name, &args)
            }
            Tok::Ident(name) => match name.as_str() {
                "true" => Ok(Value::Bool(true)),
                "false" => Ok(Value::Bool(false)),
                "null" => Ok(Value::Null),
                _ => match self.ctx.get(&name) {
                    Some(v) => Ok(v.clone()),
                    None => bail!("unknown name `{name}` in `{}`", self.src),
                },
            },
            Tok::Op(o) => bail!("unexpected `{o}` in `{}`", self.src),
        }
    }
}

fn call(name: &str, args: &[Value]) -> Result<Value> {
    let [arg] = args else {
        bail!("{name}() takes one argument");
    };
    let s = text(arg);
    Ok(match name {
        "slug" => Value::String(slug(&s)),
        "basename" => Value::String(basename(&s)),
        "isUrl" => Value::Bool(is_url(&s)),
        "re" => Value::String(crate::render::regex_literal(&s)),
        _ => bail!("unknown function `{name}`"),
    })
}

pub fn eval(src: &str, ctx: &Ctx) -> Result<Value> {
    let mut p = Parser {
        toks: lex(src)?,
        pos: 0,
        ctx,
        src,
    };
    let v = p.or()?;
    if p.pos != p.toks.len() {
        bail!("trailing input in `{src}`");
    }
    Ok(v)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn ctx() -> Ctx {
        json!({
            "name": "Loft Shell", "dir": "~/Development/loft/", "editor": "zed",
            "preview": "dx serve", "docs": "", "previewMatch": { "appId": "^x$" }, "id": "proj-loft"
        })
        .as_object()
        .unwrap()
        .clone()
    }

    #[test]
    fn helpers() {
        assert_eq!(slug("Loft Shell!"), "loft-shell");
        assert_eq!(slug("  --A__b  c"), "a-b-c");
        assert_eq!(basename("~/Development/loft/"), "loft");
        assert_eq!(basename("loft"), "loft");
        assert!(is_url("https://x") && is_url("HTTP://x") && !is_url("dx serve"));
    }

    #[test]
    fn whole_string_keeps_the_type() {
        let c = ctx();
        assert_eq!(
            interpolate_str("${previewMatch}", &c).unwrap(),
            json!({ "appId": "^x$" })
        );
        assert_eq!(interpolate_str("${docs}", &c).unwrap(), json!(""));
        assert_eq!(
            interpolate_str("${editor == 'zed'}", &c).unwrap(),
            json!(true)
        );
        assert_eq!(
            interpolate_str("${editor != \"zed\"}", &c).unwrap(),
            json!(false)
        );
    }

    #[test]
    fn text_substitution() {
        let c = ctx();
        assert_eq!(
            interpolate_str("^loft\\.${id}\\.debug$", &c).unwrap(),
            json!("^loft\\.proj-loft\\.debug$")
        );
        assert_eq!(
            interpolate_str("Project: ${name} (${slug(name)})", &c).unwrap(),
            json!("Project: Loft Shell (loft-shell)")
        );
        assert_eq!(
            interpolate_str("^${re(basename('a.b+c'))}\\b", &c).unwrap(),
            json!("^a\\.b\\+c\\b")
        );
        // A `}` inside a quoted literal doesn't end the interpolation.
        assert_eq!(interpolate_str("${'}'}x", &c).unwrap(), json!("}x"));
    }

    #[test]
    fn logic() {
        let c = ctx();
        let e = |s: &str| eval(s, &c).unwrap();
        assert_eq!(e("preview && !isUrl(preview)"), json!(true));
        assert_eq!(e("docs && 'x'"), json!(""));
        assert_eq!(e("docs || 'fallback'"), json!("fallback"));
        assert_eq!(e("!(editor == 'zed' || docs)"), json!(false));
        assert_eq!(e("null"), json!(null));
        assert!(eval("nope", &c).is_err());
        assert!(eval("slug(name", &c).is_err());
        assert!(eval("name name", &c).is_err());
        assert!(interpolate_str("${name", &c).is_err());
    }
}
