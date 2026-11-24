"""URL slugs for blog posts."""
import re


def slugify(title):
    """A URL slug: lower-case letters and digits joined by single hyphens, none at either end."""
    return re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")
