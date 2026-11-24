"""A small in-process cache for slow lookups."""
_store = {}


def cached(fn):
    """Remember fn's answer for each set of arguments it is called with."""
    def wrapper(*args, **kwargs):
        key = (fn.__name__, args, tuple(sorted(kwargs.items())))
        if key not in _store:
            _store[key] = fn(*args, **kwargs)
        return _store[key]
    wrapper.__name__ = fn.__name__
    return wrapper


def clear():
    _store.clear()


def make_key(*parts):
    """A key for an external cache: the parts joined by colons."""
    return ":".join(str(p) for p in parts)
