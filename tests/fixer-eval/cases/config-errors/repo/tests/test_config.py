import unittest

from app.config import DEFAULTS, load
from app.server import banner


class ConfigTest(unittest.TestCase):
    def test_empty_is_defaults(self):
        self.assertEqual(load(""), DEFAULTS)

    def test_values(self):
        self.assertEqual(load("port = 9000\ndebug = true"), {"port": 9000, "timeout": 30, "debug": True})

    def test_comments(self):
        self.assertEqual(load("# a comment\ntimeout = 5  # seconds"), {"port": 8080, "timeout": 5, "debug": False})

    def test_banner(self):
        self.assertEqual(banner("port = 1"), "starting with port=1 timeout=30 debug=False")


if __name__ == "__main__":
    unittest.main()
