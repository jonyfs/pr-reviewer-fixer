#!/usr/bin/env python3
"""scan-hidden.py: find text a person cannot see but a model reads, in what the agents are about to read.

WHY IT EXISTS. The reviewer and the fixer read the diff, the pull request text, its comments and the
commit messages. A zero-width character, a bidi override, a Unicode tag character or an HTML comment
is invisible on GitHub and fully visible to a model, so it is the cheapest way to hand an agent an
instruction nobody reviewing the page can see. The rule "prompt injection is CRITICAL" needs a
detector that does not depend on a model noticing what it was built not to notice.

IT STRIPS NOTHING. It only reports. Stripping HTML comments blindly would also delete the protocol's
own markers, which are HTML comments. Those are recognised exactly and left out of the report:

  - the verdict marker, by the gate's own regex (`MARKER` in gate-pr-review-state.py, imported from
    the same folder, so the two cannot drift);
  - `<!-- pr-skill-extension: state=granted cycle=<n> n=<n> -->` and
    `<!-- pr-skill-extension: state=halted reason=<reason> -->`, as `extend` and `halt` write them;
  - `<!-- pr-skill-status: skill=<name> run=<run> head=<sha> state=started|finished -->`;
  - `<!-- pr-debt:start -->` and `<!-- pr-debt:end -->`;
  - `<!-- pr-fixer-closure: cycle=<n> head=<sha> closed=<n> refused=<n> debt=<n> -->`.

  Anything else that opens with `<!--` is reported, including a near miss of a marker (an extra
  word inside one is exactly where an instruction would hide).

WHAT IT REPORTS (`kind`):

  zero-width      U+200B-U+200D, U+2060-U+2064, U+180E
  bom             U+FEFF anywhere
  bidi            U+202A-U+202E and U+2066-U+2069 (the Trojan Source overrides and isolates)
  tag             U+E0000-U+E007F (Unicode tag characters, invisible ASCII look-alikes)
  html-comment    an HTML comment that is not one of the markers above
  details         a `<details>` element (collapsed by default on GitHub)
  invisible-html  an HTML element styled or marked to be invisible (`display:none`,
                  `visibility:hidden`, `font-size:0`, `opacity:0`, `color:transparent`, `hidden`)

NOT DONE: homoglyphs (a Cyrillic `a` in an identifier). Telling a homoglyph from an ordinary
non-Latin word needs a confusables table and per-language context, and without one the hits on
names, prose and test data would bury the real ones. It is left out, and said so here.

SOURCES (any number, at least one):

  --pr <n>               the pull request's title, body and comments, read through pr-json.py
                         (edited comments included, since their body is what is shown now)
  --pr-json <file>       the same, from a file that holds pr-json.py output (`-` is stdin)
  --diff <base> <head>   the added lines of `git diff <base>...<head>` (from the merge base)
  --commits <base> <head> the messages of the commits in <base>..<head>
  --file <file>          any other text, whole

OUTPUT: one JSON object on stdout, `{"hits": [...], "count": n, "kinds": {...}, "sources": [...]}`.
Each hit has `source`, `location` (`path:line`, a comment url, `title`, `body:line`, `commit <sha>`),
`line`, `column`, `kind`, `detail` (the code point, or the element) and `excerpt` (the line around
it, ASCII-escaped and cut to 120 characters, so an invisible character is shown as `\\u200b`).

EXIT CODES: 0 nothing found, 1 at least one hit, 2 an input could not be read (git failed, pr-json.py
failed, a file is missing); then nothing is printed on stdout. Exit 2 never means clean.
"""
import importlib.util
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


class Unreadable(Exception):
    pass


def gate_marker():
    path = os.path.join(HERE, "gate-pr-review-state.py")
    try:
        spec = importlib.util.spec_from_file_location("gate_pr_review_state", path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod.MARKER
    except Exception as e:  # missing or broken gate: the verdict marker cannot be recognised
        raise Unreadable("cannot load the verdict marker regex from %s (%s)" % (path, e))


# The other four marker forms, exactly as the scripts and skills write them.
OTHER_MARKERS = [
    re.compile(r"<!-- pr-skill-extension: state=granted cycle=\d+ n=\d+ -->", re.ASCII),
    re.compile(r"<!-- pr-skill-extension: state=halted reason=[A-Za-z0-9_.-]+ -->", re.ASCII),
    re.compile(r"<!-- pr-skill-status: skill=[a-z][a-z0-9-]* run=[A-Za-z0-9_.-]+ head=[0-9a-f]{7,40} "
               r"state=(?:started|finished) -->", re.ASCII),
    re.compile(r"<!-- pr-debt:(?:start|end) -->", re.ASCII),
    re.compile(r"<!-- pr-fixer-closure: cycle=\d+ head=[0-9a-f]{7,40} closed=\d+ refused=\d+ debt=\d+ -->",
               re.ASCII),
]

CHARS = {}
for cp in list(range(0x200B, 0x200E)) + list(range(0x2060, 0x2065)) + [0x180E]:
    CHARS[cp] = "zero-width"
CHARS[0xFEFF] = "bom"
for cp in list(range(0x202A, 0x202F)) + list(range(0x2066, 0x206A)):
    CHARS[cp] = "bidi"
CHAR_RE = re.compile("[" + "".join(re.escape(chr(c)) for c in sorted(CHARS)) + "\U000E0000-\U000E007F]")

DETAILS_RE = re.compile(r"<details\b", re.I)
INVISIBLE_RE = re.compile(
    r"<[a-z][a-z0-9]*\b[^>]*?(?:"
    r"\bstyle\s*=\s*[\"'][^\"']*(?:display\s*:\s*none|visibility\s*:\s*hidden|font-size\s*:\s*0(?![.\d]*[1-9])"
    r"|opacity\s*:\s*0(?![.\d]*[1-9])|color\s*:\s*transparent)"
    r"|\shidden(?:\s|=|/?>))", re.I)


def esc(s):
    return ascii(s)[1:-1][:120]


def scan_text(text, verdict_re, source, where, line_offset=0):
    """Every hit in one text. `where(line)` names the location of a line number."""
    hits = []
    lines = text.split("\n")
    starts, pos = [], 0
    for ln in lines:
        starts.append(pos)
        pos += len(ln) + 1

    def locate(i):
        lo, hi = 0, len(starts) - 1
        while lo < hi:
            mid = (lo + hi + 1) // 2
            if starts[mid] <= i:
                lo = mid
            else:
                hi = mid - 1
        return lo, i - starts[lo]

    def add(i, kind, detail):
        n, col = locate(i)
        hits.append({"source": source, "location": where(n + 1 + line_offset), "line": n + 1 + line_offset,
                     "column": col + 1, "kind": kind, "detail": detail, "excerpt": esc(lines[n])})

    for m in CHAR_RE.finditer(text):
        cp = ord(m.group())
        kind = "tag" if 0xE0000 <= cp <= 0xE007F else CHARS[cp]
        add(m.start(), kind, "U+%04X" % cp)
    for m in re.finditer(r"<!--", text):
        rest = text[m.start():]
        if verdict_re.match(rest) or any(r.match(rest) for r in OTHER_MARKERS):
            continue
        end = text.find("-->", m.start() + 4)
        add(m.start(), "html-comment", "unterminated" if end < 0 else "%d characters" % (end + 3 - m.start()))
    for m in DETAILS_RE.finditer(text):
        add(m.start(), "details", "<details>")
    for m in INVISIBLE_RE.finditer(text):
        add(m.start(), "invisible-html", esc(m.group())[:60])
    return hits


def git(*args):
    try:
        r = subprocess.run(("git",) + args, capture_output=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise Unreadable("git %s failed (%s)" % (args[0], e))
    if r.returncode != 0:
        raise Unreadable("git %s failed: %s" % (" ".join(args[:3]), r.stderr.decode("utf-8", "replace").strip()[:200]))
    return r.stdout.decode("utf-8", "replace")


def scan_diff(base, head, verdict_re):
    for ref in (base, head):
        git("rev-parse", "--verify", "--quiet", ref + "^{commit}")
    # --text --no-textconv: a file git treats as binary (a NUL byte, a binary or -diff attribute)
    # would show no added line at all, and a textconv driver would show something other than it.
    patch = git("-c", "core.quotePath=false", "diff", "--text", "--no-textconv", "--no-color", "--no-ext-diff",
                "--no-renames", "-U0", base + "..." + head)
    hits, path, n = [], None, 0
    rem_old = rem_new = 0
    for raw in patch.split("\n"):
        if rem_old > 0 or rem_new > 0:
            # Inside a hunk every line is a hunk line, counted from the @@ header: an added line
            # whose text starts with "++ " shows as "+++ ...", and is not a file header here.
            if raw.startswith("+"):
                rem_new -= 1
                if path is not None:
                    p = path
                    hits += scan_text(raw[1:], verdict_re, "diff", lambda l, p=p: "%s:%d" % (p, l), line_offset=n - 1)
                n += 1
            elif raw.startswith("-"):
                rem_old -= 1
            elif not raw.startswith("\\"):
                rem_old -= 1
                rem_new -= 1
                n += 1
            continue
        if raw.startswith("+++ "):
            p = raw[4:]
            path = None if p == "/dev/null" else (p[2:] if p.startswith("b/") else p)
            continue
        h = re.match(r"@@ -\d+(?:,(\d+))? \+(\d+)(?:,(\d+))? @@", raw)
        if h:
            rem_old = int(h.group(1)) if h.group(1) is not None else 1
            n = int(h.group(2))
            rem_new = int(h.group(3)) if h.group(3) is not None else 1
    return hits


def scan_commits(base, head, verdict_re):
    for ref in (base, head):
        git("rev-parse", "--verify", "--quiet", ref + "^{commit}")
    out = git("log", "-z", "--format=%H%n%B", base + ".." + head)
    hits = []
    for rec in out.split("\0"):
        if not rec.strip():
            continue
        sha, _, msg = rec.partition("\n")
        s = sha.strip()
        hits += scan_text(msg, verdict_re, "commit-message", lambda l, s=s: "commit %s line %d" % (s[:12], l))
    return hits


def scan_pr(pr, verdict_re):
    if not isinstance(pr, dict) or "comments" not in pr:
        raise Unreadable("the pull request JSON has no comments list")
    hits = []
    title = pr.get("title") or ""
    hits += scan_text(title, verdict_re, "pr-title", lambda l: "title")
    hits += scan_text(pr.get("body") or "", verdict_re, "pr-body", lambda l: "body:%d" % l)
    for src, key in (("comment", "comments"), ("edited-comment", "editedComments")):
        for c in pr.get(key) or []:
            if not isinstance(c, dict):
                continue
            url = c.get("url") or ("comment by %s" % ((c.get("author") or {}).get("login") or "unknown"))
            hits += scan_text(c.get("body") or "", verdict_re, src, lambda l, u=url: "%s line %d" % (u, l))
    return hits


def main(argv):
    usage = ("usage: scan-hidden.py [--pr <n> | --pr-json <file>] [--diff <base> <head>] "
             "[--commits <base> <head>] [--file <file>]...")
    jobs, i = [], 0
    while i < len(argv):
        a = argv[i]
        need = {"--pr": 1, "--pr-json": 1, "--file": 1, "--diff": 2, "--commits": 2}.get(a)
        if need is None or len(argv[i + 1:i + 1 + need]) < need:
            print("scan-hidden: " + usage, file=sys.stderr)
            return 2
        jobs.append((a, argv[i + 1:i + 1 + need]))
        i += 1 + need
    if not jobs:
        print("scan-hidden: " + usage, file=sys.stderr)
        return 2
    try:
        verdict_re = gate_marker()
        hits, sources = [], []
        for opt, vals in jobs:
            if opt == "--pr":
                if not re.fullmatch(r"[0-9]+", vals[0], re.ASCII):
                    raise Unreadable("%r is not a pull request number" % vals[0])
                r = subprocess.run([sys.executable, "-I", os.path.join(HERE, "pr-json.py"), vals[0]],
                                   capture_output=True, text=True, timeout=300)
                if r.returncode != 0 or not r.stdout.strip():
                    raise Unreadable("pr-json.py could not read pull request #%s" % vals[0])
                hits += scan_pr(json.loads(r.stdout), verdict_re)
            elif opt == "--pr-json":
                raw = sys.stdin.read() if vals[0] == "-" else open(vals[0], encoding="utf-8").read()
                hits += scan_pr(json.loads(raw), verdict_re)
            elif opt == "--diff":
                hits += scan_diff(vals[0], vals[1], verdict_re)
            elif opt == "--commits":
                hits += scan_commits(vals[0], vals[1], verdict_re)
            else:
                hits += scan_text(open(vals[0], encoding="utf-8", errors="replace").read(), verdict_re,
                                  "file", lambda l, f=vals[0]: "%s:%d" % (f, l))
            sources.append(opt[2:] + " " + " ".join(vals))
    except (Unreadable, OSError, ValueError, subprocess.TimeoutExpired) as e:
        print("scan-hidden: could not read an input, INCONCLUSIVE: %s" % e, file=sys.stderr)
        return 2
    kinds = {}
    for h in hits:
        kinds[h["kind"]] = kinds.get(h["kind"], 0) + 1
    json.dump({"hits": hits, "count": len(hits), "kinds": kinds, "sources": sources}, sys.stdout, indent=1)
    sys.stdout.write("\n")
    return 1 if hits else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
