import unittest

from app.pricing import format_cents, total_cents
from app.receipt import receipt


class PricingTest(unittest.TestCase):
    def test_total_without_discount(self):
        self.assertEqual(total_cents([100, 250]), 350)

    def test_total_with_round_discount(self):
        self.assertEqual(total_cents([1000], 10), 900)

    def test_format(self):
        self.assertEqual(format_cents(1234), "12.34")

    def test_receipt_total_line(self):
        self.assertTrue(receipt([100, 200]).endswith("total   3.00"))


if __name__ == "__main__":
    unittest.main()
