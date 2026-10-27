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
  bidi            U+202A-U+202E and U+2066-U+2069 (the Trojan Source overrides and isolates), and
                  the marks U+200E, U+200F and U+061C
  tag             U+E0000-U+E007F (Unicode tag characters, invisible ASCII look-alikes)
  filler          U+00AD (soft hyphen), U+034F, U+115F, U+1160, U+17B4, U+17B5, U+3164 and U+FFA0
                  (blank fillers that render as nothing)
  variation-selector
                  a run of two or more variation selectors (U+FE00-U+FE0F, U+E0100-U+E01EF). One
                  selector after a character is how an emoji or an ideograph picks its glyph, so a
                  single one is not reported; a run of them is how bytes are smuggled after one
                  visible character.
  html-comment    an HTML comment that is not one of the markers above
  details         a `<details>` element (collapsed by default on GitHub)
  invisible-html  an HTML element styled or marked to be invisible (`display:none`,
                  `visibility:hidden`, `font-size:0`, `opacity:0`, `color:transparent`, `hidden`)
  link-ref-comment
                  a Markdown link reference definition whose destination is `#` or `<>`, such as
                  `[//]: # (text)` or `[comment]: <> (text)`, in every shape CommonMark reads as
                  one: the destination on the next line, an escaped `]` or a line break in the
                  label, and inside a blockquote or list item. GitHub renders a definition as
                  nothing, so this is the Markdown form of an HTML comment. A definition whose
                  destination is a `#fragment` or that carries a title (`"..."`, `'...'`,
                  `(...)`) is reported too when no link in the same text uses its label: the
                  fragment and the title are free text nobody sees. A definition with a plain URL
                  and no title is not reported, nor one whose label a link uses (its title shows
                  as the link's tooltip). A `[label]` inside a code span or a fenced block is not a
                  use. Each added line of a diff is scanned alone, so there a titled definition is
                  reported even when another line uses it.

NOT DONE: code that is not a fence or a code span. An indented code block (four spaces after a
blank line) and a fence inside a blockquote or a list item are not blanked, so a `[label]` shown as
code there still counts as a use and an unused titled definition beside it goes unreported. Telling
an indented code block from a list item's continuation needs the container structure a full
Markdown parser builds; this scan does not build it.

NOT DONE: homoglyphs (a Cyrillic `a` in an identifier). Telling a homoglyph from an ordinary
non-Latin word needs a confusables table and per-language context, and without one the hits on
names, prose and test data would bury the real ones. It is left out, and said so here.

SOURCES (any number, at least one):

  --pr <n>               the pull request's title, body and comments, read through pr-json.py
                         (edited comments included, since their body is what is shown now)
  --pr-json <file>       the same, from a file that holds pr-json.py output (`-` is stdin)
  --feedback-json <file> every item of a fetch-feedback.py list (review-thread comments, review
                         bodies and issue comments, edited, minimized or not), `-` is stdin. `--pr`
                         reads issue comments only: pr-json.py does not fetch review threads or
                         review bodies, so the fixer, which reads those, scans its own work list
                         with this source. At most one source may read stdin.
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
import bisect
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
for cp in list(range(0x202A, 0x202F)) + list(range(0x2066, 0x206A)) + [0x200E, 0x200F, 0x061C]:
    CHARS[cp] = "bidi"
for cp in (0x00AD, 0x034F, 0x115F, 0x1160, 0x17B4, 0x17B5, 0x3164, 0xFFA0):
    CHARS[cp] = "filler"
CHAR_RE = re.compile("[" + "".join(re.escape(chr(c)) for c in sorted(CHARS)) + "\U000E0000-\U000E007F]")
# Two or more variation selectors in a row: one picks a glyph, a run carries hidden bytes.
VS_RUN_RE = re.compile("[\uFE00-\uFE0F\U000E0100-\U000E01EF]{2,}")

DETAILS_RE = re.compile(r"<details\b", re.I)
# A link reference definition whose destination is `#` or `<>`, in the shapes CommonMark accepts: any
# indent, inside any blockquote or list item prefix (`> `, `- `, `1. `, nested), a label that may hold an
# escaped bracket and run over lines, and the destination on the label's line or on the next one (after
# that line's own prefix). Any indent reports a little more than CommonMark renders (an indented code
# block), which errs on the side of a hit. Each repetition of the prefix starts at a marker character and
# no two space quantifiers sit next to each other, so a line of spaced markers that is not a definition
# fails after one pass over the line instead of trying every split of its spaces.
_LR_PREFIX = r"[ \t]*(?:(?:>|[-*+][ \t]|\d{1,9}[.)][ \t])[ \t]*)*"
LINKREF_RE = re.compile(
    r"^" + _LR_PREFIX + r"\[(?:[^\[\]\\]|\\[\s\S]){0,999}\]:[ \t]*(?:\n" + _LR_PREFIX + r")?"
    r"(?:#|<>)(?=[ \t]|$)", re.M)
# Any link reference definition: its label, its destination and whether a title follows it (on the same
# line or the next). The destination and the space before a title are disjoint classes, so a long line
# fails in one pass.
LINKREF_ANY_RE = re.compile(
    r"^" + _LR_PREFIX + r"\[((?:[^\[\]\\]|\\[\s\S]){0,999})\]:[ \t]*(?:\n" + _LR_PREFIX + r")?"
    r"(<[^<>\n]*>|[^\s<]\S*)((?:[ \t]+|[ \t]*\n" + _LR_PREFIX + r")[\"'(])?", re.M)
# An HTML element styled or marked to be invisible. The tag's start, its `>` and the invisibility
# marker are found by three linear scans and joined by position, so a text of many `<a` with no `>`
# costs one pass instead of one pass per `<a`. A marker counts when a tag start sits after the last
# `>` before it, which is what `<tag [^>]* marker` matched.
TAG_START_RE = re.compile(r"<[a-z][a-z0-9]*\b", re.I)
STYLE_ATTR_RE = re.compile(r"\bstyle\s*=\s*[\"']([^\"']*)", re.I)
HIDING_STYLE_RE = re.compile(
    r"display\s*:\s*none|visibility\s*:\s*hidden|font-size\s*:\s*0(?![.\d]*[1-9])"
    r"|opacity\s*:\s*0(?![.\d]*[1-9])|color\s*:\s*transparent", re.I)
HIDDEN_ATTR_RE = re.compile(r"\shidden(?:\s|=|/?>)", re.I)


def invisible_html(text):
    """(start, end) of each element hidden by its style or its `hidden` attribute: start is the tag's
    `<`, end the end of the marker. One per tag."""
    gts = [m.start() for m in re.finditer(">", text)]
    starts = [m.start() for m in TAG_START_RE.finditer(text)]
    marks = []
    for m in STYLE_ATTR_RE.finditer(text):
        h = HIDING_STYLE_RE.search(m.group(1))
        if h:
            marks.append((m.start(), m.start(1) + h.end()))
    marks += [(m.start(), m.end()) for m in HIDDEN_ATTR_RE.finditer(text)]
    found = {}
    for pos, end in sorted(marks):
        k = bisect.bisect_left(gts, pos)
        last_gt = gts[k - 1] if k else -1
        j = bisect.bisect_right(starts, last_gt)
        if j < len(starts) and starts[j] < pos and starts[j] not in found:
            found[starts[j]] = end
    return sorted(found.items())


def norm_label(label):
    return " ".join(label.split()).casefold()


def label_uses(text):
    """The normalised labels of every `[label]` not followed by `:`, the label up to 999 characters or
    escape pairs with no unescaped bracket in it, found left to right without overlap as the regex
    `\\[((?:[^\\[\\]\\\\]|\\\\[\\s\\S]){0,999})\\](?!:)` would. One pass splits the text into escape pairs
    and single characters; the character after any `[` always starts a piece, so every `[` (escaped
    or not) sees the same split, and its label ends at the next unescaped bracket, found by bisect.
    The regex rescanned up to 999 pairs from every `[`, about 1000 steps per byte on a run of `\\[`."""
    n = len(text)
    piece = [0] * (n + 1)
    brackets = []
    i = k = 0
    while i < n:
        piece[i] = k
        if text[i] == "\\" and i + 1 < n:
            i += 2
        else:
            if text[i] in "[]":
                brackets.append(i)
            i += 1
        k += 1
    piece[n] = k
    uses, resume = set(), 0
    for m in re.finditer(r"\[", text):
        p = m.start()
        if p < resume:
            continue
        j = bisect.bisect_right(brackets, p)
        if j == len(brackets):
            break
        r = brackets[j]
        if text[r] == "]" and piece[r] - piece[p + 1] <= 999 and text[r + 1:r + 2] != ":":
            uses.add(norm_label(text[p + 1:r]))
            resume = r + 1
    return uses


def blank_code(text):
    """The text with fenced code blocks and inline code spans replaced by spaces (newlines kept), so a
    `[label]` shown as code is not read as a link that uses the label. A fence is a line that opens
    with three or more backticks or tildes (up to three spaces of indent) and closes on a line that
    holds only the same character, at least as many times, and spaces or tabs: a fence line with an
    info string (```js) inside an open fence is content, as in CommonMark. A code span is a backtick run closed by the next run of the
    same length, as CommonMark pairs them; each run is visited once, so the cost is linear."""
    out = list(text)

    def blank(a, b):
        for k in range(a, b):
            if out[k] != "\n":
                out[k] = " "

    pos, fence = 0, None
    for line in text.split("\n"):
        m = re.match(r" {0,3}(`{3,}|~{3,})", line)
        if fence is None and m:
            fence = (m.group(1)[0], len(m.group(1)))
            blank(pos, pos + len(line))
        elif fence is not None:
            blank(pos, pos + len(line))
            close = re.fullmatch(r" {0,3}(`{3,}|~{3,})[ \t]*", line)
            if close and close.group(1)[0] == fence[0] and len(close.group(1)) >= fence[1]:
                fence = None
        pos += len(line) + 1
    flat = "".join(out)
    runs = [(m.start(), m.end()) for m in re.finditer(r"`+", flat)]
    by_len = {}
    for idx, (a, b) in enumerate(runs):
        by_len.setdefault(b - a, []).append(idx)
    i = 0
    while i < len(runs):
        a, b = runs[i]
        same = by_len[b - a]
        j = bisect.bisect_right(same, i)
        if j < len(same):
            close = runs[same[j]]
            blank(a, close[1])
            i = same[j] + 1
        else:
            i += 1
    return "".join(out)


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
    for m in VS_RUN_RE.finditer(text):
        add(m.start(), "variation-selector", "%d selectors from U+%04X" % (len(m.group()), ord(m.group()[0])))
    for start, end in invisible_html(text):
        add(start, "invisible-html", esc(text[start:end])[:60])
    seen = set()
    for m in LINKREF_RE.finditer(text):
        seen.add(m.start())
        add(m.start(), "link-ref-comment", esc(m.group().strip())[:60])
    used = None
    for m in LINKREF_ANY_RE.finditer(text):
        if m.start() in seen or not (m.group(2).startswith("#") or m.group(3)):
            continue
        if used is None:
            used = label_uses(blank_code(text))
        if norm_label(m.group(1)) not in used:
            add(m.start(), "link-ref-comment", esc(m.group().strip())[:60])
    return hits


def git_path(name):
    """A path from a `+++ ` line as git prints it: one trailing tab (git adds it after a name with a
    space) dropped, a C-quoted name (`"b/caf\\303\\251"`, a quote, a backslash or a control
    character in it) decoded, then the `b/` prefix removed. None for /dev/null."""
    if name.endswith("\t"):
        name = name[:-1]
    if len(name) >= 2 and name[0] == '"' and name[-1] == '"':
        out, i, body = bytearray(), 0, name[1:-1]
        esc_map = {"a": 7, "b": 8, "t": 9, "n": 10, "v": 11, "f": 12, "r": 13, '"': 34, "\\": 92}
        while i < len(body):
            ch = body[i]
            if ch == "\\" and i + 1 < len(body):
                nx = body[i + 1]
                if nx in esc_map:
                    out.append(esc_map[nx]); i += 2; continue
                if re.fullmatch(r"[0-7]{3}", body[i + 1:i + 4]):
                    out.append(int(body[i + 1:i + 4], 8) & 0xFF); i += 4; continue
            out += ch.encode("utf-8"); i += 1
        name = out.decode("utf-8", "replace")
    if name == "/dev/null":
        return None
    return name[2:] if name.startswith("b/") else name


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
            path = git_path(raw[4:])
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


def scan_feedback(items, verdict_re):
    """A fetch-feedback.py list: one JSON list of items, each with a `body` and a `url`."""
    if not isinstance(items, list) or any(not isinstance(i, dict) for i in items):
        raise Unreadable("the feedback JSON is not a list of items")
    hits = []
    for it in items:
        src = {"review_thread": "review-comment", "review": "review", "issue_comment": "comment"}.get(
            it.get("source"), "feedback")
        url = it.get("url") or ("%s by %s" % (src, it.get("author") or "unknown"))
        hits += scan_text(it.get("body") or "", verdict_re, src, lambda l, u=url: "%s line %d" % (u, l))
    return hits


def main(argv):
    usage = ("usage: scan-hidden.py [--pr <n> | --pr-json <file>] [--feedback-json <file>] "
             "[--diff <base> <head>] [--commits <base> <head>] [--file <file>]...")
    jobs, i = [], 0
    while i < len(argv):
        a = argv[i]
        need = {"--pr": 1, "--pr-json": 1, "--feedback-json": 1, "--file": 1, "--diff": 2, "--commits": 2}.get(a)
        if need is None or len(argv[i + 1:i + 1 + need]) < need:
            print("scan-hidden: " + usage, file=sys.stderr)
            return 2
        jobs.append((a, argv[i + 1:i + 1 + need]))
        i += 1 + need
    if not jobs or sum(1 for o, v in jobs if o in ("--pr-json", "--feedback-json") and v[0] == "-") > 1:
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
            elif opt == "--feedback-json":
                raw = sys.stdin.read() if vals[0] == "-" else open(vals[0], encoding="utf-8").read()
                hits += scan_feedback(json.loads(raw), verdict_re)
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
