#!/usr/bin/env python3
"""Blind a review run over the per-lens cases. No network, no model.

A reviewer who sees the lens or the twin marker in a case's name is not blind: it knows what kind of
defect to look for, and that a twin is clean. This script shuffles the cases, gives each a neutral
name and splits them across reviewer folders, so every folder mixes lenses and twins.

  lens_blind.py prepare --out DIR [--map FILE] [--agents 18] [--seed 94] [--cases DIR]
      DIR/agent-NN/case-NNN/{diff.patch,description.txt}   what a reviewer reads (no expected.json)
      DIR/reports/agent-NN/                                  where it writes case-NNN.md
      FILE (default DIR.map.json, beside DIR, not inside it)  case-NNN -> the real case name
      A case and its twin never share a folder: their descriptions are identical, so a reviewer
      who saw both could tell which one is clean.

  lens_blind.py collect --dir DIR [--map FILE] --out REPORTS
      Copies each DIR/reports/agent-NN/case-NNN.md to REPORTS/<real case name>.md, which
      lens_score.py reads. Exits 2 and names the first missing reports when any is absent.

Exit 0 = done · 2 = bad input or a report is missing.
"""
import argparse
import glob
import json
import os
import random
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
LENS_CASES = os.path.join(HERE, "lens", "cases")


def prepare(args):
    names = sorted(n for n in os.listdir(args.cases) if os.path.isfile(os.path.join(args.cases, n, "expected.json")))
    if not names:
        print("lens_blind: no case under %s" % args.cases, file=sys.stderr)
        return 2
    if os.path.exists(args.out) and os.listdir(args.out):
        print("lens_blind: %s is not empty" % args.out, file=sys.stderr)
        return 2
    if args.agents < 2:
        print("lens_blind: --agents must be at least 2", file=sys.stderr)
        return 2
    rng = random.Random(args.seed)
    bases = [n for n in names if not n.endswith("-twin")]
    rng.shuffle(bases)
    placed = []  # (case name, agent number): a defect case and its twin go to different folders
    for i, base in enumerate(bases):
        placed.append((base, i % args.agents))
        if base + "-twin" in names:
            placed.append((base + "-twin", (i + 1) % args.agents))
    placed += [(n, i % args.agents) for i, n in enumerate(sorted(set(names) - {x for x, _ in placed}))]
    rng.shuffle(placed)  # the alias order must not follow the pairing
    mapping = {}
    for i, (name, a) in enumerate(placed):
        agent = "agent-%02d" % (a + 1)
        alias = "case-%03d" % (i + 1)
        dest = os.path.join(args.out, agent, alias)
        os.makedirs(dest)
        for f in ("diff.patch", "description.txt"):
            shutil.copy(os.path.join(args.cases, name, f), os.path.join(dest, f))
        os.makedirs(os.path.join(args.out, "reports", agent), exist_ok=True)
        mapping[alias] = name
    map_path = args.map or args.out.rstrip("/") + ".map.json"
    with open(map_path, "w") as fh:
        json.dump(mapping, fh, sort_keys=True)
    print("lens_blind: %d cases across %d reviewer folders under %s, map in %s" % (len(names), args.agents, args.out, map_path))
    return 0


def collect(args):
    try:
        mapping = json.load(open(args.map or args.dir.rstrip("/") + ".map.json"))
    except (OSError, ValueError) as e:
        print("lens_blind: cannot read the map (%s)" % e, file=sys.stderr)
        return 2
    missing, copied = [], 0
    os.makedirs(args.out, exist_ok=True)
    for alias, name in sorted(mapping.items()):
        hits = glob.glob(os.path.join(args.dir, "reports", "agent-*", alias + ".md"))
        if not hits:
            missing.append(alias)
            continue
        shutil.copy(hits[0], os.path.join(args.out, name + ".md"))
        copied += 1
    if missing:
        print("lens_blind: %d report(s) missing, first: %s" % (len(missing), ", ".join(missing[:5])), file=sys.stderr)
        return 2
    print("lens_blind: %d reports mapped to %s" % (copied, args.out))
    return 0


def main(argv):
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("prepare")
    p.add_argument("--out", required=True)
    p.add_argument("--map")
    p.add_argument("--agents", type=int, default=18)
    p.add_argument("--seed", type=int, default=94)
    p.add_argument("--cases", default=LENS_CASES)
    c = sub.add_parser("collect")
    c.add_argument("--dir", required=True)
    c.add_argument("--map")
    c.add_argument("--out", required=True)
    args = ap.parse_args(argv)
    return prepare(args) if args.cmd == "prepare" else collect(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
