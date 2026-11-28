#!/usr/bin/env python3
"""Structure check for the per-lens seeded cases (catalog item 94).

Each lens (a review dimension) has up to LIMIT defect cases. Each defect case
`lens-<slug>-<nn>` has a clean twin `lens-<slug>-<nn>-twin`: the same shape of
code with the defect removed. The reviewer must find the defect and must not
raise a CRITICAL or WARNING on the twin.

Nothing here calls a model. The check proves that every case is well formed:
the defect sits on a line the diff adds, every twin has no defect, every
defect has a twin, and no lens has more than LIMIT defect cases.

Usage: python3 -I tests/eval/lens_check.py [cases-dir]   (default: tests/eval/lens/cases)
The cases live outside tests/eval/cases, which the review scorer reads for its recall.
Exit 0 when every case is well formed, 1 otherwise.
"""
import json
import os
import re
import sys

LIMIT = 10
SEVERITIES = {"CRITICAL", "WARNING", "NOTE"}
LENSES = [
    "correctness", "design", "complexity", "readability", "security",
    "performance", "testing", "error-handling", "concurrency", "api-compat",
    "docs", "dependencies", "observability", "data-integrity", "reliability",
    "scalability", "operability", "privacy",
]
NAME = re.compile(r"^lens-([a-z-]+)-(\d{2})(-twin)?$")
HUNK = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@")


def added_lines(patch_text):
    """Map each file in a unified diff to the set of line numbers it adds."""
    added = {}
    current = None
    new_no = 0
    for raw in patch_text.split("\n"):
        if raw.startswith("+++ "):
            target = raw[4:].strip()
            current = None if target == "/dev/null" else (target[2:] if target.startswith("b/") else target)
            if current is not None:
                added.setdefault(current, set())
            continue
        if raw.startswith("--- ") or raw.startswith("diff --git"):
            continue
        m = HUNK.match(raw)
        if m:
            new_no = int(m.group(1))
            continue
        if current is None:
            continue
        if raw.startswith("+"):
            added[current].add(new_no)
            new_no += 1
        elif raw.startswith("-"):
            pass
        else:
            new_no += 1
    return added


def check_case(path, name, problems):
    for needed in ("diff.patch", "description.txt", "expected.json"):
        if not os.path.isfile(os.path.join(path, needed)):
            problems.append("%s: missing %s" % (name, needed))
            return None
    with open(os.path.join(path, "diff.patch"), encoding="utf-8") as fh:
        added = added_lines(fh.read())
    with open(os.path.join(path, "expected.json"), encoding="utf-8") as fh:
        expected = json.load(fh)
    defects = expected.get("defects", [])
    if name.endswith("-twin") and defects:
        problems.append("%s: a clean twin must have no defects" % name)
    if not name.endswith("-twin") and not defects:
        problems.append("%s: a defect case must have at least one defect" % name)
    for d in defects:
        if d.get("min_severity") not in SEVERITIES:
            problems.append("%s: %s has no valid min_severity" % (name, d.get("id")))
        file_, line = d.get("file"), d.get("line")
        tol = d.get("tolerance", 0)
        if not isinstance(line, int) or not isinstance(tol, int):
            problems.append("%s: %s needs an integer line and tolerance, got %r and %r" % (name, d.get("id"), line, tol))
            continue
        lines = added.get(file_, set())
        if not any(abs(line - x) <= tol for x in lines):
            problems.append("%s: %s points at %s:%s, which the diff does not add" % (name, d.get("id"), file_, line))
    return len(defects)


def main(argv):
    root = argv[1] if len(argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "lens", "cases")
    problems = []
    counts = {lens: 0 for lens in LENSES}
    defect_names, twin_names = set(), set()
    for name in sorted(os.listdir(root)):
        m = NAME.match(name)
        if not m:
            continue
        slug, _, twin = m.group(1), m.group(2), m.group(3)
        if slug not in counts:
            problems.append("%s: unknown lens %r" % (name, slug))
            continue
        if twin:
            twin_names.add("lens-%s-%s" % (slug, m.group(2)))
        else:
            defect_names.add(name)
            counts[slug] += 1
        check_case(os.path.join(root, name), name, problems)
    for lens, n in counts.items():
        if n > LIMIT:
            problems.append("lens %s has %d defect cases, the limit is %d" % (lens, n, LIMIT))
    for d in sorted(defect_names):
        if d not in twin_names:
            problems.append("%s has no twin" % d)
    for t in sorted(twin_names):
        if t not in defect_names:
            problems.append("%s-twin has no defect case" % t)
    total = sum(counts.values())
    print("lens cases: %d defect cases across %d lenses, %d twins" % (total, sum(1 for n in counts.values() if n), len(twin_names)))
    for lens in LENSES:
        print("  %-16s %2d" % (lens, counts[lens]))
    for p in problems:
        print("PROBLEM " + p)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
