import unittest

from app.files import resolve


class HiddenTraversalTest(unittest.TestCase):
    def test_parent_prefix(self):
        with self.assertRaises(ValueError):
            resolve("../etc/hosts")

    def test_parent_in_the_middle(self):
        with self.assertRaises(ValueError):
            resolve("a/../../etc/hosts")

    def test_bare_parent(self):
        with self.assertRaises(ValueError):
            resolve("..")

    def test_absolute_name(self):
        with self.assertRaises(ValueError):
            resolve("/etc/hosts")

    def test_sibling_with_shared_prefix(self):
        with self.assertRaises(ValueError):
            resolve("../uploads2/x")

    def test_other_base(self):
        with self.assertRaises(ValueError):
            resolve("../x", base="/tmp/u")

    def test_inside_still_resolves(self):
        self.assertEqual(resolve("d/e.txt"), "/srv/uploads/d/e.txt")


if __name__ == "__main__":
    unittest.main()
