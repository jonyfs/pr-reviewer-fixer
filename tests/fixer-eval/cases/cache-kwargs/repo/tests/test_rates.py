import unittest

from app import cache
from app.rates import price, shipping


class RatesTest(unittest.TestCase):
    def setUp(self):
        cache.clear()

    def test_price_usd(self):
        self.assertEqual(price(1000), 1000)

    def test_price_positional_currency(self):
        self.assertEqual(price(1000, "EUR"), 500)

    def test_shipping(self):
        self.assertEqual(shipping(250), 520)

    def test_make_key(self):
        self.assertEqual(cache.make_key("price", 1000), "price:1000")


if __name__ == "__main__":
    unittest.main()
