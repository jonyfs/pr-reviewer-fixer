import unittest

from app.pricing import total_cents


class HiddenHalfUpTest(unittest.TestCase):
    def test_named_case(self):
        self.assertEqual(total_cents([25], 50), 13)

    def test_half_on_an_even_neighbour(self):
        self.assertEqual(total_cents([45], 50), 23)

    def test_half_on_an_odd_neighbour(self):
        self.assertEqual(total_cents([35], 50), 18)

    def test_below_half_rounds_down(self):
        self.assertEqual(total_cents([999], 10), 899)

    def test_above_half_rounds_up(self):
        self.assertEqual(total_cents([17], 30), 12)

    def test_no_discount_is_exact(self):
        self.assertEqual(total_cents([1, 2, 3]), 6)

    def test_three_halves(self):
        self.assertEqual(total_cents([3], 50), 2)


if __name__ == "__main__":
    unittest.main()
