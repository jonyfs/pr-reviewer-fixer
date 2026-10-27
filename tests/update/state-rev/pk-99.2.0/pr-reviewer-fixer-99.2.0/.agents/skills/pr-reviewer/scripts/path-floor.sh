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
#   path-floor.sh <base> <head>     the paths of `git diff --no-renames --name-only -z <base>...<head>`
#                                   (a rename is a deletion and an addition, so its old path counts)
#   path-floor.sh --pr <n>          the pull request's file list from the GitHub API
#                                   (`gh api --paginate repos/{owner}/{repo}/pulls/<n>/files`: each
#                                   `filename`, and `previous_filename` for a rename); lint-report uses this
#   path-floor.sh --files <file>    a NUL-separated list of paths, as `git diff --name-only -z` prints it
#                                   (tests and offline use)
#
# The floor is read only from a structured list of paths, never from diff text. A unified diff is
# text the author shapes (a form feed, a coloured `gh pr diff`, a rename section), and three review
# passes of PR #29 found a way to hide a path from every parser of it that was tried.
#
# OUTPUT. One line per mandatory unit and path, sorted: `<unit> <effort> <path>`. The path is the
# rest of the line and may hold spaces. No output means no unit is mandatory. A renamed or deleted
# file counts by its old path as well as its new one: removing a workflow is a CI change too.
#
#   unit             effort    paths
#   security         max       .github/workflows/**, .github/actions/**, .github/scripts/** (what a
#                              workflow runs), action.yml or action.yaml in any directory, CODEOWNERS
#                              (root, .github/, docs/), .mcp.json, a Dockerfile or Containerfile (also
#                              Dockerfile.<x> and <x>.dockerfile): the files that run CI or an agent
#   security         max       CI outside GitHub, at the root: .gitlab-ci.yml, .gitlab/ci/**,
#                              .circleci/**, .buildkite/**, buildkite/**, buildkite.(yml|yaml|json),
#                              .woodpecker(.yml|.yaml|/**), .tekton/**, .travis.yml, azure-pipelines.yml,
#                              bitbucket-pipelines.yml, .drone(.yml|.yaml), cloudbuild.yaml, buildspec.yml,
#                              (.)appveyor(.yml|.yaml), codemagic.yaml, .cirrus.yml, .cirrus.star,
#                              .semaphore/**, .drone.jsonnet, .drone.star, bitrise.yml,
#                              .azure-pipelines/**, codefresh.yml, .codefresh/**, and a Jenkinsfile
#                              (or Jenkinsfile.<x>) in any directory. A CI config can load files from
#                              any path (GitLab `include: local:`, a Jenkinsfile `load`); those files
#                              are not summoned by name, and the change to the config that names them
#                              is, so the security unit reads what it loads.
#   security         max       agent directories at any depth: .claude/**, .codex/**, .opencode/**,
#                              .cursor/**, .gemini/**, .windsurf/**, and the skills/ folder of .agents,
#                              .roo, .cline, .kiro, .devin and .junie (every project skill folder
#                              install.sh writes), so pkg/.claude/x and apps/a/.roo/skills/x count
#   security         max       agent instructions: AGENTS.md, AGENTS.override.md, CLAUDE.md,
#                              CLAUDE.local.md, GEMINI.md in any directory, .github/copilot-instructions.md,
#                              .github/{instructions,agents,skills,prompts}/** (root only, where GitHub
#                              reads them), opencode.json(c), .cursorrules, .windsurfrules
#   security         max       authentication, authorisation and cryptography: a path segment or
#                              file stem such as auth, authenticate, authorize, oauth, login, signin,
#                              mfa, session, password, token, secret, crypto, cipher, hmac, signing,
#                              tls, cert, jwt, saml, oidc, rbac, acl, permission(s), credential(s),
#                              bcrypt (the AUTH pattern below has the full list), also as a camelCase
#                              or PascalCase word (AuthService.ts, jwtUtils.go)
#   security         standard  migrations (below)
#   data-integrity   standard  migrations: a directory named migrations, migration, migrate or
#                              alembic, or a schema file (schema.sql, structure.sql, schema.rb,
#                              schema.prisma)
#   security         standard  infrastructure and deployment (below): IAM, network and secret
#                              settings live there
#   reliability      standard  infrastructure and deployment: a directory named terraform, k8s,
#   operability      standard  kubernetes, helm, charts, kustomize, ansible, pulumi, cloudformation,
#                              infra or infrastructure; *.tf, *.tfvars, *.tf.json, *.hcl (not
#                              .terraform.lock.hcl), *.nomad; Chart.yaml, kustomization.y(a)ml,
#                              (docker-)compose*.y(a)ml, Pulumi(.<stack>).yaml, skaffold.yaml,
#                              serverless.y(a)ml, fly.toml, Procfile, values*.y(a)ml under charts/
#   privacy          standard  a path segment or word such as privacy, gdpr, lgpd, consent(ed|s|ing),
#                              pii, dsar, personal-data, data-subject, data-retention,
#                              anonymise(d)/anonymization, pseudonymise(d), redact(ed|ion|ing)
#   dependencies     standard  manifests and lockfiles (package.json, package-lock.json, yarn.lock,
#                              pnpm-lock.yaml, requirements*.txt, pyproject.toml, poetry.lock,
#                              uv.lock, Pipfile(.lock), go.mod, go.sum, Cargo.toml, Cargo.lock,
#                              Gemfile(.lock), *.gemspec, composer.json/.lock, pom.xml, build.gradle(.kts),
#                              gradle.lockfile, *.csproj, packages.lock.json, mix.exs/.lock,
#                              Package.swift/.resolved, Podfile(.lock), pubspec.yaml/.lock,
#                              deno.json/.lock, bun.lock(b), flake.lock)
#
# Names are compared case-insensitively, so `Codeowners` on a case-insensitive file system counts.
# The CI, agent and instruction classes are the ones push-guard.sh refuses for the fixer, plus action
# metadata and Dockerfiles. A project may add units in its own guide; nothing may remove one from this list.
#
# `review-cycle.sh lint-report` computes this floor for the report it checks and refuses a report
# whose `findings` block does not list each mandatory unit as run in its `mandatory_units:` field
# (references/report-contract.md). A unit with effort `max` must be listed with `effort: max`.
#
# EXIT. 0 when it read the whole list (with or without units). 2 when it could not: git failed; gh
# failed or answered something that is not the JSON it asked for (a coloured answer included); the
# API list is shorter or longer than the pull request's `changedFiles`, or that count is over 3000,
# the most files that endpoint returns; or the --files list is unreadable, holds an empty entry, or
# does not end with a NUL. It fails closed: no floor is never a guess.
set -u

die2() { echo "path-floor: $*" >&2; exit 2; }
USAGE="usage: path-floor.sh <base> <head> | --pr <n> | --files <file>"

mode="" base="" head="" file="" pr=""
case "${1:-}" in
  --files) [ $# -eq 2 ] || die2 "$USAGE"; mode="files"; file="$2" ;;
  --pr) [ $# -eq 2 ] || die2 "$USAGE"; mode="pr"; pr="$2"
        case "$pr" in ''|*[!0-9]*) die2 "--pr needs a pull request number; $USAGE" ;; esac ;;
  -h|--help) sed -n '2,94p' "$0"; exit 0 ;;
  -*) die2 "$USAGE" ;;
  *) [ $# -eq 2 ] || die2 "$USAGE"; mode="git"; base="$1"; head="$2" ;;
esac

tmp="$(mktemp)" && meta="$(mktemp)" || die2 "could not create a temporary file"
trap 'rm -f "$tmp" "$meta"' EXIT
case "$mode" in
  git)
    # --no-renames lists a rename as a deletion and an addition, so both paths are judged.
    git diff --no-renames --name-only -z "$base...$head" -- >"$tmp" 2>/dev/null \
      || die2 "git could not list the paths of $base...$head (fetch both commits first)" ;;
  files)
    [ -r "$file" ] && [ -f "$file" ] || die2 "cannot read the file list $file"
    cat -- "$file" >"$tmp" || die2 "cannot read the file list $file" ;;
  pr)
    # CLICOLOR_FORCE=1 makes gh colour JSON even into a pipe (NO_COLOR does not undo it), so both
    # calls run without it; any answer that still is not plain JSON fails the parse below.
    env -u CLICOLOR_FORCE -u GH_FORCE_TTY gh pr view "$pr" --json changedFiles >"$meta" 2>/dev/null \
      || die2 "gh could not read #$pr, so the floor is unknown"
    env -u CLICOLOR_FORCE -u GH_FORCE_TTY gh api --paginate "repos/{owner}/{repo}/pulls/$pr/files?per_page=100" >"$tmp" 2>/dev/null \
      || die2 "gh could not list the files of #$pr, so the floor is unknown" ;;
esac

X_MODE="$mode" X_IN="$tmp" X_META="$meta" python3 -I - <<'PY'
import json, os, re, sys

def fail(msg):
    print("path-floor: " + msg + ", so the floor is unknown", file=sys.stderr)
    sys.exit(2)

data = open(os.environ["X_IN"], "rb").read()
paths = set()
if os.environ["X_MODE"] in ("git", "files"):
    # `git diff --name-only -z` ends every name with a NUL. A list that does not (a newline-separated
    # one passed by mistake) would read as one long name and summon nothing.
    if data and not data.endswith(b"\0"):
        fail("the file list does not end with a NUL (write it as `git diff --name-only -z` does)")
    names = data[:-1].split(b"\0") if data else []
    if any(n == b"" for n in names):
        fail("the file list holds an empty entry")
    paths = {n.decode("utf-8", "replace") for n in names}
else:
    # `gh api --paginate` prints one JSON array per page, or one merged array: read them all.
    try:
        want = json.loads(open(os.environ["X_META"], "rb").read().decode("utf-8"))["changedFiles"]
        text, dec, i, entries = data.decode("utf-8"), json.JSONDecoder(), 0, []
        while True:
            while i < len(text) and text[i] in " \t\r\n":
                i += 1
            if i >= len(text):
                break
            page, i = dec.raw_decode(text, i)
            if not isinstance(page, list):
                raise ValueError("a page is not a list")
            entries += page
        for e in entries:
            if not isinstance(e, dict) or not isinstance(e.get("filename"), str) or not e["filename"]:
                raise ValueError("an entry has no filename")
            paths.add(e["filename"])
            # A rename carries its old path; a file that was not renamed has none (or a null).
            old = e.get("previous_filename")
            if old is not None:
                if not isinstance(old, str) or not old:
                    raise ValueError("an entry has an empty or non-string previous_filename")
                paths.add(old)
    except (ValueError, KeyError, TypeError, AttributeError, UnicodeDecodeError) as exc:
        fail("gh answered something that is not the pull request's file list (%s)" % exc)
    if not isinstance(want, int) or isinstance(want, bool):
        fail("gh gave no changedFiles count for the pull request")
    if want > 3000:
        fail("the pull request changes %d files and the files endpoint returns at most 3000" % want)
    if len(entries) != want:
        fail("the API listed %d files and the pull request changes %d (truncated, or the head moved)"
             % (len(entries), want))

CI_PREFIXES = (".github/workflows/", ".github/actions/", ".github/scripts/")
# CI outside GitHub Actions, at the root where each service reads it: what runs on every push.
OTHER_CI_PREFIXES = (".circleci/", ".buildkite/", "buildkite/", ".gitlab/ci/", ".woodpecker/", ".tekton/",
                     ".semaphore/", ".azure-pipelines/", ".codefresh/")
OTHER_CI_FILES = {".gitlab-ci.yml", ".gitlab-ci.yaml", ".travis.yml", "azure-pipelines.yml",
                  "azure-pipelines.yaml", "bitbucket-pipelines.yml", ".drone.yml", ".drone.yaml",
                  ".woodpecker.yml", ".woodpecker.yaml", "buildkite.yml", "buildkite.yaml", "buildkite.json",
                  "cloudbuild.yaml", "cloudbuild.yml", "buildspec.yml", "buildspec.yaml", "appveyor.yml",
                  ".appveyor.yml", "appveyor.yaml", ".appveyor.yaml", "codemagic.yaml", ".cirrus.yml",
                  ".cirrus.star", ".drone.jsonnet", ".drone.star", "bitrise.yml", "codefresh.yml"}
# Agent directories, matched at any depth: a harness also reads them in a subdirectory of a monorepo
# (a nested .cursor/rules, .claude/skills or .agents/skills). AGENT_DIRS count whole; SKILL_PARENTS
# count through their skills/ folder, which is where install.sh puts these skills for each harness
# (its table and README's install table; a test checks every one of them).
AGENT_DIRS = {".claude", ".codex", ".opencode", ".cursor", ".gemini", ".windsurf"}
SKILL_PARENTS = {".agents", ".roo", ".cline", ".kiro", ".devin", ".junie"}
# Files and directories an agent reads as instructions (references/harness-matrix.md lists who reads
# which): a change there changes what an agent obeys, so it is agent configuration like .claude/.
# GitHub reads .github/ only at the root.
INSTRUCTION_PREFIXES = (".github/instructions/", ".github/agents/", ".github/skills/", ".github/prompts/")
INSTRUCTION_FILES = {".github/copilot-instructions.md", "opencode.json", "opencode.jsonc", ".cursorrules",
                     ".windsurfrules"}
INSTRUCTION_NAMES = {"agents.md", "agents.override.md", "claude.md", "claude.local.md", "gemini.md"}
CODEOWNERS = {"codeowners", ".github/codeowners", "docs/codeowners"}
# Auth and crypto words, matched as whole path components. The broad ones (token, secret, signature,
# cert, tls) also catch paths that are not about security, such as src/lexer/token.rs or
# docs/signature.md. That is on purpose: a floor that over-includes costs review effort, one that
# misses costs safety. Do not trim a word to cut those extra hits.
AUTH = re.compile(
    r"(?:^|[/._-])(auth|authn|authz|authentication|authorization|authorisation|oauth|oauth2|login|logout|"
    r"authenticate|authenticated|authenticator|authenticators|authorize|authorise|authorized|authorised|"
    r"authorizer|authorizers|signin|signup|sign[-_]in|sign[-_]up|log[-_]in|logon|mfa|totp|otp|webauthn|passkey|passkeys|csrf|"
    r"session|sessions|password|passwords|passwd|crypto|cryptography|cipher|ciphers|encrypt|encryption|"
    r"decrypt|jwt|jwk|jwks|saml|oidc|sso|rbac|abac|acl|acls|permission|permissions|credential|credentials|"
    r"token|tokens|secret|secrets|apikey|apikeys|hmac|signing|signature|signatures|tls|ssl|x509|pki|cert|"
    r"certs|certificate|certificates|keystore|keychain|kms|bcrypt|scrypt|argon2|pbkdf2)(?=$|[/._-])")
MIGRATION_DIRS = {"migrations", "migration", "migrate", "alembic"}
# Infrastructure and deployment: what changes how the service runs, scales and recovers.
INFRA_DIRS = {"terraform", "k8s", "kubernetes", "helm", "charts", "kustomize", "ansible", "pulumi",
              "cloudformation", "infra", "infrastructure"}
INFRA_NAMES = {"chart.yaml", "kustomization.yaml", "kustomization.yml", "compose.yaml", "compose.yml",
               "pulumi.yaml", "skaffold.yaml", "serverless.yml", "serverless.yaml", "fly.toml", "procfile"}
PRIVACY = re.compile(
    r"(?:^|[/._-])(privacy|gdpr|lgpd|ccpa|consent|consents|pii|dsar|personal[-_]data|personaldata|"
    r"consented|consenting|data[-_]subject|data[-_]retention|anonymi[sz](?:e|ed|es|ing|ation)|"
    r"pseudonymi[sz](?:e|ed|es|ing|ation)|redact|redacted|redacting|redaction)(?=$|[/._-])")
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

def agent_dir(dirs):
    """True when a directory of the path is an agent directory, or a skill parent's skills/ folder."""
    return any(d in AGENT_DIRS or (d in SKILL_PARENTS and dirs[i + 1:i + 2] == ["skills"])
               for i, d in enumerate(dirs))

def units(path):
    p = path.lower()
    base = p.rsplit("/", 1)[-1]
    parts = p.split("/")
    out = []
    if (p.startswith(CI_PREFIXES) or p.startswith(OTHER_CI_PREFIXES) or p in OTHER_CI_FILES
            or base == "jenkinsfile" or base.startswith("jenkinsfile.") or agent_dir(parts[:-1]) or p in CODEOWNERS or p == ".mcp.json"
            or p.startswith(INSTRUCTION_PREFIXES) or p in INSTRUCTION_FILES or base in INSTRUCTION_NAMES
            or base in ("action.yml", "action.yaml", "dockerfile", "containerfile")
            or base.startswith(("dockerfile.", "containerfile.")) or base.endswith(".dockerfile")):
        out.append(("security", "max"))
    # camelCase and PascalCase name the same words without a delimiter (AuthService.ts,
    # jwtUtils.go, OAuth2Client.ts), so the original-case path is also read with its humps split.
    humps = re.sub(r"(?<=[a-z0-9])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])|(?<=[A-Za-z])(?=[0-9])", "-", path).lower()
    if AUTH.search(p) or AUTH.search(humps):
        out.append(("security", "max"))
    if any(d in MIGRATION_DIRS for d in parts[:-1]) or base in SCHEMAS:
        out += [("security", "standard"), ("data-integrity", "standard")]
    if (any(d in INFRA_DIRS for d in parts[:-1]) or base in INFRA_NAMES
            or base.endswith((".tf", ".tfvars", ".tf.json", ".nomad")) or (base.endswith(".hcl") and base != ".terraform.lock.hcl")
            or re.fullmatch(r"(?:docker-)?compose[^/]*\.ya?ml", base) or re.fullmatch(r"pulumi\.[^/]+\.yaml", base)
            or re.fullmatch(r"values[^/]*\.ya?ml", base) and "charts" in parts[:-1]):
        out += [("security", "standard"), ("reliability", "standard"), ("operability", "standard")]
    if PRIVACY.search(p) or PRIVACY.search(humps):
        out.append(("privacy", "standard"))
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
