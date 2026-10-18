#!/usr/bin/env python3
"""Checks report_mentions (review-cycle.sh) against a pinned table of GitHub results and a seeded sweep.

usage: mentions.py REVIEW_CYCLE_SH MENTION_TABLE_TSV

The function is lifted out of the script and run in this process, so thousands of inputs cost
seconds. Nothing here talks to GitHub: mention-table.tsv holds what `gh api markdown` rendered.

For every input (each row of the table, then a seeded random sweep), followed by a findings block:
  - the exit code is 0, or 3 with nothing on stdout and a reason on stderr (the sweep only);
  - the findings block comes out byte for byte;
  - a second pass changes nothing (idempotent);
  - the text before the block holds no live mention, by an oracle that is stricter than GitHub: it
    decodes entities the lenient way (bare numeric and legacy named forms too), drops every tag and
    comment, then looks for an at-sign with no ASCII letter, digit or underscore before it and a
    letter or digit after it.
For the table rows the oracle must also be at least as strict as GitHub on the input: when GitHub
rendered a mention, the oracle finds one. That keeps the oracle from being weaker than the thing it
stands in for.
"""
import html
import io
import random
import re
import sys

src = open(sys.argv[1], encoding="utf-8").read()
start = src.index("-c '", src.index("report_mentions() {")) + 4
CODE = compile(src[start:src.index("'\n}", start)], "report_mentions", "exec")
FENCE = "\n\n```findings\nversion: 1\nclaim: @jonyfs &#64;x\n```\n"


def run(text):
    class Stream:
        pass

    stdin, stdout, stderr = Stream(), Stream(), io.StringIO()
    stdin.buffer = io.BytesIO(text.encode("utf-8", "surrogateescape"))
    stdout.buffer = io.BytesIO()
    saved = sys.stdin, sys.stdout, sys.stderr
    sys.stdin, sys.stdout, sys.stderr = stdin, stdout, stderr
    rc = 0
    try:
        exec(CODE, {"__name__": "report_mentions"})
    except SystemExit as e:
        rc = e.code or 0
    finally:
        sys.stdin, sys.stdout, sys.stderr = saved
    return rc, stdout.buffer.getvalue().decode("utf-8", "surrogateescape"), stderr.getvalue()


def oracle(body):
    s = html.unescape(body)
    s = re.sub(r"<!--.*?-->", "", s, flags=re.S)
    s = re.sub(r"</?[A-Za-z][^>]*>", "", s)
    return len(re.findall(r"(?<![A-Za-z0-9_])@[A-Za-z0-9]", s))


failures = []


def fail(what, text, extra=""):
    failures.append("%s: %r %s" % (what, text, extra))


def check(text, pinned=None):
    """Returns True when the report was refused (sweep only)."""
    full = text + FENCE
    rc, out, err = run(full)
    if rc != 0:
        if pinned is not None or rc != 3 or out or not err.strip():
            fail("exit %s, stdout %r, stderr %r" % (rc, out, err), text)
        return True
    if not out.endswith(FENCE):
        fail("findings block altered", text, repr(out))
    if run(out)[1] != out:
        fail("not idempotent", text, repr(out))
    body = out[: len(out) - len(FENCE)]
    if oracle(body):
        fail("live mention left", text, repr(body))
    if pinned is not None:
        seen = oracle(text)
        if seen < pinned or (pinned and not seen):
            fail("oracle weaker than GitHub (GitHub %d, oracle %d)" % (pinned, seen), text)
    return False


rows = []
for line in open(sys.argv[2], encoding="utf-8"):
    m = re.match(r"([0-9])\t(.*)\n?$", line)
    if m:
        rows.append((int(m.group(1)), m.group(2).replace("\\n", "\n")))
for pinned, text in rows:
    check(text, pinned)
print("table: %d rows, %d on which GitHub renders a mention" % (len(rows), sum(1 for p, _ in rows if p)))

TOKENS = [
    "@", "@", "&#64;", "&#64", "&#x40;", "&#x40", "&#X0040;", "&#0064", "&commat;", "&commat",
    "&amp", "&amp;", "&nbsp", "&nbsp;", "&#32", "&#x20;", "&#106;", "&#106", "&#x6a;", "&fjlig;",
    "&lt", "jonyfs", "j", "a", "1", "_", "-", ".", " ", "  ", "\n", "\n\n", "<b>", "</b>", "</x>",
    "<div>", "<p>", "*", "`", "> ", "- ", "&", "#", ";", "x", "0", "4", "6", "é", "​",
    "&#8203;", "<!---->", "<!--", "-->",
]
rnd = random.Random(20261017)
cases = 20000
refused = sum(
    check("".join(rnd.choice(TOKENS) for _ in range(rnd.randint(1, 9)))) for _ in range(cases)
)
print("sweep: %d seeded cases, %d refused for an HTML block opener" % (cases, refused))

if failures:
    print("FAILED: %d" % len(failures))
    for f in failures[:10]:
        print("  " + f)
    sys.exit(1)
print("ok")
