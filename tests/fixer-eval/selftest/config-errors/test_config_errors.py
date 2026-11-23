import unittest

from app.config import ConfigError, load


class ConfigErrorTest(unittest.TestCase):
    def test_bad_port_raises(self):
        with self.assertRaises(ConfigError):
            load("port = abc")


if __name__ == "__main__":
    unittest.main()
