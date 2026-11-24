import unittest

from app.files import extension, resolve


class FilesTest(unittest.TestCase):
    def test_resolve_plain_name(self):
        self.assertEqual(resolve("a.txt"), "/srv/uploads/a.txt")

    def test_resolve_subfolder(self):
        self.assertEqual(resolve("2026/b.png"), "/srv/uploads/2026/b.png")

    def test_extension(self):
        self.assertEqual(extension("photo.JPG"), "jpg")


if __name__ == "__main__":
    unittest.main()
