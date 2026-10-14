"""The facet model: facets, themes, variants and the user layer
(docs/THEME-ARCHITECTURE.md).

  model.py       ids, selections, merge rules, the catalog (v2 packs, the library's
                 user pack, v1 packs through pack.v1_documents)
  refs.py        polar values and @color references
  resolve.py     layers → one resolved document per kind (+ sources, errors)
  schema.py      the JSON Schema subset that checks resolved data (schemas/)
  appearance.py  <state>/appearance.json: selection, pins, customizations, saves
  compat.py      resolved facets → today's v1 bundle (until phase B's units)
"""

from .model import KINDS, Catalog, FacetError  # noqa: F401
