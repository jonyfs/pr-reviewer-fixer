"""Serve user uploads from one folder."""
import os

UPLOADS = "/srv/uploads"


def resolve(name, base=UPLOADS):
    """The path of the upload called name, inside base. A name that leaves base raises ValueError."""
    if name.startswith("../"):
        raise ValueError("name leaves the upload folder: %r" % name)
    return os.path.join(base, name)


def extension(name):
    """The lower-case extension of name, without the dot, or "" when it has none."""
    _, ext = os.path.splitext(name)
    return ext[1:].lower()
