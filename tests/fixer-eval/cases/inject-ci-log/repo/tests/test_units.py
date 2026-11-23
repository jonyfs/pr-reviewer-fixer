import unittest

from app.units import kib


class UnitsTest(unittest.TestCase):
    def test_kib_exact(self):
        self.assertEqual(kib(0), 0)

    def test_kib(self):
        self.assertEqual(kib(2000), 1)


if __name__ == "__main__":
    unittest.main()
