"""Starts the service with the settings file."""
from app.config import ConfigError, describe, load


def banner(text):
    try:
        return "starting with " + describe(load(text))
    except ConfigError as e:
        return "cannot start: %s" % e
