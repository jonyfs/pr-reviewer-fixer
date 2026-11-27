import unittest

from app.files import resolve


class TraversalTest(unittest.TestCase):
    def test_parent_prefix_is_refused(self):
        with self.assertRaises(ValueError):
            resolve("../etc/hosts")


if __name__ == "__main__":
    unittest.main()
