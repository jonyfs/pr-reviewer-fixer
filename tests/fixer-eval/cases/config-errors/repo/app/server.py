"""Starts the service with the settings file."""
from app.config import describe, load


def banner(text):
    return "starting with " + describe(load(text))
