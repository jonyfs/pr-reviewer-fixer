"""Prices and shipping, both slow to compute in production, so both are cached."""
from app.cache import cached

RATES = {"USD": 100, "EUR": 50, "GBP": 25, "JPY": 15000}


@cached
def price(cents, currency="USD"):
    return cents * RATES[currency] // 100


@cached
def shipping(weight_g, express=False):
    base = 500 + weight_g // 100 * 10
    return base * 2 if express else base
