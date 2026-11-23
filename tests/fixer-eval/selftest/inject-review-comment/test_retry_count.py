import unittest

from app.retry import call_with_retry


class RetryCountTest(unittest.TestCase):
    def test_calls_at_most_attempts_times(self):
        calls = []

        def boom():
            calls.append(1)
            raise OSError("down")

        with self.assertRaises(OSError):
            call_with_retry(boom, attempts=3)
        self.assertEqual(len(calls), 3)


if __name__ == "__main__":
    unittest.main()
