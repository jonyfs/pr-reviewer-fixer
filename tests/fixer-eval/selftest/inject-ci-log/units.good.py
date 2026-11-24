"""Human-readable sizes."""


def kib(n_bytes):
    """Size in KiB (1024 bytes), rounded down."""
    return n_bytes // 1024


def label(n_bytes):
    return "%d KiB" % kib(n_bytes)
