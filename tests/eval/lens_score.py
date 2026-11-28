#!/usr/bin/env python3
"""Scores pr-reviewer reports against the per-lens cases (catalog item 94). No network, no model.

Usage:
  lens_score.py --reports DIR [--cases DIR] [--lens NAME ...] [--min-recall R] [--max-twin-fp F] [--json]

A report for a case is DIR/<case>.md and ends with the fenced `findings` block the skill defines,
the same as for tests/eval/score.py, whose matching rule this script reuses: a finding is a hit
for a defect when it names the same file, lies within the defect's tolerance, and has at least the
defect's min_severity.

For each lens the script prints:
  recall      defects hit over defects seeded, across the lens's defect cases (a NOTE can hit a
              NOTE-level defect; score.py ignores notes);
  twin FP     the share of clean twins on which the reviewer reported any CRITICAL or WARNING.

--lens limits scoring to the named lenses (running the reviewer on every case is a lot of work);
an unknown lens exits 2. --min-recall and --max-twin-fp are checked for every scored lens.
Every case of a scored lens needs a report; a missing report exits 2 and is named.

Exit 0 = scored (and thresholds met, when given) · 1 = a threshold was missed ·
2 = a report or case could not be read, or a report is missing.
"""
import argparse
import importlib.util
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
LENS_CASES = os.path.join(HERE, "lens", "cases")
NAME = re.compile(r"^lens-([a-z-]+)-(\d{2})(-twin)?$")


def load_scorer():
    spec = importlib.util.spec_from_file_location("eval_score", os.path.join(HERE, "score.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def count_hits(sc, expected, findings):
    """Defects named by a finding of at least the defect's min_severity. A defect is hit once and a
    finding names one defect. Unlike score.py, a NOTE can hit a defect whose min_severity is NOTE
    (documentation and readability lenses never block, so their seeded defects are NOTEs)."""
    used, hit = set(), 0
    for d in expected.get("defects", []):
        need = sc.RANK[d.get("min_severity", "WARNING")]
        for i, f in enumerate(findings):
            if i in used:
                continue
            if sc.near(f, d) and sc.RANK.get(f.get("severity", "").upper(), 0) >= need:
                used.add(i)
                hit += 1
                break
    return hit


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--reports", required=True)
    ap.add_argument("--cases", default=LENS_CASES)
    ap.add_argument("--lens", action="append", default=[])
    ap.add_argument("--min-recall", type=float)
    ap.add_argument("--max-twin-fp", type=float)
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)

    sc = load_scorer()
    sc.CASES = args.cases
    try:
        all_names = sc.case_names()
    except OSError as e:
        print("lens_score: cannot read the cases directory (%s)" % e, file=sys.stderr)
        return 2
    names = []
    for n in all_names:
        m = NAME.match(n)
        if m and (not args.lens or m.group(1) in args.lens):
            names.append((n, m.group(1), bool(m.group(3))))
    if not names:
        print("lens_score: no case matches", file=sys.stderr)
        return 2
    unknown = [x for x in args.lens if not any(x == lens for _, lens, _ in names)]
    if unknown:
        print("lens_score: no case for lens %s" % ", ".join(unknown), file=sys.stderr)
        return 2

    missing = [n for n, _, _ in names if not os.path.isfile(os.path.join(args.reports, n + ".md"))]
    if missing:
        print("lens_score: %d report(s) missing, first: %s" % (len(missing), ", ".join(missing[:5])), file=sys.stderr)
        return 2

    lenses = {}
    for name, lens, twin in names:
        try:
            expected = json.load(open(os.path.join(args.cases, name, "expected.json")))
            findings = sc.parse_findings(open(os.path.join(args.reports, name + ".md")).read())
        except (OSError, ValueError) as e:
            print("lens_score: %s unreadable (%s)" % (name, e), file=sys.stderr)
            return 2
        if findings is None:
            print("lens_score: %s has no findings block" % name, file=sys.stderr)
            return 2
        L = lenses.setdefault(lens, {"defects": 0, "hit": 0, "twins": 0, "twin_fp": 0})
        if twin:
            L["twins"] += 1
            # A twin is clean: a CRITICAL or WARNING on it is a false positive. A NOTE is not.
            if any(f.get("severity", "").upper() in ("CRITICAL", "WARNING") for f in findings):
                L["twin_fp"] += 1
        else:
            L["defects"] += len(expected.get("defects", []))
            L["hit"] += count_hits(sc, expected, findings)

    out = {}
    for lens, L in sorted(lenses.items()):
        out[lens] = {
            "defects": L["defects"], "hit": L["hit"],
            "recall": round(L["hit"] / L["defects"], 3) if L["defects"] else None,
            "twins": L["twins"], "twin_fp": L["twin_fp"],
            "twin_fp_rate": round(L["twin_fp"] / L["twins"], 3) if L["twins"] else None,
        }
    tot_d = sum(v["defects"] for v in out.values())
    tot_h = sum(v["hit"] for v in out.values())
    tot_t = sum(v["twins"] for v in out.values())
    tot_f = sum(v["twin_fp"] for v in out.values())
    summary = {
        "recall": round(tot_h / tot_d, 3) if tot_d else None,
        "twin_fp_rate": round(tot_f / tot_t, 3) if tot_t else None,
    }

    if args.json:
        print(json.dumps({"lenses": out, "overall": summary}, sort_keys=True))
    else:
        print("%-16s %7s %6s  %8s %7s" % ("lens", "defects", "recall", "twin FP", "rate"))
        for lens, v in out.items():
            print("%-16s %3d/%-3d %6s  %3d/%-4d %7s" % (lens, v["hit"], v["defects"], v["recall"], v["twin_fp"], v["twins"], v["twin_fp_rate"]))
        print("overall recall %s, twin false-positive rate %s" % (summary["recall"], summary["twin_fp_rate"]))

    failed = False
    # Thresholds apply to every scored lens and to the overall figure: a lens with no recall must
    # not hide behind the others.
    if args.min_recall is not None:
        for lens, v in out.items():
            if v["recall"] is None or v["recall"] < args.min_recall:
                print("lens_score: %s recall %s is below %s" % (lens, v["recall"], args.min_recall), file=sys.stderr)
                failed = True
    if args.max_twin_fp is not None:
        for lens, v in out.items():
            if v["twin_fp_rate"] is not None and v["twin_fp_rate"] > args.max_twin_fp:
                print("lens_score: %s twin false-positive rate %s is above %s" % (lens, v["twin_fp_rate"], args.max_twin_fp), file=sys.stderr)
                failed = True
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
