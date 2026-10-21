#!/usr/bin/env bash
#
# path-floor.sh: the review units a change must get, decided from the paths it touches.
#
# WHY IT EXISTS. The reviewer may skip a dimension that plainly does not apply, and a cheaper
# triage step reads the diff to decide which ones do. A diff is text the author wrote, so it can
# argue a dimension away ("docs only, skip security"). The path floor is the part of that decision
# no text can move: some paths always summon a unit, whatever the diff says. Before this script the
# floor was prose examples, and `.github/workflows` was not among them, so a change to CI could get
# a light review.
#
# USAGE
#   path-floor.sh <base> <head>     the paths of `git diff <base>...<head>`, as the secret screen reads it
#   path-floor.sh --diff <file>     the paths of a unified diff (`gh pr diff` output); lint-report uses this
#
# OUTPUT. One line per mandatory unit and path, sorted: `<unit> <effort> <path>`. The path is the
# rest of the line and may hold spaces. No output means no unit is mandatory. A renamed or deleted
# file counts by its old path as well as its new one: removing a workflow is a CI change too.
#
#   unit             effort    paths
#   security         max       .github/workflows/**, .github/actions/**, action.yml or action.yaml
#                              in any directory, CODEOWNERS (root, .github/, docs/), .agents/skills/**,
#                              .claude/**, .mcp.json, a Dockerfile or Containerfile (also
#                              Dockerfile.<x> and <x>.dockerfile): the files that run CI or an agent
#   security         max       authentication, authorisation and cryptography: a path segment or
#                              file stem such as auth, oauth, login, session, password, crypto,
#                              cipher, jwt, saml, oidc, rbac, acl, permission(s), credential(s)
#   security         standard  migrations (below)
#   data-integrity   standard  migrations: a directory named migrations, migration, migrate or
#                              alembic, or a schema file (schema.sql, structure.sql, schema.rb,
#                              schema.prisma)
#   dependencies     standard  manifests and lockfiles (package.json, package-lock.json, yarn.lock,
#                              pnpm-lock.yaml, requirements*.txt, pyproject.toml, poetry.lock,
#                              uv.lock, Pipfile(.lock), go.mod, go.sum, Cargo.toml, Cargo.lock,
#                              Gemfile(.lock), *.gemspec, composer.json/.lock, pom.xml, build.gradle(.kts),
#                              gradle.lockfile, *.csproj, packages.lock.json, mix.exs/.lock,
#                              Package.swift/.resolved, Podfile(.lock), pubspec.yaml/.lock,
#                              deno.json/.lock, bun.lock(b), flake.lock)
#
# Names are compared case-insensitively, so `Codeowners` on a case-insensitive file system counts.
# The CI and agent classes are the ones push-guard.sh refuses for the fixer, plus action metadata
# and Dockerfiles. A project may add units in its own guide; nothing may remove one from this list.
#
# `review-cycle.sh lint-report` runs this over the diff it checks and refuses a report whose
# coverage note does not list each mandatory unit as run (`Mandatory units:` line, see
# references/report-contract.md). A unit with effort `max` must be listed as `(max)`.
#
# EXIT. 0 when it read every path (with or without units), 2 when git or the diff could not be read,
# or a diff section named no path it could read. It fails closed: no floor is never a guess.
set -u

die2() { echo "path-floor: $*" >&2; exit 2; }

mode="" base="" head="" file=""
case "${1:-}" in
  --diff) [ $# -eq 2 ] || die2 "usage: path-floor.sh <base> <head> | --diff <file>"; mode="diff"; file="$2" ;;
  -h|--help) sed -n '2,46p' "$0"; exit 0 ;;
  *) [ $# -eq 2 ] || die2 "usage: path-floor.sh <base> <head> | --diff <file>"; mode="git"; base="$1"; head="$2" ;;
esac

tmp="$(mktemp)" || die2 "could not create a temporary file"
trap 'rm -f "$tmp"' EXIT
if [ "$mode" = git ]; then
  # --no-renames lists a rename as a deletion and an addition, so both paths are judged.
  git diff --no-renames --name-only -z "$base...$head" -- >"$tmp" 2>/dev/null \
    || die2 "git could not list the paths of $base...$head (fetch both commits first)"
else
  [ -r "$file" ] && [ -f "$file" ] || die2 "cannot read the diff file $file"
  cat -- "$file" >"$tmp" || die2 "cannot read the diff file $file"
fi

X_MODE="$mode" X_IN="$tmp" python3 -I - <<'PY'
import os, re, sys

data = open(os.environ["X_IN"], "rb").read()

def unquote(name):
    """A path as git prints it in a diff header: a C-quoted name decoded, one trailing tab dropped."""
    if name.endswith("\t"):
        name = name[:-1]
    if len(name) >= 2 and name[0] == '"' and name[-1] == '"':
        out, i, body = bytearray(), 0, name[1:-1]
        esc = {"a": 7, "b": 8, "t": 9, "n": 10, "v": 11, "f": 12, "r": 13, '"': 34, "\\": 92}
        while i < len(body):
            if body[i] == "\\" and i + 1 < len(body):
                if body[i + 1] in esc:
                    out.append(esc[body[i + 1]]); i += 2; continue
                if re.fullmatch(r"[0-7]{3}", body[i + 1:i + 4]):
                    out.append(int(body[i + 1:i + 4], 8) & 0xFF); i += 4; continue
            out += body[i].encode("utf-8"); i += 1
        name = out.decode("utf-8", "replace")
    return name

def strip(name, side):
    return name[2:] if name.startswith(side) else name

QUOTED = r'"(?:[^"\\]|\\.)*"'

def header_paths(rest):
    """The two paths of a `diff --git` header, prefixes removed, or [] when they cannot be read."""
    m = (re.fullmatch("(%s) (%s)" % (QUOTED, QUOTED), rest) or re.fullmatch("(%s) (b/.*)" % QUOTED, rest)
         or re.fullmatch('(a/[^"]*) (%s)' % QUOTED, rest))
    if m:
        a, b = unquote(m.group(1)), unquote(m.group(2))
    else:
        half = (len(rest) - 5) // 2      # rest is "a/" + X + " b/" + X
        if len(rest) < 7 or len(rest) % 2 == 0 or rest[:2] != "a/" or rest[2 + half:5 + half] != " b/" \
                or rest[2:2 + half] != rest[5 + half:]:
            return []
        a, b = rest[:2 + half], rest[3 + half:]
    if not (a.startswith("a/") and b.startswith("b/")):
        return []
    return [a[2:], b[2:]]

paths = set()
if os.environ["X_MODE"] == "git":
    for p in data.decode("utf-8", "replace").split("\0"):
        if p:
            paths.add(p)
else:
    # Only \n ends a line, as in git. str.splitlines() also breaks on \f, \v, a lone \r, \x1c-\x1e,
    # U+0085 and U+2028/2029, so one of them inside a changed line would start a new line that can
    # read as a hunk header with a count the author chose, and hide every later path. A trailing \r
    # (a diff saved with CRLF) is dropped from each line; git quotes a name that ends in \r.
    lines = [ln[:-1] if ln.endswith("\r") else ln for ln in data.decode("utf-8", "replace").split("\n")]
    rem_old = rem_new = 0
    section_named = None   # None outside a `diff --git` section; else whether it named a path
    def close_section():
        if section_named is False:
            print("path-floor: a diff section named no path it could read, so the floor is unknown",
                  file=sys.stderr)
            sys.exit(2)
    for ln in lines:
        if rem_old > 0 or rem_new > 0:
            # Inside a hunk every line is content, even one that reads like a header.
            if ln.startswith("+"):
                rem_new -= 1
            elif ln.startswith("-"):
                rem_old -= 1
            elif not ln.startswith("\\"):
                rem_old -= 1; rem_new -= 1
            continue
        if ln.startswith("diff --git "):
            close_section()
            section_named = False
            # A mode change, an empty file or a binary file has no ---/+++ lines, so the header is
            # the only place it is named. Each side is C-quoted when git quotes it; an unquoted pair
            # `a/X b/X` is split in the middle, which holds when X itself contains " b/". A header
            # that fits none of these waits for ---/+++ or rename lines, and exit 2 when none come.
            for side in header_paths(ln[len("diff --git "):]):
                paths.add(side); section_named = True
            continue
        hit = None
        if ln.startswith("--- "):
            hit = strip(unquote(ln[4:]), "a/")
        elif ln.startswith("+++ "):
            hit = strip(unquote(ln[4:]), "b/")
        else:
            m = re.match(r"(rename|copy) (from|to) (.+)$", ln)
            if m:
                hit = unquote(m.group(3))
        if hit is not None:
            if hit != "/dev/null":
                paths.add(hit)
            if section_named is not None:
                section_named = True
            continue
        if ln.startswith("@@"):
            h = re.match(r"@@ -\d+(?:,(\d+))? \+\d+(?:,(\d+))? @@", ln, re.ASCII)
            if h:
                rem_old = int(h.group(1)) if h.group(1) is not None else 1
                rem_new = int(h.group(2)) if h.group(2) is not None else 1
    close_section()

CI_PREFIXES = (".github/workflows/", ".github/actions/", ".agents/skills/", ".claude/")
CODEOWNERS = {"codeowners", ".github/codeowners", "docs/codeowners"}
AUTH = re.compile(
    r"(?:^|[/._-])(auth|authn|authz|authentication|authorization|authorisation|oauth|oauth2|login|logout|"
    r"session|sessions|password|passwords|passwd|crypto|cryptography|cipher|ciphers|encrypt|encryption|"
    r"decrypt|jwt|saml|oidc|sso|rbac|acl|acls|permission|permissions|credential|credentials)(?=$|[/._-])")
MIGRATION_DIRS = {"migrations", "migration", "migrate", "alembic"}
SCHEMAS = {"schema.sql", "structure.sql", "schema.rb", "schema.prisma"}
MANIFESTS = {
    "package.json", "package-lock.json", "npm-shrinkwrap.json", "yarn.lock", "pnpm-lock.yaml",
    "pnpm-workspace.yaml", "bun.lock", "bun.lockb", "deno.json", "deno.jsonc", "deno.lock",
    "pyproject.toml", "poetry.lock", "uv.lock", "pipfile", "pipfile.lock", "setup.py", "setup.cfg",
    "go.mod", "go.sum", "go.work", "cargo.toml", "cargo.lock", "gemfile", "gemfile.lock",
    "composer.json", "composer.lock", "pom.xml", "build.gradle", "build.gradle.kts",
    "settings.gradle", "settings.gradle.kts", "gradle.lockfile", "packages.lock.json",
    "directory.packages.props", "mix.exs", "mix.lock", "package.swift", "package.resolved",
    "podfile", "podfile.lock", "pubspec.yaml", "pubspec.lock", "flake.lock", ".terraform.lock.hcl"}

def units(path):
    p = path.lower()
    base = p.rsplit("/", 1)[-1]
    parts = p.split("/")
    out = []
    if (p.startswith(CI_PREFIXES) or p in CODEOWNERS or p == ".mcp.json"
            or base in ("action.yml", "action.yaml", "dockerfile", "containerfile")
            or base.startswith(("dockerfile.", "containerfile.")) or base.endswith(".dockerfile")):
        out.append(("security", "max"))
    if AUTH.search(p):
        out.append(("security", "max"))
    if any(d in MIGRATION_DIRS for d in parts[:-1]) or base in SCHEMAS:
        out += [("security", "standard"), ("data-integrity", "standard")]
    if (base in MANIFESTS or re.fullmatch(r"requirements[^/]*\.(txt|in)", base)
            or base.endswith((".gemspec", ".csproj", ".fsproj", ".vbproj"))):
        out.append(("dependencies", "standard"))
    return out

rows = set()
for path in paths:
    for unit, effort in units(path):
        rows.add((unit, effort, path))
for unit, effort, path in sorted(rows):
    print("%s %s %s" % (unit, effort, path))
PY
