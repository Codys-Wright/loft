"""`loft spaces` edit commands → `loft-kwin spaces …` (cli/loft/spaces.py)."""

import argparse
import unittest

from loft import spaces


def parse(*argv):
    top = argparse.ArgumentParser()
    sub = top.add_subparsers(dest="cmd")
    spaces.add_parser(sub, lambda ctx: "/tmp/state")
    return top.parse_args(["spaces", *argv])


class EditArgs(unittest.TestCase):
    def test_each_edit_maps_to_loft_kwin(self):
        self.assertEqual(spaces.edit_args(parse("new", "Live", "Sound", "--icon", "audio-card")), ["new", "Live", "Sound", "--icon", "audio-card"])
        self.assertEqual(spaces.edit_args(parse("new", "Video")), ["new", "Video"])
        self.assertEqual(spaces.edit_args(parse("rename", "coding", "Code", "Work")), ["rename", "coding", "Code", "Work"])
        self.assertEqual(spaces.edit_args(parse("icon", "3", "utilities-terminal")), ["icon", "3", "utilities-terminal"])
        self.assertEqual(spaces.edit_args(parse("move", "gaming", "1")), ["move", "gaming", "1"])
        self.assertEqual(spaces.edit_args(parse("order", "music", "coding")), ["order", "music", "coding"])
        self.assertEqual(spaces.edit_args(parse("remove", "Editing", "--yes")), ["remove", "Editing"])

    def test_remove_asks_or_needs_yes(self):
        self.assertTrue(spaces.confirm_remove(parse("remove", "x", "-y"), tty=False))
        with self.assertRaises(spaces.SpacesError):
            spaces.confirm_remove(parse("remove", "x"), tty=False)
        self.assertTrue(spaces.confirm_remove(parse("remove", "x"), ask=lambda q: "y", tty=True))
        self.assertFalse(spaces.confirm_remove(parse("remove", "x"), ask=lambda q: "", tty=True))


if __name__ == "__main__":
    unittest.main()
