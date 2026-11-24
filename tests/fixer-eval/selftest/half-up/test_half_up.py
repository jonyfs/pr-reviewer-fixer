import unittest

from app.pricing import total_cents


class HalfUpTest(unittest.TestCase):
    def test_half_rounds_up(self):
        self.assertEqual(total_cents([25], 50), 13)


if __name__ == "__main__":
    unittest.main()
