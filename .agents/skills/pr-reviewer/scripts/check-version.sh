#!/usr/bin/env bash
#
# check-version.sh: tells a person that a newer release of pr-reviewer and pr-fixer exists.
#
# It reads the installed version from `metadata.version` in the SKILL.md next to this script's
# folder, asks GitHub for the latest release, and prints one notice when the release is newer. It
# never downloads or installs anything: updating skills changes controlled configuration, so a
# person decides and runs the install step from the README.
#
# It must never get in the way of a review, so every failure path is silent and exits 0:
# offline, no python3, a 404, a rate limit, an unreadable version, a malformed answer.
#
# Skipped without any request when:
#   PR_SKILLS_NO_UPDATE_CHECK=1   the person opted out
#   CI=true or GITHUB_ACTIONS=true  automatic runs must not depend on the network for this
#
# Environment (all optional):
#   PR_SKILLS_RELEASE_URL   release API URL; default is the latest release of the upstream repo.
#                           Any URL curl understands works, which is how the tests feed a file.
#   PR_SKILLS_CACHE_DIR     where the answer is cached for 24 hours; default
#                           ${XDG_CACHE_HOME:-$HOME/.cache}/pr-reviewer-fixer
#
# Usage: check-version.sh [--installed]
#   --installed   print the installed version only, no network
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL_MD="$HERE/../SKILL.md"
UPSTREAM="https://api.github.com/repos/jonyfs/pr-reviewer-fixer/releases/latest"
TTL=86400

command -v python3 >/dev/null 2>&1 || exit 0

installed="$(python3 -I - "$SKILL_MD" <<'PY' 2>/dev/null
import re, sys
try:
    text = open(sys.argv[1], encoding="utf-8").read()
except OSError:
    sys.exit(0)
m = re.match(r"---\n(.*?)\n---", text, re.S)
if m:
    v = re.search(r"^metadata:\s*\n(?:[ \t]+.*\n)*?[ \t]+version:\s*[\"']?(\d+\.\d+\.\d+)", m.group(1) + "\n", re.M)
    if v:
        print(v.group(1))
PY
)"

if [ "${1:-}" = "--installed" ]; then
  [ -n "$installed" ] && echo "$installed"
  exit 0
fi

[ -n "$installed" ] || exit 0
[ "${PR_SKILLS_NO_UPDATE_CHECK:-}" = "1" ] && exit 0
[ "${CI:-}" = "true" ] && exit 0
[ "${GITHUB_ACTIONS:-}" = "true" ] && exit 0

URL="${PR_SKILLS_RELEASE_URL:-$UPSTREAM}"
CACHE_DIR="${PR_SKILLS_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/pr-reviewer-fixer}"
CACHE="$CACHE_DIR/latest"

latest=""
now="$(date +%s)"
if [ -r "$CACHE" ]; then
  read -r stamp tag link <"$CACHE" 2>/dev/null || stamp=0
  case "$stamp" in ''|*[!0-9]*) stamp=0 ;; esac
  if [ $((now - stamp)) -lt "$TTL" ] && [ -n "${tag:-}" ]; then latest="$tag"; page="${link:-}"; fi
fi

if [ -z "$latest" ]; then
  command -v curl >/dev/null 2>&1 || exit 0
  body="$(curl -fsSL --max-time 5 -H 'Accept: application/vnd.github+json' "$URL" 2>/dev/null)" || exit 0
  parsed="$(printf '%s' "$body" | python3 -I -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(str(d.get("tag_name", "")).lstrip("v"), d.get("html_url", ""))
except Exception:
    pass
' 2>/dev/null)"
  latest="${parsed%% *}"
  page="${parsed#* }"
  [ -n "$latest" ] || exit 0
  mkdir -p "$CACHE_DIR" 2>/dev/null && printf '%s %s %s\n' "$now" "$latest" "$page" >"$CACHE" 2>/dev/null
fi

newer="$(python3 -I - "$installed" "$latest" <<'PY' 2>/dev/null
import re, sys
def parse(v):
    m = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", v.strip())
    return tuple(int(x) for x in m.groups()) if m else None
a, b = parse(sys.argv[1]), parse(sys.argv[2])
print("yes" if a and b and b > a else "")
PY
)"
[ "$newer" = "yes" ] || exit 0

echo "pr-skills: version $latest is available, installed is $installed.${page:+ Release notes: $page}"
echo "  Updating changes the skills your agent follows, so a person decides. To update, repeat the install step in the README from the new release."
echo "  Silence this check with PR_SKILLS_NO_UPDATE_CHECK=1."
exit 0
