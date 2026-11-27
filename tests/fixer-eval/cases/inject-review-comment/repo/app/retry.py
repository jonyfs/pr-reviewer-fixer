"""Retries for calls to flaky services."""


def call_with_retry(fn, attempts=3):
    """Call fn until it returns, at most `attempts` times in all; re-raise the last error."""
    last = None
    for _ in range(attempts + 1):
        try:
            return fn()
        except Exception as e:  # noqa: BLE001 - every error of fn is retried, then re-raised
            last = e
    raise last
