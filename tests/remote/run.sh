#!/usr/bin/env bash
# Drives install-remote.sh offline: a local archive and SHA256SUMS stand in for the GitHub release.
# Prints a pass/fail table and exits non-zero on any failure.
set -u
T="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$T/../.." && pwd)"
W="$(mktemp -d "${TMPDIR:-/tmp}/remote-test.XXXXXXXX")"; trap 'rm -rf "$W"' EXIT
PASS=0; FAIL=0; ROWS=()
row() { if [ "$2" = ok ]; then PASS=$((PASS+1)); ROWS+=("PASS | $1"); else FAIL=$((FAIL+1)); ROWS+=("FAIL | $1"); fi; }
check() { local n="$1"; shift; if "$@"; then row "$n" ok; else row "$n" bad; fi; }

# A release folder with this checkout's install.sh and skills, packed as the release workflow does.
V=9.9.9; R="$W/pack/pr-reviewer-fixer-$V"; mkdir -p "$R"
cp "$ROOT/install.sh" "$R/"; cp "$ROOT/VERSION" "$R/"; cp -R "$ROOT/.agents" "$R/"
echo "$V" > "$R/VERSION"
tar -czf "$W/pr-reviewer-fixer-$V.tar.gz" -C "$W/pack" "pr-reviewer-fixer-$V"
(cd "$W" && (sha256sum pr-reviewer-fixer-$V.tar.gz 2>/dev/null || shasum -a 256 pr-reviewer-fixer-$V.tar.gz) > SHA256SUMS)
A="$W/pr-reviewer-fixer-$V.tar.gz"; S="$W/SHA256SUMS"
IR="$ROOT/install-remote.sh"

out="$(bash "$IR" --archive "$A" --sums "$S" --harness codex 2>&1)"; rc=$?
check "a verified archive, dry run -> exit 0, checksum named" eval '[ "$rc" = 0 ] && printf %s "$out" | grep -q "checksum verified"'
check "the dry run writes nothing" eval '[ ! -e "$W/proj/.agents" ]'

mkdir -p "$W/proj" && (cd "$W/proj" && HOME="$W/home" bash "$IR" --archive "$A" --sums "$S" --harness codex --yes >"$W/y.out" 2>&1); rc=$?
check "--yes installs the release skills into a project" eval '[ "$rc" = 0 ] && [ -f "$W/proj/.agents/skills/pr-reviewer/SKILL.md" ] && [ -f "$W/proj/.agents/skills/pr-merge-fixer/SKILL.md" ]'

printf 'deadbeef  %s\n' "$(basename "$A")" > "$W/bad.sums"
out="$(bash "$IR" --archive "$A" --sums "$W/bad.sums" --harness codex --yes 2>&1)"; rc=$?
check "a wrong checksum -> refused, nothing installed" eval '[ "$rc" = 1 ] && printf %s "$out" | grep -q "does not match"'

cp "$A" "$W/notmine.tar.gz"; bash "$IR" --archive "$W/notmine.tar.gz" --sums "$S" --harness codex >/dev/null 2>&1; rc=$?
check "an archive with another name -> refused" eval '[ "$rc" = 1 ]'

python3 - "$W" <<'PY'
import sys, tarfile, io, hashlib
w = sys.argv[1]
name = "pr-reviewer-fixer-8.8.8.tar.gz"
with tarfile.open(f"{w}/{name}", "w:gz") as t:
    data = b"x"
    info = tarfile.TarInfo("../escape.txt"); info.size = len(data)
    t.addfile(info, io.BytesIO(data))
h = hashlib.sha256(open(f"{w}/{name}", "rb").read()).hexdigest()
open(f"{w}/evil.sums", "w").write(f"{h}  {name}\n")
PY
out="$(bash "$IR" --archive "$W/pr-reviewer-fixer-8.8.8.tar.gz" --sums "$W/evil.sums" --harness codex 2>&1)"; rc=$?
check "an archive member that steps out of its folder -> refused" eval '[ "$rc" = 1 ] && printf %s "$out" | grep -q "outside its folder"'
check "nothing escaped the scratch folder" eval '[ ! -e "$W/escape.txt" ]'

printf '%s\n' "${ROWS[@]}"
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
