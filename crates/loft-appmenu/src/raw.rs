//! Menu properties as they come off the bus, in a form that also round-trips
//! through JSON (test fixtures, `dump`).

use serde::{Deserialize, Serialize};
use zbus::zvariant::Value;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum Prop {
    Bool(bool),
    Int(i64),
    Str(String),
    /// (uu): GMenu `:section` / `:submenu` links.
    Pair([u32; 2]),
    /// aas: DBusMenu `shortcut`.
    Keys(Vec<Vec<String>>),
}

impl Prop {
    pub fn as_str(&self) -> Option<&str> {
        match self {
            Prop::Str(s) => Some(s),
            _ => None,
        }
    }

    pub fn as_bool(&self) -> Option<bool> {
        match self {
            Prop::Bool(b) => Some(*b),
            _ => None,
        }
    }

    pub fn as_int(&self) -> Option<i64> {
        match self {
            Prop::Int(i) => Some(*i),
            _ => None,
        }
    }

    pub fn as_pair(&self) -> Option<(u32, u32)> {
        match self {
            Prop::Pair([a, b]) => Some((*a, *b)),
            _ => None,
        }
    }

    /// For passing a GAction target back (Activate's `av`).
    pub fn to_value(&self) -> Option<Value<'static>> {
        match self {
            Prop::Bool(b) => Some(Value::Bool(*b)),
            Prop::Int(i) => Some(match i32::try_from(*i) {
                Ok(v) => Value::I32(v),
                Err(_) => Value::I64(*i),
            }),
            Prop::Str(s) => Some(Value::from(s.clone())),
            _ => None,
        }
    }

    /// Converts the value types menus use; others (icon pixmaps, …) → None.
    pub fn from_value(v: &Value<'_>) -> Option<Prop> {
        Some(match v {
            Value::Value(inner) => return Prop::from_value(inner),
            Value::Bool(b) => Prop::Bool(*b),
            Value::U8(i) => Prop::Int(i64::from(*i)),
            Value::I16(i) => Prop::Int(i64::from(*i)),
            Value::U16(i) => Prop::Int(i64::from(*i)),
            Value::I32(i) => Prop::Int(i64::from(*i)),
            Value::U32(i) => Prop::Int(i64::from(*i)),
            Value::I64(i) => Prop::Int(*i),
            Value::U64(i) => Prop::Int(i64::try_from(*i).ok()?),
            Value::Str(s) => Prop::Str(s.to_string()),
            Value::ObjectPath(p) => Prop::Str(p.to_string()),
            Value::Structure(s) => match s.fields() {
                [Value::U32(a), Value::U32(b)] => Prop::Pair([*a, *b]),
                _ => return None,
            },
            Value::Array(a) => {
                let mut chords = Vec::new();
                for chord in a.iter() {
                    let chord = match chord {
                        Value::Value(inner) => inner.as_ref(),
                        other => other,
                    };
                    let Value::Array(keys) = chord else {
                        return None;
                    };
                    let mut out = Vec::new();
                    for k in keys.iter() {
                        match k {
                            Value::Str(s) => out.push(s.to_string()),
                            _ => return None,
                        }
                    }
                    chords.push(out);
                }
                Prop::Keys(chords)
            }
            _ => return None,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use zbus::zvariant::{Array, StructureBuilder};

    #[test]
    fn converts_values() {
        assert_eq!(
            Prop::from_value(&Value::from("x")),
            Some(Prop::Str("x".into()))
        );
        assert_eq!(Prop::from_value(&Value::from(true)), Some(Prop::Bool(true)));
        assert_eq!(Prop::from_value(&Value::from(-1i32)), Some(Prop::Int(-1)));
        let wrapped = Value::Value(Box::new(Value::from(5u32)));
        assert_eq!(Prop::from_value(&wrapped), Some(Prop::Int(5)));
        let pair = StructureBuilder::new()
            .add_field(1u32)
            .add_field(2u32)
            .build()
            .unwrap();
        assert_eq!(
            Prop::from_value(&Value::Structure(pair)),
            Some(Prop::Pair([1, 2]))
        );
        let keys: Vec<Vec<&str>> = vec![vec!["Control", "S"]];
        let v = Value::Array(Array::from(
            keys.iter()
                .map(|c| Value::Array(Array::from(c.clone())))
                .collect::<Vec<_>>(),
        ));
        assert_eq!(
            Prop::from_value(&v),
            Some(Prop::Keys(vec![vec!["Control".into(), "S".into()]]))
        );
        // icon-data (ay) is dropped.
        assert_eq!(
            Prop::from_value(&Value::Array(Array::from(vec![1u8, 2]))),
            None
        );
    }

    #[test]
    fn json_round_trip() {
        let props: Vec<Prop> =
            serde_json::from_str(r#"[true, 3, "s", [1, 2], [["Control","Q"]]]"#).unwrap();
        assert_eq!(
            props,
            vec![
                Prop::Bool(true),
                Prop::Int(3),
                Prop::Str("s".into()),
                Prop::Pair([1, 2]),
                Prop::Keys(vec![vec!["Control".into(), "Q".into()]])
            ]
        );
    }
}
