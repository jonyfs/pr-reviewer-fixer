#!/usr/bin/env bash
# Drives update.sh and the --latest / --decline modes of check-version.sh against a fake release
# served from local files (file:// URLs). No network needed.
#
# Every successful --yes row passes --allow-custom-source and points both variables at local files,
# since the upstream address is a constant and the suite must not reach GitHub. The default path
# (no flag, no variable) is covered two ways: refusal rows with the variables set and no flag, and
# one row that puts a stub `curl` first on PATH, which logs each call and serves the fake release
# for the upstream https addresses only, then asserts those exact addresses were asked for.
# Usage: run.sh <skill scripts dir> <install.sh>
set -u
unset REVIEW_BLOCK_AT PUSH_GUARD_ALLOW_SENSITIVE
T="$(cd "$(dirname "$0")" && pwd)"
SRC="$(cd "${1:?scripts dir}" && pwd)"
INSTALL="$(cd "$(dirname "${2:?install.sh}")" && pwd)/$(basename "$2")"
ROOT="$(cd "$SRC/../../../.." && pwd)"
W="$T/state-${TEST_TAG:-main}"; rm -rf "$W"; mkdir -p "$W"
PASS=0; FAIL=0
check() { local name="$1"; shift; if "$@"; then PASS=$((PASS+1)); echo "PASS | $name"; else FAIL=$((FAIL+1)); echo "FAIL | $name"; fi; }

NEW=99.1.0
# A fake release: the repository's skills and install.sh under a higher version.
mkrelease() { # <version> <dir>: archive, SHA256SUMS and release.json in <dir>/v<version>/
  local v="$1" d="$2" pk="$W/pk-$1"
  rm -rf "$pk"; mkdir -p "$pk/pr-reviewer-fixer-$v" "$d/v$v"
  cp -R "$ROOT/.agents" "$ROOT/install.sh" "$pk/pr-reviewer-fixer-$v/"
  echo "$v" >"$pk/pr-reviewer-fixer-$v/VERSION"
  for s in pr-reviewer pr-fixer; do
    sed -E "s/version: \"[0-9.]+\"/version: \"$v\"/" "$pk/pr-reviewer-fixer-$v/.agents/skills/$s/SKILL.md" >"$pk/x" \
      && mv "$pk/x" "$pk/pr-reviewer-fixer-$v/.agents/skills/$s/SKILL.md"
  done
  echo "# marker of $v" >>"$pk/pr-reviewer-fixer-$v/.agents/skills/pr-reviewer/references/pr-protocol.md"
  find "$pk" -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null
  (cd "$pk" && tar -czf "$d/v$v/pr-reviewer-fixer-$v.tar.gz" "pr-reviewer-fixer-$v")
  (cd "$d/v$v" && sha256sum "pr-reviewer-fixer-$v.tar.gz" >SHA256SUMS)
  printf '{"tag_name":"v%s","html_url":"https://github.com/jonyfs/pr-reviewer-fixer/releases/tag/v%s"}' \
    "$v" "$v" >"$d/release-$v.json"
}
REL="$W/rel"; mkrelease "$NEW" "$REL"

# A fresh install of the current source in a scratch skills directory.
mkinstall() { # <dir>
  rm -rf "$1"; mkdir -p "$1"
  bash "$INSTALL" --target "$1" --source "$ROOT/.agents/skills" --yes >/dev/null 2>&1
}
# runu <skills dir> <cache name> <release root> [update.sh args]: one run against a fake release,
# with the flag that lets the test variables through. UPATH replaces PATH when a row sets it.
runu() {
  local d="$1" c="$2" r="$3"; shift 3
  env -i PATH="${UPATH:-$PATH}" HOME="$W/home" TMPDIR="$W/tmp" PR_SKILLS_CACHE_DIR="$W/$c" \
    PR_SKILLS_RELEASE_URL="file://$r/release-$NEW.json" PR_SKILLS_DOWNLOAD_URL="file://$r" \
    bash "$d/pr-reviewer/scripts/update.sh" --allow-custom-source "$@" 2>&1
}
nothing_left() { [ -z "$(ls -A "$W/tmp")" ]; }
mkdir -p "$W/tmp" "$W/home"
ver() { "$1/scripts/check-version.sh" --installed; }

# 1. Dry run changes nothing.
A="$W/a"; mkinstall "$A"; OLD="$(ver "$A/pr-reviewer")"
before="$(cd "$A" && find . -type f | sort | xargs sha256sum | sha256sum)"
out="$(runu "$A" cache "$REL")"; rc=$?
after="$(cd "$A" && find . -type f | sort | xargs sha256sum | sha256sum)"
check "no --yes: prints the plan, exit 0, changes nothing" eval \
  '[ $rc = 0 ] && [ "$before" = "$after" ] && printf %s "$out" | grep -q "would install $NEW" && printf %s "$out" | grep -q "Run again with --yes"'

# 2. --yes installs both skills.
out="$(runu "$A" cache "$REL" --yes)"; rc=$?
check "--yes: exit 0, both skills at the new version" eval \
  '[ $rc = 0 ] && [ "$(ver "$A/pr-reviewer")" = "$NEW" ] && [ "$(ver "$A/pr-fixer")" = "$NEW" ] && printf %s "$out" | grep -q "now at $NEW"'
check "--yes: the new files are in place" eval 'grep -q "marker of $NEW" "$A/pr-reviewer/references/pr-protocol.md"'
check "--yes: no scratch directory is left behind" nothing_left
out="$(env -i PATH="$PATH" HOME="$W/home" TMPDIR="$W/tmp" PR_SKILLS_CACHE_DIR="$W/cache" \
  PR_SKILLS_RELEASE_URL="file://$REL/release-$NEW.json" PR_SKILLS_DOWNLOAD_URL="file://$REL" \
  bash "$A/pr-fixer/scripts/update.sh" --yes --allow-custom-source 2>&1)"; rc=$?
check "run again from the new copy: already up to date, exit 0" eval \
  '[ $rc = 0 ] && printf %s "$out" | grep -q "already up to date"'

# 3. One skill installed: only that one is updated.
B="$W/b"; mkinstall "$B"; rm -rf "$B/pr-fixer"
out="$(runu "$B" cache2 "$REL" --yes)"; rc=$?
check "only pr-reviewer installed: updated, pr-fixer not added" eval \
  '[ $rc = 0 ] && [ "$(ver "$B/pr-reviewer")" = "$NEW" ] && [ ! -e "$B/pr-fixer" ]'

# 4. A checksum that does not match is refused and the install is untouched.
C="$W/c"; mkinstall "$C"; BAD="$W/badrel"; mkrelease "$NEW" "$BAD"
echo "tampered" >>"$BAD/v$NEW/pr-reviewer-fixer-$NEW.tar.gz"
out="$(runu "$C" cache3 "$BAD" --yes)"; rc=$?
check "wrong SHA-256: refused, exit 1, install untouched, no scratch left" eval \
  '[ $rc = 1 ] && printf %s "$out" | grep -q "SHA-256" && [ "$(ver "$C/pr-reviewer")" = "$OLD" ] && nothing_left'

# 5. A missing archive.
rm -f "$BAD/v$NEW/pr-reviewer-fixer-$NEW.tar.gz"
out="$(runu "$C" cache3 "$BAD" --yes)"; rc=$?
check "download fails: exit 1, names the archive, the source and the curl exit, install untouched, no scratch left" eval \
  '[ $rc = 1 ] && printf %s "$out" | grep -q "could not download pr-reviewer-fixer-$NEW.tar.gz from CUSTOM file://" && printf %s "$out" | grep -Eq "curl exit [0-9]+" && [ "$(ver "$C/pr-reviewer")" = "$OLD" ] && nothing_left'

# 6. The archive's VERSION is not the release asked for.
D="$W/d"; mkinstall "$D"; mkrelease "$NEW" "$W/vrel"
(cd "$W/vrel/v$NEW" && mkdir -p z && tar -xzf "pr-reviewer-fixer-$NEW.tar.gz" -C z \
  && echo 1.0.0 >"z/pr-reviewer-fixer-$NEW/VERSION" \
  && tar -czf "pr-reviewer-fixer-$NEW.tar.gz" -C z "pr-reviewer-fixer-$NEW" \
  && sha256sum "pr-reviewer-fixer-$NEW.tar.gz" >SHA256SUMS && rm -rf z)
out="$(runu "$D" cache4 "$W/vrel" --yes)"; rc=$?
check "archive VERSION differs from the release: refused, install untouched, no scratch left" eval \
  '[ $rc = 1 ] && printf %s "$out" | grep -q "holds version" && [ "$(ver "$D/pr-reviewer")" = "$OLD" ] && nothing_left'

# 7. Members with .. or an absolute path are refused before anything is unpacked.
E="$W/e"; mkinstall "$E"
badmember() { # <dir> <member name>: an archive with that one member, and a matching SHA256SUMS
  mkrelease "$NEW" "$1"
  python3 - "$1/v$NEW/pr-reviewer-fixer-$NEW.tar.gz" "$2" <<'PY'
import io, sys, tarfile
with tarfile.open(sys.argv[1], "w:gz") as t:
    data = b"x"
    ti = tarfile.TarInfo(sys.argv[2]); ti.size = len(data)
    t.addfile(ti, io.BytesIO(data))
PY
  (cd "$1/v$NEW" && sha256sum "pr-reviewer-fixer-$NEW.tar.gz" >SHA256SUMS)
}
# The names would land at $W/escape and $W/abs-escape if the archive were unpacked.
badmember "$W/trel" "pr-reviewer-fixer-99.1.0/../../../../escape"
out="$(runu "$E" cache5 "$W/trel" --yes)"; rc=$?
check "member with '..': refused, nothing written outside the scratch, install untouched" eval \
  '[ $rc = 1 ] && printf %s "$out" | grep -q "absolute path or" && [ "$(ver "$E/pr-reviewer")" = "$OLD" ] && nothing_left && [ ! -e "$W/escape" ] && [ ! -e "$W/tmp/escape" ]'
badmember "$W/arel" "$W/abs-escape"
out="$(runu "$E" cache5 "$W/arel" --yes)"; rc=$?
check "member with an absolute path: refused, nothing written there, install untouched" eval \
  '[ $rc = 1 ] && printf %s "$out" | grep -q "absolute path or" && [ "$(ver "$E/pr-reviewer")" = "$OLD" ] && nothing_left && [ ! -e "$W/abs-escape" ]'

# 8. No answer from GitHub.
F="$W/f"; mkinstall "$F"
out="$(env -i PATH="$PATH" HOME="$W/home" TMPDIR="$W/tmp" PR_SKILLS_CACHE_DIR="$W/cache6" \
  PR_SKILLS_RELEASE_URL="file://$W/nowhere.json" \
  bash "$F/pr-reviewer/scripts/update.sh" --yes --allow-custom-source 2>&1)"; rc=$?
check "release answer unreachable: loud, exit 1, nothing changed" eval \
  '[ $rc = 1 ] && printf %s "$out" | grep -q "could not read the latest release" && [ "$(ver "$F/pr-reviewer")" = "$OLD" ]'

# 9. An installed version newer than the release is never replaced.
G="$W/g"; mkinstall "$G"
printf '{"tag_name":"v0.0.1","html_url":"x"}' >"$W/old-release.json"
out="$(env -i PATH="$PATH" HOME="$W/home" TMPDIR="$W/tmp" PR_SKILLS_CACHE_DIR="$W/cache7" \
  PR_SKILLS_RELEASE_URL="file://$W/old-release.json" \
  bash "$G/pr-reviewer/scripts/update.sh" --yes --allow-custom-source 2>&1)"; rc=$?
check "installed newer than the release: refuses to go back, exit 1" eval \
  '[ $rc = 1 ] && printf %s "$out" | grep -q "refusing to go back" && [ "$(ver "$G/pr-reviewer")" = "$OLD" ]'

# 10. A checkout of the repository itself is refused.
out="$(env -i PATH="$PATH" HOME="$W/home" TMPDIR="$W/tmp" PR_SKILLS_CACHE_DIR="$W/cache8" \
  bash "$SRC/update.sh" --yes 2>&1)"; rc=$?
check "run from the repository checkout: refused, exit 1" eval \
  '[ $rc = 1 ] && printf %s "$out" | grep -q "checkout of the repository itself"'

# 11. Unknown argument.
out="$(bash "$A/pr-reviewer/scripts/update.sh" --force 2>&1)"; rc=$?
check "unknown argument: exit 1" eval '[ $rc = 1 ] && printf %s "$out" | grep -q "unknown argument"'

# 12. The review-gate template of each installed skill keeps its prefix when the install is not
# under .agents/skills. Both skills ship a copy, and install.sh --target rewrites neither.
gate() { printf '%s/%s/templates/review-gate.yml' "$1" "$2"; }
keeps_prefix() { # <skills dir> <skill>: the copy reads .claude/skills and no .agents/skills
  grep -q "\.claude/skills/pr-reviewer/scripts/" "$(gate "$1" "$2")" \
    && ! grep -q "\.agents/skills/pr-reviewer/scripts/" "$(gate "$1" "$2")"
}
mkclaude() { # <project dir>: both skills installed with --harness claude-code
  rm -rf "$1"; mkdir -p "$1/.claude/skills"
  (cd "$1" && bash "$INSTALL" --harness claude-code --source "$ROOT/.agents/skills" --yes \
    >/dev/null 2>&1)
}
H="$W/h/.claude/skills"; mkclaude "$W/h"
grep -q "\.claude/skills/pr-reviewer/scripts/" "$(gate "$H" pr-reviewer)" \
  && grep -q "\.claude/skills/pr-reviewer/scripts/" "$(gate "$H" pr-fixer)"; had=$?
out="$(runu "$H" cache9 "$REL" --yes)"; rc=$?
check "pr-reviewer template prefix in a .claude/skills install survives the update" eval \
  '[ $had = 0 ] && [ $rc = 0 ] && keeps_prefix "$H" pr-reviewer'
check "template prefix of the pr-fixer copy in a .claude/skills install survives the update" eval \
  '[ $had = 0 ] && [ $rc = 0 ] && keeps_prefix "$H" pr-fixer'
check "an unchanged template is not announced as changed" eval \
  '! printf %s "$out" | grep -q "review-gate.yml changed in this release"'

# 14. install.sh fails on the second skill. The archive's install.sh is a stub that replaces
# pr-reviewer through the real one, then fails the way a pr-fixer swap would.
J="$W/j"; mkinstall "$J"; mkrelease "$NEW" "$W/frel"
FP="$W/frel/v$NEW"
(cd "$FP" && mkdir -p z && tar -xzf "pr-reviewer-fixer-$NEW.tar.gz" -C z \
  && mv "z/pr-reviewer-fixer-$NEW/install.sh" "z/pr-reviewer-fixer-$NEW/install-real.sh" \
  && cat >"z/pr-reviewer-fixer-$NEW/install.sh" <<'STUB'
#!/usr/bin/env bash
d="$(cd "$(dirname "$0")" && pwd)"; args=()
for a in "$@"; do [ "$a" = both ] && a=pr-reviewer; args+=("$a"); done
bash "$d/install-real.sh" "${args[@]}" || exit 1
echo "install: simulated failure while replacing pr-fixer" >&2
exit 1
STUB
  tar -czf "pr-reviewer-fixer-$NEW.tar.gz" -C z "pr-reviewer-fixer-$NEW" \
  && sha256sum "pr-reviewer-fixer-$NEW.tar.gz" >SHA256SUMS && rm -rf z)
out="$(runu "$J" cache10 "$W/frel" --yes)"; rc=$?
check "install.sh fails on the second skill: exit 1, says to run it again, no scratch left" eval \
  '[ $rc = 1 ] && printf %s "$out" | grep -q "install.sh failed" && printf %s "$out" | grep -q "run update.sh again" && nothing_left'
check "that failure leaves a mixed install: pr-reviewer replaced, pr-fixer as it was" eval \
  '[ "$(ver "$J/pr-reviewer")" = "$NEW" ] && [ "$(ver "$J/pr-fixer")" = "$OLD" ]'
out="$(runu "$J" cache10 "$REL" --yes)"; rc=$?
check "a second run, once the cause is gone, finishes the job" eval \
  '[ $rc = 0 ] && [ "$(ver "$J/pr-reviewer")" = "$NEW" ] && [ "$(ver "$J/pr-fixer")" = "$NEW" ] && nothing_left'

# 14b. The same failure in a .claude/skills install: the copy of the skill that was replaced
# loses nothing, and neither does the one that was not.
H2="$W/h2/.claude/skills"; mkclaude "$W/h2"
out="$(runu "$H2" cache10b "$W/frel" --yes)"; rc=$?
check "install.sh fails on the second skill: both templates keep their .claude/skills prefix" eval \
  '[ $rc = 1 ] && [ "$(ver "$H2/pr-reviewer")" = "$NEW" ] && [ "$(ver "$H2/pr-fixer")" = "$OLD" ] \
    && keeps_prefix "$H2" pr-reviewer && keeps_prefix "$H2" pr-fixer'
out="$(runu "$H2" cache10b "$REL" --yes)"; rc=$?
check "the next run finishes the job and both templates still keep the prefix" eval \
  '[ $rc = 0 ] && [ "$(ver "$H2/pr-fixer")" = "$NEW" ] \
    && keeps_prefix "$H2" pr-reviewer && keeps_prefix "$H2" pr-fixer'

# 14c. A release that changes only the pr-fixer copy of the template is announced, and the new
# content arrives with the old prefix.
mkrelease "$NEW" "$W/grel"
(cd "$W/grel/v$NEW" && mkdir -p z && tar -xzf "pr-reviewer-fixer-$NEW.tar.gz" -C z \
  && echo "# gate marker of $NEW" \
    >>"z/pr-reviewer-fixer-$NEW/.agents/skills/pr-fixer/templates/review-gate.yml" \
  && tar -czf "pr-reviewer-fixer-$NEW.tar.gz" -C z "pr-reviewer-fixer-$NEW" \
  && sha256sum "pr-reviewer-fixer-$NEW.tar.gz" >SHA256SUMS && rm -rf z)
H3="$W/h3/.claude/skills"; mkclaude "$W/h3"
out="$(runu "$H3" cache10c "$W/grel" --yes)"; rc=$?
check "only the pr-fixer template changed: announced, naming pr-fixer only" eval \
  '[ $rc = 0 ] && printf %s "$out" | grep -q "review-gate.yml changed in this release (pr-fixer)"'
check "only the pr-fixer template changed: its new content is in place under the old prefix" eval \
  'grep -q "gate marker of $NEW" "$(gate "$H3" pr-fixer)" && keeps_prefix "$H3" pr-fixer \
    && keeps_prefix "$H3" pr-reviewer'

# 15. A source variable moves nothing without --allow-custom-source.
K="$W/k"; mkinstall "$K"
before="$(cd "$K" && find . -type f | sort | xargs sha256sum | sha256sum)"
out="$(env -i PATH="$PATH" HOME="$W/home" TMPDIR="$W/tmp" PR_SKILLS_CACHE_DIR="$W/cache11" \
  PR_SKILLS_RELEASE_URL="file://$REL/release-$NEW.json" PR_SKILLS_DOWNLOAD_URL="file://$REL" \
  bash "$K/pr-reviewer/scripts/update.sh" --yes 2>&1)"; rc=$?
after="$(cd "$K" && find . -type f | sort | xargs sha256sum | sha256sum)"
check "both variables set, no flag: refused, names a variable, nothing changed" eval \
  '[ $rc = 1 ] && printf %s "$out" | grep -q "PR_SKILLS_DOWNLOAD_URL is set" && printf %s "$out" | grep -q -- "--allow-custom-source" && [ "$before" = "$after" ] && nothing_left'
out="$(env -i PATH="$PATH" HOME="$W/home" TMPDIR="$W/tmp" PR_SKILLS_CACHE_DIR="$W/cache11" \
  PR_SKILLS_RELEASE_URL="file://$REL/release-$NEW.json" \
  bash "$K/pr-reviewer/scripts/update.sh" --yes 2>&1)"; rc=$?
after="$(cd "$K" && find . -type f | sort | xargs sha256sum | sha256sum)"
check "RELEASE_URL alone, no flag: refused, names it, nothing changed" eval \
  '[ $rc = 1 ] && printf %s "$out" | grep -q "PR_SKILLS_RELEASE_URL is set" && [ "$before" = "$after" ]'
out="$(env -i PATH="$PATH" HOME="$W/home" TMPDIR="$W/tmp" PR_SKILLS_CACHE_DIR="$W/cache11" \
  PR_SKILLS_DOWNLOAD_URL="file://$REL" bash "$K/pr-reviewer/scripts/update.sh" 2>&1)"; rc=$?
after="$(cd "$K" && find . -type f | sort | xargs sha256sum | sha256sum)"
check "DOWNLOAD_URL alone, no flag, no --yes: refused too, nothing changed" eval \
  '[ $rc = 1 ] && printf %s "$out" | grep -q "PR_SKILLS_DOWNLOAD_URL is set" && [ "$before" = "$after" ]'
out="$(runu "$K" cache11 "$REL")"
check "with the flag the source is printed as custom (scheme and host only), with the plan" eval \
  'printf %s "$out" | grep -q "source: release answer from CUSTOM file://, code from CUSTOM file://" && printf %s "$out" | grep -q "would install $NEW"'
out="$(runu "$K" cache11 "$REL" --yes)"
check "with the flag and --yes the done line names the custom source" eval \
  'printf %s "$out" | grep -q "now at $NEW, from CUSTOM file://"'

# 16. The shasum branch (no sha256sum on PATH, as on macOS).
if command -v shasum >/dev/null 2>&1; then
  NS="$W/nosha"; rm -rf "$NS"; mkdir -p "$NS"
  python3 - "$NS" <<'PY'
import os, sys
dst = sys.argv[1]
for d in os.environ["PATH"].split(":"):
    try:
        names = os.listdir(d)
    except OSError:
        continue
    for n in names:
        p = os.path.join(d, n)
        if n in ("sha256sum", "gsha256sum") or os.path.exists(os.path.join(dst, n)):
            continue
        if os.path.isfile(p) and os.access(p, os.X_OK):
            os.symlink(p, os.path.join(dst, n))
PY
  L="$W/l"; mkinstall "$L"
  out="$(UPATH="$NS" runu "$L" cache12 "$REL" --yes)"; rc=$?
  check "no sha256sum on PATH: shasum -a 256 checks the archive, install succeeds" eval \
    '[ $rc = 0 ] && [ "$(ver "$L/pr-reviewer")" = "$NEW" ]'
  L2="$W/l2"; mkinstall "$L2"
  tamper="$W/tamp"; mkrelease "$NEW" "$tamper"; echo x >>"$tamper/v$NEW/pr-reviewer-fixer-$NEW.tar.gz"
  out="$(UPATH="$NS" runu "$L2" cache12 "$tamper" --yes)"; rc=$?
  check "no sha256sum on PATH: a wrong sum is still refused" eval \
    '[ $rc = 1 ] && printf %s "$out" | grep -q "SHA-256" && [ "$(ver "$L2/pr-reviewer")" = "$OLD" ]'
else
  echo "SKIP | no shasum on this machine; the shasum branch is not exercised"
fi

# 17. A mirror URL with a user, a password and a signed query is never printed whole. The two
# strings below must appear in no output, and the host must (so the output is not just empty).
SECRET_URL='https://ci:s3cr3tTOKEN@mirror.test/rel?sig=abc123'
leaks() { printf %s "$1" | grep -Eq 's3cr3tTOKEN|abc123'; }
REAL_CURL="$(command -v curl)"
MB="$W/mirrorbin"; mkdir -p "$MB"
# A curl that serves file:// as usual and fails every other address the way curl does, echoing it.
cat >"$MB/curl" <<'STUB'
#!/usr/bin/env bash
url=""; for a in "$@"; do url="$a"; done
case "$url" in
  file://*) exec "$REAL_CURL" "$@" ;;
  *) echo "curl: (6) Could not resolve host while fetching $url" >&2; exit 6 ;;
esac
STUB
chmod +x "$MB/curl"
SEC="$W/s3cr3tTOKEN/abc123"; mkdir -p "$W/s3cr3tTOKEN"; cp -R "$REL" "$SEC"
M="$W/m"; mkinstall "$M"
before="$(cd "$M" && find . -type f | sort | xargs sha256sum | sha256sum)"
out1="$(env -i PATH="$MB:$PATH" HOME="$W/home" TMPDIR="$W/tmp" PR_SKILLS_CACHE_DIR="$W/cache13" \
  PR_SKILLS_RELEASE_URL="$SECRET_URL" PR_SKILLS_DOWNLOAD_URL="$SECRET_URL" \
  bash "$M/pr-reviewer/scripts/update.sh" --yes 2>&1)"; rc1=$?
out2="$(env -i PATH="$MB:$PATH" HOME="$W/home" TMPDIR="$W/tmp" PR_SKILLS_CACHE_DIR="$W/cache13" \
  PR_SKILLS_RELEASE_URL="file://$SEC/release-$NEW.json" PR_SKILLS_DOWNLOAD_URL="file://$SEC" \
  bash "$M/pr-reviewer/scripts/update.sh" --yes 2>&1)"; rc2=$?
after="$(cd "$M" && find . -type f | sort | xargs sha256sum | sha256sum)"
check "https mirror with user, password and query, no flag: refused, host shown, no secret printed" eval \
  '[ $rc1 = 1 ] && printf %s "$out1" | grep -q "host https://mirror.test" && ! leaks "$out1"'
check "file:// source with the secret in its path, no flag: refused, no secret printed" eval \
  '[ $rc2 = 1 ] && printf %s "$out2" | grep -q "host file://" && ! leaks "$out2" && [ "$before" = "$after" ]'

# An unencoded / ? or # inside the userinfo: nothing of the userinfo may reach the output.
for u in 'https://usr9x:123/456@mirror.test/x' 'https://usr9x:123#456@mirror.test/x' \
         'https://usr9x:12?3@mirror.test/x' 'https://us/r9x:7@mirror.test/x'; do
  out="$(env -i PATH="$PATH" HOME="$W/home" TMPDIR="$W/tmp" PR_SKILLS_CACHE_DIR="$W/cache13" \
    PR_SKILLS_DOWNLOAD_URL="$u" bash "$M/pr-reviewer/scripts/update.sh" --yes 2>&1)"; rc=$?
  check "refusal with an unencoded delimiter in the userinfo ($u): host not readable, no part of the userinfo printed" eval \
    '[ $rc = 1 ] && printf %s "$out" | grep -q "host https://(host not readable)" && ! printf %s "$out" | grep -Eq "usr9x|us/r9x|123|456|:12|:7"'
done

# The plan (a dry run) with the flag: a https download base and a file:// release answer.
out="$(env -i PATH="$MB:$PATH" REAL_CURL="$REAL_CURL" HOME="$W/home" TMPDIR="$W/tmp" PR_SKILLS_CACHE_DIR="$W/cache13" \
  PR_SKILLS_RELEASE_URL="file://$SEC/release-$NEW.json" PR_SKILLS_DOWNLOAD_URL="$SECRET_URL" \
  bash "$M/pr-reviewer/scripts/update.sh" --allow-custom-source 2>&1)"; rc=$?
check "plan with a https mirror: host shown, no secret printed, exit 0" eval \
  '[ $rc = 0 ] && printf %s "$out" | grep -q "would install $NEW" && printf %s "$out" | grep -q "CUSTOM https://mirror.test" && ! leaks "$out"'
# A failed download: the fake curl echoes the full URL on stderr, as a real one can.
out="$(env -i PATH="$MB:$PATH" REAL_CURL="$REAL_CURL" HOME="$W/home" TMPDIR="$W/tmp" PR_SKILLS_CACHE_DIR="$W/cache13" \
  PR_SKILLS_RELEASE_URL="file://$SEC/release-$NEW.json" PR_SKILLS_DOWNLOAD_URL="$SECRET_URL" \
  bash "$M/pr-reviewer/scripts/update.sh" --allow-custom-source --yes 2>&1)"; rc=$?
after="$(cd "$M" && find . -type f | sort | xargs sha256sum | sha256sum)"
check "download from a https mirror fails: loud, host and curl exit shown, no secret, nothing changed" eval \
  '[ $rc = 1 ] && printf %s "$out" | grep -q "could not download" && printf %s "$out" | grep -q "https://mirror.test" && printf %s "$out" | grep -q "curl exit 6" && ! leaks "$out" && [ "$before" = "$after" ] && nothing_left'
# A mirror that serves the archive and fails only SHA256SUMS, echoing the full URL on stderr: the
# only row that reaches the second curl call, so dropping its stderr redirect shows here.
SB2="$W/sumsbin"; mkdir -p "$SB2"
cat >"$SB2/curl" <<'STUB'
#!/usr/bin/env bash
out=""; url=""; prev=""
for a in "$@"; do [ "$prev" = -o ] && out="$a"; prev="$a"; url="$a"; done
case "$url" in
  *.tar.gz) cp "$STUB_REL/v$STUB_VER/${url##*/}" "$out" ;;
  *SHA256SUMS) echo "curl: (22) The requested URL returned error while fetching $url" >&2; exit 22 ;;
  *) exec "$REAL_CURL" "$@" ;;
esac
STUB
chmod +x "$SB2/curl"
out="$(env -i PATH="$SB2:$PATH" REAL_CURL="$REAL_CURL" STUB_REL="$REL" STUB_VER="$NEW" HOME="$W/home" TMPDIR="$W/tmp" \
  PR_SKILLS_CACHE_DIR="$W/cache13" PR_SKILLS_RELEASE_URL="file://$SEC/release-$NEW.json" PR_SKILLS_DOWNLOAD_URL="$SECRET_URL" \
  bash "$M/pr-reviewer/scripts/update.sh" --allow-custom-source --yes 2>&1)"; rc=$?
after="$(cd "$M" && find . -type f | sort | xargs sha256sum | sha256sum)"
check "SHA256SUMS download fails after the archive: loud, host and curl exit 22 shown, no secret, nothing changed" eval \
  '[ $rc = 1 ] && printf %s "$out" | grep -q "could not download SHA256SUMS from CUSTOM https://mirror.test" && printf %s "$out" | grep -q "curl exit 22" && ! leaks "$out" && [ "$before" = "$after" ] && nothing_left'
# The release answer from a https mirror that fails.
out="$(env -i PATH="$MB:$PATH" REAL_CURL="$REAL_CURL" HOME="$W/home" TMPDIR="$W/tmp" PR_SKILLS_CACHE_DIR="$W/cache13" \
  PR_SKILLS_RELEASE_URL="$SECRET_URL" bash "$M/pr-reviewer/scripts/update.sh" --allow-custom-source --yes 2>&1)"; rc=$?
check "release answer from a https mirror fails: loud, no secret printed" eval \
  '[ $rc = 1 ] && printf %s "$out" | grep -q "could not read the latest release from the release source (CUSTOM https://mirror.test;" && ! printf %s "$out" | grep -q "from GitHub" && ! leaks "$out"'
# A file:// source whose path holds the secret installs, and nothing it prints carries the path.
out="$(env -i PATH="$PATH" HOME="$W/home" TMPDIR="$W/tmp" PR_SKILLS_CACHE_DIR="$W/cache13" \
  PR_SKILLS_RELEASE_URL="file://$SEC/release-$NEW.json" PR_SKILLS_DOWNLOAD_URL="file://$SEC" \
  bash "$M/pr-reviewer/scripts/update.sh" --allow-custom-source --yes 2>&1)"; rc=$?
check "file:// source with the secret in its path: installs, plan and done line carry no secret" eval \
  '[ $rc = 0 ] && [ "$(ver "$M/pr-reviewer")" = "$NEW" ] && printf %s "$out" | grep -q "now at $NEW, from CUSTOM file://" && ! leaks "$out"'

# 18. --version: the release the person was asked about must be the latest one.
V="$W/v"; mkinstall "$V"
before="$(cd "$V" && find . -type f | sort | xargs sha256sum | sha256sum)"
out="$(runu "$V" cache14 "$REL" --yes --version 99.0.9)"; rc=$?
after="$(cd "$V" && find . -type f | sort | xargs sha256sum | sha256sum)"
check "--version differs from the latest release: refused, says both, nothing changed" eval \
  '[ $rc = 1 ] && printf %s "$out" | grep -q "asked about 99.0.9, but the latest release is $NEW" && [ "$before" = "$after" ] && nothing_left'
out="$(runu "$V" cache14 "$REL" --yes --version 99.9.9)"; rc=$?
after="$(cd "$V" && find . -type f | sort | xargs sha256sum | sha256sum)"
check "--version newer than the latest release: refused, says both, nothing changed" eval \
  '[ $rc = 1 ] && printf %s "$out" | grep -q "asked about 99.9.9, but the latest release is $NEW" && [ "$before" = "$after" ] && nothing_left'
for bad in 1.2 1.2.3-rc1 v1.2.3 1.2.3.4; do
  out="$(runu "$V" cache14 "$REL" --yes --version "$bad")"; rc=$?
  after="$(cd "$V" && find . -type f | sort | xargs sha256sum | sha256sum)"
  check "--version $bad (malformed): refused, nothing changed" eval \
    '[ $rc = 1 ] && printf %s "$out" | grep -q "needs a version" && [ "$before" = "$after" ] && nothing_left'
done
out="$(runu "$V" cache14 "$REL" --yes --version latest)"; rc=$?
check "--version with a non-version: refused" eval '[ $rc = 1 ] && printf %s "$out" | grep -q "needs a version"'
out="$(runu "$V" cache14 "$REL" --yes --version)"; rc=$?
check "--version with no value: refused" eval '[ $rc = 1 ] && printf %s "$out" | grep -q "needs a version"'

# 19. The default path: no flag, no variable. A stub curl serves the fake release for the upstream
# addresses and logs every call, so a wrong address in the constant, or a missing --proto, fails here.
SB="$W/stubbin"; mkdir -p "$SB"
cat >"$SB/curl" <<'STUB'
#!/usr/bin/env bash
out=""; url=""; prev=""
for a in "$@"; do [ "$prev" = -o ] && out="$a"; prev="$a"; url="$a"; done
printf '%s\n' "$*" >>"$STUB_LOG"
up=https://github.com/jonyfs/pr-reviewer-fixer/releases
case "$url" in
  https://api.github.com/repos/jonyfs/pr-reviewer-fixer/releases/latest) cat "$STUB_REL/release-$STUB_VER.json" ;;
  "$up/download/v$STUB_VER/"*) cp "$STUB_REL/v$STUB_VER/${url##*/}" "$out" ;;
  *) echo "stub curl: unexpected address $url" >&2; exit 7 ;;
esac
STUB
chmod +x "$SB/curl"
N="$W/n"; mkinstall "$N"; : >"$W/stub.log"
out="$(env -i PATH="$SB:$PATH" HOME="$W/home" TMPDIR="$W/tmp" PR_SKILLS_CACHE_DIR="$W/cache15" \
  STUB_LOG="$W/stub.log" STUB_REL="$REL" STUB_VER="$NEW" \
  bash "$N/pr-reviewer/scripts/update.sh" --yes --version "$NEW" 2>&1)"; rc=$?
UP=https://github.com/jonyfs/pr-reviewer-fixer/releases/download/v$NEW
check "default path: installs from the upstream addresses, https only, source says upstream" eval \
  '[ $rc = 0 ] && [ "$(ver "$N/pr-reviewer")" = "$NEW" ] && [ "$(ver "$N/pr-fixer")" = "$NEW" ] && printf %s "$out" | grep -q "source: release answer from upstream, code from upstream" && nothing_left'
check "default path: the log holds the release API address and both download addresses" eval \
  'grep -q "https://api.github.com/repos/jonyfs/pr-reviewer-fixer/releases/latest\$" "$W/stub.log" && grep -q "$UP/pr-reviewer-fixer-$NEW.tar.gz\$" "$W/stub.log" && grep -q "$UP/SHA256SUMS\$" "$W/stub.log"'
check "default path: every call is held to https, redirects included" eval \
  '[ "$(grep -c -- "--proto =https --proto-redir =https" "$W/stub.log")" = "$(wc -l <"$W/stub.log" | tr -d " ")" ] && [ "$(wc -l <"$W/stub.log" | tr -d " ")" = 3 ]'

# 13. check-version.sh: the notice names update.sh and the decline command; --decline silences it.
I="$W/i"; mkinstall "$I"
note() { env -i PATH="$PATH" HOME="$W/home" PR_SKILLS_CACHE_DIR="$W/cacheN" PR_SKILLS_RELEASE_URL="file://$REL/release-$NEW.json" "$@" bash "$I/pr-reviewer/scripts/check-version.sh"; }
rm -rf "$W/cacheN"; out="$(note)"
check "notice: names the update and decline commands and says a person decides" eval 'printf %s "$out" | grep -q "update.sh --yes" && printf %s "$out" | grep -q "check-version.sh --decline" && printf %s "$out" | grep -q "a person decides"'
d="$(env -i PATH="$PATH" HOME="$W/home" PR_SKILLS_CACHE_DIR="$W/cacheN" PR_SKILLS_RELEASE_URL="file://$REL/release-$NEW.json" bash "$I/pr-reviewer/scripts/check-version.sh" --decline)"; rc=$?
out="$(note)"
check "--decline: confirms, then the notice is silent" eval '[ $rc = 0 ] && printf %s "$d" | grep -q "not asking again about version $NEW" && [ -z "$out" ]'
mkrelease "99.2.0" "$REL"
out="$(env -i PATH="$PATH" HOME="$W/home" PR_SKILLS_CACHE_DIR="$W/cacheN" PR_SKILLS_RELEASE_URL="file://$REL/release-99.2.0.json" bash "$I/pr-reviewer/scripts/check-version.sh" --latest)"
out2="$(env -i PATH="$PATH" HOME="$W/home" PR_SKILLS_CACHE_DIR="$W/cacheN" PR_SKILLS_RELEASE_URL="file://$REL/release-99.2.0.json" bash "$I/pr-reviewer/scripts/check-version.sh")"
check "--latest reads fresh past the cache; a newer release is announced again after a decline" eval 'printf %s "$out" | grep -q "^99.2.0 " && printf %s "$out2" | grep -q "99.2.0 is available"'
out="$(note PR_SKILLS_NO_UPDATE_CHECK=1)"
rm -rf "$W/cacheN"; out3="$(env -i PATH="$PATH" HOME="$W/home" PR_SKILLS_CACHE_DIR="$W/cacheN" PR_SKILLS_RELEASE_URL="file://$REL/release-$NEW.json" PR_SKILLS_NO_UPDATE_CHECK=1 bash "$I/pr-reviewer/scripts/check-version.sh" --latest)"
check "--latest still answers when the opt-out variable is set" eval 'printf %s "$out3" | grep -q "^$NEW "'

echo "TOTAL: $PASS passed, $FAIL failed"
# The scratch holds copies of the skills. A green run removes it; a red run keeps it to look at.
# The model-key scan of run-all.sh reads tracked files only, so a scratch folder left behind is not read.
[ "$FAIL" = 0 ] && rm -rf "$W"
[ "$FAIL" = 0 ]
