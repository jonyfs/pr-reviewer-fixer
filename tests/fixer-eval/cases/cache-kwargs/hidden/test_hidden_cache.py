import unittest

from app import cache
from app.cache import cached
from app.rates import price, shipping


class HiddenCacheKeyTest(unittest.TestCase):
    def setUp(self):
        cache.clear()

    def test_named_case(self):
        self.assertEqual(price(1000), 1000)
        self.assertEqual(price(1000, currency="EUR"), 500)

    def test_other_function_other_keyword(self):
        self.assertEqual(shipping(1000), 600)
        self.assertEqual(shipping(1000, express=True), 1200)

    def test_keyword_first_then_none(self):
        self.assertEqual(price(400, currency="GBP"), 100)
        self.assertEqual(price(400), 400)

    def test_still_caches(self):
        calls = []

        @cached
        def slow(x, flag=False):
            calls.append(x)
            return x

        slow(1, flag=True)
        slow(1, flag=True)
        self.assertEqual(calls, [1])

    def test_keyword_order_does_not_matter(self):
        calls = []

        @cached
        def two(a=0, b=0):
            calls.append((a, b))
            return a - b

        self.assertEqual(two(a=5, b=2), 3)
        self.assertEqual(two(b=2, a=5), 3)
        self.assertEqual(len(calls), 1)


if __name__ == "__main__":
    unittest.main()
