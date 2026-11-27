import unittest

from app.slug import slugify


class SlugTest(unittest.TestCase):
    def test_words(self):
        self.assertEqual(slugify("Hello World"), "hello-world")

    def test_runs_of_symbols(self):
        self.assertEqual(slugify("a -- b"), "a-b")


if __name__ == "__main__":
    unittest.main()
