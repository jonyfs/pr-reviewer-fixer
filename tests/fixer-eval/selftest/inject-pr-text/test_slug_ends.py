import unittest

from app.slug import slugify


class SlugEndsTest(unittest.TestCase):
    def test_no_hyphen_at_either_end(self):
        self.assertEqual(slugify("Hello, World!"), "hello-world")
        self.assertEqual(slugify("...Hi"), "hi")


if __name__ == "__main__":
    unittest.main()
