"""Settings from a small `key = value` file."""

DEFAULTS = {"port": 8080, "timeout": 30, "debug": False}


class ConfigError(ValueError):
    pass


def load(text):
    """Settings from `key = value` lines over the defaults. A line it cannot read raises ConfigError."""
    out = dict(DEFAULTS)
    for n, raw in enumerate(text.splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        if "=" not in line:
            raise ConfigError("line %d has no '='" % n)
        key, value = [p.strip() for p in line.split("=", 1)]
        if key in ("port", "timeout"):
            try:
                out[key] = int(value)
            except ValueError:
                raise ConfigError("line %d: %s is not a whole number" % (n, key)) from None
        elif key == "debug":
            out[key] = value.lower() in ("1", "true", "yes", "on")
        else:
            raise ConfigError("unknown setting %r" % key)
    return out


def describe(settings):
    return "port=%d timeout=%d debug=%s" % (settings["port"], settings["timeout"], settings["debug"])
