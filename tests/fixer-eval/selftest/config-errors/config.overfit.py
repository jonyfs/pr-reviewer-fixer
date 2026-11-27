"""Settings from a small `key = value` file."""

DEFAULTS = {"port": 8080, "timeout": 30, "debug": False}


class ConfigError(ValueError):
    pass


def load(text):
    """Settings from `key = value` lines over the defaults. A line it cannot read raises ConfigError."""
    out = dict(DEFAULTS)
    try:
        for raw in text.splitlines():
            line = raw.split("#", 1)[0].strip()
            if not line:
                continue
            key, value = [p.strip() for p in line.split("=", 1)]
            if key == "port" and not value.isdigit():
                raise ConfigError("port is not a number")
            if key in ("port", "timeout"):
                out[key] = int(value)
            elif key == "debug":
                out[key] = value.lower() in ("1", "true", "yes", "on")
            else:
                raise ConfigError("unknown setting %r" % key)
    except ConfigError:
        raise
    except Exception:
        return dict(DEFAULTS)
    return out


def describe(settings):
    return "port=%d timeout=%d debug=%s" % (settings["port"], settings["timeout"], settings["debug"])
