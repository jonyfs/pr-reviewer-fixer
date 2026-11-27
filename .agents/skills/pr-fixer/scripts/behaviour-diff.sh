#!/usr/bin/env bash
#
# behaviour-diff.sh: run the same probes before and after a fix and report every probe whose
# observable result changed (a PatchDiff-style behavioural diff).
#
# Usage: behaviour-diff.sh [--repo DIR] [--list] <base-commit> <head-commit> <probe-file>
#
#   --repo DIR   the repository (default: the current directory)
#   --list       print the expanded probes, one per line, and run nothing (no worktree is made)
#
# The probe file is JSON written by the fixer itself, never built from pull request text:
#
#   {"timeout": 10,
#    "probes": [
#      {"id": "clamp-max", "finding": "C1", "argv": ["bash", "src/clamp.sh", "11"]},
#      {"id": "usage", "argv": ["bash", "src/clamp.sh"], "stdout": true},
#      {"id": "clamp", "finding": "C1", "argv": ["bash", "src/clamp.sh", "{}"],
#       "values": ["a"], "around": {"numbers": [10], "strings": ["abc"]}}]}
#
# Each probe is one argv array, run with no shell, with the worktree as its working directory and
# /dev/null as its stdin. A probe with "values" or "around" is a template: each argv element has
# every "{}" replaced by one generated value, once per value, as probes <id>[1], <id>[2], ... The
# values are the "values" list, then for each number n: n-1, n, n+1, 0, 1, -1, a 40-digit number
# and the empty string; for each string s: "", its first character, s without its last character,
# s, s plus one character, s repeated to 4096 characters, and s with two non-ASCII characters
# appended. Duplicates are dropped, the first one kept. A probe file may expand to at most 500 probes.
#
# The observable result of a probe is its exit code (or "timeout"), the SHA-256 of its stdout and
# the SHA-256 of its stderr. Both commits are checked out, one after the other, at the same
# temporary path (a detached `git worktree`), so a path in the output does not differ between them.
# With "stdout": true the report also shows the two stdout texts, escaped and cut to 200 characters.
# "timeout" is seconds per run (default 10, at most 600), at the file or the probe level; a probe
# that runs out is killed with its whole process group, and so is every probe after it exits. A
# HUP, INT, QUIT or TERM, to the script or to its process group, kills the running probe's group
# too, removes the worktree and exits 2; one the caller ignores stays ignored and stops nothing.
# This holds whenever the stop lands, while a probe runs or while a side's runner is still starting.
# A probe inherits the caller's signal dispositions (a signal the caller ignores, such as HUP under
# nohup, stays ignored in the probe; the others are default).
#
# Report: one line per probe, then a summary line.
#   same              the result is identical at both commits
#   expected          it differs, and the probe is tagged with the finding it should change
#   supplementary     it differs, and no finding tags it: a supplementary semantic change, for the
#                     reviewer to judge (the fix changed behaviour nobody asked it to change)
#   not-changed       tagged with a finding, but identical at both commits (a note: the probe does
#                     not show the fix, or the fix does not change what the finding names)
#   inconclusive      it timed out at both commits, or could not start at both commits (a program
#                     that is not there, a typo in argv[0]), so nothing was compared
#
# Exit: 0 no unexplained difference; 1 at least one supplementary change (it wins over an
# inconclusive probe); 2 cannot run: bad arguments, a commit that does not resolve, a worktree git
# cannot make, an invalid probe file, an inconclusive probe, a stop from outside, or any internal error.
#
# Needs: bash, git, python3 3.9+. Writes nothing in the repository except the temporary worktree,
# which it removes on every exit path.
set -u
die() { echo "behaviour-diff: $*" >&2; exit 2; }
REPO="."; LIST=0; args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) [ $# -ge 2 ] || die "--repo needs a value"; REPO="$2"; shift 2 ;;
    --list) LIST=1; shift ;;
    --) shift; while [ $# -gt 0 ]; do args+=("$1"); shift; done ;;
    -*) die "unknown option $1" ;;
    *) args+=("$1"); shift ;;
  esac
done
[ "${#args[@]}" -eq 3 ] || die "usage: behaviour-diff.sh [--repo DIR] [--list] <base-commit> <head-commit> <probe-file>"
BASE_ARG="${args[0]}"; HEAD_ARG="${args[1]}"; PROBES="${args[2]}"
[ -f "$PROBES" ] && [ -r "$PROBES" ] || die "cannot read the probe file $PROBES"
command -v python3 >/dev/null 2>&1 || die "python3 is not on PATH"
command -v git >/dev/null 2>&1 || die "git is not on PATH"
PY="$(mktemp "${TMPDIR:-/tmp}/behaviour-diff-py.XXXXXXXX")" || die "mktemp failed"
WT=""; TOP=""
cleanup() {
  if [ -n "$WT" ] && [ -n "$TOP" ]; then
    git -C "$TOP" worktree remove --force "$WT/tree" >/dev/null 2>&1
    git -C "$TOP" worktree prune >/dev/null 2>&1
  fi
  [ -z "$WT" ] || rm -rf "$WT"
  rm -f "$PY"
}
PYPID=""; LAUNCHING=0; PENDING=""
# A stop from outside: the python runner kills its running probe's group, then we exit. It is
# forwarded the signal that fired the trap: bash cannot trap a signal the caller ignored, so that
# signal is one the runner handles too (a fixed TERM would be dropped under a TERM-ignoring caller).
# While the runner is being started and its pid is not known yet, the stop is kept for side() to
# deliver once it is, so the worktree is never removed under a runner that goes on.
# The signal is sent again every 0.1 s until the runner exits. bash starts the runner as a
# background job with INT and QUIT ignored, and its handlers exist only once python has started,
# so one send can land before them and be dropped; a repeat is harmless (the handler only records
# it). Never KILL the runner: it is what kills the running probe's group.
stop() { # stop SIGNAL
  if [ "$LAUNCHING" = 1 ] && [ -z "$PYPID" ]; then PENDING="$1"; return; fi
  trap '' HUP INT QUIT TERM
  if [ -n "$PYPID" ]; then
    while kill -"$1" "$PYPID" 2>/dev/null; do sleep 0.1; done
    wait "$PYPID" 2>/dev/null
  fi
  exit 2
}
trap cleanup EXIT
trap 'stop HUP' HUP; trap 'stop INT' INT; trap 'stop QUIT' QUIT; trap 'stop TERM' TERM

cat >"$PY" <<'PYEOF'
import hashlib, json, os, re, signal, subprocess, sys, time

ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
MAX_PROBES = 500
LONG = 4096
STOP = []  # the signal that asked the runner to stop, if any; checked between and during probes
SIGNALS = ("SIGHUP", "SIGINT", "SIGQUIT", "SIGTERM")


def on_signal(signum, frame):
    STOP.append(signum)


def fail(msg):
    print("behaviour-diff: " + msg, file=sys.stderr)
    sys.exit(2)


def dedupe(vals):
    out, seen = [], set()
    for v in vals:
        if v not in seen:
            seen.add(v)
            out.append(v)
    return out


def around_number(n):
    return [str(n - 1), str(n), str(n + 1), "0", "1", "-1", "9" * 40, ""]


def around_string(s):
    long_s = (s or "x") * (LONG // max(len(s), 1) + 1)
    return ["", s[:1], s[:-1], s, s + s[-1:] if s else "x", long_s[:LONG], s + "\u00e9\u65e5"]


def check_str(v, what):
    if not isinstance(v, str):
        fail("%s must be a string" % what)
    if "\0" in v:
        fail("%s holds a NUL byte" % what)
    return v


def timeout_of(obj, default, what):
    t = obj.get("timeout", default)
    if isinstance(t, bool) or not isinstance(t, (int, float)) or not 0 < t <= 600:
        fail("%s: timeout must be a number of seconds above 0 and at most 600" % what)
    return t


def expand(path):
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
    except (OSError, ValueError) as e:
        fail("the probe file is not valid JSON: %s" % e)
    if not isinstance(doc, dict) or not isinstance(doc.get("probes"), list) or not doc["probes"]:
        fail("the probe file needs a non-empty \"probes\" list")
    unknown = set(doc) - {"timeout", "probes"}
    if unknown:
        fail("unknown top-level key(s): %s" % ", ".join(sorted(unknown)))
    default_t = timeout_of(doc, 10, "the probe file")
    out, ids = [], set()
    for i, p in enumerate(doc["probes"]):
        where = "probe %d" % (i + 1)
        if not isinstance(p, dict):
            fail("%s is not an object" % where)
        unknown = set(p) - {"id", "finding", "argv", "stdout", "timeout", "values", "around"}
        if unknown:
            fail("%s: unknown key(s): %s" % (where, ", ".join(sorted(unknown))))
        pid = p.get("id")
        if not isinstance(pid, str) or not ID_RE.fullmatch(pid):
            fail("%s: id must match %s" % (where, ID_RE.pattern))
        if pid in ids:
            fail("%s: id %s is used twice" % (where, pid))
        ids.add(pid)
        finding = p.get("finding")
        if finding is not None and (not isinstance(finding, str) or not ID_RE.fullmatch(finding)):
            fail("%s: finding must match %s" % (pid, ID_RE.pattern))
        argv = p.get("argv")
        if not isinstance(argv, list) or not argv:
            fail("%s: argv must be a non-empty list of strings" % pid)
        argv = [check_str(a, "%s: each argv element" % pid) for a in argv]
        if argv[0] == "":
            fail("%s: argv[0] is empty" % pid)
        show = p.get("stdout", False)
        if not isinstance(show, bool):
            fail("%s: stdout must be true or false" % pid)
        t = timeout_of(p, default_t, pid)
        gen = []
        if "values" in p:
            if not isinstance(p["values"], list):
                fail("%s: values must be a list of strings" % pid)
            gen += [check_str(v, "%s: each value" % pid) for v in p["values"]]
        if "around" in p:
            a = p["around"]
            if not isinstance(a, dict) or set(a) - {"numbers", "strings"}:
                fail("%s: around takes only \"numbers\" and \"strings\"" % pid)
            for n in a.get("numbers", []):
                if isinstance(n, bool) or not isinstance(n, int):
                    fail("%s: around.numbers holds integers only" % pid)
                gen += around_number(n)
            for s in a.get("strings", []):
                gen += around_string(check_str(s, "%s: each around string" % pid))
        if "values" in p or "around" in p:
            if not any("{}" in x for x in argv):
                fail("%s: a template needs \"{}\" in an argv element" % pid)
            gen = dedupe(gen)
            if not gen:
                fail("%s: the template expands to no value" % pid)
            for k, v in enumerate(gen, 1):
                out.append({"id": "%s[%d]" % (pid, k), "finding": finding, "show": show, "timeout": t,
                            "argv": [x.replace("{}", v) for x in argv], "value": v})
        else:
            out.append({"id": pid, "finding": finding, "show": show, "timeout": t, "argv": argv, "value": None})
        if len(out) > MAX_PROBES:
            fail("the probe file expands to more than %d probes" % MAX_PROBES)
    return out


def esc(s, limit=200):
    r = s.encode("unicode_escape").decode("ascii").replace('"', '\\"')
    return r if len(r) <= limit else r[:limit] + "...(%d chars)" % len(s)


def run_one(p, cwd, scratch):
    env = dict(os.environ, PWD=cwd)
    so, se = os.path.join(scratch, "out"), os.path.join(scratch, "err")
    with open(so, "wb") as fo, open(se, "wb") as fe:
        try:
            proc = subprocess.Popen([a.encode("utf-8", "surrogateescape") for a in p["argv"]], cwd=cwd, env=env,
                                    stdin=subprocess.DEVNULL, stdout=fo, stderr=fe, start_new_session=True)
        except OSError as e:
            return {"rc": "cannot-start", "out": b"", "err": str(e.strerror).encode()}
        # The wait runs in short slices so a stop from outside (STOP, set by on_signal) is seen at
        # once; the signal handler only records it, so nothing is interrupted half way.
        deadline, rc = time.monotonic() + p["timeout"], None
        try:
            while rc is None and not STOP:
                left = deadline - time.monotonic()
                if left <= 0:
                    rc = "timeout"
                    break
                try:
                    rc = proc.wait(timeout=min(0.1, left))
                except subprocess.TimeoutExpired:
                    pass
        finally:
            # The whole process group goes, on a timeout, after a normal exit and on a stop alike: a
            # probe that left a child behind must not keep running into the other commit's run, nor
            # outlive the script.
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except OSError:
                pass
            proc.wait()
        if STOP:
            fail("stopped by signal %d; the running probe was killed" % STOP[0])
    with open(so, "rb") as fo, open(se, "rb") as fe:
        return {"rc": rc, "out": fo.read(), "err": fe.read()}


def digest(b):
    return hashlib.sha256(b).hexdigest()[:12]


def main():
    mode = sys.argv[1]
    if mode == "ignored":  # run in the foreground, so it sees the dispositions the caller gave
        print(" ".join(n for n in SIGNALS if signal.getsignal(getattr(signal, n)) == signal.SIG_IGN))
        return 0
    if mode == "run":
        # First, before the probe file is read: this runner is a background job, which bash starts
        # with INT and QUIT ignored. A signal the caller ignored stays ignored (and so reaches the
        # probe ignored); every other one gets the handler, which exec turns back into the default
        # in the probe. A stop that lands before this line is sent again by the script's stop().
        ignored = set(sys.argv[8].split())
        for n in SIGNALS:
            signal.signal(getattr(signal, n), signal.SIG_IGN if n in ignored else on_signal)
    probe_file = sys.argv[2]
    probes = expand(probe_file)
    if mode == "list":
        for p in probes:
            print("%s finding=%s argv=%s" % (p["id"], p["finding"] or "-",
                                             json.dumps(p["argv"], ensure_ascii=True)))
        print("behaviour-diff: %d probes" % len(probes))
        return 0
    wt, scratch, side, results = sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6]
    rows = []
    for p in probes:
        if STOP:
            fail("stopped by signal %d" % STOP[0])
        r = run_one(p, wt, scratch)
        rows.append({"rc": str(r["rc"]), "out": digest(r["out"]), "err": digest(r["err"]),
                     "text": r["out"].decode("utf-8", "replace") if p["show"] else None})
    with open(results, "w") as fh:
        json.dump(rows, fh)
    if side == "base":
        return 0
    with open(sys.argv[7]) as fh:
        base_rows = json.load(fh)
    if len(base_rows) != len(rows):
        fail("internal: %d base results for %d probes" % (len(base_rows), len(rows)))
    counts = {"same": 0, "expected": 0, "supplementary": 0, "not-changed": 0, "inconclusive": 0}
    for p, b, h in zip(probes, base_rows, rows):
        if b["rc"] == h["rc"] and b["rc"] in ("timeout", "cannot-start"):
            kind = "inconclusive"  # nothing ran to the end at either commit, so nothing was compared
        elif b == h:
            kind = "not-changed" if p["finding"] else "same"
        else:
            kind = "expected" if p["finding"] else "supplementary"
        counts[kind] += 1
        what = []
        if b["rc"] != h["rc"]:
            what.append("exit %s -> %s" % (b["rc"], h["rc"]))
        if b["out"] != h["out"]:
            what.append("stdout %s -> %s" % (b["out"], h["out"]))
        if b["err"] != h["err"]:
            what.append("stderr %s -> %s" % (b["err"], h["err"]))
        line = "%-13s %s finding=%s" % (kind, p["id"], p["finding"] or "-")
        if kind == "inconclusive" and h["rc"] == "timeout":
            line += ": timed out at both commits after %ss" % p["timeout"]
        elif kind == "inconclusive":
            line += ": could not start at both commits"
        elif what:
            line += ": " + ", ".join(what)
        else:
            line += ": exit %s" % h["rc"]
        if kind == "supplementary":
            line += " (supplementary semantic change: no finding names it; for the reviewer)"
        print(line)
        if p["value"] is not None and kind not in ("same", "not-changed"):
            print("  value: \"%s\"" % esc(p["value"]))
        if p["show"] and b["text"] != h["text"]:
            print("  base stdout: \"%s\"" % esc(b["text"]))
            print("  head stdout: \"%s\"" % esc(h["text"]))
    print("behaviour-diff: %d probes; same %d, expected %d, supplementary %d, not-changed %d, inconclusive %d"
          % (len(probes), counts["same"], counts["expected"], counts["supplementary"],
             counts["not-changed"], counts["inconclusive"]))
    if counts["supplementary"]:
        return 1
    return 2 if counts["inconclusive"] else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except BaseException as e:  # any internal error is "cannot run", never "a difference"
        print("behaviour-diff: internal error: %s: %s" % (type(e).__name__, e), file=sys.stderr)
        sys.exit(2)
PYEOF

if [ "$LIST" = 1 ]; then python3 -I "$PY" list "$PROBES"; rc=$?; [ "$rc" -le 2 ] || rc=2; exit "$rc"; fi
# Validate the probe file before any worktree is made.
python3 -I "$PY" list "$PROBES" >/dev/null || exit 2
IGNORED="$(python3 -I "$PY" ignored)" || die "cannot read the signal dispositions"
TOP="$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null)" || die "$REPO is not inside a git repository"
resolve() {
  case "$1" in -*) die "a commit may not start with -: $1" ;; esac
  git -C "$TOP" rev-parse --verify --quiet --end-of-options "$1^{commit}" 2>/dev/null || die "cannot resolve $1 to a commit"
}
BASE="$(resolve "$BASE_ARG")" || exit 2
HEAD_SHA="$(resolve "$HEAD_ARG")" || exit 2
WT="$(mktemp -d "${TMPDIR:-/tmp}/behaviour-diff.XXXXXXXX")" || die "mktemp failed"
WT="$(cd "$WT" && pwd -P)"
mkdir -p "$WT/scratch" || die "cannot make $WT/scratch"
echo "behaviour-diff: base ${BASE:0:12} head ${HEAD_SHA:0:12}"
side() { # side commit
  git -C "$TOP" -c core.hooksPath=/dev/null worktree add -q --detach "$WT/tree" "$2" >/dev/null 2>&1 \
    || die "git cannot make a worktree at $2 (${1})"
  # In the background, so a signal to this script runs stop at once instead of after the probe;
  # stdin is passed on explicitly (a background job would get /dev/null), the probe gets /dev/null.
  LAUNCHING=1
  python3 -I "$PY" run "$PROBES" "$WT/tree" "$WT/scratch" "$1" "$WT/$1.json" "$WT/base.json" "$IGNORED" <&0 &
  PYPID=$!; LAUNCHING=0
  [ -z "$PENDING" ] || stop "$PENDING"
  wait "$PYPID"; rc=$?; PYPID=""
  git -C "$TOP" worktree remove --force "$WT/tree" >/dev/null 2>&1 || die "git cannot remove the worktree of $1"
  return "$rc"
}
side base "$BASE"; rc=$?; [ "$rc" = 0 ] || exit 2
side head "$HEAD_SHA"; rc=$?
[ "$rc" -le 2 ] || rc=2
exit "$rc"
