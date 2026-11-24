import unittest

from app.retry import call_with_retry


class RetryTest(unittest.TestCase):
    def test_returns_first_success(self):
        self.assertEqual(call_with_retry(lambda: 5), 5)

    def test_reraises(self):
        def boom():
            raise KeyError("x")

        with self.assertRaises(KeyError):
            call_with_retry(boom)


if __name__ == "__main__":
    unittest.main()
