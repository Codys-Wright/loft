"""Loft CLI: theme engine (render) and manager. See cli.py."""

import os as _os

# Loft was studio-linux: its STUDIO_* variables still work (for one release)
# when the LOFT_* one isn't set.
for _key, _value in list(_os.environ.items()):
    if _key.startswith("STUDIO_"):
        _os.environ.setdefault("LOFT_" + _key[len("STUDIO_") :], _value)
