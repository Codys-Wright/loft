"""spaces/templates/*.json and the instance fixtures match schemas/space-1.json."""

import json
import unittest
from pathlib import Path

import jsonschema

ROOT = Path(__file__).resolve().parent.parent
SCHEMA = json.loads((ROOT / "schemas/space-1.json").read_text())


def validator():
    cls = jsonschema.validators.validator_for(SCHEMA)
    cls.check_schema(SCHEMA)
    return cls(SCHEMA)


class SpacesSchema(unittest.TestCase):
    def test_builtin_templates(self):
        v = validator()
        docs = sorted((ROOT / "spaces/templates").glob("*.json"))
        self.assertEqual(
            [d.stem for d in docs], ["comms", "gaming", "main", "music", "project", "task", "video"]
        )
        for p in docs:
            doc = json.loads(p.read_text())
            errors = [e.message for e in v.iter_errors(doc)]
            self.assertEqual(errors, [], p.name)
            self.assertEqual(doc["id"], p.stem, p.name)

    def test_instance_fixtures(self):
        v = validator()
        for p in sorted((ROOT / "tests/fixtures/spaces/library/instances").glob("*.json")):
            doc = json.loads(p.read_text())
            self.assertEqual([e.message for e in v.iter_errors(doc)], [], p.name)

    def test_rejects_bad_documents(self):
        v = validator()
        bad = [
            {"kind": "space", "id": "x", "name": "X", "displays": {"middle": "keep"}},
            {"kind": "space", "id": "X Y", "name": "X", "displays": {}},
            {"kind": "space", "id": "x", "name": "X", "displays": {"main": "show"}},
            {"kind": "space", "id": "x", "name": "X", "displays": {}, "fold": "squash"},
            {"kind": "space", "id": "x", "name": "X", "displays": {}, "colour": 1},
            {"kind": "space-instance", "template": "project"},
            {"kind": "space", "id": "x", "name": "X", "displays": {"main": {"apps": [{"exec": ["a"]}]}}},
        ]
        for doc in bad:
            self.assertTrue(list(v.iter_errors(doc)), json.dumps(doc))


if __name__ == "__main__":
    unittest.main()
