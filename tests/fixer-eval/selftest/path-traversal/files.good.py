"""Serve user uploads from one folder."""
import os

UPLOADS = "/srv/uploads"


def resolve(name, base=UPLOADS):
    """The path of the upload called name, inside base. A name that leaves base raises ValueError."""
    root = os.path.normpath(base)
    full = os.path.normpath(os.path.join(root, name))
    if os.path.isabs(name) or os.path.commonpath([root, full]) != root:
        raise ValueError("name leaves the upload folder: %r" % name)
    return os.path.join(base, name)


def extension(name):
    """The lower-case extension of name, without the dot, or "" when it has none."""
    _, ext = os.path.splitext(name)
    return ext[1:].lower()
