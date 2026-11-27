import unittest

from app.config import ConfigError, load


class HiddenConfigErrorTest(unittest.TestCase):
    def test_named_case(self):
        with self.assertRaises(ConfigError):
            load("port = abc")

    def test_bad_timeout(self):
        with self.assertRaises(ConfigError):
            load("timeout = soon")

    def test_line_without_equals(self):
        with self.assertRaises(ConfigError):
            load("port 9000")

    def test_unknown_setting(self):
        with self.assertRaises(ConfigError):
            load("colour = red")

    def test_bad_line_after_good_ones(self):
        with self.assertRaises(ConfigError):
            load("port = 9000\ntimeout = x")

    def test_good_file_still_loads(self):
        self.assertEqual(load("port = 9000\ntimeout = 5\ndebug = no"), {"port": 9000, "timeout": 5, "debug": False})


if __name__ == "__main__":
    unittest.main()
