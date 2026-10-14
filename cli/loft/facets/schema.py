"""A small JSON Schema (2020-12) checker for schemas/*.json.

The facet schemas use a handful of keywords; checking them here keeps the
resolver's behavior the same with or without the jsonschema module (bare
python3 runs, the Nix CLI). Unknown keywords raise, so a schema can't
silently stop checking something.
"""

from __future__ import annotations

import json
import os
import re
from pathlib import Path

ANNOTATIONS = {"$schema", "$id", "$defs", "$comment", "title", "description", "default", "examples"}
TYPES = {
    "object": dict,
    "array": list,
    "string": str,
    "boolean": bool,
    "null": type(None),
}


def schema_dir() -> Path:
    """<data dir>/schemas ($LOFT_DATA_DIR, default: this tree)."""
    root = os.environ.get("LOFT_DATA_DIR")
    if root and (Path(root) / "schemas").is_dir():
        return Path(root) / "schemas"
    return Path(__file__).resolve().parents[3] / "schemas"


_cache: dict[str, dict] = {}


def load(rel: str) -> dict:
    if rel not in _cache:
        _cache[rel] = json.loads((schema_dir() / rel).read_text(encoding="utf-8"))
    return _cache[rel]


def _is_type(v, t: str) -> bool:
    if t == "number":
        return isinstance(v, (int, float)) and not isinstance(v, bool)
    if t == "integer":
        return isinstance(v, int) and not isinstance(v, bool) or (isinstance(v, float) and v.is_integer())
    return isinstance(v, TYPES[t])


def errors(value, schema: dict, root: dict | None = None, where: str = "") -> list[str]:
    """Every problem with `value`, as `path: message` strings ('' = valid)."""
    root = root if root is not None else schema
    out: list[str] = []
    at = where or "(root)"
    for kw, arg in schema.items():
        if kw in ANNOTATIONS:
            continue
        if kw == "$ref":
            if not arg.startswith("#/$defs/"):
                raise ValueError(f"unsupported $ref {arg}")
            out += errors(value, root["$defs"][arg[len("#/$defs/") :]], root, where)
        elif kw == "type":
            types = arg if isinstance(arg, list) else [arg]
            if not any(_is_type(value, t) for t in types):
                return [f"{at}: expected {' or '.join(types)}, got {json.dumps(value)}"]
        elif kw == "enum":
            if value not in arg:
                out.append(f"{at}: {json.dumps(value)} is not one of {', '.join(json.dumps(a) for a in arg)}")
        elif kw == "const":
            if value != arg:
                out.append(f"{at}: expected {json.dumps(arg)}")
        elif kw in ("minimum", "maximum", "exclusiveMinimum"):
            if _is_type(value, "number"):
                bad = value < arg if kw == "minimum" else value > arg if kw == "maximum" else value <= arg
                if bad:
                    op = {"minimum": "<", "maximum": ">", "exclusiveMinimum": "<="}[kw]
                    out.append(f"{at}: {value} {op} {arg}")
        elif kw == "minLength":
            if isinstance(value, str) and len(value) < arg:
                out.append(f"{at}: shorter than {arg}")
        elif kw == "pattern":
            if isinstance(value, str) and not re.search(arg, value):
                out.append(f"{at}: {json.dumps(value)} doesn't match {arg}")
        elif kw in ("minItems", "maxItems"):
            if isinstance(value, list) and (len(value) < arg if kw == "minItems" else len(value) > arg):
                out.append(f"{at}: {len(value)} items ({kw} {arg})")
        elif kw == "items":
            if isinstance(value, list):
                for i, v in enumerate(value):
                    out += errors(v, arg, root, f"{where}/{i}" if where else str(i))
        elif kw == "required":
            if isinstance(value, dict):
                out += [f"{at}: missing {k}" for k in arg if k not in value]
        elif kw == "minProperties":
            if isinstance(value, dict) and len(value) < arg:
                out.append(f"{at}: expected at least {arg} keys")
        elif kw == "propertyNames":
            if isinstance(value, dict):
                out += [f"{at}: unknown key {k}" for k in value if errors(k, arg, root, where)]
        elif kw == "properties":
            if isinstance(value, dict):
                for k, sub in arg.items():
                    if k in value:
                        out += errors(value[k], sub, root, f"{where}/{k}" if where else k)
        elif kw == "additionalProperties":
            if isinstance(value, dict):
                known = schema.get("properties", {})
                for k, v in value.items():
                    if k in known:
                        continue
                    if arg is False:
                        out.append(f"{where}/{k}: unknown key" if where else f"{k}: unknown key")
                    elif isinstance(arg, dict):
                        out += errors(v, arg, root, f"{where}/{k}" if where else k)
        elif kw in ("anyOf", "oneOf"):
            results = [errors(value, sub, root, where) for sub in arg]
            ok = sum(1 for r in results if not r)
            if ok == 0:
                best = min(results, key=len)
                out += best if len(best) == 1 else [f"{at}: matches none of the allowed forms"]
            elif kw == "oneOf" and ok > 1:
                out.append(f"{at}: matches more than one form")
        else:
            raise ValueError(f"unsupported schema keyword {kw}")
    return out


def check_facet(kind: str, data) -> list[str]:
    return errors(data, load(f"facets/{kind}.json"))


def check_doc(rel: str, doc) -> list[str]:
    return errors(doc, load(rel))
