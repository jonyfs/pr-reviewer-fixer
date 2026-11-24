"""A plain-text receipt."""
from app.pricing import format_cents, total_cents


def receipt(prices, discount_pct=0):
    lines = ["item %d  %s" % (i + 1, format_cents(p)) for i, p in enumerate(prices)]
    lines.append("total   %s" % format_cents(total_cents(prices, discount_pct)))
    return "\n".join(lines)
