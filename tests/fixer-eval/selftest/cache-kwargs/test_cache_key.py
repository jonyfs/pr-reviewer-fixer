import unittest

from app import cache
from app.rates import price


class CacheKeyTest(unittest.TestCase):
    def setUp(self):
        cache.clear()

    def test_keyword_currency_is_its_own_entry(self):
        self.assertEqual(price(1000), 1000)
        self.assertEqual(price(1000, currency="EUR"), 500)


if __name__ == "__main__":
    unittest.main()
