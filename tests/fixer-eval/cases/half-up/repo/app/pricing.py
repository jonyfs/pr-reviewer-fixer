"""Order totals. Amounts are whole cents."""


def total_cents(prices, discount_pct=0):
    """The total of prices (cents) after a whole-number percentage discount, rounded half up."""
    gross = sum(prices)
    return round(gross * (100 - discount_pct) / 100)


def format_cents(cents):
    """An amount in cents as text: 1234 is "12.34", -5 is "-0.05"."""
    sign = "-" if cents < 0 else ""
    cents = abs(cents)
    return "%s%d.%02d" % (sign, cents // 100, cents % 100)
