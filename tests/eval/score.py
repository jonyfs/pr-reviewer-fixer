#!/usr/bin/env python3
"""Scores pr-reviewer reports against seeded cases. No network, no model.

Usage:
  score.py --validate [--cases DIR]         check that every case's expected lines sit in its diff
                                            and that no decoy's window overlaps a defect's
  score.py --reports DIR [--min-recall R] [--min-precision P] [--json]

Each case lives in cases/<name>/ with diff.patch, description.txt and expected.json. A reviewer
report for the case is DIR/<name>.md and ends with the fenced `findings` block the skill defines
(tests/eval/README.md explains how to produce one).

A finding is a hit for a defect when it names the same file, its line is within the defect's
tolerance, and its severity is at least the defect's min_severity. A defect is hit once. Notes are
not counted for precision. Precision is hits over CRITICAL and WARNING findings; a finding that
lands on a decoy is also listed as a decoy hit.

Exit 0 = scored (and thresholds met, when given) · 1 = a threshold was missed or --validate found
a problem · 2 = a report or case could not be read.
"""
import argparse, json, os, re, sys

RANK = {"NOTE": 1, "WARNING": 2, "CRITICAL": 3}
HERE = os.path.dirname(os.path.abspath(__file__))
CASES = os.path.join(HERE, "cases")
DEFAULT_TOLERANCE = 3


def parse_findings(text):
    m = re.search(r"```findings\n(.*?)\n```", text, re.S)
    if not m:
        return None
    out, cur = [], None
    for ln in m.group(1).splitlines():
        if re.match(r"^\s*-\s+id:", ln):
            cur = {}
            out.append(cur)
            continue
        kv = re.match(r"^\s{2,}(file|line|severity|status):\s*(.*?)\s*$", ln)
        if kv and cur is not None:
            cur[kv.group(1)] = kv.group(2).strip("\"'")
    return [f for f in out if (f.get("status") or "open") in ("open", "refused-rejected")]


def near(f, anchor):
    try:
        line = int(f.get("line", ""))
    except ValueError:
        return False
    return f.get("file") == anchor["file"] and abs(line - anchor["line"]) <= anchor.get("tolerance", DEFAULT_TOLERANCE)


def score_case(expected, findings):
    counted = [f for f in findings if f.get("severity", "").upper() in ("CRITICAL", "WARNING")]
    hit_ids, hit_findings = set(), set()
    for d in expected.get("defects", []):
        need = RANK[d.get("min_severity", "WARNING")]
        for i, f in enumerate(counted):
            if i in hit_findings:
                continue
            if near(f, d) and RANK.get(f.get("severity", "").upper(), 0) >= need:
                hit_ids.add(d["id"])
                hit_findings.add(i)
                break
    decoy_hits = sum(1 for i, f in enumerate(counted) if i not in hit_findings
                     and any(near(f, x) for x in expected.get("decoys", [])))
    return {
        "defects": len(expected.get("defects", [])),
        "hit": len(hit_ids),
        "reported": len(counted),
        "true_positive": len(hit_findings),
        "decoy_hits": decoy_hits,
        "missed": sorted({d["id"] for d in expected.get("defects", [])} - hit_ids),
    }


def hunks(diff_text):
    ranges, cur = {}, None
    for ln in diff_text.splitlines():
        if ln.startswith("+++ "):
            p = ln[4:].strip()
            cur = None if p == "/dev/null" else (p[2:] if p.startswith("b/") else p)
            if cur:
                ranges.setdefault(cur, [])
        elif ln.startswith("@@") and cur:
            m = re.match(r"@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@", ln)
            if m:
                s, n = int(m.group(1)), int(m.group(2) if m.group(2) is not None else 1)
                ranges[cur].append((s, s + max(n, 1) - 1))
    return ranges


def case_names():
    return sorted(d for d in os.listdir(CASES) if os.path.isfile(os.path.join(CASES, d, "expected.json")))


def validate():
    problems = []
    for name in case_names():
        base = os.path.join(CASES, name)
        for need in ("diff.patch", "description.txt", "expected.json"):
            if not os.path.isfile(os.path.join(base, need)):
                problems.append("%s: missing %s" % (name, need))
        try:
            exp = json.load(open(os.path.join(base, "expected.json")))
            rng = hunks(open(os.path.join(base, "diff.patch")).read())
        except (OSError, ValueError) as e:
            problems.append("%s: unreadable (%s)" % (name, e))
            continue
        for kind in ("defects", "decoys"):
            for a in exp.get(kind, []):
                if not any(s <= a["line"] <= e for s, e in rng.get(a["file"], [])):
                    problems.append("%s: %s %s:%s is not inside a hunk of diff.patch" % (name, kind[:-1], a["file"], a["line"]))
        # A line inside both windows would score as the defect (defects are matched first), so the
        # case could not see the false positive the decoy was seeded for.
        for d in exp.get("defects", []):
            for x in exp.get("decoys", []):
                reach = d.get("tolerance", DEFAULT_TOLERANCE) + x.get("tolerance", DEFAULT_TOLERANCE)
                if x["file"] == d["file"] and abs(x["line"] - d["line"]) <= reach:
                    problems.append("%s: decoy %s:%s is within the window of defect %s (%s:%s, tolerance %s)"
                                    % (name, x["file"], x["line"], d["id"], d["file"], d["line"], d.get("tolerance", DEFAULT_TOLERANCE)))
    return problems


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--validate", action="store_true")
    ap.add_argument("--cases", help="cases directory (default: cases/ beside this script)")
    ap.add_argument("--reports")
    ap.add_argument("--min-recall", type=float)
    ap.add_argument("--min-precision", type=float)
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    if a.cases:
        global CASES
        CASES = os.path.abspath(a.cases)
    if a.validate:
        probs = validate()
        for p in probs:
            print("eval: " + p)
        print("eval: %d case(s), %s" % (len(case_names()), "ok" if not probs else "%d problem(s)" % len(probs)))
        return 1 if probs else 0
    if not a.reports:
        ap.error("give --reports DIR or --validate")
    rows, tot = {}, {"defects": 0, "hit": 0, "reported": 0, "true_positive": 0, "decoy_hits": 0}
    for name in case_names():
        rp = os.path.join(a.reports, name + ".md")
        try:
            findings = parse_findings(open(rp, encoding="utf-8", errors="replace").read())
            exp = json.load(open(os.path.join(CASES, name, "expected.json")))
        except (OSError, ValueError) as e:
            print("eval: cannot read %s (%s)" % (rp, e), file=sys.stderr)
            return 2
        if findings is None:
            print("eval: %s has no fenced findings block" % rp, file=sys.stderr)
            return 2
        r = score_case(exp, findings)
        rows[name] = r
        for k in tot:
            tot[k] += r[k]
    recall = tot["hit"] / tot["defects"] if tot["defects"] else 1.0
    precision = tot["true_positive"] / tot["reported"] if tot["reported"] else 1.0
    summary = {"cases": rows, "total": tot, "recall": round(recall, 3), "precision": round(precision, 3)}
    if a.json:
        print(json.dumps(summary, indent=2, sort_keys=True))
    else:
        print("%-16s %7s %9s %10s %s" % ("case", "hit", "reported", "decoy hits", "missed"))
        for n, r in rows.items():
            print("%-16s %3d/%-3d %9d %10d %s" % (n, r["hit"], r["defects"], r["reported"], r["decoy_hits"], ",".join(r["missed"]) or "-"))
        print("recall %.3f  precision %.3f  (%d/%d defects, %d/%d reported findings)" %
              (recall, precision, tot["hit"], tot["defects"], tot["true_positive"], tot["reported"]))
    bad = (a.min_recall is not None and recall < a.min_recall) or (a.min_precision is not None and precision < a.min_precision)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
